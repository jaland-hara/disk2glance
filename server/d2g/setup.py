"""First-run web setup wizard (the orchestrator was started with `d2g bootstrap`).

The wizard is open only with the one-time setup code printed by the installer (and only from
`ui_allow`, by default anywhere during setup). Steps: administrator, cloud credentials (checked
by real probes: a 1 GB volume and a security group are created and deleted), placement,
receivers, access. "Apply" writes /etc/d2g/openrc, runs `d2g setup`, creates the admin, opens
443 in the orchestrator's security group if asked, starts the local receiver and restarts the
orchestrator into normal mode.
"""
import hashlib
import ipaddress
import os
import secrets
import shlex
import subprocess
import time
import urllib.parse

from . import common as C
from .common import log, now

SG_CTL = "d2g-ctl"


def orch():
    from . import orch as O
    return O


def ui():
    from . import ui as U
    return U


def code_ok(c, code):
    return bool(code) and c.get("setup_code") and secrets.compare_digest(c["setup_code"], hashlib.sha256(code.encode()).hexdigest()) \
        and now() < c.get("setup_exp", 0)


def handle(h, method, p, c, ip):
    U = ui()
    path = "/" + "/".join(p)
    if method == "GET" and path in ("/", "/login"):
        return h.reply(302, raw=b"", ctype="text/plain", headers=U.SEC_HEADERS | {"Location": "/setup"})
    if method == "GET" and (path == "/setup" or path.startswith("/ui/")):
        name = "setup.html" if path == "/setup" else path[4:]
        f = os.path.realpath(os.path.join(U.STATIC, name))
        if not f.startswith(os.path.realpath(U.STATIC) + os.sep) or not os.path.isfile(f):
            return h.reply(404, raw=b"not found\n", ctype="text/plain", headers=U.SEC_HEADERS)
        with open(f, "rb") as fh:
            return h.reply(200, raw=fh.read(), ctype=U.STATIC_TYPES.get(os.path.splitext(f)[1], "application/octet-stream"),
                           headers=U.SEC_HEADERS)
    if not path.startswith("/api/setup/"):
        h.drain()
        return h.reply(404, {"error": "настройка не завершена"}, headers=U.SEC_HEADERS)
    n, until = U.failed(f"ip:{ip}")
    if until > now():
        h.drain()
        return h.reply(429, {"error": f"слишком много попыток, повторите через {until - now()} с"}, headers=U.SEC_HEADERS)
    if not code_ok(c, h.headers.get("X-Setup-Code", "").strip()):
        h.drain()
        U.note_fail(f"ip:{ip}")
        log(f"setup: wrong or expired code from {ip}")
        time.sleep(1)
        return h.reply(401, {"error": "неверный или истёкший код (новый: sudo d2g setup-code на ВМ оркестратора)"}, headers=U.SEC_HEADERS)
    try:
        if path == "/api/setup/info" and method == "GET":
            return h.reply(200, info(c, ip), headers=U.SEC_HEADERS)
        if path == "/api/setup/totp" and method == "GET":
            import base64
            sec = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
            return h.reply(200, {"secret": sec, "issuer": f"d2g-{c['install_id']}"}, headers=U.SEC_HEADERS)
        if path == "/api/setup/totp" and method == "POST":
            # the code lives ~1 min: check it now and remember the confirmed secret for "apply"
            b = h.body_json(limit=4096)
            sec, code = str(b.get("secret", "")), str(b.get("code", ""))
            if not sec or not U.totp_ok(sec, code):
                raise ValueError("код из приложения не подходит: проверьте время на телефоне и отсканируйте QR-код заново")
            c["setup_totp"] = sec
            C.save_json(orch().CONF, c, 0o644)
            return h.reply(200, {"ok": True}, headers=U.SEC_HEADERS)
        if path == "/api/setup/cloud" and method == "POST":
            return h.reply(200, cloud_check(c, h.body_json(limit=16 << 10)), headers=U.SEC_HEADERS)
        if path == "/api/setup/apply" and method == "POST":
            return h.reply(200, apply(c, h.body_json(limit=64 << 10), ip), headers=U.SEC_HEADERS)
    except ValueError as ex:
        return h.reply(400, {"error": str(ex)}, headers=U.SEC_HEADERS)
    h.drain()
    return h.reply(404, {"error": "not found"}, headers=U.SEC_HEADERS)


