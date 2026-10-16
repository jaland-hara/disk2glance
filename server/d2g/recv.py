"""Receiver: accepts disk parts from agents (mTLS) and writes them into attached volumes.

The orchestrator decides which volumes this receiver serves: every 5 s the receiver posts its
state (devices, jobs, progress) and gets back the job specs it must serve. The part journal
(block MD5s) lives here, next to the data.
"""
import hashlib
import json
import mmap
import multiprocessing
import os
import stat
import subprocess
import threading
import time

from . import common as C
from .common import BLOCKS_PER_PART, CHUNK, log, now

CONF = os.path.join(C.ETC, "rx.json")
PKI = os.path.join(C.ETC, "pki")
SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, agent TEXT, agent_serial TEXT, serial TEXT, disk_bytes INTEGER, part_bytes INTEGER,
  state TEXT, fresh INTEGER DEFAULT 1, pass_no INTEGER DEFAULT 0, pass_start INTEGER, pass_snapshot TEXT,
  synced_at INTEGER, synced_snapshot TEXT, released INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS parts (job TEXT, n INTEGER, md5 TEXT, ts INTEGER, PRIMARY KEY (job, n));
"""
db = C.DB(os.path.join(C.VAR, "rx.db"), SCHEMA)
_ZMD5 = {}


def zero_md5(n):
    if n not in _ZMD5:
        _ZMD5[n] = hashlib.md5(bytes(n)).hexdigest()
    return _ZMD5[n]


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


class Limits:
    """total: shared by all worker processes; per job: per process."""
    def __init__(self, total, per_job):
        self.total = total
        self.per_job_n = per_job
        self.per_job = {}
        self.lock = threading.Lock()

    def job(self, jid):
        with self.lock:
            if jid not in self.per_job:
                self.per_job[jid] = threading.BoundedSemaphore(self.per_job_n)
            return self.per_job[jid]


class RxHandler(C.Handler):
    def agent_job(self, jid):
        cn, serial = self.peer_cert()
        if not cn:
            return None, (401, "client certificate required")
        j = db().execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        if not j or j["agent"] != cn or not C.same_serial(j["agent_serial"], serial):
            return None, (404, "no such job")
        if j["released"]:
            return None, (409, "job is released by the orchestrator")
        return j, None

    def route(self, method, p):
        if p == ["v1", "ping"]:
            return self.reply(200, {"receiver": self.server.conf["name"]})
        if len(p) >= 3 and p[:2] == ["v1", "jobs"]:
            j, err = self.agent_job(p[2])
            if err:
                self.drain()
                return self.reply(err[0], {"error": err[1]})
            tail = p[3:]
            if tail == ["parts"] and method == "GET":
                rows = db().execute("SELECT n, md5 FROM parts WHERE job=?", (j["id"],)).fetchall()
                return self.reply(200, {"part_bytes": j["part_bytes"], "block_bytes": j["part_bytes"] // BLOCKS_PER_PART,
                                        "parts": {str(r["n"]): r["md5"] for r in rows}})
            if len(tail) == 2 and tail[0] == "parts" and method == "PUT":
                return self.put_part(j, int(tail[1]))
            if tail == ["start"] and method == "POST":
                b = self.body_json()
                db().execute("UPDATE jobs SET state='receiving', pass_start=?, pass_snapshot=? WHERE id=?",
                             (now(), b.get("snapshot_time"), j["id"]))
                log(f"job {j['id']}: pass {j['pass_no'] + 1} started by {j['agent']} from {self.peer_ip}")
                return self.reply(200, {})
            if tail == ["complete"] and method == "POST":
                return self.complete(j, self.body_json())
        self.drain()
        return self.reply(404, {"error": "not found"})

    def put_part(self, j, n):
        """Write blocks of part n. Journal value of a part: its block MD5s "md5,md5,...".

        X-D2G-Blocks: "i:md5,..." — the body is these blocks one after another;
        X-D2G-Zero-Blocks: "i,..." — blocks of zeros, no data. A part the journal does not
        know must come whole (all blocks), a known part may come as changed blocks only."""
        lim = self.server.limits
        part, disk = j["part_bytes"], j["disk_bytes"]
        block = part // BLOCKS_PER_PART
        nparts = (disk + part - 1) // part
        if not 1 <= n <= nparts:
            self.drain()
            return self.reply(400, {"error": f"part {n} out of 1..{nparts}"})
        off = (n - 1) * part
        length = min(part, disk - off)
        nblocks = (length + block - 1) // block
        blen = lambda i: min(block, length - i * block)  # noqa: E731
        try:
            data = [(int(x.split(":")[0]), x.split(":")[1]) for x in self.headers.get("X-D2G-Blocks", "").split(",") if x]
            zero = [int(x) for x in self.headers.get("X-D2G-Zero-Blocks", "").split(",") if x]
        except (ValueError, IndexError):
            self.drain()
            return self.reply(400, {"error": "bad X-D2G-Blocks / X-D2G-Zero-Blocks"})
        idx = [i for i, _ in data] + zero
        clen = int(self.headers.get("Content-Length") or 0)
        if not idx or len(set(idx)) != len(idx) or not all(0 <= i < nblocks for i in idx) \
                or clen != sum(blen(i) for i, _ in data):
            self.drain()
            return self.reply(400, {"error": f"part {n}: bad block list or Content-Length"})
        row = db().execute("SELECT md5 FROM parts WHERE job=? AND n=?", (j["id"], n)).fetchone()
        known = row["md5"].split(",") if row and row["md5"].count(",") == nblocks - 1 else None
        if known is None and len(idx) != nblocks:
            self.drain()
            return self.reply(409, {"error": f"part {n} is unknown here: send all its blocks"})
        jsem = lim.job(j["id"])
        if not lim.total.acquire(False):
            self.drain()
            return self.reply(503, {"error": "busy"}, {"Retry-After": "1"})
        if not jsem.acquire(False):
            lim.total.release()
            self.drain()
            return self.reply(503, {"error": "job busy"}, {"Retry-After": "1"})
        try:
            dev = check_target(C.dev_of(j["serial"]))
            new = list(known) if known else [""] * nblocks
            # O_DIRECT: dozens of parallel parts through the page cache end in writeback storms
            # (650 MB/s for 20 s, then 40-60 MB/s with iowait 99% on VK). The buffer is an
            # anonymous mmap (page-aligned); offsets and lengths are multiples of 512.
            fd = os.open(dev, os.O_WRONLY | os.O_DIRECT)
            buf = mmap.mmap(-1, CHUNK)
            mv = memoryview(buf)
            try:
                for i, want in data:
                    m, done, bl, bo = hashlib.md5(), 0, blen(i), off + i * block
                    while done < bl:
                        cnt = min(CHUNK, bl - done)
                        if self.rfile.readinto(mv[:cnt]) != cnt:
                            raise ConnectionResetError("short body")
                        m.update(mv[:cnt])
                        w = 0
                        while w < cnt:
                            w += os.pwrite(fd, mv[w:cnt], bo + done + w)
                        done += cnt
                    if m.hexdigest() != want:
                        # the bytes on the volume are wrong now: forget the part, it is sent again whole
                        db().execute("DELETE FROM parts WHERE job=? AND n=?", (j["id"], n))
                        self.close_connection = True   # the rest of the body is not read
                        return self.reply(400, {"error": f"part {n} block {i}: MD5 mismatch"})
                    new[i] = want
                for i in zero:
                    # a new volume reads as zeros: zeros of a part never written need no write
                    if not (j["fresh"] and known is None):
                        buf.seek(0)
                        buf.write(bytes(CHUNK))
                        done, bl, bo = 0, blen(i), off + i * block
                        while done < bl:
                            done += os.pwrite(fd, mv[:min(CHUNK, bl - done)], bo + done)
                    new[i] = zero_md5(blen(i))
                os.fdatasync(fd)
            finally:
                mv.release()
                buf.close()
                os.close(fd)
            db().execute("INSERT OR REPLACE INTO parts VALUES (?,?,?,?)", (j["id"], n, ",".join(new), now()))
            return self.reply(200, {"n": n, "blocks": len(data), "zero": len(zero)})
        finally:
            jsem.release()
            lim.total.release()

    def complete(self, j, b):
        md5s = b.get("part_md5") or []
        nparts = (j["disk_bytes"] + j["part_bytes"] - 1) // j["part_bytes"]
        if len(md5s) != nparts:
            return self.reply(400, {"error": f"{len(md5s)} MD5s, job has {nparts} parts"})
        # per part the agent sends MD5 of its block list, the receiver computes it from the journal
        have = {r["n"]: hashlib.md5(r["md5"].encode()).hexdigest()
                for r in db().execute("SELECT n, md5 FROM parts WHERE job=?", (j["id"],))}
        bad = [i + 1 for i, h in enumerate(md5s) if have.get(i + 1) != h]
        if bad:
            return self.reply(409, {"error": "parts missing or different", "parts": bad[:1000], "count": len(bad)})
        db().execute("UPDATE jobs SET state='synced', fresh=0, pass_no=pass_no+1, synced_at=?, synced_snapshot=? WHERE id=?",
                     (now(), b.get("snapshot_time"), j["id"]))
        log(f"job {j['id']} synced (pass {j['pass_no'] + 1}, snapshot {b.get('snapshot_time')}, sent {b.get('sent')}/{nparts})")
        return self.reply(200, {"state": "synced"})


# --- heartbeat: state up, job specs down -------------------------------------------------------
def devices():
    out = {}
    for d in os.listdir("/sys/block"):
        try:
            with open(f"/sys/block/{d}/serial") as f:
                out[f.read().strip()] = d
        except OSError:
            pass
    return out


def heartbeat_loop(conf):
    ctx = C.client_ctx(f"{PKI}/ca.crt", f"{PKI}/rx.crt", f"{PKI}/rx.key")
    root_src, root_ser = C.root_serial()
    last_err = None
    while True:
        try:
            dev = devices()
            jobs = {}
            for j in db().execute("SELECT * FROM jobs"):
                cnt = db().execute("SELECT count(*), max(ts) FROM parts WHERE job=?", (j["id"],)).fetchone()
                pass_parts = db().execute("SELECT count(*) FROM parts WHERE job=? AND ts>=?",
                                          (j["id"], j["pass_start"] or 0)).fetchone()[0]
                jobs[j["id"]] = {"state": j["state"], "released": j["released"], "parts": cnt[0], "last_part": cnt[1],
                                 "pass_no": j["pass_no"], "pass_start": j["pass_start"], "pass_parts": pass_parts,
                                 "synced_at": j["synced_at"], "synced_snapshot": j["synced_snapshot"],
                                 "device": j["serial"] in dev}
            st, resp = C.api(conf["ctl_name"], conf["ctl_addr"], "POST", "/v1/rx/heartbeat",
                             {"devices": sorted(s for s in dev if s != root_ser), "jobs": jobs,
                              "load": os.getloadavg()[0], "root": root_src}, ctx=ctx, timeout=20)
            if st != 200:
                raise RuntimeError(f"HTTP {st} {resp}")
            reconcile(resp.get("jobs", []), dev)
            if last_err:
                log("heartbeat OK again")
            last_err = None
        except Exception as ex:  # noqa: BLE001
            if str(ex) != last_err:
                log(f"heartbeat: {ex}")
            last_err = str(ex)
        time.sleep(5)


def reconcile(specs, dev):
    want = {s["id"]: s for s in specs}
    for s in specs:
        j = db().execute("SELECT * FROM jobs WHERE id=?", (s["id"],)).fetchone()
        if not j:
            if s["state"] == "active" and s["serial"] in dev:
                check_target(C.dev_of(s["serial"]))
                db().execute("INSERT INTO jobs (id, agent, agent_serial, serial, disk_bytes, part_bytes, state, fresh) "
                             "VALUES (?,?,?,?,?,?,'ready',1)", (s["id"], s["agent"], s["agent_serial"], s["serial"],
                                                                 s["disk_bytes"], s["part_bytes"]))
                log(f"job {s['id']}: serving volume {s['serial']} ({dev[s['serial']]}) for agent {s['agent']}")
            continue
        if j["agent_serial"] != s["agent_serial"]:
            db().execute("UPDATE jobs SET agent_serial=? WHERE id=?", (s["agent_serial"], s["id"]))
        if s["state"] == "release" and not j["released"]:
            db().execute("UPDATE jobs SET released=1 WHERE id=?", (s["id"],))
            subprocess.run(["sync"])
            log(f"job {s['id']}: released")
        if s["state"] == "active" and j["released"]:
            db().execute("UPDATE jobs SET released=0 WHERE id=?", (s["id"],))
    for j in db().execute("SELECT id FROM jobs").fetchall():
        if j["id"] not in want:
            db().execute("DELETE FROM parts WHERE job=?", (j["id"],))
            db().execute("DELETE FROM jobs WHERE id=?", (j["id"],))
            log(f"job {j['id']}: dropped (no longer assigned)")


# --- commands ------------------------------------------------------------------------------------
def cmd_join(a):
    """Get a certificate from the orchestrator with the one-time token from cloud-init."""
    j = C.load_json(a.join_file)
    os.makedirs(PKI, mode=0o700, exist_ok=True)
    os.makedirs(C.VAR, mode=0o700, exist_ok=True)
    csr = C.new_key_csr(f"{PKI}/rx.key", "rx:" + j["name"])
    ctx = C.client_ctx(f"{PKI}/ca.crt")
    for attempt in range(60):
        try:
            st, resp = C.api(j["ctl_name"], j["ctl_addr"], "POST", "/v1/rx/join",
                             {"name": j["name"], "token": j["token"], "csr": csr}, ctx=ctx)
            break
        except OSError as ex:
            log(f"join: {ex} (attempt {attempt + 1})")
            time.sleep(10)
    else:
        C.die("orchestrator unreachable")
    if st != 200:
        C.die(f"join: HTTP {st} {resp}")
    with open(f"{PKI}/rx.crt", "w") as f:
        f.write(resp["cert"])
    C.save_json(CONF, {"name": j["name"], "dns": resp["dns"], "ctl_name": j["ctl_name"], "ctl_addr": j["ctl_addr"],
                       "port": 443, "max_inflight": resp.get("max_inflight", 4 * (os.cpu_count() or 1)),
                       "max_per_job": resp.get("max_per_job", 16)})
    os.remove(a.join_file)
    db.init()
    print(f"joined as {resp['dns']}")


def cmd_serve(a):
    conf = C.load_json(CONF)
    db.init()
    src, serial = C.root_serial()
    hit = db().execute("SELECT id FROM jobs WHERE serial=?", (serial,)).fetchone() if serial else None
    if hit:
        C.die(f"the root filesystem {src} is on the volume of job {hit['id']}: this VM booted a copy of a source. "
              f"Stop it, detach the job volumes, start it again and run unique-boot.sh")
    srv = C.Server((conf.get("bind", "0.0.0.0"), conf["port"]), RxHandler)
    srv.ctx = C.server_ctx(f"{PKI}/rx.crt", f"{PKI}/rx.key", f"{PKI}/ca.crt")
    srv.conf = conf
    workers = a.workers or os.cpu_count() or 1
    total = multiprocessing.BoundedSemaphore(conf["max_inflight"])
    srv.limits = Limits(total, conf["max_per_job"])
    log(f"receiver {conf['dns']} on :{conf['port']} ({workers} workers, inflight {conf['max_inflight']}, "
        f"per job {conf['max_per_job']} per worker), orchestrator {conf['ctl_name']} at {conf['ctl_addr']}")
    C.serve(srv, workers, in_parent=lambda: heartbeat_loop(conf))


def cmd_status(a):
    for j in db().execute("SELECT * FROM jobs"):
        cnt = db().execute("SELECT count(*) FROM parts WHERE job=?", (j["id"],)).fetchone()[0]
        print(json.dumps({k: j[k] for k in j.keys()} | {"parts": cnt}))
