"""Схемы для docs/guide.md: python3 make-diagrams.py -> *.svg рядом с файлом. Без внешних зависимостей."""
import os
from xml.sax.saxutils import escape as E

OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "Arial, Helvetica, sans-serif"
INK, MUT, LINE = "#1C2430", "#5B6676", "#3A4556"
BLUE, GREEN, ORANGE, PURPLE, GREY = "#2458D6", "#1B7F3B", "#C46A00", "#7A3DB8", "#6B7684"
FILL = {BLUE: "#EAF0FD", GREEN: "#E9F6EE", ORANGE: "#FDF1E3", PURPLE: "#F3ECFB", GREY: "#F1F3F6"}


class Svg:
    def __init__(self, w, h, title, sub=""):
        self.w, self.h, self.o = w, h, []
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
        mid = f"a{abs(hash((tuple(pts), c))) % 100000}"
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

    def save(self, name):
        with open(os.path.join(OUT, name), "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">'
                    + "".join(self.o) + "</svg>\n")


# 1. Общая схема ---------------------------------------------------------------------------------------
s = Svg(1200, 560, "Как устроен перенос", "Данные идут с исходной ВМ прямо в том целевого проекта; облачная учётная запись есть только у оркестратора")
s.zone(30, 100, 300, 330, "Исходные ВМ", GREY)
s.box(55, 145, 250, 70, "app01", ["агент disk2rx"])
s.box(55, 240, 250, 70, "db01", ["агент disk2rx"])
s.t(180, 345, "в ЦОДе, другом облаке", 13, MUT, anchor="middle")
s.t(180, 363, "или в другом проекте VK Cloud", 13, MUT, anchor="middle")
s.zone(430, 100, 740, 330, "Целевой проект VK Cloud", BLUE)
s.box(460, 145, 330, 160, "ВМ оркестратора", ["nginx :443", "оркестратор (веб-интерфейс, команда d2g)", "приёмник rx0", "учётная запись облака — только здесь"], c=BLUE)
s.box(860, 145, 140, 70, "том 1", ["копия app01"], c=GREEN)
s.box(860, 240, 140, 70, "том 2", ["копия db01"], c=GREEN)
s.box(1040, 190, 110, 70, "новая ВМ", ["с тома"], c=GREEN)
s.box(460, 335, 330, 70, "администратор", ["браузер → SSH-туннель → интерфейс"], c=GREY, fill="#F7F8FA")
s.arrow([(305, 180), (460, 180)], "HTTPS 443\n(mTLS)")
s.arrow([(305, 275), (380, 275), (380, 230), (460, 230)])
s.arrow([(790, 180), (860, 180)])
s.arrow([(790, 260), (860, 275)])
s.arrow([(1000, 180), (1040, 215)], c=GREEN)
s.arrow([(625, 335), (625, 305)], c=GREY)
s.num(30 + 15, 470, 1); s.t(70, 476, "Агент делает снапшот диска и отправляет только занятые блоки.", 14)
s.num(30 + 15, 505, 2); s.t(70, 511, "Приёмник записывает их в том; повторные проходы (дельты) передают только изменения.", 14)
s.num(640, 470, 3, GREEN); s.t(665, 476, "«Создать ВМ»: том отключается от приёмника,", 14)
s.t(665, 494, "и из него создаётся новая ВМ.", 14)
s.save("overview.svg")

# 2. SSH-туннель ---------------------------------------------------------------------------------------
s = Svg(1200, 400, "Как открыть веб-интерфейс через SSH-туннель", "Порт 443 наружу открывать не нужно: браузер подключается через SSH, интерфейс видит обращение с 127.0.0.1")
s.zone(30, 100, 400, 210, "Компьютер администратора", GREY)
s.box(55, 145, 160, 80, "браузер", ["https://localhost:8443"])
s.box(250, 145, 160, 80, "ssh -L", ["8443 → 127.0.0.1:443"])
s.zone(560, 100, 610, 210, "ВМ оркестратора (FIP 203.0.113.10)", BLUE)
s.box(590, 145, 160, 80, "sshd :22", ["вход по ключу"], c=BLUE)
s.box(800, 145, 160, 80, "nginx :443", ["127.0.0.1"], c=BLUE)
s.box(990, 145, 160, 80, "веб-интерфейс", ["d2g"], c=BLUE)
s.arrow([(215, 185), (250, 185)])
s.arrow([(410, 185), (590, 185)], "SSH, порт 22\nчерез интернет")
s.arrow([(750, 185), (800, 185)])
s.arrow([(960, 185), (990, 185)])
s.t(30, 350, "Команда на компьютере администратора:", 14, INK, bold=True)
s.t(30, 376, "ssh -i ~/.ssh/<ключ> -L 8443:127.0.0.1:443 ubuntu@203.0.113.10", 15, INK, mono=True)
s.save("ssh-tunnel.svg")

