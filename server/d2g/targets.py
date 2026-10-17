"""Target projects: VMs can be moved into other projects than the orchestrator's own ("home").

Each target has its own service account (/etc/d2g/targets/<name>.openrc, 600) and a mode:
- transfer: disks are received in the home project (rx0 / home receivers); on "create VM" the
  volume is detached, transferred to the target project (Cinder volume transfer: request with the
  home account, accept with the target account) and the VM is created there. Same region only.
- receiver: the orchestrator creates receivers inside the target project with its account
  (cloud-init, they talk to the orchestrator over its public address); volumes are created,
  received and turned into VMs there. Works across regions and keeps data inside the project.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import urllib.parse

from . import common as C
from .common import die, log, now

TDIR = os.path.join(C.ETC, "targets")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
MODES = ("transfer", "receiver")
KEYS = ("az", "network", "rx_image", "rx_flavor", "rx_volume_type", "rx_volume_gb", "rx_key", "rx_sg", "allow",
        "fip_pool", "max_volumes", "vm_sg")


def orch():
    from . import orch as O
    return O


def openrc(name):
    return os.path.join(TDIR, f"{name}.openrc")


def row(name):
    return orch().db().execute("SELECT * FROM targets WHERE name=?", (name,)).fetchone()


def tconf(c, name):
    """Effective settings of a target: 'home' is the orchestrator's own project."""
    if not name or name == "home":
        return dict(c, name="home", mode="home", title="проект оркестратора")
    r = row(name)
    if not r:
        raise ValueError(f"no target project {name}")
    t = json.loads(r["conf"] or "{}")
    t.setdefault("rx_flavor", c.get("rx_flavor", "STD3-4-4"))
    t.setdefault("rx_volume_type", c.get("rx_volume_type", "ceph-ssd"))
    t.setdefault("rx_volume_gb", 20)
    t.setdefault("rx_key", "")
    t.setdefault("rx_sg", [])
    t.setdefault("allow", [])
    t.setdefault("fip_pool", [])
    t.setdefault("max_volumes", c.get("max_volumes", 20))
    t.setdefault("vm_sg", ["default"])
    return dict(t, name=name, mode=r["mode"], title=r["title"] or name, project=r["project"], region=r["region"],
                install_id=c["install_id"], domain=c["domain"], ctl_name=c["ctl_name"], part_mb=c.get("part_mb", 64))


def cloud_for(name):
    from .cloud import Cloud
    if not name or name == "home":
        return Cloud()
    return Cloud(openrc=openrc(name))


def volume_owner(t):
    """Where job volumes live: the target itself in receiver mode, else the home project."""
    return t["name"] if t["mode"] == "receiver" else "home"


def find_image(cl):
    """A public Ubuntu 24.04 (else 22.04) image of the target project for its receivers."""
    imgs = cl.call("GET", "image", "/v2/images?visibility=public&status=active&limit=200").get("images", [])
    for pat in (r"^ubuntu-24-\d", r"^ubuntu-22-\d", r"(?i)ubuntu.*24\.04", r"(?i)ubuntu.*22\.04"):
        c = sorted((i for i in imgs if re.search(pat, i.get("name", "")) and "vgpu" not in i["name"].lower()),
                   key=lambda i: i.get("created_at", ""), reverse=True)
        if c:
            return c[0]["id"]
    return None


def egress_ips(cl, network, fip=None):
    """Addresses a VM in this network goes out to the internet with: its FIP and the router SNAT."""
    ips = [fip] if fip else []
    nets = cl.call("GET", "network", f"/networks?name={urllib.parse.quote(network)}")["networks"]
    for n in nets:
        for p in cl.call("GET", "network", f"/ports?network_id={n['id']}&device_owner=network:router_interface")["ports"]:
            r = cl.call("GET", "network", f"/routers/{p['device_id']}")["router"]
            for x in (r.get("external_gateway_info") or {}).get("external_fixed_ips", []):
                ips.append(x["ip_address"])
    return sorted(set(ips))


def open_ctl_for(c, ips):
    """443 on the orchestrator for receivers: rule in SG d2g-ctl if it is attached to it.
    ips: addresses, or "sg:<id>" for a security group of the home project."""
    from .cloud import Cloud
    from .setup import SG_CTL
    home = Cloud()
    s = home.server(c["server_id"])
    if SG_CTL not in {g["name"] for g in s.get("security_groups", [])}:
        log(f"open 443 on the orchestrator for {', '.join(ips)} (security group {SG_CTL} is not attached)")
        return False
    home.ensure_sg(SG_CTL, "d2g orchestrator: 443 from administrators, sources and receivers",
                   [("tcp", 443, ip if ip.startswith("sg:") else f"{ip}/32") for ip in ips])
    return True


def save_openrc(name, env):
    os.makedirs(TDIR, mode=0o700, exist_ok=True)
    tmp = openrc(name) + ".new"
    with open(tmp, "w") as f:
        os.chmod(tmp, 0o600)
        f.write("".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items()))
    os.replace(tmp, openrc(name))


def check(c, env, az=None):
    """Same probes as the setup wizard, without 'this VM is in the project'."""
    from .setup import cloud_check
    b = {"auth_url": env["OS_AUTH_URL"], "project_id": env["OS_PROJECT_ID"], "username": env["OS_USERNAME"],
         "password": env["OS_PASSWORD"], "user_domain": env.get("OS_USER_DOMAIN_NAME", "service-users"),
         "region": env.get("OS_REGION_NAME", "")}
    return cloud_check(c, b, own=False, az=az)


def env_of_openrc(path):
    out = subprocess.run(["bash", "-c", 'set -a; . "$1" >/dev/null; env -0', "_", path],
                         capture_output=True, check=True).stdout.decode()
    return dict(x.split("=", 1) for x in out.split("\0") if x.startswith("OS_"))