def info(c, ip):
    return {"ctl_name": c["ctl_name"], "grey_ip": c["grey_ip"], "public_ip": c.get("public_ip", ""), "az": c["az"],
            "client_ip": ip, "fingerprint": ui().fingerprint(f"{orch().PKI}/ui.crt"),
            "version": open("/opt/d2g/VERSION").read().strip() if os.path.exists("/opt/d2g/VERSION") else "dev",
            "expires": c.get("setup_exp")}


def env_of(b):
    env = {"OS_AUTH_URL": str(b.get("auth_url", "")).strip(), "OS_PROJECT_ID": str(b.get("project_id", "")).strip(),
           "OS_USERNAME": str(b.get("username", "")).strip(), "OS_PASSWORD": str(b.get("password", "")),
           "OS_USER_DOMAIN_NAME": str(b.get("user_domain", "service-users")).strip() or "service-users",
           "OS_REGION_NAME": str(b.get("region", "")).strip(), "OS_INTERFACE": "public", "OS_IDENTITY_API_VERSION": "3"}
    u = urllib.parse.urlparse(env["OS_AUTH_URL"])
    if u.scheme != "https" or not u.netloc:
        raise ValueError("адрес Keystone должен начинаться с https://")
    for k in ("OS_PROJECT_ID", "OS_USERNAME", "OS_PASSWORD"):
        if not env[k]:
            raise ValueError(f"не заполнено: {k}")
    return env


