"use strict";
// d2g first-run setup wizard. Talks to /api/setup/* with the one-time code from the installer.
const $ = (s, r = document) => r.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const STEPS = ["Администратор", "Облако", "Размещение", "Приёмники", "Доступ", "Применить"];
const W = { code: "", info: null, step: 0, admin: { name: "admin", password: "", totp: false, totp_secret: "", totp_code: "" },
  cloud: { auth_url: "https://infra.mail.ru:35357/v3/", project_id: "", username: "", password: "", user_domain: "service-users", region: "RegionOne" },
  check: null, place: {}, rx: { local: true, flavor: "", volume_type: "", max_volumes: 20, fip_pool: [], key: "" },
  access: { ui_allow: "", allow: "", ctl_sg: true } };

function toast(msg, bad) {
  const d = document.createElement("div");
  if (bad) d.className = "bad";
  d.textContent = msg;
  $("#toast").appendChild(d);
  setTimeout(() => d.remove(), bad ? 10000 : 5000);
}
async function api(path, body) {
  const opt = { headers: { "X-Setup-Code": W.code } };
  if (body !== undefined) { opt.method = "POST"; opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body); }
  const r = await fetch(path, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || "HTTP " + r.status);
  return j;
}
const opt = (list, cur, label) => list.map((x) => { const v = typeof x === "object" ? x.name : x; return `<option value="${esc(v)}" ${v === cur ? "selected" : ""}>${esc(label ? label(x) : v)}</option>`; }).join("");
const flavorLabel = (f) => `${f.name} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ`;
const field = (label, html, hint) => `<div class="field"><label>${esc(label)}</label>${html}${hint ? `<div class="hint">${hint}</div>` : ""}</div>`;
const lines = (t) => t.split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean);

function nav(back, next, nextText) {
  return `<div class="wnav">${back ? `<button class="btn" id="back">Назад</button>` : "<span></span>"}
    ${next ? `<button class="btn primary" id="next">${esc(nextText || "Далее")}</button>` : ""}</div>`;
}
function steps() {
  $("#steps").hidden = false;
  $("#steps").innerHTML = STEPS.map((s, i) => `<div class="${i === W.step ? "on" : i < W.step ? "done" : ""}">${i < W.step ? "✓ " : (i + 1) + ". "}${esc(s)}</div>`).join("");
}
function go(n) { W.step = n; steps(); PAGES[n](); window.scrollTo(0, 0); }
function bind(id, fn) { const e = $("#" + id); if (e) e.addEventListener("click", fn); }

// --- step 0: the setup code ---
function pageCode() {
  $("#page").innerHTML = `<h2>Первоначальная настройка оркестратора</h2>
    <p class="lead">Введите одноразовый код настройки. Код выведен установщиком; новый код: <span class="mono">sudo d2g setup-code</span> на ВМ оркестратора.</p>
    <form id="cf">${field("Код настройки", `<input id="code" class="mono" placeholder="xxxx-xxxx-xxxx" autocomplete="off" autofocus>`)}
    <div class="err" id="cerr"></div><button class="btn primary" type="submit">Продолжить</button></form>`;
  $("#cf").addEventListener("submit", async (e) => {
    e.preventDefault();
    W.code = $("#code").value.trim();
    try {
      W.info = await api("/api/setup/info");
      $("#ctl").textContent = W.info.ctl_name;
      $("#ver").textContent = "версия " + W.info.version;
      W.place.public_ip = W.info.public_ip;
      const me = W.info.client_ip;
      W.access.ui_allow = me && me !== "127.0.0.1" ? me + "/32" : "127.0.0.1/32";
      go(0);
    } catch (x) { $("#cerr").textContent = x.message; }
  });
}