# 3. Этапы переноса ------------------------------------------------------------------------------------
s = Svg(1200, 470, "Этапы переноса одной ВМ", "Исходная ВМ всё это время работает; останавливать приложение нужно только перед последней дельтой (при необходимости)")
steps = [("Агент", ["команда из интерфейса,", "запуск на исходной ВМ"], GREY),
         ("Задание", ["том по размеру диска", "у приёмника"], BLUE),
         ("Первый проход", ["все занятые блоки", "снапшот → том"], BLUE),
         ("Дельты", ["только изменения,", "по расписанию"], BLUE),
         ("Создать ВМ", ["том отключается,", "ВМ создаётся с тома"], GREEN),
         ("Удалить агента", ["с исходной ВМ", "(на копии выключен)"], GREY)]
x = 30
for i, (n, l, c) in enumerate(steps):
    s.box(x, 130, 172, 100, n, l, c=c)
    s.num(x + 20, 130, i + 1, c if c != GREY else LINE)
    if i < len(steps) - 1:
        s.arrow([(x + 172, 180), (x + 196, 180)])
    x += 196
s.arrow([(30 + 3 * 196 + 86, 230), (30 + 3 * 196 + 86, 275), (30 + 3 * 196 + 140, 275), (30 + 3 * 196 + 140, 232)], "повторять", c=BLUE, lpos=(30 + 3 * 196 + 113, 300))
s.t(30, 360, "Где смотреть:", 14, INK, bold=True)
s.t(30, 386, "1 — вкладка «Исходные ВМ»;  2–4 — «Задания» и «Обзор» (прогресс);  5 — «Задания» → «Создать ВМ»,", 14, MUT)
s.t(30, 408, "ход создания — «Журнал»;  6 — «Исходные ВМ» → «Удалить агента».", 14, MUT)
s.t(30, 440, "После шага 5 новые проходы по этому заданию невозможны: том уже стал диском новой ВМ.", 14, ORANGE)
s.save("stages.svg")

# 4. Перенос в другой проект ---------------------------------------------------------------------------
s = Svg(1200, 640, "Перенос в другой проект", "Оркестратор один; для каждого проекта на вкладке «Проекты» добавляется его служебная учётная запись")
s.t(30, 115, "А. Передача тома — проект в том же регионе", 17, BLUE, bold=True)
s.zone(30, 130, 560, 200, "Проект оркестратора", BLUE)
s.box(60, 175, 170, 80, "приёмник rx0", ["принимает диск"], c=BLUE)
s.box(290, 175, 140, 80, "том", ["копия диска"], c=GREEN)
s.zone(650, 130, 520, 200, "Проект клиента (тот же регион)", PURPLE)
s.box(690, 175, 140, 80, "том", ["тот же том"], c=GREEN)
s.box(900, 175, 160, 80, "новая ВМ", ["с тома"], c=GREEN)
s.arrow([(230, 215), (290, 215)])
s.arrow([(430, 215), (690, 215)], "передача тома\n(Cinder transfer)", c=PURPLE)
s.arrow([(830, 215), (900, 215)], c=GREEN)
s.t(60, 300, "В проекте клиента не нужны ни приёмник, ни FIP. Режим ещё не проверен на стенде.", 13, MUT)
s.t(30, 380, "Б. Свой приёмник — другой регион или данные не должны попадать в проект оркестратора", 17, ORANGE, bold=True)
s.zone(30, 395, 380, 200, "Проект оркестратора", BLUE)
s.box(60, 440, 320, 80, "оркестратор", ["управляет, данных не принимает"], c=BLUE)
s.zone(470, 395, 700, 200, "Проект клиента (любой регион)", ORANGE)
s.box(500, 440, 180, 80, "приёмник", ["создан оркестратором"], c=ORANGE)
s.box(740, 440, 140, 80, "том", ["копия диска"], c=GREEN)
s.box(940, 440, 160, 80, "новая ВМ", ["с тома"], c=GREEN)
s.arrow([(500, 470), (380, 470)], "управление\nчерез интернет", c=GREY, dash=True, lpos=(440, 445))
s.arrow([(680, 480), (740, 480)])
s.arrow([(880, 480), (940, 480)], c=GREEN)
s.t(500, 565, "Исходные ВМ отправляют диск прямо на этот приёмник (по серому адресу или его FIP).", 13, MUT)
s.save("projects.svg")
print("ok")
