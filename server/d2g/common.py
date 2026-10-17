"""Shared pieces of the orchestrator and the receiver: paths, database, PKI, HTTPS server/client."""
import base64
import hashlib
import http.client
import http.server
import json
import os
import secrets
import signal
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time

VAR = os.environ.get("D2G_VAR", "/var/lib/d2g")
ETC = os.environ.get("D2G_ETC", "/etc/d2g")
PKG = os.environ.get("D2G_PKG", "/opt/d2g/pkg")
CHUNK = 4 << 20
BLOCKS_PER_PART = 16   # a part is hashed in 16 blocks: a delta sends only the blocks that changed


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def die(msg, code=1):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def now():
    return int(time.time())


def load_json(path):
    with open(path) as f:
        return json.load(f)


def save_json(path, obj, mode=0o600):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


# --- database: one connection per thread (and per process: never across fork) -----------------
class DB:
    def __init__(self, path, schema):
        self.path, self.schema = path, schema
        self.tls = threading.local()

    def __call__(self):
        c = getattr(self.tls, "c", None)
        if c is None or getattr(self.tls, "pid", None) != os.getpid():
            c = sqlite3.connect(self.path, timeout=30, isolation_level=None)
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("PRAGMA busy_timeout=30000")
            self.tls.c, self.tls.pid = c, os.getpid()
        return c

    def init(self):
        self().executescript(self.schema)