// --- step 1: administrator ---
function page1() {
  const a = W.admin;
  $("#page").innerHTML = `<h2>Администратор</h2><p class="lead">Первая учётная запись веб-интерфейса. Других можно добавить позже командой <span class="mono">d2g admin add</span>.</p>
    ${field("Имя", `<input id="an" value="${esc(a.name)}" maxlength="32">`, "строчные латинские буквы, цифры, дефис")}
    <div class="grid2">${field("Пароль", `<input id="ap" type="password" autocomplete="new-password" value="${esc(a.password)}">`, "не короче 12 символов")}
    ${field("Ещё раз", `<input id="ap2" type="password" autocomplete="new-password" value="${esc(a.password)}">`)}</div>
    <div class="field checks"><label><input type="checkbox" id="at" ${a.totp ? "checked" : ""}> Второй фактор: код из приложения (TOTP) — рекомендуется, если интерфейс открыт по FIP</label></div>
    <div id="totp"></div><div class="err" id="err"></div>${nav(false, true)}`;
  const showTotp = async () => {
    if (!$("#at").checked) { $("#totp").innerHTML = ""; return; }
    if (!a.totp_secret) a.totp_secret = (await api("/api/setup/totp")).secret;
    const name = $("#an").value.trim() || "admin";
    const uri = `otpauth://totp/${encodeURIComponent("d2g-" + W.info.ctl_name.split(".")[1] + ":" + name)}?secret=${a.totp_secret}&issuer=${encodeURIComponent("d2g-" + W.info.ctl_name.split(".")[1])}`;
    const q = qrcode(0, "M"); q.addData(uri); q.make();
    $("#totp").innerHTML = `<div class="qr"><img alt="QR-код для приложения" src="${q.createDataURL(5, 2)}">
      <div><p class="small">Отсканируйте код приложением (Google Authenticator, Яндекс Ключ, 1Password…) или введите секрет вручную:</p>
      <pre class="cmd">${esc(a.totp_secret)}</pre>${field("Код из приложения", `<input id="ac" inputmode="numeric" maxlength="8" value="${esc(a.totp_code)}">`, "проверяется при переходе к следующему шагу")}</div></div>`;
  };
  $("#at").addEventListener("change", () => showTotp().catch((x) => toast(x.message, true)));
  if (a.totp) showTotp();
  bind("next", () => {
    a.name = $("#an").value.trim(); a.password = $("#ap").value; a.totp = $("#at").checked;
    a.totp_code = $("#ac") ? $("#ac").value.trim() : "";
    if (!/^[a-z0-9][a-z0-9-]{0,31}$/.test(a.name)) return ($("#err").textContent = "Имя: строчные латинские буквы, цифры, дефис.");
    if (a.password.length < 12) return ($("#err").textContent = "Пароль не короче 12 символов.");
    if (a.password !== $("#ap2").value) return ($("#err").textContent = "Пароли не совпадают.");
    if (!a.totp) return go(1);
    if (!/^\d{6}$/.test(a.totp_code)) return ($("#err").textContent = "Введите 6 цифр кода из приложения.");
    api("/api/setup/totp", { secret: a.totp_secret, code: a.totp_code }).then(() => go(1)).catch((x) => { $("#err").textContent = x.message; });
  });
}

// --- step 2: cloud credentials ---
function page2() {
  const c = W.cloud, ch = W.check;
  $("#page").innerHTML = `<h2>Облако</h2><p class="lead">Сервисная учётная запись проекта, в который переносятся ВМ. Она хранится только на этой ВМ (<span class="mono">/etc/d2g/openrc</span>, права 600) и на исходные ВМ не попадает.</p>
    ${field("Адрес Keystone", `<input id="u" value="${esc(c.auth_url)}">`)}
    <div class="grid2">${field("ID проекта", `<input id="pr" class="mono" value="${esc(c.project_id)}">`)}${field("Регион", `<input id="rg" value="${esc(c.region)}">`)}</div>
    <div class="grid2">${field("Пользователь", `<input id="un" value="${esc(c.username)}" autocomplete="off">`)}${field("Домен пользователя", `<input id="dm" value="${esc(c.user_domain)}">`, "у сервисных учётных записей VK Cloud — service-users")}</div>
    ${field("Пароль", `<input id="pw" type="password" autocomplete="off" value="${esc(c.password)}">`)}
    <button class="btn" id="chk">Проверить</button> <span id="chs"></span>
    <div id="res">${ch ? checks(ch) : ""}</div><div class="err" id="err"></div>${nav(true, true)}`;
  const read = () => Object.assign(c, { auth_url: $("#u").value.trim(), project_id: $("#pr").value.trim(), region: $("#rg").value.trim(),
    username: $("#un").value.trim(), user_domain: $("#dm").value.trim(), password: $("#pw").value });
  bind("chk", async () => {
    read();
    $("#chs").innerHTML = '<span class="spinner"></span>создаю и удаляю пробный том и группу безопасности…';
    $("#res").innerHTML = ""; $("#err").textContent = "";
    try { W.check = await api("/api/setup/cloud", c); $("#res").innerHTML = checks(W.check); }
    catch (x) { W.check = null; $("#err").textContent = x.message; }
    $("#chs").textContent = "";
  });
  bind("back", () => { read(); go(0); });
  bind("next", () => {
    read();
    if (!W.check) return ($("#err").textContent = "Сначала нажмите «Проверить».");
    if (!W.check.ok && !confirm("Не все проверки прошли. Продолжить всё равно?")) return;
    go(2);
  });
}
function checks(ch) {
  return `<ul class="checklist">${ch.checks.map((x) => `<li><span class="${x.ok ? "ok-t" : "bad-t"}">${x.ok ? "✓" : "✗"}</span><span>${esc(x.name)}</span><span class="d">${esc(x.detail)}</span></li>`).join("")}</ul>
    <p class="small ${ch.ok ? "muted" : "err"}">${ch.ok ? "Учётная запись подходит. Проект " + esc(ch.project) + "." : "Недостаточно прав: нужна роль «Администратор виртуальных машин» (mcs_admin_vm), для FIP — ещё «Администратор внутренних сетей»."}</p>`;
}

