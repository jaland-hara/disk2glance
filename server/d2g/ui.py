"""Web interface of the orchestrator: administrators, login, sessions, the UI API.

Security without a domain (the UI is reached by the orchestrator's IP):
- its own self-signed certificate (a leaf, not our CA) with the FIP and grey IP in SAN; the
  administrator checks the SHA-256 fingerprint printed by `d2g setup` once, or imports the
  certificate; our CA is never put into browsers (it could sign anything);
- access only from `ui_allow` subnets (real client address from nginx PROXY protocol);
- passwords: scrypt; 5 failed logins -> the user and the address are locked for 5 min;
  optional TOTP (RFC 6238); optional admin client certificate (mTLS, `ui_mtls`);
- session cookie Secure/HttpOnly/SameSite=Strict, 30 min idle / 12 h absolute; CSRF token
  in a header for every change; strict CSP (no inline scripts), no framing.
Changes go through the same `d2g` CLI as root (argv lists, validated values), so the UI and
the CLI behave the same; long ones (volumes, VMs) run as background tasks with a live log.
"""
import base64
import getpass
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import struct
import subprocess
import sys
import threading
import time

from . import common as C
from .common import die, log, now

STATIC = os.path.join(os.path.dirname(__file__), "static")
SESSION_IDLE = 1800
SESSION_MAX = 12 * 3600
LOCK_AFTER = 5
LOCK_FOR = 300
D2G = "/usr/local/sbin/d2g"
SCHEMA = """
CREATE TABLE IF NOT EXISTS admins (
  name TEXT PRIMARY KEY, pw TEXT, totp TEXT, created INTEGER, last_login INTEGER, last_ip TEXT);
CREATE TABLE IF NOT EXISTS sessions (
  sid TEXT PRIMARY KEY, name TEXT, csrf TEXT, ip TEXT, created INTEGER, seen INTEGER);
CREATE TABLE IF NOT EXISTS login_fail (key TEXT PRIMARY KEY, n INTEGER, until INTEGER);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY, who TEXT, what TEXT, argv TEXT, state TEXT, started INTEGER, finished INTEGER,
  rc INTEGER, log TEXT DEFAULT '');
"""
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
JOB_RE = re.compile(r"^j[0-9a-f]{8}$")
RX_RE = re.compile(r"^rx[0-9]{1,3}$")
TARGET_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
ARG_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")


def orch():
    from . import orch as O
    return O


# --- passwords and TOTP ------------------------------------------------------------------------------
def pw_hash(pw):
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(pw.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return "scrypt$16384$8$1$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(h).decode()


def pw_check(pw, stored):
    try:
        _, n, r, p, salt, h = stored.split("$")
        got = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p), dklen=32)
        return hmac.compare_digest(got, base64.b64decode(h))
    except Exception:  # noqa: BLE001
        return False