# --- PKI (openssl CLI) ---------------------------------------------------------------------------
def sh(*cmd, inp=None):
    r = subprocess.run(cmd, input=inp, capture_output=True)
    if r.returncode:
        raise RuntimeError(f"{cmd[0]} {cmd[1]}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def pubkey_pin(certfile):
    pub = sh("openssl", "x509", "-in", certfile, "-noout", "-pubkey")
    der = sh("openssl", "pkey", "-pubin", "-outform", "DER", inp=pub)
    return "sha256//" + base64.b64encode(hashlib.sha256(der).digest()).decode()


def ca_init(pki, cn):
    os.makedirs(pki, mode=0o700, exist_ok=True)
    if not os.path.exists(f"{pki}/ca.crt"):
        sh("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
           "-keyout", f"{pki}/ca.key", "-out", f"{pki}/ca.crt", "-days", "3650", "-subj", f"/CN={cn}",
           "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        os.chmod(f"{pki}/ca.key", 0o600)


def new_key_csr(keyfile, cn):
    if not os.path.exists(keyfile):
        sh("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", keyfile)
        os.chmod(keyfile, 0o600)
    return sh("openssl", "req", "-new", "-key", keyfile, "-subj", f"/CN={cn}").decode()


def sign_csr(pki, csr_pem, cn, eku, dns=None, days=365):
    """Sign a CSR whose common name must be exactly cn. eku: 'serverAuth', 'clientAuth' or both."""
    with tempfile.TemporaryDirectory() as td:
        with open(f"{td}/csr", "w") as f:
            f.write(csr_pem)
        subj = sh("openssl", "req", "-in", f"{td}/csr", "-noout", "-subject", "-nameopt", "multiline").decode()
        got = [ln.split("=", 1)[1].strip() for ln in subj.splitlines() if ln.strip().startswith("commonName")]
        if got != [cn]:
            raise ValueError(f"CSR common name {got} != {cn}")
        sh("openssl", "req", "-in", f"{td}/csr", "-noout", "-verify")
        ext = f"extendedKeyUsage={eku}\nkeyUsage=critical,digitalSignature\n"
        if dns:
            ext += "subjectAltName=" + ",".join(f"DNS:{d}" for d in dns) + "\n"
        with open(f"{td}/ext", "w") as f:
            f.write(ext)
        serial = secrets.token_hex(16)
        sh("openssl", "x509", "-req", "-in", f"{td}/csr", "-CA", f"{pki}/ca.crt", "-CAkey", f"{pki}/ca.key",
           "-set_serial", "0x" + serial, "-days", str(days), "-extfile", f"{td}/ext", "-out", f"{td}/crt")
        with open(f"{td}/crt") as f:
            return serial, f.read()


def same_serial(a, b):
    return bool(a) and bool(b) and a.lower().lstrip("0") == b.lower().lstrip("0")


# --- HTTPS server -------------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "d2g"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, obj=None, headers=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, ctype="application/octet-stream"):
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            while True:
                b = f.read(CHUNK)
                if not b:
                    break
                self.wfile.write(b)

    def drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        while n > 0:
            b = self.rfile.read(min(n, CHUNK))
            if not b:
                break
            n -= len(b)

    def body_json(self, limit=16 << 20):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def peer_cert(self):
        """(common name, serial) of the verified client certificate, or (None, None)."""
        cert = self.connection.getpeercert()
        if not cert:
            return None, None
        cn = [v for rdn in cert.get("subject", ()) for k, v in rdn if k == "commonName"]
        return (cn[0] if len(cn) == 1 else None), cert.get("serialNumber", "")

    @property
    def peer_ip(self):
        return getattr(self.connection, "d2g_peer", None) or self.client_address[0]

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PUT(self):
        self.dispatch("PUT")

    def dispatch(self, method):
        p = self.path.split("?")[0].strip("/").split("/")
        try:
            self.route(method, p)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, ssl.SSLError):
            self.close_connection = True
        except Exception as ex:  # noqa: BLE001
            log(f"{self.peer_ip} {method} {self.path}: {type(ex).__name__}: {ex}")
            try:
                self.reply(500, {"error": str(ex)})
            except Exception:  # noqa: BLE001
                pass
            self.close_connection = True


def read_proxy_header(sock):
    """nginx (stream, proxy_protocol on) sends 'PROXY TCP4 src dst sport dport\\r\\n' first.
    Direct connections start with a TLS ClientHello. Returns the source address or None."""
    head = sock.recv(6, socket.MSG_PEEK)
    if head != b"PROXY ":
        return None
    line = b""
    while not line.endswith(b"\r\n") and len(line) < 108:
        c = sock.recv(1)
        if not c:
            break
        line += c
    parts = line.decode(errors="replace").split()
    return parts[2] if len(parts) >= 3 else None


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 256
    allow_reuse_address = True

    def finish_request(self, request, client_address):
        # PROXY header and TLS handshake in the per-connection thread: a slow client does not
        # block accept()
        try:
            request.settimeout(120)
            peer = read_proxy_header(request)
            tls = self.ctx.wrap_socket(request, server_side=True)
            tls.d2g_peer = peer
        except (ssl.SSLError, OSError) as ex:
            if "EOF" not in str(ex):
                log(f"{client_address[0]}: TLS handshake failed: {ex}")
            return
        try:
            self.RequestHandlerClass(tls, client_address, self)
        finally:
            try:
                tls.close()
            except OSError:
                pass


def server_ctx(cert, key, ca):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    ctx.load_verify_locations(ca)
    ctx.verify_mode = ssl.CERT_OPTIONAL   # some calls (CA, packages, enrollment) come without a client cert
    return ctx


def serve(srv, workers, before_fork=None, in_parent=None, extra=()):
    """Run srv in `workers` processes sharing the listening socket. in_parent(): background
    work started in the parent only (threads do not survive fork). extra: more servers, run in
    a thread of every process."""
    if before_fork:
        before_fork()
    kids = []
    for _ in range(max(1, workers) - 1):
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            for x in extra:
                threading.Thread(target=x.serve_forever, daemon=True).start()
            srv.serve_forever()
            os._exit(0)
        kids.append(pid)

    def stop(*_):
        for p in kids:
            try:
                os.kill(p, signal.SIGTERM)
            except ProcessLookupError:
                pass
        os._exit(0)
    signal.signal(signal.SIGTERM, stop)
    if in_parent:
        threading.Thread(target=in_parent, daemon=True).start()
    for x in extra:
        threading.Thread(target=x.serve_forever, daemon=True).start()
    srv.serve_forever()


# --- HTTPS client (to a name at a given address, with our CA) ---------------------------------------
class _Conn(http.client.HTTPSConnection):
    def __init__(self, name, addr, port, ctx, timeout):
        super().__init__(name, port, context=ctx, timeout=timeout)
        self.d2g_addr = addr

    def connect(self):
        sock = socket.create_connection((self.d2g_addr, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def client_ctx(ca, cert=None, key=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(ca)
    if cert:
        ctx.load_cert_chain(cert, key)
    return ctx


def api(name, addr, method, path, body=None, ctx=None, port=443, timeout=30):
    c = _Conn(name, addr, port, ctx, timeout)
    try:
        data = json.dumps(body).encode() if body is not None else None
        c.request(method, path, body=data, headers={"Content-Type": "application/json"} if data else {})
        r = c.getresponse()
        raw = r.read()
        try:
            obj = json.loads(raw) if raw else {}
        except ValueError:
            obj = {"raw": raw[:300].decode(errors="replace")}
        return r.status, obj
    finally:
        c.close()


# --- block devices --------------------------------------------------------------------------------
def dev_of(serial):
    return f"/dev/disk/by-id/virtio-{serial}"


def root_serial():
    src = subprocess.run(["findmnt", "-no", "SOURCE", "/"], capture_output=True, text=True).stdout.strip()
    disk = subprocess.run(["lsblk", "-no", "PKNAME", src], capture_output=True, text=True).stdout.split()
    try:
        with open(f"/sys/block/{disk[0]}/serial") as f:
            return src, f.read().strip()
    except (IndexError, OSError):
        return src, ""