// --- step 3: placement ---
function page3() {
  const L = W.check.lists, me = W.check.me || {}, p = W.place;
  p.az = p.az || W.check.az; p.network = p.network || (me.networks || [])[0] || L.networks[0];
  if (!p.public_ip && me.fip) p.public_ip = me.fip;
  $("#page").innerHTML = `<h2>Размещение</h2><p class="lead">Значения определены по метаданным этой ВМ; при необходимости измените их.</p>
    ${field("Зона доступности", `<select id="az">${opt(L.zones, p.az)}</select>`, "тома, приёмники и новые ВМ создаются в этой зоне")}
    ${field("Сеть оркестратора и приёмников", `<select id="net">${opt(L.networks, p.network)}</select>`)}
    ${field("Публичный адрес (FIP) оркестратора", `<input id="pip" value="${esc(p.public_ip || "")}" placeholder="нет">`, "по нему подключаются агенты из интернета и открывается интерфейс; пусто — только серый адрес " + esc(W.info.grey_ip))}
    <div class="err" id="err"></div>${nav(true, true)}`;
  const read = () => Object.assign(p, { az: $("#az").value, network: $("#net").value, public_ip: $("#pip").value.trim() });
  bind("back", () => { read(); go(1); });
  bind("next", () => { read(); go(3); });
}

// --- step 4: receivers ---
function page4() {
  const L = W.check.lists, r = W.rx;
  r.flavor = r.flavor || (L.flavors.find((f) => f.name === "STD3-4-4") || L.flavors.find((f) => f.vcpus >= 4) || L.flavors[0]).name;
  r.volume_type = r.volume_type || (L.volume_types.includes("ceph-ssd") ? "ceph-ssd" : L.volume_types[0]);
  const free = (L.fips || []).filter((f) => f.free && f.ip !== W.place.public_ip);
  $("#page").innerHTML = `<h2>Приёмники</h2><p class="lead">Приёмник принимает диски и записывает их в тома. По умолчанию он работает на этой же ВМ; отдельные приёмники оркестратор создаёт сам, когда на этой ВМ не хватает места для томов.</p>
    <div class="field checks"><label><input type="checkbox" id="loc" ${r.local ? "checked" : ""}> Приёмник на этой ВМ (rx0) — рекомендуется 4–8 vCPU</label></div>
    <div class="grid2">${field("Тип томов", `<select id="vt">${opt(L.volume_types, r.volume_type)}</select>`)}
    ${field("Томов на приёмник", `<input id="mv" type="number" min="1" max="26" value="${r.max_volumes}">`)}</div>
    ${field("Флейвор отдельных приёмников", `<select id="fl">${opt(L.flavors, r.flavor, flavorLabel)}</select>`)}
    ${field("Ключ SSH для отдельных приёмников", `<select id="key"><option value="">без ключа</option>${opt(L.keypairs, r.key)}</select>`, "для диагностики; можно без ключа")}
    ${field("FIP, которые можно назначать приёмникам", free.length ? `<div class="checks">${free.map((f) => `<label><input type="checkbox" value="${esc(f.id)}" ${r.fip_pool.includes(f.id) ? "checked" : ""}> ${esc(f.ip)}</label>`).join("")}</div>` : '<div class="muted small">свободных FIP в проекте нет — приёмники будут доступны по серому адресу и через оркестратор</div>',
      "собственный FIP ускоряет приём из интернета; новые FIP оркестратор не выделяет")}
    ${nav(true, true)}`;
  const read = () => Object.assign(r, { local: $("#loc").checked, volume_type: $("#vt").value, max_volumes: +$("#mv").value || 20,
    flavor: $("#fl").value, key: $("#key").value, fip_pool: [...document.querySelectorAll(".checks input[value]:checked")].map((x) => x.value) });
  bind("back", () => { read(); go(2); });
  bind("next", () => { read(); go(4); });
}

