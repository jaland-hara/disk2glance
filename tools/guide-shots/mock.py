# d2g UI on recorded, neutralized API answers (for guide screenshots). mock.py STATIC DATA PORT
import http.server, json, os, sys, urllib.parse
STATIC, DATA, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
SHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shot.js")

def load(name):
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)

def scene_of(h):
    for src in (h.path, h.headers.get("Referer", "")):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(src).query)
        if "scene" in q:
            return q["scene"][0]
    return "05-finished"

class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json; charset=utf-8"):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def page(self, name):
        with open(os.path.join(STATIC, name), "rb") as f:
            html = f.read()
        self.send(200, html.replace(b"</body>", b'<script src="/shot.js"></script>\n</body>'), "text/html; charset=utf-8")

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        sc = scene_of(self)
        if p == "/":
            return self.page("index.html")
        if p in ("/login", "/setup"):
            return self.page(p[1:] + ".html")
        if p == "/shot.js":
            with open(SHOT, "rb") as f:
                return self.send(200, f.read(), "text/javascript; charset=utf-8")
        if p.startswith("/ui/"):
            f = os.path.join(STATIC, p[4:])
            ext = os.path.splitext(f)[1]
            with open(f, "rb") as fh:
                return self.send(200, fh.read(), {".js": "text/javascript", ".css": "text/css", ".html": "text/html"}.get(ext, "application/octet-stream") + "; charset=utf-8")
        if p == "/api/ui/me":
            return self.send(200, load(f"{sc}-me.json"))
        if p == "/api/ui/state":
            s = load(f"{sc}-state.json")
            seen = False   # one "logged in" event is enough
            ev = []
            for e in s["events"]:
                if e["what"].startswith("logged in"):
                    if seen:
                        continue
                    seen = True
                ev.append(e)
            s["events"] = ev
            return self.send(200, s)
        if p == "/api/ui/cloud":
            return self.send(200, load(f"cloud-{q.get('target', ['home'])[0]}.json"))
        if p.startswith("/api/ui/task/"):
            tid = p.rsplit("/", 1)[1]
            for t in load("05-finished-state.json")["tasks"]:
                if t["id"] == tid:
                    return self.send(200, t)
        if p == "/api/setup/info":
            return self.send(200, load("setup-info.json"))
        if p == "/api/setup/totp":
            return self.send(200, {"secret": "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", "issuer": "d2g-5ed4d7"})
        self.send(404, {"error": "not in mock: " + p})

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        if p == "/api/ui/agent/add":
            return self.send(200, load("agent-add.json"))
        if p == "/api/setup/cloud":
            return self.send(200, load("setup-cloud.json"))
        if p == "/api/setup/totp":
            return self.send(200, {"ok": True})
        if p == "/api/setup/apply":
            return self.send(200, load("setup-apply.json"))
        self.send(200, {"message": "ok"})

    def log_message(self, *a):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