def totp_at(secret, t):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    d = hmac.new(key, struct.pack(">Q", int(t) // 30), hashlib.sha1).digest()
    o = d[-1] & 15
    return "%06d" % ((struct.unpack(">I", d[o:o + 4])[0] & 0x7FFFFFFF) % 10**6)


def totp_ok(secret, code):
    code = (code or "").strip()
    return any(hmac.compare_digest(totp_at(secret, time.time() + k * 30), code) for k in (-1, 0, 1))


# --- access checks -------------------------------------------------------------------------------------
def ip_allowed(ip, cidrs):
    try:
        a = ipaddress.ip_address(ip)
        return any(a in ipaddress.ip_network(c, strict=False) for c in cidrs)
    except ValueError:
        return False


def failed(key):
    r = orch().db().execute("SELECT n, until FROM login_fail WHERE key=?", (key,)).fetchone()
    return (r["n"], r["until"]) if r else (0, 0)


def note_fail(key):
    n, until = failed(key)
    if until and until <= now():
        n = 0   # the lock has expired: count again from zero
    n += 1
    orch().db().execute("INSERT OR REPLACE INTO login_fail VALUES (?,?,?)",
                        (key, n, now() + LOCK_FOR if n >= LOCK_AFTER else 0))


def session_of(handler):
    ck = handler.headers.get("Cookie", "")
    sid = next((c.split("=", 1)[1] for c in (x.strip() for x in ck.split(";")) if c.startswith("d2g_s=")), "")
    if not sid:
        return None
    h = hashlib.sha256(sid.encode()).hexdigest()
    d = orch().db()
    s = d.execute("SELECT * FROM sessions WHERE sid=?", (h,)).fetchone()
    if not s or now() - s["seen"] > SESSION_IDLE or now() - s["created"] > SESSION_MAX:
        if s:
            d.execute("DELETE FROM sessions WHERE sid=?", (h,))
        return None
    d.execute("UPDATE sessions SET seen=? WHERE sid=?", (now(), h))
    return s


# --- background tasks (d2g CLI as root) -------------------------------------------------------------------
def run_task(who, what, argv):
    tid = "t" + secrets.token_hex(4)
    orch().db().execute("INSERT INTO tasks (id, who, what, argv, state, started) VALUES (?,?,?,?, 'running', ?)",
                        (tid, who, what, json.dumps(argv), now()))

    def work():
        d = orch().db()
        env = dict(os.environ, D2G_ACTOR=f"ui:{who}", PYTHONUNBUFFERED="1")
        try:
            p = subprocess.Popen([D2G] + argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
            buf = ""
            for line in p.stdout:
                buf += line
                d.execute("UPDATE tasks SET log=? WHERE id=?", (buf[-20000:], tid))
            rc = p.wait()
        except Exception as ex:  # noqa: BLE001
            rc, buf = 1, f"{ex}"
            d.execute("UPDATE tasks SET log=? WHERE id=?", (buf, tid))
        d.execute("UPDATE tasks SET state=?, rc=?, finished=? WHERE id=?", ("done" if rc == 0 else "failed", rc, now(), tid))
    threading.Thread(target=work, daemon=True).start()
    return tid


def run_now(who, argv):
    env = dict(os.environ, D2G_ACTOR=f"ui:{who}", PYTHONUNBUFFERED="1")
    r = subprocess.run([D2G] + argv, capture_output=True, text=True, env=env, timeout=120)
    return r.returncode, (r.stdout + r.stderr).strip()


# --- cloud lists for the forms (cached) ----------------------------------------------------------------------
_cloud_cache = {"t": 0, "v": None}   # "t": 0 drops every project's cache
_cloud_by = {}
_cloud_lock = threading.Lock()


def cloud_lists(target="home"):
    """Lists for the forms (cached 5 min per project)."""
    from . import targets as T
    with _cloud_lock:
        if _cloud_cache["t"] == 0:
            _cloud_by.clear()
            _cloud_cache["t"] = 1
        hit = _cloud_by.get(target)
        if hit and time.time() - hit[0] < 300:
            return hit[1]
        cl = T.cloud_for(target)
        fl = cl.call("GET", "compute", "/flavors/detail")["flavors"]
        v = {"flavors": sorted(({"name": f["name"], "vcpus": f["vcpus"], "ram": f["ram"]} for f in fl),
                               key=lambda f: (f["vcpus"], f["ram"], f["name"])),
             "networks": sorted(n["name"] for n in cl.call("GET", "network", "/networks")["networks"]
                                if not n.get("router:external")),
             "security_groups": sorted({g["name"] for g in cl.call("GET", "network", "/security-groups")["security_groups"]}),
             "keypairs": sorted(k["keypair"]["name"] for k in cl.call("GET", "compute", "/os-keypairs")["keypairs"]),
             "volume_types": sorted(t["name"] for t in cl.call("GET", "volumev3", "/types")["volume_types"]),
             "zones": sorted(z["zoneName"] for z in cl.call("GET", "compute", "/os-availability-zone")["availabilityZoneInfo"]
                             if z.get("zoneState", {}).get("available")),
             "fips": sorted(({"id": f["id"], "ip": f["floating_ip_address"], "free": not f.get("port_id")}
                             for f in cl.call("GET", "network", "/floatingips")["floatingips"]), key=lambda f: f["ip"]),
             "cloud": {k: cl.env.get(k, "") for k in ("OS_AUTH_URL", "OS_PROJECT_ID", "OS_USERNAME", "OS_USER_DOMAIN_NAME",
                                                      "OS_REGION_NAME")}}
        _cloud_by[target] = (time.time(), v)
        return v


# --- state for the pages ------------------------------------------------------------------------------------
def state(c):
    O = orch()
    d = O.db()
    rx = []
    for r in d.execute("SELECT * FROM receivers WHERE state!='deleted' ORDER BY local DESC, created"):
        n = d.execute("SELECT count(*) FROM jobs WHERE receiver=? AND state NOT IN ('finished','deleted')",
                      (r["name"],)).fetchone()[0]
        info = json.loads(r["info"] or "{}")
        rx.append({"name": r["name"], "dns": O.rx_dns(c, r["name"]), "state": r["state"] if r["state"] != "up" or O.rx_up(r) else "down",
                   "local": bool(r["local"]), "flavor": r["flavor"], "az": r["az"], "grey_ip": r["grey_ip"], "fip": r["fip"],
                   "volumes": n, "max_volumes": c["max_volumes"], "load": info.get("load"), "seen": r["last_seen"],
                   "target": r["target"] or "home"})
    agents = []
    for a in d.execute("SELECT * FROM agents ORDER BY name"):
        inv = json.loads(a["inventory"] or "{}")
        rep = json.loads(a["last_report"] or "{}")
        agents.append({"name": a["name"], "state": "revoked" if a["revoked"] else ("enrolled" if a["cert_serial"] else "token"),
                       "seen": a["last_seen"], "peer": a["peer"], "path": a["path"], "threads": a["threads"],
                       "os": inv.get("os"), "kernel": inv.get("kernel"), "hostname": inv.get("hostname"),
                       "disk_bytes": inv.get("disk_bytes"), "module": inv.get("module"), "version": inv.get("agent_version"),
                       "command": a["command"], "report": {"rc": rep.get("rc"), "summary": rep.get("summary"),
                                                           "command": rep.get("command"), "at": a["report_at"]},
                       "token_exp": a["token_exp"]})
    jobs = []
    for j in d.execute("SELECT * FROM jobs WHERE state!='deleted' ORDER BY created DESC"):
        n = O.nparts(j)
        rate = None
        if j["state"] == "receiving" and j["pass_parts"] and j["last_part"] and j["pass_start"]:
            rate = j["pass_parts"] * j["part_bytes"] / 2**20 / max(1, j["last_part"] - j["pass_start"])
        jobs.append({k: j[k] for k in ("id", "agent", "receiver", "volume_id", "az", "disk_bytes", "part_bytes", "state",
                                       "created", "sync_every", "parts", "pass_no", "pass_start", "pass_parts", "last_part",
                                       "synced_at", "synced_snapshot", "server_id", "vm_name")}
                    | {"nparts": n, "rate": rate, "target": j["target"] or "home"})
    from . import targets as T
    targets = [{"name": "home", "title": "проект оркестратора", "mode": "home", "project": c.get("project"), "region": "",
                "az": c.get("az"), "network": c.get("network"), "check_ok": 1}]
    for r in d.execute("SELECT * FROM targets ORDER BY name"):
        t = T.tconf(c, r["name"])
        targets.append({k: t.get(k) for k in ("name", "title", "mode", "project", "region", "az", "network", "rx_flavor",
                                              "rx_volume_type", "fip_pool", "allow", "vm_sg", "max_volumes")}
                       | {"check_ok": r["check_ok"], "checked_at": r["checked_at"]})
    tasks = [dict(t) for t in d.execute("SELECT id, who, what, state, started, finished, rc, substr(log, -3000) AS log "
                                        "FROM tasks ORDER BY started DESC LIMIT 20")]
    events = [dict(e) for e in d.execute("SELECT * FROM events ORDER BY ts DESC LIMIT 200")]
    return {"now": now(), "orchestrator": {k: c.get(k) for k in ("ctl_name", "grey_ip", "public_ip", "az", "network",
                                                                  "rx_flavor", "rx_volume_type", "max_volumes", "allow",
                                                                  "fip_pool", "ui_allow", "ui_mtls", "part_mb")},
            "receivers": rx, "agents": agents, "jobs": jobs, "tasks": tasks, "events": events, "targets": targets}


# --- request handling (called from OrchHandler for connections without the ctl SNI name) ----------------------
SEC_HEADERS = {"Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                                          "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
               "X-Frame-Options": "DENY", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
               "Cache-Control": "no-store"}
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}


def handle(h, method, p):
    c = orch().conf()   # read every time: settings changed from the UI apply at once
    ip = h.peer_ip
    if not ip_allowed(ip, c.get("ui_allow") or []):
        h.drain()
        log(f"UI: {ip} is not in ui_allow")
        return h.reply(403, raw=b"forbidden\n", ctype="text/plain", headers=SEC_HEADERS)
    if c.get("ui_mtls"):
        cn, serial = h.peer_cert()
        if not cn or not cn.startswith("admin:"):
            h.drain()
            return h.reply(403, raw=b"admin certificate required\n", ctype="text/plain", headers=SEC_HEADERS)
    if c.get("setup_mode"):
        from . import setup
        return setup.handle(h, method, p, c, ip)
    path = "/" + "/".join(p)
    if method == "GET" and (path in ("/", "/login") or path.startswith("/ui/")):
        name = {"/": "index.html", "/login": "login.html"}.get(path, path[4:])
        f = os.path.realpath(os.path.join(STATIC, name))
        if not f.startswith(os.path.realpath(STATIC) + os.sep) or not os.path.isfile(f):
            return h.reply(404, raw=b"not found\n", ctype="text/plain", headers=SEC_HEADERS)
        if path == "/" and not session_of(h):
            return h.reply(302, raw=b"", ctype="text/plain", headers=SEC_HEADERS | {"Location": "/login"})
        with open(f, "rb") as fh:
            return h.reply(200, raw=fh.read(), ctype=STATIC_TYPES.get(os.path.splitext(f)[1], "application/octet-stream"),
                           headers=SEC_HEADERS)
    if path == "/api/ui/login" and method == "POST":
        return login(h, c, ip)
    s = session_of(h)
    if not s:
        h.drain()
        return h.reply(401, {"error": "login required"}, headers=SEC_HEADERS)
    if method == "POST" and not hmac.compare_digest(h.headers.get("X-CSRF", ""), s["csrf"]):
        h.drain()
        return h.reply(403, {"error": "bad CSRF token"}, headers=SEC_HEADERS)
    who = s["name"]
    if path == "/api/ui/logout" and method == "POST":
        orch().db().execute("DELETE FROM sessions WHERE sid=?", (s["sid"],))
        return h.reply(200, {}, headers=SEC_HEADERS | {"Set-Cookie": "d2g_s=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"})
    if path == "/api/ui/me" and method == "GET":
        return h.reply(200, {"name": who, "csrf": s["csrf"], "idle": SESSION_IDLE}, headers=SEC_HEADERS)
    if path == "/api/ui/state" and method == "GET":
        return h.reply(200, state(c), headers=SEC_HEADERS)
    if path == "/api/ui/cloud" and method == "GET":
        import urllib.parse
        q = urllib.parse.parse_qs(h.path.split("?", 1)[1] if "?" in h.path else "")
        tg = (q.get("target") or ["home"])[0]
        if tg != "home" and not orch().db().execute("SELECT 1 FROM targets WHERE name=?", (tg,)).fetchone():
            return h.reply(404, {"error": "no such project"}, headers=SEC_HEADERS)
        return h.reply(200, cloud_lists(tg), headers=SEC_HEADERS)
    if path.startswith("/api/ui/task/") and method == "GET":
        t = orch().db().execute("SELECT * FROM tasks WHERE id=?", (p[-1],)).fetchone()
        return h.reply(200 if t else 404, dict(t) if t else {"error": "no task"}, headers=SEC_HEADERS)
    if method == "POST" and path.startswith("/api/ui/"):
        b = h.body_json(limit=64 << 10)
        try:
            return h.reply(200, action(who, p[2:], b, ip), headers=SEC_HEADERS)
        except ValueError as ex:
            return h.reply(400, {"error": str(ex)}, headers=SEC_HEADERS)
    h.drain()
    return h.reply(404, {"error": "not found"}, headers=SEC_HEADERS)


def login(h, c, ip):
    b = h.body_json(limit=4096)
    name, pw, code = str(b.get("user", ""))[:64], str(b.get("password", ""))[:256], str(b.get("totp", ""))[:12]
    for key in (f"ip:{ip}", f"user:{name}"):
        n, until = failed(key)
        if until > now():
            log(f"UI login {name!r} from {ip}: locked")
            return h.reply(429, {"error": f"too many attempts, try again in {until - now()} s"}, headers=SEC_HEADERS)
    a = orch().db().execute("SELECT * FROM admins WHERE name=?", (name,)).fetchone()
    ok = bool(a) and pw_check(pw, a["pw"])
    if ok and a["totp"]:
        if not code:
            return h.reply(401, {"error": "TOTP code required", "totp": True}, headers=SEC_HEADERS)
        ok = totp_ok(a["totp"], code)
    if not ok:
        note_fail(f"ip:{ip}")
        note_fail(f"user:{name}")
        orch().event(f"ui:{name or '?'}", f"login failed from {ip}")
        log(f"UI login {name!r} from {ip}: failed")
        time.sleep(1)
        return h.reply(401, {"error": "wrong user, password or code"}, headers=SEC_HEADERS)
    d = orch().db()
    d.execute("DELETE FROM login_fail WHERE key IN (?,?)", (f"ip:{ip}", f"user:{name}"))
    sid = secrets.token_urlsafe(32)
    d.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?)", (hashlib.sha256(sid.encode()).hexdigest(), name,
                                                            secrets.token_urlsafe(24), ip, now(), now()))
    d.execute("UPDATE admins SET last_login=?, last_ip=? WHERE name=?", (now(), ip, name))
    orch().event(f"ui:{name}", f"logged in from {ip}")
    return h.reply(200, {"ok": True}, headers=SEC_HEADERS | {
        "Set-Cookie": f"d2g_s={sid}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={SESSION_MAX}"})