// --- step 5: access ---
function page5() {
  const a = W.access;
  $("#page").innerHTML = `<h2>Доступ</h2><p class="lead">Кто может открыть интерфейс и с каких адресов подключаются исходные ВМ. По одному адресу или подсети в строке.</p>
    ${field("Веб-интерфейс открыт для", `<textarea id="ua">${esc(a.ui_allow)}</textarea>`, `ваш текущий адрес: <span class="mono">${esc(W.info.client_ip)}</span>; остальным — 403`)}
    ${field("Исходные ВМ подключаются с", `<textarea id="al" placeholder="10.0.0.0/8&#10;203.0.113.7/32">${esc(a.allow)}</textarea>`, "подсети ЦОДа (Direct Connect) и внешние адреса (SNAT) других облаков; используется для групп безопасности")}
    <div class="field checks"><label><input type="checkbox" id="sg" ${a.ctl_sg ? "checked" : ""}><span>Открыть 443 для этих адресов и подсети приёмников в группе безопасности d2g-ctl и подключить её к этой ВМ</span></label></div>
    <div class="err" id="err"></div>${nav(true, true)}`;
  const read = () => Object.assign(a, { ui_allow: $("#ua").value, allow: $("#al").value, ctl_sg: $("#sg").checked });
  bind("back", () => { read(); go(3); });
  bind("next", () => { read(); if (!lines(a.ui_allow).length) return ($("#err").textContent = "Нужен хотя бы один адрес для интерфейса."); go(5); });
}

// --- step 6: apply ---
function page6() {
  const a = W.admin, c = W.cloud, p = W.place, r = W.rx, x = W.access;
  const row = (k, v) => `<div>${esc(k)}</div><div>${v}</div>`;
  $("#page").innerHTML = `<h2>Применить</h2><p class="lead">Проверьте настройки и нажмите «Применить». Это займёт до минуты.</p>
    <div class="summary">${row("Администратор", esc(a.name) + (a.totp ? " · TOTP" : ""))}
    ${row("Облако", `${esc(c.username)} @ проект <span class="mono">${esc(c.project_id)}</span>`)}
    ${row("Зона, сеть", esc(p.az + ", " + p.network))}${row("Публичный адрес", esc(p.public_ip || "нет"))}
    ${row("Приёмник на этой ВМ", r.local ? "да" : "нет")}${row("Отдельные приёмники", esc(`${r.flavor}, тома ${r.volume_type}, до ${r.max_volumes} томов, FIP: ${r.fip_pool.length || "нет"}`))}
    ${row("Интерфейс открыт для", `<span class="mono">${esc(lines(x.ui_allow).join(", "))}</span>`)}
    ${row("Исходные ВМ с", `<span class="mono">${esc(lines(x.allow).join(", ") || "—")}</span>`)}
    ${row("Группа безопасности", x.ctl_sg ? "открыть 443 (d2g-ctl)" : "не изменять")}</div>
    <div id="out"></div><div class="err" id="err"></div>${nav(true, true, "Применить")}`;
  bind("back", () => go(4));
  bind("next", async () => {
    $("#next").disabled = true; $("#err").textContent = "";
    $("#out").innerHTML = '<p><span class="spinner"></span>применяю настройки…</p>';
    try {
      const res = await api("/api/setup/apply", { admin: { name: a.name, password: a.password, totp_secret: a.totp ? a.totp_secret : "" },
        cloud: c, place: p, receivers: r, access: { ui_allow: lines(x.ui_allow), allow: lines(x.allow), ctl_sg: x.ctl_sg } });
      W.step = 6; steps();
      $("#page").innerHTML = `<h2>Готово</h2><ul class="checklist">${res.steps.map((s) => `<li><span class="ok-t">✓</span><span>${esc(s)}</span></li>`).join("")}</ul>
        <p>Оркестратор перезапускается. Через несколько секунд войдите как <b>${esc(a.name)}</b>: <a href="/login">открыть интерфейс</a>.</p>
        <p class="small muted">Далее: «Исходные ВМ» → «Добавить ВМ», выполните команду на исходной ВМ, затем «Задания» → «Новое задание».</p>`;
      setTimeout(() => { location.href = "/login"; }, 8000);
    } catch (e) { $("#out").innerHTML = ""; $("#err").textContent = e.message; $("#next").disabled = false; }
  });
}
const PAGES = [page1, page2, page3, page4, page5, page6];
pageCode();