# --- CLI ------------------------------------------------------------------------------------------------
def cmd_target(a):
    O = orch()
    c = O.conf()
    d = O.db()
    if a.op == "list":
        print(f"{'home':<12} {'(this)':<9} project {c.get('project', '?')}  AZ {c['az']}  network {c['network']}")
        for r in d.execute("SELECT * FROM targets ORDER BY name"):
            t = tconf(c, r["name"])
            nrx = d.execute("SELECT count(*) FROM receivers WHERE target=? AND state!='deleted'", (r["name"],)).fetchone()[0]
            nj = d.execute("SELECT count(*) FROM jobs WHERE target=? AND state NOT IN ('finished','deleted')", (r["name"],)).fetchone()[0]
            print(f"{r['name']:<12} {r['mode']:<9} project {r['project']}  region {r['region'] or '-'}  AZ {t.get('az', '-')}  "
                  f"network {t.get('network', '-')}  receivers {nrx}  open jobs {nj}  check {'OK' if r['check_ok'] else 'FAILED'}")
        return
    if not a.name or not NAME_RE.match(a.name) or a.name == "home":
        die("target name: lowercase letters, digits, '-' (not 'home')")
    if a.op in ("add", "set"):
        r = row(a.name)
        if a.op == "add" and r:
            die(f"target {a.name} exists (use 'd2g target set')")
        if a.op == "set" and not r:
            die(f"no target {a.name}")
        if a.openrc:
            env = env_of_openrc(a.openrc)
        elif r:
            env = env_of_openrc(openrc(a.name))
        else:
            die("--openrc FILE with the target project's service account is required")
        mode = a.mode or (r["mode"] if r else "transfer")
        if mode not in MODES:
            die(f"mode: {' | '.join(MODES)}")
        t = json.loads(r["conf"]) if r else {}
        for k in ("az", "network", "rx_image", "rx_flavor", "rx_volume_type", "rx_key"):
            v = getattr(a, k, None)
            if v:
                t[k] = v
        for k in ("allow", "fip_pool", "vm_sg"):
            v = getattr(a, k, None) or []
            if v:
                t[k] = sorted(set(v)) if a.replace_lists else sorted(set(t.get(k, []) + v))
        if a.max_volumes:
            t["max_volumes"] = a.max_volumes
        res = check(c, env, az=t.get("az"))
        for x in res["checks"]:
            print(("  OK   " if x["ok"] else "  FAIL ") + x["name"] + (f" — {x['detail']}" if x["detail"] else ""))
        if not res["ok"] and not a.force:
            die("the account does not pass the checks (--force to save anyway)")
        L = res.get("lists", {})
        t.setdefault("az", res.get("az") or (L.get("zones") or [None])[0])
        if mode == "receiver":
            if not t.get("network"):
                die("--network is required for mode receiver (the network of the target's receivers)")
            if not t.get("rx_image"):
                from .cloud import Cloud
                t["rx_image"] = find_image(Cloud(env=env)) or die("no public Ubuntu image found: pass --rx-image ID")
            if not c.get("public_ip"):
                die("mode receiver needs a public address of the orchestrator (d2g setup --public-ip): "
                    "receivers in other projects reach it over the internet")
        if mode == "transfer" and t.get("az") and t["az"] not in (L.get("zones") or [t["az"]]):
            log(f"WARN: zone {t['az']} is not in the target's zones {L.get('zones')}")
        save_openrc(a.name, env)
        d.execute("INSERT INTO targets (name, title, mode, project, region, conf, created, checked_at, check_ok) "
                  "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET title=excluded.title, mode=excluded.mode, "
                  "project=excluded.project, region=excluded.region, conf=excluded.conf, checked_at=excluded.checked_at, "
                  "check_ok=excluded.check_ok",
                  (a.name, a.title or (r["title"] if r else a.name), mode, env["OS_PROJECT_ID"],
                   env.get("OS_REGION_NAME", ""), json.dumps(t), r["created"] if r else now(), now(), int(res["ok"])))
        O.event(O.actor(), f"target {a.name}: {'added' if a.op == 'add' else 'changed'}, mode {mode}, "
                           f"project {env['OS_PROJECT_ID']}")
        print(f"target {a.name}: mode {mode}, project {env['OS_PROJECT_ID']}, AZ {t.get('az')}, network {t.get('network', '-')}")
    elif a.op == "check":
        r = row(a.name) or die(f"no target {a.name}")
        res = check(c, env_of_openrc(openrc(a.name)), az=json.loads(r["conf"]).get("az"))
        for x in res["checks"]:
            print(("  OK   " if x["ok"] else "  FAIL ") + x["name"] + (f" — {x['detail']}" if x["detail"] else ""))
        d.execute("UPDATE targets SET checked_at=?, check_ok=? WHERE name=?", (now(), int(res["ok"]), a.name))
    elif a.op == "delete":
        row(a.name) or die(f"no target {a.name}")
        busy = d.execute("SELECT id FROM jobs WHERE target=? AND state NOT IN ('finished','deleted')", (a.name,)).fetchall()
        rx = d.execute("SELECT name FROM receivers WHERE target=? AND state!='deleted'", (a.name,)).fetchall()
        if busy or rx:
            die(f"target {a.name} still has jobs {[x['id'] for x in busy]} / receivers {[x['name'] for x in rx]}")
        d.execute("DELETE FROM targets WHERE name=?", (a.name,))
        try:
            os.remove(openrc(a.name))
        except FileNotFoundError:
            pass
        O.event(O.actor(), f"target {a.name}: deleted")
        print(f"target {a.name}: deleted (its account file removed)")