def need(b, key, rx=ARG_RE, optional=False):
    v = b.get(key)
    if v in (None, "") and optional:
        return None
    v = str(v)
    if not rx.match(v):
        raise ValueError(f"bad {key}")
    return v


def setup_argv(c, **kw):
    """d2g setup with whole lists (--replace-lists): current settings, changed by kw."""
    v = {k: c.get(k) for k in ("ui_allow", "allow", "fip_pool", "rx_flavor", "rx_volume_type", "max_volumes")} | kw
    argv = ["setup", "--replace-lists", "--rx-flavor", v["rx_flavor"], "--rx-volume-type", v["rx_volume_type"],
            "--max-volumes", str(int(v["max_volumes"]))]
    for flag, key in (("--ui-allow", "ui_allow"), ("--allow", "allow"), ("--fip-pool", "fip_pool")):
        for x in v[key] or []:
            argv += [flag, x]
    return argv


def action(who, p, b, ip=""):
    """p: path after /api/ui/; returns JSON for the page."""
    if p == ["settings", "access"]:
        from .setup import cidr
        ua = [cidr(x) for x in b.get("ui_allow") or []]
        al = [cidr(x) for x in b.get("allow") or []]
        if not ua:
            raise ValueError("нужен хотя бы один адрес или подсеть для веб-интерфейса")
        if not ip_allowed(ip, ua):
            raise ValueError(f"вашего адреса {ip} нет в новом списке: вы закроете доступ себе")
        rc, out = run_now(who, setup_argv(orch().conf(), ui_allow=ua, allow=al))
        if rc:
            raise ValueError(out[-1500:])
        return {"message": "доступ обновлён"}
    if p == ["settings", "receivers"]:
        kw = {"rx_flavor": need(b, "rx_flavor"), "rx_volume_type": need(b, "rx_volume_type"),
              "max_volumes": max(1, min(26, int(b.get("max_volumes") or 20))),
              "fip_pool": [need({"f": x}, "f") for x in b.get("fip_pool") or []]}
        rc, out = run_now(who, setup_argv(orch().conf(), **kw))
        if rc:
            raise ValueError(out[-1500:])
        _cloud_cache["t"] = 0
        return {"message": "параметры приёмников обновлены"}
    if p == ["settings", "cloud"]:
        from .setup import cloud_check, env_of
        res = cloud_check(orch().conf(), b)
        if b.get("save") and res["ok"]:
            env = env_of(b)
            import shlex
            with open("/etc/d2g/openrc.new", "w") as f:
                os.chmod("/etc/d2g/openrc.new", 0o600)
                f.write("".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items()))
            os.replace("/etc/d2g/openrc.new", "/etc/d2g/openrc")
            orch().event(f"ui:{who}", f"cloud credentials changed (user {env['OS_USERNAME']}, project {env['OS_PROJECT_ID']})")
            _cloud_cache["t"] = 0
            res["saved"] = True
        return res
    if p == ["agent", "add"]:
        name = need(b, "name", NAME_RE)
        path = b.get("path") or "auto"
        if path not in ("auto", "rx-grey", "rx-fip", "ctl", "ctl-grey"):
            raise ValueError("bad path")
        threads = int(b.get("threads") or 8)
        if not 1 <= threads <= 64:
            raise ValueError("threads 1..64")
        rc, out = run_now(who, ["agent", "add", name, "--path", path, "--threads", str(threads)])
        if rc:
            raise ValueError(out)
        cmds, kind = [], None
        for line in out.splitlines():
            if line.startswith("# public") or line.startswith("# grey"):
                kind = line[2:].rstrip(":")
            elif line.startswith("curl ") and kind:
                cmds.append({"kind": kind, "command": line})
        return {"commands": cmds, "valid_min": 60}
    if len(p) == 3 and p[0] == "agent" and p[2] in ("revoke", "sync", "uninstall"):
        rc, out = run_now(who, ["agent", p[2], need({"n": p[1]}, "n", NAME_RE)])
        if rc:
            raise ValueError(out)
        return {"message": out}
    if p == ["target", "check"]:
        from .setup import cloud_check
        return cloud_check(orch().conf(), b, own=False, az=need(b, "az", optional=True))
    if p == ["target", "save"]:
        return target_save(who, b)
    if len(p) == 3 and p[0] == "target" and p[2] == "delete":
        rc, out = run_now(who, ["target", "delete", need({"t": p[1]}, "t", TARGET_RE)])
        if rc:
            raise ValueError(out[-1500:])
        _cloud_cache["t"] = 0
        return {"message": out}
    if p == ["job", "new"]:
        argv = ["job", "new", need(b, "agent", NAME_RE), "--target", need(b, "target", TARGET_RE, optional=True) or "home"]
        for k, flag in (("type", "--type"), ("az", "--az"), ("receiver", "--receiver")):
            v = need(b, k, optional=True)
            if v:
                argv += [flag, v]
        if b.get("every"):
            argv += ["--every", str(int(b["every"]))]
        if b.get("size_gb"):
            argv += ["--size-gb", str(int(b["size_gb"]))]
        return {"task": run_task(who, f"new job for {argv[2]}", argv)}
    if len(p) == 3 and p[0] == "job":
        jid = need({"j": p[1]}, "j", JOB_RE)
        if p[2] == "sync":
            argv = ["job", "sync", jid] + (["--every", str(int(b["every"]))] if "every" in b else [])
            rc, out = run_now(who, argv)
            if rc:
                raise ValueError(out)
            return {"message": out}
        if p[2] == "finish":
            argv = ["job", "finish", jid, "--flavor", need(b, "flavor"), "--network", need(b, "network")]
            for sg in b.get("sg") or []:
                argv += ["--sg", need({"s": sg}, "s")]
            for k in ("key", "name"):
                v = need(b, k, optional=True)
                if v:
                    argv += [f"--{k}", v]
            if b.get("force"):
                argv.append("--force")
            return {"task": run_task(who, f"finish {jid}", argv)}
        if p[2] == "delete":
            argv = ["job", "delete", jid] + (["--keep-volume"] if b.get("keep_volume") else [])
            return {"task": run_task(who, f"delete {jid}", argv)}
    if p == ["receiver", "add"]:
        argv = ["receiver", "add", "--target", need(b, "target", TARGET_RE, optional=True) or "home"]
        for k in ("az", "flavor", "fip"):
            v = need(b, k, optional=True)
            if v:
                argv += [f"--{k}", v]
        return {"task": run_task(who, "new receiver", argv)}
    if len(p) == 3 and p[0] == "receiver" and p[2] == "delete":
        return {"task": run_task(who, f"delete receiver {p[1]}", ["receiver", "delete", need({"r": p[1]}, "r", RX_RE)])}
    raise ValueError("unknown action")


