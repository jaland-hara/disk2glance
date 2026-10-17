"""OpenStack REST (Keystone v3, Nova 2.1+, Cinder v3, Neutron) without client libraries."""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from .common import ETC

OPENRC = os.path.join(ETC, "openrc")


class Cloud:
    def __init__(self, openrc=OPENRC, env=None):
        if env is None:
            # openrc is a shell file (quoting, $'..' escapes): let bash parse it
            out = subprocess.run(["bash", "-c", 'set -a; . "$1" >/dev/null; env -0', "_", openrc],
                                 capture_output=True, check=True).stdout.decode()
            env = dict(x.split("=", 1) for x in out.split("\0") if x.startswith("OS_"))
        self.env = env
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
        self.t_auth = time.time()
        region = e.get("OS_REGION_NAME")
        self.ep = {}
        for s in cat:
            for x in s["endpoints"]:
                if x["interface"] == "public" and (not region or x.get("region") == region):
                    self.ep[s["type"]] = x["url"].rstrip("/")
        self.project = e["OS_PROJECT_ID"]

    def call(self, method, svc, path, body=None):
        if time.time() - self.t_auth > 2400:   # VK tokens live 1 h
            self.auth()
        base = self.ep[svc]
        if svc == "network" and not base.endswith("/v2.0"):
            base += "/v2.0"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data, {"X-Auth-Token": self.token, "Content-Type": "application/json",
                                                         "Accept": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as ex:
            if ex.code == 404 and method in ("GET", "DELETE"):
                raise NotFound(f"{method} {svc}{path}") from None
            msg = ex.read().decode(errors="replace")[:400]
            raise RuntimeError(f"{method} {svc}{path}: HTTP {ex.code} {msg}") from None

    # --- volumes ---
    def vol(self, vid):
        return self.call("GET", "volumev3", f"/volumes/{vid}")["volume"]

    def wait_vol(self, vid, want, timeout=900):
        t = time.time()
        while time.time() - t < timeout:
            st = self.vol(vid)["status"]
            if st == want:
                return
            if st.startswith("error"):
                raise RuntimeError(f"volume {vid}: {st}")
            time.sleep(3)
        raise RuntimeError(f"volume {vid}: timeout waiting for {want}")

    def create_volume(self, name, gb, vtype, az, image=None, meta=None, desc=""):
        v = {"size": gb, "availability_zone": az, "name": name, "description": desc, "metadata": meta or {}}
        if vtype:
            v["volume_type"] = vtype
        if image:
            v["imageRef"] = image
        return self.call("POST", "volumev3", "/volumes", {"volume": v})["volume"]["id"]

    def attach(self, server, vid):
        self.call("POST", "compute", f"/servers/{server}/os-volume_attachments", {"volumeAttachment": {"volumeId": vid}})
        self.wait_vol(vid, "in-use")

    def detach(self, server, vid):
        self.call("DELETE", "compute", f"/servers/{server}/os-volume_attachments/{vid}")
        self.wait_vol(vid, "available")

    def vol_action(self, vid, action):
        self.call("POST", "volumev3", f"/volumes/{vid}/action", action)

    # --- servers ---
    def server(self, sid):
        return self.call("GET", "compute", f"/servers/{sid}")["server"]

    def flavor_id(self, name):
        fl = [f for f in self.call("GET", "compute", "/flavors")["flavors"] if f["name"] == name or f["id"] == name]
        if not fl:
            raise RuntimeError(f"no flavor {name}")
        return fl[0]["id"]

    def network_id(self, name):
        nets = self.call("GET", "network", f"/networks?name={urllib.parse.quote(name)}")["networks"]
        return nets[0]["id"] if nets else name

    def create_server(self, name, flavor, az, net, vid, sgs, key=None, user_data=None, delete_vol=False, meta=None):
        s = {"name": name, "flavorRef": self.flavor_id(flavor), "availability_zone": az,
             "networks": [{"uuid": self.network_id(net)}],
             "block_device_mapping_v2": [{"uuid": vid, "source_type": "volume", "destination_type": "volume",
                                          "boot_index": 0, "delete_on_termination": delete_vol}],
             "security_groups": [{"name": g} for g in sgs], "metadata": meta or {}}
        if key:
            s["key_name"] = key
        if user_data:
            s["user_data"] = base64.b64encode(user_data.encode()).decode()
        return self.call("POST", "compute", "/servers", {"server": s})["server"]["id"]

    def wait_server(self, sid, timeout=600):
        t = time.time()
        while time.time() - t < timeout:
            s = self.server(sid)
            if s["status"] == "ACTIVE":
                return s
            if s["status"] == "ERROR":
                raise RuntimeError(f"server {sid}: ERROR {s.get('fault', {}).get('message', '')}")
            time.sleep(3)
        raise RuntimeError(f"server {sid}: timeout")

    def delete_server(self, sid):
        try:
            self.call("DELETE", "compute", f"/servers/{sid}")
        except NotFound:
            return
        t = time.time()
        while time.time() - t < 300:
            try:
                self.server(sid)
            except NotFound:
                return
            time.sleep(3)

    def server_ip(self, s, net):
        for n, addrs in s.get("addresses", {}).items():
            for a in addrs:
                if a.get("OS-EXT-IPS:type", "fixed") == "fixed" and (n == net or len(s["addresses"]) == 1):
                    return a["addr"]
        return None

    # --- floating IPs and security groups ---
    def fip(self, fid):
        return self.call("GET", "network", f"/floatingips/{fid}")["floatingip"]

    def fip_attach(self, fid, server):
        ports = self.call("GET", "network", f"/ports?device_id={server}")["ports"]
        if not ports:
            raise RuntimeError(f"server {server} has no port")
        return self.call("PUT", "network", f"/floatingips/{fid}", {"floatingip": {"port_id": ports[0]["id"]}})["floatingip"]

    def fip_detach(self, fid):
        self.call("PUT", "network", f"/floatingips/{fid}", {"floatingip": {"port_id": None}})

    def ensure_sg(self, name, desc, rules):
        """rules: [(proto, port, cidr)]; adds missing ones, keeps others."""
        sgs = self.call("GET", "network", f"/security-groups?name={urllib.parse.quote(name)}")["security_groups"]
        sg = sgs[0] if sgs else self.call("POST", "network", "/security-groups",
                                          {"security_group": {"name": name, "description": desc}})["security_group"]
        have = {(r.get("protocol"), r.get("port_range_min"), r.get("remote_ip_prefix"))
                for r in sg.get("security_group_rules", []) if r.get("direction") == "ingress"}
        for proto, port, cidr in rules:
            if (proto, port, cidr) in have:
                continue
            self.call("POST", "network", "/security-group-rules", {"security_group_rule": {
                "security_group_id": sg["id"], "direction": "ingress", "ethertype": "IPv4", "protocol": proto,
                "port_range_min": port, "port_range_max": port, "remote_ip_prefix": cidr}})
        return sg["id"]


class NotFound(RuntimeError):
    pass


def metadata():
    with urllib.request.urlopen("http://169.254.169.254/openstack/latest/meta_data.json", timeout=10) as r:
        return json.load(r)
