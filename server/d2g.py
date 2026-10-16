#!/usr/bin/env python3
"""d2g — orchestrator + receiver for disk transfers into Cinder volumes (stage 1, one VM).

The server runs inside the target cloud. It creates a volume per transfer, attaches it to
itself and accepts the disk of a source VM over HTTPS (mTLS) in independent parts, written
straight into the volume at their offsets. A journal "part -> MD5" makes transfers resumable
and lets the agent send only changed parts on the next pass (delta). Afterwards the volume is
detached, made bootable and a VM is created from it.

Python standard library only (Ubuntu 24.04 / Python 3.12). openssl is used for the CA.

  d2g init --name rx01.d2g --ip 10.20.20.8 --ip 138.16.205.159   # CA, server cert, database
  d2g serve                                                       # HTTPS API (systemd)
  d2g agent add NAME                                              # one-time enrollment token
  d2g agent list | d2g agent revoke NAME
  d2g job new AGENT [--type ceph-ssd]                             # volume -> attach -> job
  d2g job list | d2g job show JOB
  d2g job finish JOB --flavor F --network N [--sg S]... [--key K] [--name VM]
  d2g job delete JOB [--keep-volume]

Cloud credentials: /etc/d2g/openrc (OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_ID,
OS_USER_DOMAIN_NAME, OS_REGION_NAME). They never leave this VM.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import socketserver
import sqlite3
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

VAR = os.environ.get("D2G_VAR", "/var/lib/d2g")
ETC = os.environ.get("D2G_ETC", "/etc/d2g")
PKI = os.path.join(VAR, "pki")
DB = os.path.join(VAR, "d2g.db")
CONF = os.path.join(ETC, "d2g.json")
OPENRC = os.path.join(ETC, "openrc")
CHUNK = 4 << 20
TOKEN_TTL = 3600
DEFAULT_PART = 64 << 20


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def die(msg, code=1):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def now():
    return int(time.time())


# --- database --------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
  name TEXT PRIMARY KEY, token_hash TEXT, token_exp INTEGER, enrolled_at INTEGER,
  cert_serial TEXT, revoked INTEGER DEFAULT 0, inventory TEXT, last_seen INTEGER, peer TEXT);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, agent TEXT, volume_id TEXT, serial TEXT, az TEXT,
  disk_bytes INTEGER, part_bytes INTEGER, state TEXT, fresh INTEGER DEFAULT 1,
  created INTEGER, pass_no INTEGER DEFAULT 0, pass_start INTEGER, pass_snapshot TEXT,
  synced_at INTEGER, synced_snapshot TEXT, server_id TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS parts (
  job TEXT, n INTEGER, md5 TEXT, ts INTEGER, PRIMARY KEY (job, n));
CREATE TABLE IF NOT EXISTS events (ts INTEGER, who TEXT, what TEXT);
"""
_tls = threading.local()


def db():
    c = getattr(_tls, "db", None)
    if c is None:
        c = sqlite3.connect(DB, timeout=30, isolation_level=None)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA busy_timeout=30000")
        _tls.db = c
    return c


def event(who, what):
    db().execute("INSERT INTO events VALUES (?,?,?)", (now(), who, what))


def conf():
    with open(CONF) as f:
        return json.load(f)