def target_save(who, b):
    """Add or change a target project: the account goes to a temporary file (600) for 'd2g target'."""
    from . import targets as T
    from .setup import env_of, cidr
    name = need(b, "name", TARGET_RE)
    if name == "home":
        raise ValueError("имя home занято проектом оркестратора")
    exists = orch().db().execute("SELECT 1 FROM targets WHERE name=?", (name,)).fetchone()
    mode = b.get("mode")
    if mode not in ("transfer", "receiver"):
        raise ValueError("способ: transfer или receiver")
    argv = ["target", "set" if exists else "add", name, "--mode", mode, "--replace-lists"]
    tmp = None
    if b.get("password"):
        env = env_of(b)
        os.makedirs(T.TDIR, mode=0o700, exist_ok=True)
        tmp = os.path.join(T.TDIR, f".new-{name}-{secrets.token_hex(3)}")
        with open(tmp, "w") as f:
            os.chmod(tmp, 0o600)
            import shlex
            f.write("".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items()))
        argv += ["--openrc", tmp]
    elif not exists:
        raise ValueError("нужен пароль служебной учётной записи проекта")
    if b.get("title"):
        argv += ["--title", str(b["title"])[:64]]
    for k in ("az", "network", "rx_flavor", "rx_volume_type", "rx_key"):
        v = need(b, k, optional=True)
        if v:
            argv += ["--" + k.replace("_", "-"), v]
    if b.get("max_volumes"):
        argv += ["--max-volumes", str(max(1, min(26, int(b["max_volumes"]))))]
    for x in b.get("allow") or []:
        argv += ["--allow", cidr(x)]
    for x in b.get("fip_pool") or []:
        argv += ["--fip-pool", need({"f": x}, "f")]
    for x in b.get("vm_sg") or []:
        argv += ["--vm-sg", need({"s": x}, "s")]
    try:
        rc, out = run_now(who, argv)
    finally:
        if tmp and os.path.exists(tmp):
            os.remove(tmp)
    if rc:
        raise ValueError(out[-1500:])
    _cloud_cache["t"] = 0
    return {"message": out.strip().splitlines()[-1] if out.strip() else "сохранено"}


