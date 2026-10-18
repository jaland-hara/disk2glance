"""Общий код схем документации: строгий стиль — тонкие линии, ортогональные стрелки от края до
края блоков, подписи рядом с линиями. Без внешних зависимостей."""
from xml.sax.saxutils import escape as E

FONT = "Arial, Helvetica, sans-serif"
MONO = "Menlo, Consolas, monospace"
INK, MUT, LINE, FAINT = "#1C2430", "#5B6676", "#3A4556", "#C9D1DC"
BLUE, GREEN, ORANGE, PURPLE, GREY = "#2458D6", "#1B7F3B", "#B35A00", "#6B3FA0", "#6B7684"
FILL = {BLUE: "#F2F6FE", GREEN: "#F1F8F3", ORANGE: "#FDF5EC", PURPLE: "#F6F2FB", GREY: "#F6F7F9", LINE: "#FFFFFF"}


class Box:
    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h

    def l(self, f=0.5):
        return (self.x, self.y + self.h * f)

    def r(self, f=0.5):
        return (self.x + self.w, self.y + self.h * f)

    def t(self, f=0.5):
        return (self.x + self.w * f, self.y)

    def b(self, f=0.5):
        return (self.x + self.w * f, self.y + self.h)


class Svg:
    def __init__(self, w, h, title, sub=""):
        self.w, self.h, self.o, self.n = w, h, [], 0
        self.o.append(f'<rect width="{w}" height="{h}" fill="#FFFFFF"/>')
        self.t(32, 42, title, 22, INK, bold=True)
        if sub:
            self.t(32, 66, sub, 14, MUT)
        self.o.append(f'<line x1="32" y1="80" x2="{w - 32}" y2="80" stroke="{FAINT}" stroke-width="1"/>')

    def t(self, x, y, s, size=13, fill=INK, bold=False, anchor="start", mono=False):
        self.o.append(f'<text x="{x}" y="{y}" font-family="{MONO if mono else FONT}" font-size="{size}" fill="{fill}" '
                      f'font-weight="{700 if bold else 400}" text-anchor="{anchor}">{E(s)}</text>')

    def zone(self, x, y, w, h, title, c=GREY):
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{FILL.get(c, "#F6F7F9")}" stroke="{FAINT}" stroke-width="1"/>')
        self.o.append(f'<rect x="{x}" y="{y}" width="4" height="{h}" fill="{c}"/>')
        self.t(x + 16, y + 22, title.upper(), 11.5, c, bold=True)

    def box(self, x, y, w, h, name, lines=(), c=LINE, fill="#FFFFFF", dash=False):
        da = ' stroke-dasharray="5 4"' if dash else ""
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="3" fill="{fill}" stroke="{c}" stroke-width="1.4"{da}/>')
        n = 1 + len(lines)
        top = y + h / 2 - (n - 1) * 8.5 + 4.5
        self.t(x + w / 2, top, name, 14, INK, bold=True, anchor="middle")
        for i, s in enumerate(lines):
            self.t(x + w / 2, top + 19 + i * 17, s, 12, MUT, anchor="middle")
        return Box(x, y, w, h)

    def num(self, x, y, n, c=LINE):
        self.o.append(f'<circle cx="{x}" cy="{y}" r="10" fill="{c}"/>')
        self.t(x, y + 4, str(n), 11.5, "#FFFFFF", bold=True, anchor="middle")

    def arrow(self, pts, label="", c=LINE, dash=False, lpos=None, width=1.6, anchor="middle", lc=None):
        """pts: orthogonal polyline from edge to edge; label at lpos (x, y of the text baseline)."""
        self.n += 1
        mid = f"m{self.n}"
        d = " ".join(f"{'M' if i == 0 else 'L'}{x},{y}" for i, (x, y) in enumerate(pts))
        da = ' stroke-dasharray="6 4"' if dash else ""
        self.o.append(f'<defs><marker id="{mid}" markerWidth="8" markerHeight="8" refX="7.5" refY="4" orient="auto" '
                      f'markerUnits="userSpaceOnUse"><path d="M0,0.5 L8,4 L0,7.5 z" fill="{c}"/></marker></defs>')
        self.o.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{width}"{da} marker-end="url(#{mid})"/>')
        if label and lpos:
            for i, s in enumerate(label.split("\n")):
                self.t(lpos[0], lpos[1] + i * 15, s, 12, lc or c, anchor=anchor)

    def line(self, x1, y1, x2, y2, c=FAINT, w=1, dash=False):
        da = ' stroke-dasharray="5 4"' if dash else ""
        self.o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{c}" stroke-width="{w}"{da}/>')

    def rect(self, x, y, w, h, fill, stroke=FAINT, rx=2, sw=1):
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')

    def save(self, path):
        with open(path, "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">'
                    + "".join(self.o) + "</svg>\n")