# --- PKI (openssl) -----------------------------------------------------------------------
def sh(*cmd, inp=None):
    r = subprocess.run(cmd, input=inp, capture_output=True)
    if r.returncode:
        raise RuntimeError(f"{cmd[0]} {cmd[1]}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def pubkey_pin(certfile):
    pub = sh("openssl", "x509", "-in", certfile, "-noout", "-pubkey")
    der = sh("openssl", "pkey", "-pubin", "-outform", "DER", inp=pub)
    return "sha256//" + base64.b64encode(hashlib.sha256(der).digest()).decode()


def cmd_init(a):
    os.makedirs(PKI, mode=0o700, exist_ok=True)
    os.makedirs(ETC, mode=0o755, exist_ok=True)
    ca_key, ca_crt = f"{PKI}/ca.key", f"{PKI}/ca.crt"
    if not os.path.exists(ca_crt):
        sh("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
           "-keyout", ca_key, "-out", ca_crt, "-days", "3650", "-subj", f"/CN=d2g CA {a.name}",
           "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        os.chmod(ca_key, 0o600)
    san = ",".join([f"DNS:{a.name}"] + [f"IP:{ip}" for ip in a.ip])
    with tempfile.TemporaryDirectory() as td:
        ext = f"{td}/ext"
        with open(ext, "w") as f:
            f.write(f"subjectAltName={san}\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n")
        sh("openssl", "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
           "-keyout", f"{PKI}/server.key", "-out", f"{td}/csr", "-subj", f"/CN={a.name}")
        sh("openssl", "x509", "-req", "-in", f"{td}/csr", "-CA", ca_crt, "-CAkey", ca_key, "-set_serial",
           "0x" + secrets.token_hex(16), "-days", "825", "-extfile", ext, "-out", f"{PKI}/server.crt")
    os.chmod(f"{PKI}/server.key", 0o600)
    c = {"name": a.name, "ips": a.ip, "port": a.port, "part_bytes": a.part_mb << 20,
         "max_inflight": a.max_inflight, "max_per_job": a.max_per_job}
    with open(CONF, "w") as f:
        json.dump(c, f, indent=1)
    db().executescript(SCHEMA)
    print(f"server name {a.name}, pin {pubkey_pin(PKI + '/server.crt')}")


def sign_csr(name, csr_pem):
    with tempfile.TemporaryDirectory() as td:
        with open(f"{td}/csr", "w") as f:
            f.write(csr_pem)
        subj = sh("openssl", "req", "-in", f"{td}/csr", "-noout", "-subject", "-nameopt", "multiline").decode()
        cn = [l.split("=", 1)[1].strip() for l in subj.splitlines() if l.strip().startswith("commonName")]
        if cn != [name]:
            raise ValueError(f"CSR common name {cn} != agent name {name}")
        sh("openssl", "req", "-in", f"{td}/csr", "-noout", "-verify")
        with open(f"{td}/ext", "w") as f:
            f.write("extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n")
        serial = secrets.token_hex(16)
        sh("openssl", "x509", "-req", "-in", f"{td}/csr", "-CA", f"{PKI}/ca.crt", "-CAkey", f"{PKI}/ca.key",
           "-set_serial", "0x" + serial, "-days", "365", "-extfile", f"{td}/ext", "-out", f"{td}/crt")
        with open(f"{td}/crt") as f:
            return serial, f.read()


# --- OpenStack (REST, no client libraries) --------------------------------------------------
class Cloud:
    def __init__(self):
        # openrc is a shell file (quoting, $'..' escapes): let bash parse it
        out = subprocess.run(["bash", "-c", 'set -a; . "$1" >/dev/null; env -0', "_", OPENRC],
                             capture_output=True, check=True).stdout.decode()
        self.env = dict(x.split("=", 1) for x in out.split("\0") if x.startswith("OS_"))
        self.token = None
        self.auth()

    def auth(self):
        e = self.env
        body = {"auth": {"identity": {"methods": ["password"], "password": {"user": {
            "name": e["OS_USERNAME"], "password": e["OS_PASSWORD"],
            "domain": {"name": e.get("OS_USER_DOMAIN_NAME", "Users")}}}},
            "scope": {"project": {"id": e["OS_PROJECT_ID"]}}}}
        req = urllib.request.Request(e["OS_AUTH_URL"].rstrip("/") + "/auth/tokens", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            self.token = r.headers["X-Subject-Token"]
            cat = json.load(r)["token"]["catalog"]
        region = e.get("OS_REGION_NAME")
        self.ep = {}
        for s in cat:
            for x in s["endpoints"]:
                if x["interface"] == "public" and (not region or x.get("region") == region):
                    self.ep[s["type"]] = x["url"].rstrip("/")

    def call(self, method, svc, path, body=None, ok=(200, 201, 202, 204)):
        url = self.ep[svc] + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data, {"X-Auth-Token": self.token, "Content-Type": "application/json",
                                                 "Accept": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as ex:
            msg = ex.read().decode(errors="replace")[:400]
            raise RuntimeError(f"{method} {svc}{path}: HTTP {ex.code} {msg}") from None

    def vol(self, vid):
        return self.call("GET", "volumev3", f"/volumes/{vid}")["volume"]

    def wait_vol(self, vid, want, timeout=600):
        t = time.time()
        while time.time() - t < timeout:
            st = self.vol(vid)["status"]
            if st == want:
                return
            if st.startswith("error"):
                raise RuntimeError(f"volume {vid}: {st}")
            time.sleep(3)
        raise RuntimeError(f"volume {vid}: timeout waiting for {want}")


def metadata():
    with urllib.request.urlopen("http://169.254.169.254/openstack/latest/meta_data.json", timeout=10) as r:
        return json.load(r)


def dev_of(serial):
    return f"/dev/disk/by-id/virtio-{serial}"


def check_target(path):
    """The target must be a whole, unmounted, unused virtio disk (never our system disk)."""
    real = os.path.realpath(path)
    if not stat.S_ISBLK(os.stat(real).st_mode):
        raise RuntimeError(f"{path} is not a block device")
    name = os.path.basename(real)
    if os.path.exists(f"/sys/class/block/{name}/partition"):
        raise RuntimeError(f"{real} is a partition")
    out = subprocess.run(["lsblk", "-nro", "MOUNTPOINTS", real], capture_output=True, text=True).stdout
    if out.strip():
        raise RuntimeError(f"{real} or its partitions are mounted")
    if os.listdir(f"/sys/class/block/{name}/holders"):
        raise RuntimeError(f"{real} is in use (holders)")
    return real


# --- HTTPS API -------------------------------------------------------------------------------
class Limits:
    def __init__(self, total, per_job):
        self.total = threading.BoundedSemaphore(total)
        self.per_job_n = per_job
        self.per_job = {}
        self.lock = threading.Lock()

    def job(self, jid):
        with self.lock:
            if jid not in self.per_job:
                self.per_job[jid] = threading.BoundedSemaphore(self.per_job_n)
            return self.per_job[jid]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "d2g"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, obj=None, headers=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        while n > 0:
            b = self.rfile.read(min(n, CHUNK))
            if not b:
                break
            n -= len(b)

    def body_json(self, limit=8 << 20):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def agent(self):
        """Agent name from the verified client certificate, or None."""
        cert = self.connection.getpeercert()
        if not cert:
            return None
        cn = [v for rdn in cert.get("subject", ()) for k, v in rdn if k == "commonName"]
        if len(cn) != 1:
            return None
        row = db().execute("SELECT revoked, cert_serial FROM agents WHERE name=?", (cn[0],)).fetchone()
        if not row or row["revoked"] or row["cert_serial"] is None:
            return None
        if cert.get("serialNumber", "").lower().lstrip("0") != row["cert_serial"].lower().lstrip("0"):
            return None   # an older certificate of this name (re-enrolled)
        db().execute("UPDATE agents SET last_seen=?, peer=? WHERE name=?", (now(), self.client_address[0], cn[0]))
        return cn[0]

    def job_of(self, name, jid):
        j = db().execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        if not j or j["agent"] != name:
            return None
        return j

    def route(self, method):
        p = self.path.split("?")[0].strip("/").split("/")
        try:
            if p[:2] == ["v1", "ca"] and method == "GET":
                with open(f"{PKI}/ca.crt") as f:
                    return self.reply(200, {"ca": f.read()})
            if p[:2] == ["v1", "enroll"] and method == "POST":
                return self.enroll()
            name = self.agent()
            if not name:
                self.drain()
                return self.reply(401, {"error": "client certificate required"})
            if p[:3] == ["v1", "agent", "job"] and method == "GET":
                j = db().execute("SELECT * FROM jobs WHERE agent=? AND state NOT IN ('finished','deleted') "
                                 "ORDER BY created DESC LIMIT 1", (name,)).fetchone()
                if not j:
                    return self.reply(404, {"error": "no job for this agent"})
                return self.reply(200, {k: j[k] for k in ("id", "disk_bytes", "part_bytes", "state", "fresh", "pass_no")})
            if len(p) >= 3 and p[:2] == ["v1", "jobs"]:
                j = self.job_of(name, p[2])
                if not j:
                    self.drain()
                    return self.reply(404, {"error": "no such job"})
                if j["state"] in ("finished", "deleted", "finishing"):
                    self.drain()
                    return self.reply(409, {"error": f"job is {j['state']}"})
                tail = p[3:]
                if tail == ["parts"] and method == "GET":
                    rows = db().execute("SELECT n, md5 FROM parts WHERE job=?", (j["id"],)).fetchall()
                    return self.reply(200, {"part_bytes": j["part_bytes"], "parts": {str(r["n"]): r["md5"] for r in rows}})
                if len(tail) == 2 and tail[0] == "parts" and method == "PUT":
                    return self.put_part(j, int(tail[1]))
                if tail == ["start"] and method == "POST":
                    b = self.body_json()
                    db().execute("UPDATE jobs SET state='receiving', pass_start=?, pass_snapshot=? WHERE id=?",
                                 (now(), b.get("snapshot_time"), j["id"]))
                    event(name, f"job {j['id']}: pass {j['pass_no'] + 1} started, snapshot {b.get('snapshot_time')}")
                    return self.reply(200, {})
                if tail == ["complete"] and method == "POST":
                    return self.complete(j, self.body_json())
            self.drain()
            return self.reply(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError, TimeoutError, ssl.SSLError):
            self.close_connection = True
        except Exception as ex:  # noqa: BLE001
            log(f"{self.client_address[0]} {method} {self.path}: {ex}")
            try:
                self.reply(500, {"error": str(ex)})
            except Exception:  # noqa: BLE001
                pass
            self.close_connection = True

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def enroll(self):
        b = self.body_json()
        name, token = b.get("name", ""), b.get("token", "")
        row = db().execute("SELECT * FROM agents WHERE name=?", (name,)).fetchone()
        h = hashlib.sha256(token.encode()).hexdigest()
        if not row or not row["token_hash"] or not secrets.compare_digest(row["token_hash"], h) or row["token_exp"] < now():
            log(f"enroll {name!r} from {self.client_address[0]}: bad or expired token")
            return self.reply(403, {"error": "bad or expired token"})
        serial, crt = sign_csr(name, b.get("csr", ""))
        db().execute("UPDATE agents SET token_hash=NULL, token_exp=NULL, enrolled_at=?, cert_serial=?, revoked=0, "
                     "inventory=?, last_seen=?, peer=? WHERE name=?",
                     (now(), serial, json.dumps(b.get("inventory") or {}), now(), self.client_address[0], name))
        event(name, f"enrolled from {self.client_address[0]}")
        log(f"agent {name} enrolled from {self.client_address[0]}")
        return self.reply(200, {"cert": crt})

    def put_part(self, j, n):
        lim = self.server.limits
        part, disk = j["part_bytes"], j["disk_bytes"]
        nparts = (disk + part - 1) // part
        if not 1 <= n <= nparts:
            self.drain()
            return self.reply(400, {"error": f"part {n} out of 1..{nparts}"})
        off = (n - 1) * part
        length = min(part, disk - off)
        zero = self.headers.get("X-D2G-Zero") == "1"
        clen = int(self.headers.get("Content-Length") or 0)
        want = self.headers.get("Content-MD5", "")
        if (zero and clen) or (not zero and clen != length) or (not zero and not want):
            self.drain()
            return self.reply(400, {"error": f"part {n}: need Content-Length {length} and Content-MD5, or X-D2G-Zero"})
        jsem = lim.job(j["id"])
        if not lim.total.acquire(blocking=False):
            self.drain()
            return self.reply(503, {"error": "busy"}, {"Retry-After": "5"})
        if not jsem.acquire(blocking=False):
            lim.total.release()
            self.drain()
            return self.reply(503, {"error": "job busy"}, {"Retry-After": "5"})
        try:
            dev = check_target(dev_of(j["serial"]))
            fd = os.open(dev, os.O_WRONLY)
            try:
                if zero:
                    zmd5 = hashlib.md5(bytes(length)).hexdigest()
                    known = db().execute("SELECT md5 FROM parts WHERE job=? AND n=?", (j["id"], n)).fetchone()
                    # a new volume reads as zeros: a zero part that was never written needs no write
                    if j["fresh"] and not known:
                        pass
                    else:
                        z, done = bytes(CHUNK), 0
                        while done < length:
                            done += os.pwrite(fd, z[:min(CHUNK, length - done)], off + done)
                        os.fdatasync(fd)
                    got = zmd5
                else:
                    m, done = hashlib.md5(), 0
                    while done < length:
                        b = self.rfile.read(min(CHUNK, length - done))
                        if not b:
                            raise ConnectionResetError("short body")
                        m.update(b)
                        w = 0
                        while w < len(b):
                            w += os.pwrite(fd, b[w:], off + done + w)
                        done += len(b)
                    os.fdatasync(fd)
                    if base64.b64encode(m.digest()).decode() != want:
                        # the bytes on the volume are wrong now: forget the part so it is sent again
                        db().execute("DELETE FROM parts WHERE job=? AND n=?", (j["id"], n))
                        return self.reply(400, {"error": f"part {n}: MD5 mismatch"})
                    got = m.hexdigest()
            finally:
                os.close(fd)
            db().execute("INSERT OR REPLACE INTO parts VALUES (?,?,?,?)", (j["id"], n, got, now()))
            return self.reply(200, {"n": n, "md5": got})
        finally:
            jsem.release()
            lim.total.release()

    def complete(self, j, b):
        md5s = b.get("part_md5") or []
        nparts = (j["disk_bytes"] + j["part_bytes"] - 1) // j["part_bytes"]
        if len(md5s) != nparts:
            return self.reply(400, {"error": f"{len(md5s)} MD5s, job has {nparts} parts"})
        have = {r["n"]: r["md5"] for r in db().execute("SELECT n, md5 FROM parts WHERE job=?", (j["id"],))}
        bad = [i + 1 for i, h in enumerate(md5s) if have.get(i + 1) != h]
        if bad:
            return self.reply(409, {"error": "parts missing or different", "parts": bad[:1000], "count": len(bad)})
        db().execute("UPDATE jobs SET state='synced', fresh=0, pass_no=pass_no+1, synced_at=?, synced_snapshot=? WHERE id=?",
                     (now(), b.get("snapshot_time"), j["id"]))
        event(j["agent"], f"job {j['id']}: pass {j['pass_no'] + 1} complete, snapshot {b.get('snapshot_time')}, "
                          f"sent {b.get('sent')} of {nparts} parts")
        log(f"job {j['id']} synced (pass {j['pass_no'] + 1}, snapshot {b.get('snapshot_time')}, sent {b.get('sent')}/{nparts})")
        return self.reply(200, {"state": "synced"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def finish_request(self, request, client_address):
        # TLS handshake in the per-connection thread, so a slow client does not block accept()
        try:
            request.settimeout(120)
            tls = self.ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError) as ex:
            log(f"{client_address[0]}: TLS handshake failed: {ex}")
            return
        try:
            self.RequestHandlerClass(tls, client_address, self)
        finally:
            try:
                tls.close()
            except OSError:
                pass


def cmd_serve(a):
    c = conf()
    db().executescript(SCHEMA)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(f"{PKI}/server.crt", f"{PKI}/server.key")
    ctx.load_verify_locations(f"{PKI}/ca.crt")
    ctx.verify_mode = ssl.CERT_OPTIONAL   # enrollment and the CA download come without a client cert
    srv = Server(("0.0.0.0", c["port"]), Handler)
    srv.ctx = ctx
    srv.limits = Limits(c["max_inflight"], c["max_per_job"])
    log(f"d2g serving {c['name']} on :{c['port']} (inflight {c['max_inflight']}, per job {c['max_per_job']})")
    srv.serve_forever()


# --- CLI: agents ------------------------------------------------------------------------------
def cmd_agent(a):
    d = db()
    if a.op == "add":
        tok = secrets.token_urlsafe(24)
        d.execute("INSERT INTO agents (name) VALUES (?) ON CONFLICT(name) DO NOTHING", (a.name,))
        d.execute("UPDATE agents SET token_hash=?, token_exp=? WHERE name=?",
                  (hashlib.sha256(tok.encode()).hexdigest(), now() + TOKEN_TTL, a.name))
        event("admin", f"agent {a.name}: enrollment token issued")
        c = conf()
        pin = pubkey_pin(PKI + "/server.crt")
        print(f"# token is valid for {TOKEN_TTL // 60} min and can be used once; on the source VM:")
        for ip in c["ips"]:
            print(f"sudo disk2rx --enroll --name {a.name} --server {c['name']} --connect {ip} --pin '{pin}' --token {tok}")
    elif a.op == "list":
        for r in d.execute("SELECT * FROM agents ORDER BY name"):
            inv = json.loads(r["inventory"] or "{}")
            st = "revoked" if r["revoked"] else ("enrolled" if r["cert_serial"] else "token issued")
            seen = time.strftime("%d.%m %H:%M", time.localtime(r["last_seen"])) if r["last_seen"] else "-"
            print(f"{r['name']:<16} {st:<12} seen {seen} from {r['peer'] or '-':<16} "
                  f"{inv.get('os', '')} {inv.get('kernel', '')} disk {int(inv.get('disk_bytes', 0)) / 2**30:.1f} GiB")
    elif a.op == "revoke":
        d.execute("UPDATE agents SET revoked=1, token_hash=NULL WHERE name=?", (a.name,))
        event("admin", f"agent {a.name}: revoked")
        print(f"{a.name}: revoked")


# --- CLI: jobs -------------------------------------------------------------------------------
def job_line(j):
    part, disk = j["part_bytes"], j["disk_bytes"]
    nparts = (disk + part - 1) // part
    total = db().execute("SELECT count(*) FROM parts WHERE job=?", (j["id"],)).fetchone()[0]
    since = j["pass_start"] or 0
    cur = db().execute("SELECT count(*), min(ts), max(ts) FROM parts WHERE job=? AND ts>=?", (j["id"], since)).fetchone()
    rate = ""
    if cur[0] and cur[2] and cur[2] > cur[1]:
        rate = f", pass {cur[0]} parts, ~{cur[0] * part / 2**20 / (cur[2] - since or 1):.0f} MiB/s"
    synced = time.strftime("%d.%m %H:%M:%S", time.localtime(j["synced_at"])) if j["synced_at"] else "-"
    return (f"{j['id']}  {j['agent']:<14} {j['state']:<10} {total}/{nparts} parts{rate}  "
            f"passes {j['pass_no']}, synced {synced} (snapshot {j['synced_snapshot'] or '-'})  vol {j['volume_id']}")


def cmd_job(a):
    d = db()
    if a.op == "list":
        for j in d.execute("SELECT * FROM jobs WHERE state!='deleted' ORDER BY created"):
            print(job_line(j))
        return
    if a.op == "show":
        j = d.execute("SELECT * FROM jobs WHERE id=?", (a.job,)).fetchone() or die("no such job")
        print(job_line(j))
        for e in d.execute("SELECT * FROM events WHERE what LIKE ? ORDER BY ts", (f"%{a.job}%",)):
            print(" ", time.strftime("%d.%m %H:%M:%S", time.localtime(e["ts"])), e["who"], e["what"])
        return
    cl = Cloud()
    md = metadata()
    if a.op == "new":
        ag = d.execute("SELECT * FROM agents WHERE name=?", (a.agent,)).fetchone()
        if not ag or not ag["cert_serial"] or ag["revoked"]:
            die(f"agent {a.agent} is not enrolled")
        if d.execute("SELECT 1 FROM jobs WHERE agent=? AND state NOT IN ('finished','deleted')", (a.agent,)).fetchone():
            die(f"agent {a.agent} already has an open job")
        inv = json.loads(ag["inventory"] or "{}")
        disk = int(inv.get("disk_bytes") or 0) or die("agent did not report its disk size")
        gb = max(a.size_gb or 0, (disk + 2**30 - 1) // 2**30)
        jid = "j" + secrets.token_hex(4)
        v = cl.call("POST", "volumev3", "/volumes", {"volume": {
            "size": gb, "volume_type": a.type, "availability_zone": md["availability_zone"],
            "name": f"d2g-{a.agent}-{jid}", "description": f"d2g job {jid} for {a.agent}",
            "metadata": {"d2g_job": jid, "d2g_agent": a.agent}}})["volume"]
        log(f"volume {v['id']} {gb} GB {a.type} in {md['availability_zone']}")
        cl.wait_vol(v["id"], "available")
        cl.call("POST", "compute", f"/servers/{md['uuid']}/os-volume_attachments", {"volumeAttachment": {"volumeId": v["id"]}})
        cl.wait_vol(v["id"], "in-use")
        serial = v["id"][:20]
        for _ in range(60):
            if os.path.exists(dev_of(serial)):
                break
            time.sleep(1)
        real = check_target(dev_of(serial))
        cfg = conf()
        d.execute("INSERT INTO jobs (id, agent, volume_id, serial, az, disk_bytes, part_bytes, state, fresh, created) "
                  "VALUES (?,?,?,?,?,?,?,?,1,?)", (jid, a.agent, v["id"], serial, md["availability_zone"], disk,
                                                   a.part_mb << 20 if a.part_mb else cfg["part_bytes"], "ready", now()))
        event("admin", f"job {jid}: volume {v['id']} {gb} GB {a.type} attached as {real}")
        print(f"job {jid}: agent {a.agent}, volume {v['id']} -> {real}; on the source VM: sudo disk2rx")
    elif a.op == "finish":
        j = d.execute("SELECT * FROM jobs WHERE id=?", (a.job,)).fetchone() or die("no such job")
        if j["state"] != "synced" and not a.force:
            die(f"job is {j['state']}, not synced (use --force to build from whatever is on the volume)")
        d.execute("UPDATE jobs SET state='finishing' WHERE id=?", (j["id"],))
        inv = json.loads(d.execute("SELECT inventory FROM agents WHERE name=?", (j["agent"],)).fetchone()[0] or "{}")
        vid = j["volume_id"]
        att = [x for x in cl.vol(vid).get("attachments", []) if x.get("server_id") == md["uuid"]]
        if att:
            subprocess.run(["sync"])
            cl.call("DELETE", "compute", f"/servers/{md['uuid']}/os-volume_attachments/{vid}")
            cl.wait_vol(vid, "available")
        log(f"volume {vid} detached")
        props = {"os_type": "linux", "hw_vif_model": "virtio"}
        props.update({k: str(v) for k, v in (inv.get("props") or {}).items()})
        cl.call("POST", "volumev3", f"/volumes/{vid}/action", {"os-set_bootable": {"bootable": True}})
        cl.call("POST", "volumev3", f"/volumes/{vid}/action", {"os-set_image_metadata": {"metadata": props}})
        flv = [f for f in cl.call("GET", "compute", "/flavors")["flavors"] if f["name"] == a.flavor or f["id"] == a.flavor]
        flv or die(f"no flavor {a.flavor}")
        nets = cl.call("GET", "network", f"/v2.0/networks?name={urllib.request.quote(a.network)}")["networks"]
        net = nets[0]["id"] if nets else a.network
        name = a.name or f"{j['agent']}-d2g"
        srv = {"name": name, "flavorRef": flv[0]["id"], "availability_zone": j["az"], "networks": [{"uuid": net}],
               "block_device_mapping_v2": [{"uuid": vid, "source_type": "volume", "destination_type": "volume",
                                            "boot_index": 0, "delete_on_termination": False}],
               "security_groups": [{"name": s} for s in (a.sg or ["default"])]}
        if a.key:
            srv["key_name"] = a.key
        sid = cl.call("POST", "compute", "/servers", {"server": srv})["server"]["id"]
        log(f"server {name} {sid} created, waiting for ACTIVE")
        for _ in range(200):
            s = cl.call("GET", "compute", f"/servers/{sid}")["server"]
            if s["status"] in ("ACTIVE", "ERROR"):
                break
            time.sleep(3)
        if s["status"] != "ACTIVE":
            d.execute("UPDATE jobs SET state='synced', server_id=? WHERE id=?", (sid, j["id"]))
            die(f"server {sid}: {s['status']} {s.get('fault', {}).get('message', '')}")
        ips = [x["addr"] for n in s.get("addresses", {}).values() for x in n]
        d.execute("UPDATE jobs SET state='finished', server_id=? WHERE id=?", (sid, j["id"]))
        event("admin", f"job {j['id']}: VM {name} {sid} created from volume {vid}, {ips}")
        print(f"VM {name} {sid} ACTIVE {' '.join(ips)}")
    elif a.op == "delete":
        j = d.execute("SELECT * FROM jobs WHERE id=?", (a.job,)).fetchone() or die("no such job")
        vid = j["volume_id"]
        try:
            v = cl.vol(vid)
            if any(x.get("server_id") == md["uuid"] for x in v.get("attachments", [])):
                cl.call("DELETE", "compute", f"/servers/{md['uuid']}/os-volume_attachments/{vid}")
                cl.wait_vol(vid, "available")
            others = [x for x in v.get("attachments", []) if x.get("server_id") != md["uuid"]]
            if others:
                log(f"volume {vid} is attached to {others[0].get('server_id')} — kept")
            elif not a.keep_volume:
                cl.call("DELETE", "volumev3", f"/volumes/{vid}")
                log(f"volume {vid} deleted")
        except RuntimeError as ex:
            log(f"volume {vid}: {ex}")
        d.execute("UPDATE jobs SET state='deleted' WHERE id=?", (j["id"],))
        d.execute("DELETE FROM parts WHERE job=?", (j["id"],))
        event("admin", f"job {j['id']}: deleted")
        print(f"job {j['id']}: deleted")


def main():
    ap = argparse.ArgumentParser(prog="d2g", description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("init")
    p.add_argument("--name", required=True)
    p.add_argument("--ip", action="append", default=[])
    p.add_argument("--port", type=int, default=443)
    p.add_argument("--part-mb", type=int, default=DEFAULT_PART >> 20)
    p.add_argument("--max-inflight", type=int, default=4 * (os.cpu_count() or 1))
    p.add_argument("--max-per-job", type=int, default=16)
    p.set_defaults(fn=cmd_init)
    sp.add_parser("serve").set_defaults(fn=cmd_serve)
    p = sp.add_parser("agent")
    p.add_argument("op", choices=["add", "list", "revoke"])
    p.add_argument("name", nargs="?")
    p.set_defaults(fn=cmd_agent)
    p = sp.add_parser("job")
    p.add_argument("op", choices=["new", "list", "show", "finish", "delete"])
    p.add_argument("arg", nargs="?")
    p.add_argument("--type", default="ceph-ssd")
    p.add_argument("--size-gb", type=int)
    p.add_argument("--part-mb", type=int)
    p.add_argument("--flavor")
    p.add_argument("--network")
    p.add_argument("--sg", action="append")
    p.add_argument("--key")
    p.add_argument("--name")
    p.add_argument("--force", action="store_true")
    p.add_argument("--keep-volume", action="store_true")
    p.set_defaults(fn=cmd_job)
    a = ap.parse_args()
    if a.cmd == "agent" and a.op in ("add", "revoke") and not a.name:
        die("agent name required")
    if a.cmd == "job":
        a.agent = a.job = a.arg
        if a.op in ("new", "show", "finish", "delete") and not a.arg:
            die("job (or agent for 'new') required")
        if a.op == "finish" and not (a.flavor and a.network):
            die("--flavor and --network required")
    os.umask(0o077)
    a.fn(a)


if __name__ == "__main__":
    main()