# --- UI certificate ------------------------------------------------------------------------------------
def ui_cert(pki, c):
    """Self-signed leaf certificate for the UI (by IP). Re-created when the addresses change."""
    ips = sorted({x for x in (c.get("public_ip"), c.get("grey_ip"), "127.0.0.1") if x})
    want = ",".join(f"IP:{x}" for x in ips) + ",DNS:localhost"
    crt, key = f"{pki}/ui.crt", f"{pki}/ui.key"
    if os.path.exists(crt):
        have = C.sh("openssl", "x509", "-in", crt, "-noout", "-ext", "subjectAltName").decode()
        if all(x in have for x in ips):
            return fingerprint(crt)
    C.sh("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", key,
         "-out", crt, "-days", "825", "-subj", f"/CN=d2g {c['install_id']} admin UI",
         "-addext", f"subjectAltName={want}", "-addext", "basicConstraints=critical,CA:FALSE",
         "-addext", "extendedKeyUsage=serverAuth")
    os.chmod(key, 0o600)
    return fingerprint(crt)


def fingerprint(crt):
    out = C.sh("openssl", "x509", "-in", crt, "-noout", "-fingerprint", "-sha256").decode()
    return out.strip().split("=", 1)[1]


# --- CLI: administrators ---------------------------------------------------------------------------------
def cmd_admin(a):
    O = orch()
    d = O.db()
    if a.op == "list":
        for r in d.execute("SELECT * FROM admins ORDER BY name"):
            last = time.strftime("%d.%m %H:%M", time.localtime(r["last_login"])) if r["last_login"] else "never"
            print(f"{r['name']:<16} TOTP {'on' if r['totp'] else 'off':<4} last login {last} from {r['last_ip'] or '-'}")
        return
    if not a.name or not NAME_RE.match(a.name):
        die("admin name: lowercase letters, digits, '-'")
    if a.op in ("add", "passwd"):
        exists = d.execute("SELECT 1 FROM admins WHERE name=?", (a.name,)).fetchone()
        if a.op == "add" and exists:
            die(f"{a.name} exists (use passwd)")
        if a.op == "passwd" and not exists:
            die(f"no admin {a.name}")
        pw = sys.stdin.readline().rstrip("\n") if a.password_stdin else getpass.getpass("password: ")
        if not a.password_stdin and pw != getpass.getpass("again: "):
            die("passwords differ")
        if len(pw) < 12:
            die("at least 12 characters")
        if a.op == "add":
            d.execute("INSERT INTO admins (name, pw, created) VALUES (?,?,?)", (a.name, pw_hash(pw), now()))
        else:
            d.execute("UPDATE admins SET pw=? WHERE name=?", (pw_hash(pw), a.name))
            d.execute("DELETE FROM sessions WHERE name=?", (a.name,))
        O.event(O.actor(), f"admin {a.name}: {'added' if a.op == 'add' else 'password changed'}")
        print(f"{a.name}: {'added' if a.op == 'add' else 'password changed'}")
    elif a.op == "totp":
        if a.off:
            d.execute("UPDATE admins SET totp=NULL WHERE name=?", (a.name,))
            print(f"{a.name}: TOTP off")
        else:
            sec = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
            d.execute("UPDATE admins SET totp=? WHERE name=?", (sec, a.name))
            c = O.conf()
            print(f"{a.name}: TOTP on. Add to an authenticator app:\n  secret {sec}\n"
                  f"  otpauth://totp/d2g-{c['install_id']}:{a.name}?secret={sec}&issuer=d2g-{c['install_id']}")
        d.execute("DELETE FROM sessions WHERE name=?", (a.name,))
        O.event(O.actor(), f"admin {a.name}: TOTP {'off' if a.off else 'on'}")
    elif a.op == "delete":
        d.execute("DELETE FROM admins WHERE name=?", (a.name,))
        d.execute("DELETE FROM sessions WHERE name=?", (a.name,))
        O.event(O.actor(), f"admin {a.name}: deleted")
        print(f"{a.name}: deleted")
    elif a.op == "cert":
        # client certificate for the browser (mTLS for the UI, d2g setup --ui-mtls on)
        out = os.path.abspath(a.out or f"{a.name}.p12")
        with __import__("tempfile").TemporaryDirectory() as td:
            csr = C.new_key_csr(f"{td}/k", "admin:" + a.name)
            _, crt = C.sign_csr(O.PKI, csr, "admin:" + a.name, "clientAuth", days=365)
            with open(f"{td}/c", "w") as f:
                f.write(crt)
            pw = getpass.getpass("password for the .p12 file: ")
            C.sh("openssl", "pkcs12", "-export", "-inkey", f"{td}/k", "-in", f"{td}/c", "-certfile", f"{O.PKI}/ca.crt",
                 "-name", f"d2g admin {a.name}", "-out", out, "-passout", "pass:" + pw)
        os.chmod(out, 0o600)
        O.event(O.actor(), f"admin {a.name}: client certificate issued")
        print(f"{out}: import it into the browser; turn the check on with: d2g setup --ui-mtls on")
