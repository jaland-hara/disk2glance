"""Общий код схем документации: блоки, зоны, стрелки, подписи. Без внешних зависимостей."""
import os
from xml.sax.saxutils import escape as E

FONT = "Arial, Helvetica, sans-serif"
INK, MUT, LINE = "#1C2430", "#5B6676", "#3A4556"
BLUE, GREEN, ORANGE, PURPLE, GREY = "#2458D6", "#1B7F3B", "#C46A00", "#7A3DB8", "#6B7684"
FILL = {BLUE: "#EAF0FD", GREEN: "#E9F6EE", ORANGE: "#FDF1E3", PURPLE: "#F3ECFB", GREY: "#F1F3F6"}


class Svg:
    def __init__(self, w, h, title, sub=""):
        self.w, self.h, self.o, self.n = w, h, [], 0
        self.o.append(f'<rect width="{w}" height="{h}" fill="#FFFFFF"/>')
        self.t(32, 44, title, 24, INK, bold=True)
        if sub:
            self.t(32, 70, sub, 15, MUT)

    def t(self, x, y, s, size=14, fill=INK, bold=False, anchor="start", mono=False):
        fam = "Menlo, Consolas, monospace" if mono else FONT
        self.o.append(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" fill="{fill}" '
                      f'font-weight="{700 if bold else 400}" text-anchor="{anchor}">{E(s)}</text>')

    def zone(self, x, y, w, h, title, c):
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{FILL[c]}" stroke="{c}" '
                      f'stroke-width="2" stroke-dasharray="8 6"/>')
        self.t(x + 16, y + 26, title, 16, c, bold=True)

    def box(self, x, y, w, h, name, lines=(), c=LINE, fill="#FFFFFF"):
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" stroke="{c}" stroke-width="2"/>')
        self.t(x + w / 2, y + 24, name, 15, INK, bold=True, anchor="middle")
        for i, s in enumerate(lines):
            self.t(x + w / 2, y + 44 + i * 18, s, 13, MUT, anchor="middle")
        return (x, y, w, h)

    def num(self, x, y, n, c=BLUE):
        self.o.append(f'<circle cx="{x}" cy="{y}" r="15" fill="{c}"/>')
        self.t(x, y + 5, str(n), 15, "#FFFFFF", bold=True, anchor="middle")

    def arrow(self, pts, label="", c=LINE, dash=False, lpos=None, width=2.5):
        d = " ".join(f"{'M' if i == 0 else 'L'}{x},{y}" for i, (x, y) in enumerate(pts))
        da = ' stroke-dasharray="7 5"' if dash else ""
        self.n += 1
        mid = f"a{self.n}"
        self.o.append(f'<defs><marker id="{mid}" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto">'
                      f'<path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker></defs>')
        self.o.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{width}"{da} marker-end="url(#{mid})"/>')
        if label:
            (x1, y1), (x2, y2) = pts[0], pts[1]
            lx, ly = lpos or ((x1 + x2) / 2, (y1 + y2) / 2)
            for i, s in enumerate(label.split("\n")):
                wpx = len(s) * 7.2 + 12
                yy = ly - 8 + i * 18
                self.o.append(f'<rect x="{lx - wpx / 2}" y="{yy - 13}" width="{wpx}" height="18" rx="4" fill="#FFFFFF" opacity="0.95"/>')
                self.t(lx, yy, s, 13, c, anchor="middle")

    def save(self, path):
        with open(path, "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">'
                    + "".join(self.o) + "</svg>\n")