def cloud_check(c, b, own=True, az=None):
    """own: the account of the orchestrator's own project (its VM must be visible there).
    az: zone for the probe volume (default: the orchestrator's zone, or the first zone)."""
    from .cloud import Cloud, metadata
    env = env_of(b)
    try:
        cl = Cloud(env=env)
    except Exception as ex:  # noqa: BLE001
        raise ValueError(f"Keystone не принял учётные данные: {ex}") from None
    md = metadata()
    checks, me = [], {}
    if not own:
        zones = []
        try:
            zones = sorted(z["zoneName"] for z in cl.call("GET", "compute", "/os-availability-zone")["availabilityZoneInfo"]
                           if z.get("zoneState", {}).get("available"))
        except Exception:  # noqa: BLE001
            pass
        md = dict(md, availability_zone=az if az in zones else (md["availability_zone"] if md["availability_zone"] in zones
                                                                  else (zones or [md["availability_zone"]])[0]))

    def chk(name, fn):
        try:
            checks.append({"name": name, "ok": True, "detail": fn() or ""})
        except Exception as ex:  # noqa: BLE001
            checks.append({"name": name, "ok": False, "detail": str(ex)[:300]})

    def own_vm():
        s = cl.server(md["uuid"])
        me["networks"] = list(s.get("addresses", {}))
        me["security_groups"] = sorted({g["name"] for g in s.get("security_groups", [])})
        me["fip"] = next((a["addr"] for n in s["addresses"].values() for a in n if a.get("OS-EXT-IPS:type") == "floating"), "")
        return f"{s['name']}, сети: {', '.join(me['networks'])}"
    if own:
        chk("Эта ВМ видна в проекте", own_vm)
    chk("Просмотр ВМ и томов", lambda: (cl.call("GET", "compute", "/servers?limit=1"), cl.call("GET", "volumev3", "/volumes?limit=1")) and "")

    def vol():
        vid = cl.create_volume(f"d2g-check-{secrets.token_hex(3)}", 1, None, md["availability_zone"], desc="d2g setup check")
        try:
            cl.wait_vol(vid, "available", timeout=120)
        finally:
            cl.call("DELETE", "volumev3", f"/volumes/{vid}")
        return "том 1 ГБ создан и удалён"
    chk("Создание и удаление томов", vol)

    def sg():
        name = f"d2g-check-{secrets.token_hex(3)}"
        g = cl.call("POST", "network", "/security-groups", {"security_group": {"name": name, "description": "d2g setup check"}})
        cl.call("DELETE", "network", f"/security-groups/{g['security_group']['id']}")
        return "группа создана и удалена"
    chk("Создание групп безопасности", sg)
    chk("Плавающие IP (просмотр)", lambda: cl.call("GET", "network", "/floatingips") and "")
    lists = {}
    try:
        fl = cl.call("GET", "compute", "/flavors/detail")["flavors"]
        lists["flavors"] = sorted(({"name": f["name"], "vcpus": f["vcpus"], "ram": f["ram"]} for f in fl),
                                  key=lambda f: (f["vcpus"], f["ram"], f["name"]))
        lists["networks"] = sorted(n["name"] for n in cl.call("GET", "network", "/networks")["networks"] if not n.get("router:external"))
        lists["volume_types"] = sorted(t["name"] for t in cl.call("GET", "volumev3", "/types")["volume_types"])
        lists["zones"] = sorted(z["zoneName"] for z in cl.call("GET", "compute", "/os-availability-zone")["availabilityZoneInfo"]
                                if z.get("zoneState", {}).get("available"))
        lists["keypairs"] = sorted(k["keypair"]["name"] for k in cl.call("GET", "compute", "/os-keypairs")["keypairs"])
        lists["fips"] = sorted(({"id": f["id"], "ip": f["floating_ip_address"], "free": not f.get("port_id")}
                                for f in cl.call("GET", "network", "/floatingips")["floatingips"]), key=lambda f: f["ip"])
    except Exception as ex:  # noqa: BLE001
        checks.append({"name": "Списки (флейворы, сети, типы томов)", "ok": False, "detail": str(ex)[:300]})
    return {"ok": all(x["ok"] for x in checks), "project": cl.project, "checks": checks, "me": me, "lists": lists,
            "az": md["availability_zone"]}


def cidr(v):
    try:
        return str(ipaddress.ip_network(str(v).strip(), strict=False))
    except ValueError:
        raise ValueError(f"это не адрес и не подсеть: {v!r}") from None


def apply(c, b, ip):
    U = ui()
    from .cloud import Cloud
    adm = b.get("admin") or {}
    name, pw = str(adm.get("name", "")).strip(), str(adm.get("password", ""))
    if not U.NAME_RE.match(name):
        raise ValueError("имя администратора: строчные латинские буквы, цифры, дефис")
    if len(pw) < 12:
        raise ValueError("пароль администратора: не короче 12 символов")
    totp = str(adm.get("totp_secret") or "")
    if totp and not secrets.compare_digest(totp, c.get("setup_totp") or ""):
        raise ValueError("второй фактор не подтверждён: вернитесь к шагу «Администратор» и введите код из приложения")
    env = env_of(b.get("cloud") or {})
    try:
        cl = Cloud(env=env)
    except Exception as ex:  # noqa: BLE001
        raise ValueError(f"Keystone не принял учётные данные: {ex}") from None
    pl, rx, ac = b.get("place") or {}, b.get("receivers") or {}, b.get("access") or {}
    arg = lambda v: U.need({"v": v}, "v")  # noqa: E731
    ui_allow = [cidr(x) for x in ac.get("ui_allow") or []]
    if not ui_allow:
        raise ValueError("нужен хотя бы один адрес или подсеть для веб-интерфейса")
    if not U.ip_allowed(ip, ui_allow) and ip != "127.0.0.1":
        raise ValueError(f"вашего адреса {ip} нет в списке для интерфейса: вы закроете доступ себе")
    allow = [cidr(x) for x in ac.get("allow") or []]
    pool = [arg(x) for x in rx.get("fip_pool") or []]
    with open("/etc/d2g/openrc.new", "w") as f:
        os.chmod("/etc/d2g/openrc.new", 0o600)
        f.write("".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items()))
    os.replace("/etc/d2g/openrc.new", "/etc/d2g/openrc")
    argv = ["setup", "--replace-lists", "--finish-setup", "--network", arg(pl.get("network")), "--az", arg(pl.get("az")),
            "--public-ip", str(pl.get("public_ip") or ""), "--rx-flavor", arg(rx.get("flavor")),
            "--rx-volume-type", arg(rx.get("volume_type")), "--max-volumes", str(int(rx.get("max_volumes") or 20))]
    if pl.get("public_ip"):
        ipaddress.ip_address(pl["public_ip"])
    if rx.get("key"):
        argv += ["--rx-key", arg(rx["key"])]
    if not rx.get("local", True):
        argv.append("--no-local-receiver")
    for x in ui_allow:
        argv += ["--ui-allow", x]
    for x in allow:
        argv += ["--allow", x]
    for x in pool:
        argv += ["--fip-pool", x]
    steps = []
    r = subprocess.run([U.D2G] + argv, capture_output=True, text=True, env=dict(os.environ, D2G_ACTOR=f"setup:{name}"))
    if r.returncode:
        raise ValueError("d2g setup завершился с ошибкой:\n" + (r.stdout + r.stderr)[-2000:])
    steps.append("настройки оркестратора записаны, CA и сертификаты готовы")
    d = orch().db()
    d.execute("INSERT OR REPLACE INTO admins (name, pw, totp, created) VALUES (?,?,?,?)", (name, U.pw_hash(pw), totp or None, now()))
    orch().event(f"setup:{name}", f"setup finished from {ip}; administrator {name} created{' with TOTP' if totp else ''}")
    steps.append(f"администратор {name} создан" + (" (TOTP включён)" if totp else ""))
    if ac.get("ctl_sg"):
        try:
            steps.append(open_ctl_sg(cl, orch().conf(), sorted(set(ui_allow + allow))))
        except Exception as ex:  # noqa: BLE001
            steps.append(f"группу безопасности открыть не удалось: {ex} — откройте 443 вручную")
    if os.path.exists("/etc/d2g/rx.json"):
        subprocess.run(["/opt/d2g/unique-boot.sh"], capture_output=True)
        subprocess.run(["systemctl", "enable", "--now", "d2g-rx"], capture_output=True)
        steps.append("приёмник rx0 на этой ВМ запущен")
    # the orchestrator re-reads its settings on restart: in 2 s, after this reply is sent
    subprocess.Popen(["systemd-run", "-q", "--on-active=2", "systemctl", "restart", "d2g-orch"])
    c2 = orch().conf()
    return {"ok": True, "steps": steps, "url": f"https://{c2.get('public_ip') or c2['grey_ip']}/"}


def open_ctl_sg(cl, c, cidrs):
    """Security group d2g-ctl: 443 from the administrators, the sources and this VM's own subnet
    (receivers), attached to the orchestrator VM."""
    rules = [("tcp", 443, x) for x in cidrs if not ipaddress.ip_network(x).is_loopback]
    for net in cl.call("GET", "network", f"/networks?name={urllib.parse.quote(c['network'])}")["networks"]:
        for sid in net.get("subnets", []):
            rules.append(("tcp", 443, cl.call("GET", "network", f"/subnets/{sid}")["subnet"]["cidr"]))
    cl.ensure_sg(SG_CTL, "d2g orchestrator: 443 from administrators, sources and receivers", rules)
    s = cl.server(c["server_id"])
    if SG_CTL not in {g["name"] for g in s.get("security_groups", [])}:
        cl.call("POST", "compute", f"/servers/{c['server_id']}/action", {"addSecurityGroup": {"name": SG_CTL}})
    return f"группа {SG_CTL} (443 от {len(rules)} адресов и подсетей) подключена к ВМ оркестратора"
