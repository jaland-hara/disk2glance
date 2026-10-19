"use strict";
// d2g orchestrator web UI: polls /api/ui/state, renders tabs, runs actions through the UI API.
let S = null, ME = null, CLOUD = {}, TAB = "overview", WATCH = new Set(), LOGOPEN = new Set();
const $ = (s, r = document) => r.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const GiB = (b) => (b ? (b / 2 ** 30).toFixed(b >= 10 * 2 ** 30 ? 0 : 1) + " ГиБ" : "—");
const ago = (t) => {
  if (!t) return "—";
  const d = (S ? S.now : Date.now() / 1000) - t;
  if (d < 60) return Math.max(0, Math.round(d)) + " с назад";
  if (d < 3600) return Math.round(d / 60) + " мин назад";
  if (d < 86400) return Math.round(d / 3600) + " ч назад";
  return new Date(t * 1000).toLocaleString("ru-RU");
};
const when = (t) => (t ? new Date(t * 1000).toLocaleString("ru-RU") : "—");
const dur = (s) => (s >= 3600 ? (s / 3600).toFixed(1) + " ч" : s >= 60 ? Math.round(s / 60) + " мин" : s + " с");

const JOB_STATE = { attaching: ["Подключение тома", "info"], ready: ["Готово к проходу", "info"], receiving: ["Идёт проход", "info"],
  synced: ["Синхронизировано", "ok"], finishing: ["Создаётся ВМ", "warn"], deleting: ["Удаление", "warn"], finished: ["ВМ создана", "ok"] };
const AGENT_STATE = { enrolled: ["Подключён", "ok"], token: ["Ждёт установки", "warn"], revoked: ["Отключён", "bad"] };
const RX_STATE = { up: ["Работает", "ok"], down: ["Нет связи", "bad"], creating: ["Создаётся", "info"], joined: ["Запускается", "info"], failed: ["Ошибка", "bad"] };
const PATHS = { auto: "автоматически", "rx-grey": "серый IP приёмника", "rx-fip": "FIP приёмника", ctl: "через оркестратор (публичный)", "ctl-grey": "через оркестратор (серый)" };
const badge = (map, k) => { const [t, c] = map[k] || [k, ""]; return `<span class="badge ${c}">${esc(t)}</span>`; };

async function api(path, body) {
  const opt = { credentials: "same-origin", headers: {} };
  if (body !== undefined) { opt.method = "POST"; opt.headers["Content-Type"] = "application/json"; opt.headers["X-CSRF"] = ME ? ME.csrf : ""; opt.body = JSON.stringify(body); }
  const r = await fetch(path, opt);
  if (r.status === 401) { location.href = "/login"; throw new Error("login"); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || "HTTP " + r.status);
  return j;
}
function toast(msg, bad) {
  const d = document.createElement("div");
  if (bad) d.className = "bad";
  d.textContent = msg;
  $("#toast").appendChild(d);
  setTimeout(() => d.remove(), bad ? 9000 : 5000);
}

// --- rendering ---------------------------------------------------------------------------------------------
function jobProgress(j) {
  if (j.state === "receiving") {
    const first = j.pass_no === 0;
    const pct = first ? Math.round((100 * j.parts) / j.nparts) : null;
    const rate = j.rate ? ` · ~${Math.round(j.rate)} МиБ/с` : "";
    return `<div class="small">${first ? `первый проход: ${j.parts}/${j.nparts} частей` : `проход ${j.pass_no + 1}: изменилось ${j.pass_parts} частей`}${rate}</div>` +
      (first ? `<div class="bar"><i data-pct="${pct}"></i></div>` : "");
  }
  if (j.state === "synced" || j.state === "finished") return `<div class="small">${j.parts}/${j.nparts} частей · проходов: ${j.pass_no}</div>`;
  return `<div class="small muted">${j.parts}/${j.nparts} частей</div>`;
}
function tasksPanel(limit) {
  const ts = S.tasks.slice(0, limit);
  if (!ts.length) return `<div class="panel"><div class="empty">Операций ещё не было</div></div>`;
  const st = { running: ["Выполняется", "info"], done: ["Готово", "ok"], failed: ["Ошибка", "bad"], interrupted: ["Прервано", "warn"] };
  return `<div class="panel"><table><tr><th>Операция</th><th>Кто</th><th>Состояние</th><th>Начата</th><th></th></tr>` +
    ts.map((t) => `<tr><td>${esc(t.what)}</td><td>${esc(t.who)}</td><td>${badge(st, t.state)}</td><td class="nowrap">${ago(t.started)}</td>
      <td><button class="btn" data-act="tasklog" data-id="${esc(t.id)}">${LOGOPEN.has(t.id) ? "Скрыть вывод" : "Вывод"}</button></td></tr>` +
      (LOGOPEN.has(t.id) ? `<tr><td colspan="5"><pre class="log">${esc(t.log || "(пусто)")}</pre></td></tr>` : "")).join("") + `</table></div>`;
}
function vOverview() {
  const enrolled = S.agents.filter((a) => a.state === "enrolled").length;
  const active = S.jobs.filter((j) => !["finished"].includes(j.state));
  const running = S.jobs.filter((j) => j.state === "receiving");
  const rxUp = S.receivers.filter((r) => r.state === "up").length;
  const vols = S.receivers.reduce((a, r) => a + r.volumes, 0);
  return `<div class="cards">
    <div class="card"><div class="k">Исходные ВМ</div><div class="v">${enrolled}</div><div class="s">подключено; всего агентов ${S.agents.length}</div></div>
    <div class="card"><div class="k">Задания</div><div class="v">${active.length}</div><div class="s">${running.length ? "идёт проходов: " + running.length : "проходов сейчас нет"}</div></div>
    <div class="card"><div class="k">Синхронизировано</div><div class="v">${S.jobs.filter((j) => j.state === "synced").length}</div><div class="s">готовы к переключению</div></div>
    <div class="card"><div class="k">Приёмники</div><div class="v">${rxUp}/${S.receivers.length}</div><div class="s">томов подключено: ${vols}</div></div>
  </div>
  <h2>Текущие задания</h2>${jobsTable(active, true)}
  <h2>Последние операции</h2>${tasksPanel(5)}`;
}
function agentsTable() {
  if (!S.agents.length) return `<div class="panel"><div class="empty">Исходных ВМ ещё нет. Нажмите «Добавить ВМ» и выполните команду на исходной ВМ.</div></div>`;
  return `<div class="panel"><table><tr><th>ВМ</th><th>Состояние</th><th>Система</th><th class="num">Диски</th><th>Путь до приёмника</th><th>Связь</th><th>Последний отчёт</th><th></th></tr>` +
    S.agents.map((a) => {
      const rep = a.report && a.report.rc !== undefined && a.report.rc !== null
        ? `<span class="badge ${a.report.rc === 0 ? "ok" : "bad"}">${a.report.rc === 0 ? "успешно" : "ошибка " + esc(a.report.rc)}</span> <span class="small muted">${ago(a.report.at)}</span><div class="small">${esc(a.report.summary || "")}</div>` : `<span class="muted">—</span>`;
      const cmd = a.command ? `<div class="small"><span class="badge info">в очереди: ${esc(a.command === "sync" ? "проход" : a.command)}</span></div>` : "";
      return `<tr><td><b>${esc(a.name)}</b><div class="small muted">${esc(a.hostname || "")}</div></td>
        <td>${badge(AGENT_STATE, a.state)}${cmd}${a.state === "token" && a.token_exp ? `<div class="small muted">токен до ${when(a.token_exp)}</div>` : ""}</td>
        <td><div>${esc(a.os || "—")}</div><div class="small muted">${esc(a.kernel || "")}${a.module === "no" ? ' · <span class="badge warn">нет модуля</span>' : ""}</div></td>
        <td class="num small nowrap">${diskList(a.disks, a.disk_bytes)}</td><td class="small">${esc(PATHS[a.path] || a.path)}<div class="muted">${a.threads} потоков</div></td>
        <td class="small nowrap">${ago(a.seen)}<div class="muted mono">${esc(a.peer || "")}</div></td><td>${rep}</td>
        <td><div class="actions">${a.state === "enrolled" ? `<button class="btn" data-act="agent-sync" data-name="${esc(a.name)}">Проход</button>` : ""}
          ${a.state !== "revoked" ? `<button class="btn" data-act="agent-add" data-name="${esc(a.name)}">Новый токен</button>` : ""}
          ${a.state === "enrolled" ? `<button class="btn danger" data-act="agent-uninstall" data-name="${esc(a.name)}">Удалить агента</button>` : ""}
          ${a.state !== "revoked" ? `<button class="btn danger" data-act="agent-revoke" data-name="${esc(a.name)}">Отключить</button>` : ""}</div></td></tr>`;
    }).join("") + `</table></div>`;
}
// disks of a source VM: "vda 20 ГиБ" per line (agents before 0.9 report one disk)
function diskList(disks, bytes) {
  if (!disks || !disks.length) return GiB(bytes);
  return disks.map((d) => `${esc(d.dev.replace("/dev/", ""))} ${GiB(d.bytes)}`).join("<br>");
}
const nDisks = (n) => `${n} ${n % 10 === 1 && n % 100 !== 11 ? "диск" : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? "диска" : "дисков"}`;
function vAgents() {
  return `<h2><span class="grow">Исходные ВМ</span><button class="btn primary" data-act="agent-add">Добавить ВМ</button></h2>${agentsTable()}
  <p class="small muted">Агент устанавливается одной командой с этого оркестратора и ожидает его команд. Сертификат агента позволяет только записывать данные в его том через приёмник; учётные данные облака на исходную ВМ не попадают.</p>`;
}
function jobsTable(list, compact) {
  if (!list.length) return `<div class="panel"><div class="empty">${compact ? "Активных заданий нет" : "Заданий ещё нет. Сначала подключите исходную ВМ, затем создайте задание."}</div></div>`;
  return `<div class="panel"><table><tr><th>Задание</th><th>ВМ</th><th>Состояние</th><th>Прогресс</th><th>Синхронизировано</th>${compact ? "" : "<th>Куда / приёмник / том</th><th>Расписание</th>"}<th></th></tr>` +
    list.map((j) => { const ag = S.agents.find((a) => a.name === j.agent) || {}; const queued = ag.command === "sync" && j.state !== "receiving" && j.state !== "finished";
      return `<tr><td class="mono">${esc(j.id)}</td><td><b>${esc(j.agent)}</b><div class="small muted">${(j.disks || []).length > 1 ? nDisks(j.disks.length) + " · " : ""}${GiB(j.disk_bytes)}</div></td>
      <td>${badge(JOB_STATE, j.state)}${queued ? '<div class="small"><span class="badge info">проход в очереди</span></div>' : ""}${j.vm_name ? `<div class="small">ВМ ${esc(j.vm_name)}</div>` : ""}</td><td>${jobProgress(j)}</td>
      <td class="small">${j.synced_at ? ago(j.synced_at) + `<div class="muted">снапшот ${esc((j.synced_snapshot || "").replace("T", " ").replace(/\.\d+Z$/, " UTC"))}</div>` : "—"}</td>
      ${compact ? "" : `<td class="small"><b>${esc(tgtLabel(j.target))}</b><div class="muted">${esc(j.receiver)} · ${esc(j.az)}</div>${(j.disks || []).map((d) => `<div class="muted nowrap">${esc(d.dev.replace("/dev/", ""))} → <span class="mono">${esc((d.volume_id || "").slice(0, 8))}</span></div>`).join("")}</td>
      <td class="small">${j.sync_every ? "каждые " + dur(j.sync_every) : "—"}</td>`}
      <td><div class="actions">${["synced", "ready"].includes(j.state) && !queued ? `<button class="btn" data-act="job-sync" data-id="${esc(j.id)}">Дельта</button>` : ""}
        ${!compact && ["synced", "ready", "receiving"].includes(j.state) ? `<button class="btn" data-act="job-every" data-id="${esc(j.id)}">Расписание</button>` : ""}
        ${j.state === "synced" ? `<button class="btn primary" data-act="job-finish" data-id="${esc(j.id)}">Создать ВМ</button>` : ""}
        ${!compact && j.state !== "finished" ? `<button class="btn danger" data-act="job-delete" data-id="${esc(j.id)}">Удалить</button>` : ""}</div></td></tr>`; }).join("") + `</table></div>`;
}
function vJobs() {
  return `<h2><span class="grow">Задания</span><button class="btn primary" data-act="job-new">Новое задание</button></h2>${jobsTable(S.jobs, false)}
  <p class="small muted">Задание: том в целевом проекте, подключённый к приёмнику. Первый проход передаёт все занятые блоки диска, следующие (дельты) — только изменившиеся. «Создать ВМ» отключает том и создаёт с него ВМ; исходная ВМ при этом не меняется.</p>`;
}
function vReceivers() {
  return `<h2><span class="grow">Приёмники</span><button class="btn primary" data-act="rx-add">Добавить приёмник</button></h2>
  <div class="panel"><table><tr><th>Имя</th><th>Состояние</th><th>ВМ</th><th>Адреса</th><th class="num">Томов</th><th class="num">Нагрузка</th><th>Связь</th><th></th></tr>` +
    S.receivers.map((r) => `<tr><td><b>${esc(r.name)}</b><div class="small muted mono">${esc(r.dns)}</div></td><td>${badge(RX_STATE, r.state)}</td>
      <td class="small">${r.local ? "на ВМ оркестратора" : esc(r.flavor)}<div class="muted">${esc(tgtLabel(r.target))} · ${esc(r.az)}</div></td>
      <td class="small mono">${esc(r.grey_ip || "—")}${r.fip ? "<br>FIP " + esc(r.fip) : ""}</td><td class="num">${r.volumes}/${r.max_volumes}</td>
      <td class="num">${r.load != null ? Number(r.load).toFixed(2) : "—"}</td><td class="small nowrap">${ago(r.seen)}</td>
      <td>${r.local ? "" : `<button class="btn danger" data-act="rx-delete" data-name="${esc(r.name)}" ${r.volumes ? "disabled" : ""}>Удалить</button>`}</td></tr>`).join("") +
    `</table></div><p class="small muted">Если в нужной зоне нет приёмника со свободным местом, оркестратор создаст новый приёмник автоматически (около 1,5 мин).</p>`;
}
function vLog() {
  return `<h2>Операции</h2>${tasksPanel(20)}<h2>Журнал</h2><div class="panel"><table><tr><th>Время</th><th>Кто</th><th>Что</th></tr>` +
    S.events.map((e) => `<tr><td class="nowrap small">${when(e.ts)}</td><td class="small">${esc(e.who)}</td><td class="small">${esc(e.what)}</td></tr>`).join("") + `</table></div>`;
}
function vSettings() {
  const o = S.orchestrator, row = (k, v) => `<div>${esc(k)}</div><div>${v}</div>`;
  return `<h2><span class="grow">Настройки</span><button class="btn" data-act="set-access">Изменить доступ</button>
    <button class="btn" data-act="set-rx">Изменить приёмники</button><button class="btn" data-act="set-cloud">Учётная запись облака</button></h2><div class="panel"><div class="kv">
    ${row("Имя оркестратора", `<span class="mono">${esc(o.ctl_name)}</span>`)}
    ${row("Адреса", `серый <span class="mono">${esc(o.grey_ip)}</span>, публичный <span class="mono">${esc(o.public_ip || "—")}</span>`)}
    ${row("Зона, сеть", `${esc(o.az)}, ${esc(o.network)}`)}
    ${row("Приёмники", `${esc(o.rx_flavor)}, тома ${esc(o.rx_volume_type)}, до ${esc(o.max_volumes)} томов на приёмник, часть ${esc(o.part_mb)} МиБ`)}
    ${row("443 на приёмниках открыт для", `<span class="mono">${esc((o.allow || []).join(", ") || "—")}</span>`)}
    ${row("Пул FIP для приёмников", `<span class="mono">${esc((o.fip_pool || []).join(", ") || "—")}</span>`)}
    ${row("Веб-интерфейс доступен с адресов", `<span class="mono">${esc((o.ui_allow || []).join(", "))}</span>`)}
    ${row("Сертификат администратора", o.ui_mtls ? "обязателен" : "не требуется")}
  </div></div>
  <p class="small muted">Администраторы и сертификат администратора — на ВМ оркестратора: <span class="mono">d2g admin add|passwd|totp|cert ИМЯ</span>, <span class="mono">d2g setup --ui-mtls on|off</span>.</p>`;
}
function vTargets() {
  const cnt = (name, list, f) => list.filter((x) => (x.target || "home") === name && f(x)).length;
  return `<h2><span class="grow">Проекты</span><button class="btn primary" data-act="tg-add">Добавить проект</button></h2>
  <div class="panel"><table><tr><th>Проект</th><th>Способ</th><th>ID проекта · регион</th><th>Зона, сеть</th><th class="num">Приёмники</th><th class="num">Задания</th><th>Учётная запись</th><th></th></tr>` +
    S.targets.map((t) => `<tr><td><b>${esc(t.name === "home" ? "этот проект" : t.title || t.name)}</b><div class="small muted mono">${esc(t.name)}</div></td>
      <td>${badge(MODE, t.mode)}</td><td class="small mono">${esc(t.project || "")}<div class="muted">${esc(t.region || "")}</div></td>
      <td class="small">${esc(t.az || "—")}<div class="muted">${esc(t.network || "—")}</div></td>
      <td class="num">${cnt(t.name, S.receivers, () => true)}</td><td class="num">${cnt(t.name, S.jobs, (j) => j.state !== "finished")}</td>
      <td>${t.name === "home" ? '<span class="small muted">в «Настройках»</span>' : t.check_ok ? `<span class="badge ok">проверена</span><div class="small muted">${ago(t.checked_at)}</div>` : '<span class="badge bad">проверка не прошла</span>'}</td>
      <td>${t.name === "home" ? "" : `<div class="actions"><button class="btn" data-act="tg-edit" data-name="${esc(t.name)}">Изменить</button>
        <button class="btn danger" data-act="tg-delete" data-name="${esc(t.name)}">Удалить</button></div>`}</td></tr>`).join("") + `</table></div>
  <p class="small muted"><b>Передача тома</b> — диск принимается в проекте оркестратора, а при «Создать ВМ» том передаётся в проект и ВМ создаётся там; нужна только служебная учётная запись проекта, работает в пределах одного региона.
  <b>Свой приёмник</b> — оркестратор создаёт приёмник внутри проекта (учётной записью проекта) и принимает диск прямо туда; подходит для другого региона и для случаев, когда данные не должны попадать в проект оркестратора. Приёмник подключается к оркестратору по его публичному адресу, агенты — к приёмнику по серому адресу или его FIP.</p>`;
}
async function editTarget(name) {
  const t = name ? tgt(name) : { name: "", title: "", mode: "transfer", allow: [], fip_pool: [], vm_sg: ["default"] };
  const home = (await cloud()).cloud || {};
  let lists = name ? await cloud(name).catch(() => null) : null;
  const creds = `<div class="grid2"><div class="field"><label>Имя (латиницей)</label><input id="tn" value="${esc(t.name)}" ${name ? "readonly" : ""} maxlength="24" placeholder="client-a"></div>
      <div class="field"><label>Название</label><input id="tt" value="${esc(t.title || "")}" maxlength="64" placeholder="Клиент А, продуктив"></div></div>
    <div class="field"><label>Способ</label><select id="tm"><option value="transfer" ${t.mode === "transfer" ? "selected" : ""}>передача тома (тот же регион)</option>
      <option value="receiver" ${t.mode === "receiver" ? "selected" : ""}>свой приёмник в проекте</option></select></div>
    <div class="field"><label>Адрес Keystone</label><input id="u" value="${esc(home.OS_AUTH_URL || "https://infra.mail.ru:35357/v3/")}"></div>
    <div class="grid2"><div class="field"><label>ID проекта</label><input id="pr" class="mono" value="${esc(t.project || "")}"></div>
      <div class="field"><label>Регион</label><input id="rg" value="${esc(t.region || home.OS_REGION_NAME || "RegionOne")}"></div></div>
    <div class="grid2"><div class="field"><label>Служебная учётная запись</label><input id="un" autocomplete="off"></div>
      <div class="field"><label>Домен</label><input id="dm" value="service-users"></div></div>
    <div class="field"><label>Пароль</label><input id="pw" type="password" autocomplete="off" placeholder="${name ? "пусто — учётная запись не меняется" : ""}"></div>
    <button class="btn" id="tchk">Проверить учётную запись</button> <span id="tchs" class="small muted"></span><div id="tres"></div><div id="tset"></div>`;
  modal(name ? `Проект ${t.title || name}` : "Добавить проект", creds, [{ text: "Отмена" }, { text: "Сохранить", cls: "primary", ok: true }], async (m) => {
    if (!lists) throw new Error("Сначала проверьте учётную запись");
    const mode = val(m, "tm"), q = (id) => (m.querySelector("#" + id) ? val(m, id) : "");
    const body = { name: val(m, "tn"), title: val(m, "tt"), mode, auth_url: val(m, "u"), project_id: val(m, "pr"), region: val(m, "rg"),
      username: val(m, "un"), user_domain: val(m, "dm"), password: m.querySelector("#pw").value, az: q("taz"), network: q("tnet"),
      rx_flavor: q("tfl"), rx_volume_type: q("tvt"), rx_key: q("tkey"),
      allow: m.querySelector("#tal") ? lines(m.querySelector("#tal").value) : [],
      fip_pool: [...m.querySelectorAll("#tfips input:checked")].map((x) => x.value), vm_sg: [...m.querySelectorAll("#tsg input:checked")].map((x) => x.value) };
    const r = await api("/api/ui/target/save", body);
    close(); CLOUD = {}; toast(r.message || "Сохранено"); refresh();
  });
  const m = $("#modal .modal");
  const settings = () => {
    const L = lists, rx = val(m, "tm") === "receiver";
    if (!L) { m.querySelector("#tset").innerHTML = ""; return; }
    const free = (L.fips || []).filter((f) => f.free || (t.fip_pool || []).includes(f.id));
    m.querySelector("#tset").innerHTML = `<hr><div class="grid2"><div class="field"><label>Зона</label>${sel("taz", L.zones, t.az)}</div>
      <div class="field"><label>Сеть ${rx ? "приёмников и " : ""}новых ВМ</label>${sel("tnet", L.networks, t.network)}</div></div>
      <div class="field"><label>Группы безопасности новых ВМ</label><div class="checks" id="tsg">${L.security_groups.map((g) => `<label><input type="checkbox" value="${esc(g)}" ${(t.vm_sg || ["default"]).includes(g) ? "checked" : ""}>${esc(g)}</label>`).join("")}</div></div>
      ${rx ? `<div class="grid2"><div class="field"><label>Флейвор приёмников</label><select id="tfl">${L.flavors.map((f) => `<option value="${esc(f.name)}" ${f.name === (t.rx_flavor || "STD3-4-4") ? "selected" : ""}>${esc(f.name)} — ${f.vcpus} vCPU</option>`).join("")}</select></div>
        <div class="field"><label>Тип томов</label>${sel("tvt", L.volume_types, t.rx_volume_type || (L.volume_types.includes("ceph-ssd") ? "ceph-ssd" : ""))}</div></div>
        <div class="field"><label>Ключ SSH приёмников</label>${sel("tkey", L.keypairs, t.rx_key || "", "без ключа")}</div>
        <div class="field"><label>FIP для приёмников</label><div class="checks" id="tfips">${free.map((f) => `<label><input type="checkbox" value="${esc(f.id)}" ${(t.fip_pool || []).includes(f.id) ? "checked" : ""}>${esc(f.ip)}</label>`).join("") || '<span class="small muted">свободных FIP нет — агенты смогут подключиться к приёмнику только по серому адресу (источник в той же сети или Direct Connect)</span>'}</div></div>
        <div class="field"><label>Исходные ВМ подключаются с (443 на приёмниках проекта)</label><textarea id="tal">${esc((t.allow || []).join("\n"))}</textarea></div>` : ""}`;
  };
  m.querySelector("#tm").addEventListener("change", settings);
  m.querySelector("#tchk").addEventListener("click", async () => {
    m.querySelector("#tchs").innerHTML = '<span class="spinner"></span>создаю и удаляю пробный том и группу безопасности…';
    m.querySelector("#tres").innerHTML = "";
    try {
      const r = await api("/api/ui/target/check", { auth_url: val(m, "u"), project_id: val(m, "pr"), region: val(m, "rg"), username: val(m, "un"),
        user_domain: val(m, "dm"), password: m.querySelector("#pw").value, az: t.az || "" });
      m.querySelector("#tres").innerHTML = `<ul class="small">${r.checks.map((x) => `<li>${x.ok ? "✓" : "✗"} ${esc(x.name)} <span class="muted">${esc(x.detail)}</span></li>`).join("")}</ul>`;
      lists = r.lists; t.az = t.az || r.az; settings();
    } catch (x) { m.querySelector("#tres").innerHTML = `<div class="err">${esc(x.message)}</div>`; }
    m.querySelector("#tchs").textContent = "";
  });
  settings();
}
const VIEWS = { overview: vOverview, agents: vAgents, jobs: vJobs, receivers: vReceivers, targets: vTargets, log: vLog, settings: vSettings };
function render() {
  if (!S) return;
  $("#main").innerHTML = VIEWS[TAB]();
  // widths through CSSOM: the CSP forbids inline style attributes
  document.querySelectorAll("[data-pct]").forEach((e) => { e.style.width = e.dataset.pct + "%"; });
}

// --- modals ---------------------------------------------------------------------------------------------
function modal(title, body, buttons, onOk) {
  $("#modal").innerHTML = `<div class="modal-bg"><div class="modal"><h3>${esc(title)}</h3><div class="body">${body}<div class="err" id="merr"></div></div>
    <div class="foot">${buttons.map((b, i) => `<button class="btn ${b.cls || ""}" data-mbtn="${i}">${esc(b.text)}</button>`).join("")}</div></div></div>`;
  const m = $("#modal .modal");
  $("#modal .modal-bg").addEventListener("mousedown", (e) => { if (e.target.classList.contains("modal-bg")) close(); });
  m.querySelectorAll("[data-mbtn]").forEach((b) => b.addEventListener("click", async () => {
    const btn = buttons[+b.dataset.mbtn];
    if (!btn.ok) return close();
    b.disabled = true;
    try { await onOk(m); } catch (x) { $("#merr").textContent = x.message; b.disabled = false; }
  }));
  const first = m.querySelector("input, select");
  if (first) first.focus();
}
const close = () => { $("#modal").innerHTML = ""; };
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("#modal").firstChild) close(); });
const sel = (id, opts, cur, empty) => `<select id="${id}">${empty !== undefined ? `<option value="">${esc(empty)}</option>` : ""}${opts.map((o) => `<option ${o === cur ? "selected" : ""}>${esc(o)}</option>`).join("")}</select>`;
const val = (m, id) => m.querySelector("#" + id).value.trim();
async function cloud(target = "home") { if (!CLOUD[target]) CLOUD[target] = await api("/api/ui/cloud?target=" + encodeURIComponent(target)); return CLOUD[target]; }
const tgt = (name) => (S.targets || []).find((t) => t.name === name) || { name, title: name, mode: "home" };
const tgtLabel = (name) => { const t = tgt(name); return t.name === "home" ? "этот проект" : (t.title || t.name); };
const MODE = { home: ["проект оркестратора", ""], transfer: ["передача тома", "info"], receiver: ["свой приёмник", "warn"] };
// where job volumes live: the target itself in receiver mode, else the orchestrator's project
const volOwner = (name) => (tgt(name).mode === "receiver" ? name : "home");

function startTask(r, what) {
  if (r.task) { WATCH.add(r.task); LOGOPEN.add(r.task); toast(`${what}: запущено, ход выполнения — на вкладке «Журнал»`); }
  else if (r.message) toast(r.message);
  refresh();
}
function addAgent(name) {
  modal(name ? `Новый токен для ${name}` : "Добавить исходную ВМ",
    `<div class="field"><label>Имя</label><input id="n" value="${esc(name || "")}" ${name ? "readonly" : ""} placeholder="web01" maxlength="32">
       <div class="hint">строчные латинские буквы, цифры и дефис</div></div>
     <div class="field"><label>Путь до приёмника</label>${`<select id="p">${Object.entries(PATHS).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join("")}</select>`}
       <div class="hint">«автоматически» — агент использует первый ответивший адрес: серый IP приёмника, его FIP, оркестратор</div></div>
     <div class="field"><label>Потоков</label><input id="t" type="number" min="1" max="64" value="8">
       <div class="hint">на медленном канале увеличение числа потоков не ускоряет передачу</div></div>`,
    [{ text: "Отмена" }, { text: "Получить команду", cls: "primary", ok: true }],
    async (m) => {
      const r = await api("/api/ui/agent/add", { name: val(m, "n"), path: val(m, "p"), threads: +val(m, "t") });
      const cmds = r.commands.map((c) => `<div class="small muted">${c.kind === "public" ? "если ВМ подключается через интернет (публичный адрес оркестратора)" : "если ВМ в ЦОДе или в той же сети (серый адрес)"}</div>
        <pre class="cmd">${esc(c.command)}</pre><button class="btn" data-copy="${esc(c.command)}">Скопировать</button>`).join("<hr>");
      modal("Команда для исходной ВМ", `<p>Выполните на исходной ВМ от root. Токен действует ${r.valid_min} мин и только один раз.</p>${cmds}`,
        [{ text: "Готово", cls: "primary" }]);
      document.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", () => navigator.clipboard.writeText(b.dataset.copy).then(() => toast("Скопировано"))));
      refresh();
    });
}
async function newJob(target, agent) {
  const busy = new Set(S.jobs.filter((j) => j.state !== "finished").map((j) => j.agent));
  const free = S.agents.filter((a) => a.state === "enrolled" && !busy.has(a.name)).map((a) => a.name);
  if (!free.length) return toast("Нет подключённых ВМ без задания: сначала добавьте исходную ВМ", true);
  target = target || "home";
  agent = free.includes(agent) ? agent : free[0];
  const disks = (S.agents.find((a) => a.name === agent) || {}).disks || [];
  const t = tgt(target), owner = volOwner(target), c = await cloud(owner), to = owner === "home" ? S.orchestrator : t;
  const how = t.mode === "transfer" ? "Диск принимается в проекте оркестратора; при «Создать ВМ» том передаётся в выбранный проект и ВМ создаётся там."
    : t.mode === "receiver" ? "Диск принимается приёмником внутри выбранного проекта; если приёмника нет, оркестратор создаст его (около 2 мин)."
    : "Том, приёмник и будущая ВМ — в проекте оркестратора.";
  modal("Новое задание",
    `<div class="field"><label>Исходная ВМ</label>${sel("a", free, agent)}</div>
     <div class="field"><label>Куда переносить</label><select id="tg">${S.targets.map((x) => `<option value="${esc(x.name)}" ${x.name === target ? "selected" : ""}>${esc(x.name === "home" ? "этот проект (оркестратора)" : (x.title || x.name) + " — " + MODE[x.mode][0])}</option>`).join("")}</select>
       <div class="hint">${esc(how)}</div></div>
     ${disks.length > 1 ? `<div class="field"><label>Диски</label><div class="checks">${disks.map((d) => `<label><input type="checkbox" class="dsk" value="${esc(d.dev)}" checked ${d.boot ? "disabled" : ""}> ${esc(d.dev)} — ${GiB(d.bytes)}${d.boot ? " (загрузочный)" : ""}${d.mounts && d.mounts.length ? ` <span class="muted">${esc(d.mounts.join(" "))}</span>` : ""}</label>`).join("")}</div>
       <div class="hint">Снапшоты всех дисков снимаются одним набором — в одну точку времени. Каждый диск переносится в свой том. Группа томов LVM переносится только целиком.</div></div>` : ""}
     <div class="field"><label>Тип тома</label>${sel("vt", c.volume_types, to.rx_volume_type)}</div>
     <div class="field"><label>Зона</label>${sel("az", c.zones, to.az)}<div class="hint">том, приёмник и будущая ВМ будут в этой зоне</div></div>
     <div class="field"><label>Дельты по расписанию</label><select id="ev"><option value="0">нет, по кнопке</option><option value="900">каждые 15 мин</option>
       <option value="3600">каждый час</option><option value="14400">каждые 4 ч</option><option value="86400">раз в сутки</option></select></div>
     <p class="small muted">На каждый диск исходной ВМ создаётся том того же размера и подключается к приёмнику; первый проход запускается автоматически.</p>`,
    [{ text: "Отмена" }, { text: "Создать", cls: "primary", ok: true }],
    async (m) => { const dk = [...m.querySelectorAll(".dsk")].filter((x) => x.checked).map((x) => x.value);
      const r = await api("/api/ui/job/new", { agent: val(m, "a"), target: val(m, "tg"), type: val(m, "vt"), az: val(m, "az"), every: +val(m, "ev"), disks: dk.length && dk.length < disks.length ? dk.join(",") : "" }); close(); startTask(r, "Новое задание"); });
  // another project: other zones and volume types
  $("#tg").addEventListener("change", (e) => { const a = val($("#modal .modal"), "a"); newJob(e.target.value, a).catch((x) => toast(x.message, true)); });
  // another VM: its disks
  $("#a").addEventListener("change", (e) => { const tg = val($("#modal .modal"), "tg"); newJob(tg, e.target.value).catch((x) => toast(x.message, true)); });
}
async function finishJob(id) {
  const j = S.jobs.find((x) => x.id === id), t = tgt(j.target), c = await cloud(j.target);
  const where = t.name === "home" ? "" : `<p class="small">ВМ будет создана в проекте <b>${esc(t.title || t.name)}</b>${t.mode === "transfer" ? " — том сначала будет передан туда из проекта оркестратора" : ""}.</p>`;
  modal(`Создать ВМ из ${j.agent}`,
    `<p class="small">Снапшот: <b>${esc((j.synced_snapshot || "").replace("T", " ").replace(/\.\d+Z$/, " UTC"))}</b> (${ago(j.synced_at)}). Чтобы новая ВМ содержала последние изменения, сначала выполните дельту. После создания ВМ том отключается от приёмника, и новые проходы по этому заданию невозможны.</p>${where}
     <div class="field"><label>Имя ВМ</label><input id="nm" value="${esc(j.agent)}-d2g" maxlength="64"></div>
     <div class="field"><label>Флейвор</label><select id="fl">${c.flavors.map((f) => `<option value="${esc(f.name)}">${esc(f.name)} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ</option>`).join("")}</select></div>
     <div class="field"><label>Сеть</label>${sel("net", c.networks, t.network || S.orchestrator.network)}</div>
     <div class="field"><label>Группы безопасности</label><div class="checks">${c.security_groups.map((g) => `<label><input type="checkbox" value="${esc(g)}" ${(t.vm_sg || ["default"]).includes(g) ? "checked" : ""}>${esc(g)}</label>`).join("")}</div></div>
     <div class="field"><label>Ключ SSH</label>${sel("key", c.keypairs, "", "без ключа")}</div>`,
    [{ text: "Отмена" }, { text: "Создать ВМ", cls: "primary", ok: true }],
    async (m) => {
      const sg = [...m.querySelectorAll(".checks input:checked")].map((x) => x.value);
      const r = await api(`/api/ui/job/${id}/finish`, { name: val(m, "nm"), flavor: val(m, "fl"), network: val(m, "net"), sg, key: val(m, "key") });
      close(); startTask(r, "Создание ВМ");
    });
}
function every(id) {
  const j = S.jobs.find((x) => x.id === id);
  modal(`Расписание дельт: ${j.agent}`, `<div class="field"><label>Дельта</label><select id="ev">${[[0, "по кнопке"], [900, "каждые 15 мин"], [3600, "каждый час"], [14400, "каждые 4 ч"], [86400, "раз в сутки"]]
    .map(([v, t]) => `<option value="${v}" ${v === j.sync_every ? "selected" : ""}>${t}</option>`).join("")}</select></div>`,
    [{ text: "Отмена" }, { text: "Сохранить", cls: "primary", ok: true }],
    async (m) => { const r = await api(`/api/ui/job/${id}/sync`, { every: +val(m, "ev") }); close(); toast(r.message || "Сохранено"); refresh(); });
}
async function addRx(target) {
  target = target || "home";
  const choices = S.targets.filter((x) => x.mode !== "transfer");
  const t = tgt(target), c = await cloud(target), to = target === "home" ? S.orchestrator : t;
  modal("Добавить приёмник",
    `<div class="field"><label>Проект</label><select id="tg">${choices.map((x) => `<option value="${esc(x.name)}" ${x.name === target ? "selected" : ""}>${esc(x.name === "home" ? "этот проект (оркестратора)" : x.title || x.name)}</option>`).join("")}</select></div>
     <div class="field"><label>Зона</label>${sel("az", c.zones, to.az)}</div>
     <div class="field"><label>Флейвор</label><select id="fl">${c.flavors.map((f) => `<option value="${esc(f.name)}" ${f.name === to.rx_flavor ? "selected" : ""}>${esc(f.name)} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ</option>`).join("")}</select></div>
     <div class="field"><label>FIP</label><select id="fip"><option value="">без FIP (серый IP${target === "home" ? " и через оркестратор" : ""})</option>${(to.fip_pool || []).length ? '<option value="auto">свободный из пула</option>' : ""}</select></div>`,
    [{ text: "Отмена" }, { text: "Создать", cls: "primary", ok: true }],
    async (m) => { const r = await api("/api/ui/receiver/add", { target: val(m, "tg"), az: val(m, "az"), flavor: val(m, "fl"), fip: val(m, "fip") }); close(); startTask(r, "Новый приёмник"); });
  $("#tg").addEventListener("change", (e) => addRx(e.target.value).catch((x) => toast(x.message, true)));
}
const lines = (t) => t.split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean);
function setAccess() {
  const o = S.orchestrator;
  modal("Доступ", `<div class="field"><label>Веб-интерфейс открыт для</label><textarea id="ua">${esc((o.ui_allow || []).join("\n"))}</textarea>
      <div class="hint">по одному адресу или подсети в строке; ваш текущий адрес должен остаться в списке</div></div>
    <div class="field"><label>Исходные ВМ подключаются с (443 на отдельных приёмниках)</label><textarea id="al">${esc((o.allow || []).join("\n"))}</textarea></div>
    <p class="small muted">Группа безопасности самой ВМ оркестратора этой формой не меняется.</p>`,
    [{ text: "Отмена" }, { text: "Сохранить", cls: "primary", ok: true }],
    async (m) => { const r = await api("/api/ui/settings/access", { ui_allow: lines(m.querySelector("#ua").value), allow: lines(m.querySelector("#al").value) }); close(); toast(r.message); refresh(); });
}
async function setRx() {
  const o = S.orchestrator, c = await cloud();
  const fips = (c.fips || []).filter((f) => f.free || (o.fip_pool || []).includes(f.id));
  modal("Отдельные приёмники", `<div class="field"><label>Флейвор</label><select id="fl">${c.flavors.map((f) => `<option value="${esc(f.name)}" ${f.name === o.rx_flavor ? "selected" : ""}>${esc(f.name)} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ</option>`).join("")}</select></div>
    <div class="field"><label>Тип томов</label>${sel("vt", c.volume_types, o.rx_volume_type)}</div>
    <div class="field"><label>Томов на приёмник</label><input id="mv" type="number" min="1" max="26" value="${esc(o.max_volumes)}"></div>
    <div class="field"><label>Пул FIP для приёмников</label>${fips.length ? `<div class="checks">${fips.map((f) => `<label><input type="checkbox" value="${esc(f.id)}" ${(o.fip_pool || []).includes(f.id) ? "checked" : ""}>${esc(f.ip)}</label>`).join("")}</div>` : '<div class="small muted">свободных FIP в проекте нет</div>'}</div>`,
    [{ text: "Отмена" }, { text: "Сохранить", cls: "primary", ok: true }],
    async (m) => {
      const r = await api("/api/ui/settings/receivers", { rx_flavor: val(m, "fl"), rx_volume_type: val(m, "vt"), max_volumes: +val(m, "mv"),
        fip_pool: [...m.querySelectorAll(".checks input:checked")].map((x) => x.value) });
      close(); CLOUD = {}; toast(r.message); refresh();
    });
}
async function setCloud() {
  const cur = (await cloud()).cloud || {};
  modal("Учётная запись облака", `<p class="small muted">Новая учётная запись проверяется (пробный том 1 ГБ и группа безопасности создаются и удаляются) и сохраняется, только если все проверки прошли.</p>
    <div class="field"><label>Адрес Keystone</label><input id="u" value="${esc(cur.OS_AUTH_URL)}"></div>
    <div class="field"><label>ID проекта</label><input id="pr" class="mono" value="${esc(cur.OS_PROJECT_ID)}"></div>
    <div class="field"><label>Регион</label><input id="rg" value="${esc(cur.OS_REGION_NAME)}"></div>
    <div class="field"><label>Пользователь</label><input id="un" value="${esc(cur.OS_USERNAME)}" autocomplete="off"></div>
    <div class="field"><label>Домен пользователя</label><input id="dm" value="${esc(cur.OS_USER_DOMAIN_NAME || "service-users")}"></div>
    <div class="field"><label>Пароль</label><input id="pw" type="password" autocomplete="off"></div><div id="res"></div>`,
    [{ text: "Отмена" }, { text: "Проверить и сохранить", cls: "primary", ok: true }],
    async (m) => {
      m.querySelector("#res").innerHTML = '<p class="small muted">проверяю…</p>';
      const r = await api("/api/ui/settings/cloud", { auth_url: val(m, "u"), project_id: val(m, "pr"), region: val(m, "rg"), username: val(m, "un"),
        user_domain: val(m, "dm"), password: m.querySelector("#pw").value, save: true });
      m.querySelector("#res").innerHTML = `<ul class="small">${r.checks.map((x) => `<li>${x.ok ? "✓" : "✗"} ${esc(x.name)} <span class="muted">${esc(x.detail)}</span></li>`).join("")}</ul>`;
      if (r.saved) { CLOUD = {}; toast("Учётная запись облака сохранена"); setTimeout(close, 1500); } else throw new Error("Не все проверки прошли, учётная запись не сохранена");
    });
}
function confirmAct(title, text, okText, fn) {
  modal(title, `<p>${text}</p>`, [{ text: "Отмена" }, { text: okText, cls: "primary", ok: true }], async () => { const r = await fn(); close(); startTask(r, title); });
}

// --- events ---------------------------------------------------------------------------------------------
document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-tab],[data-act]");
  if (!t) return;
  if (t.dataset.tab) { TAB = t.dataset.tab; document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b === t)); history.replaceState(null, "", "#" + TAB); return render(); }
  const a = t.dataset.act, id = t.dataset.id, name = t.dataset.name;
  const run = (p) => p.catch((x) => toast(x.message, true));
  if (a === "logout") return run(api("/api/ui/logout", {}).then(() => (location.href = "/login")));
  if (a === "tasklog") { LOGOPEN.has(id) ? LOGOPEN.delete(id) : LOGOPEN.add(id); return render(); }
  if (a === "agent-add") return addAgent(name);
  if (a === "agent-sync") return run(api(`/api/ui/agent/${name}/sync`, {}).then((r) => startTask(r, "Проход")));
  if (a === "agent-revoke") return confirmAct(`Отключить ${name}`, "Сертификат агента перестанет приниматься оркестратором и приёмниками. Задания останутся.", "Отключить", () => api(`/api/ui/agent/${name}/revoke`, {}));
  if (a === "agent-uninstall") return confirmAct(`Удалить агента с ${name}`, "Агент удалит себя с исходной ВМ (модуль, программы, настройки) при следующем опросе. Сама ВМ не меняется.", "Удалить агента", () => api(`/api/ui/agent/${name}/uninstall`, {}));
  if (a === "job-new") return run(newJob());
  if (a === "job-sync") return run(api(`/api/ui/job/${id}/sync`, {}).then((r) => startTask(r, "Дельта")));
  if (a === "job-every") return every(id);
  if (a === "job-finish") return run(finishJob(id));
  if (a === "job-delete") return confirmAct(`Удалить задание ${id}`, "Тома задания будут отключены от приёмника и удалены вместе с перенесёнными данными. Исходная ВМ не меняется.", "Удалить", () => api(`/api/ui/job/${id}/delete`, {}));
  if (a === "rx-add") return run(addRx());
  if (a === "tg-add") return run(editTarget());
  if (a === "tg-edit") return run(editTarget(name));
  if (a === "tg-delete") return confirmAct(`Удалить проект ${name}`, "Проект будет удалён из списка вместе с его учётной записью. Приёмников и незавершённых заданий в проекте быть не должно; ВМ в проекте не затрагиваются.", "Удалить", () => api(`/api/ui/target/${name}/delete`, {}));
  if (a === "set-access") return setAccess();
  if (a === "set-rx") return run(setRx());
  if (a === "set-cloud") return run(setCloud());
  if (a === "rx-delete") return confirmAct(`Удалить приёмник ${name}`, "ВМ приёмника будет удалена, её FIP вернётся в пул.", "Удалить", () => api(`/api/ui/receiver/${name}/delete`, {}));
});

// --- polling --------------------------------------------------------------------------------------------
// the page is re-rendered every few seconds: never between pointerdown and click, or the click is lost
let timer = null, POINTER = false;
document.addEventListener("pointerdown", () => { POINTER = true; }, true);
document.addEventListener("pointerup", () => setTimeout(() => { POINTER = false; }, 300), true);
async function refresh() {
  try {
    S = await api("/api/ui/state");
    for (const id of [...WATCH]) {
      const t = S.tasks.find((x) => x.id === id);
      if (t && t.state !== "running") { WATCH.delete(id); toast(`${t.what}: ${t.state === "done" ? "готово" : "ошибка, см. вывод операции"}`, t.state !== "done"); }
    }
    if (!$("#modal").firstChild && !POINTER) render();
  } catch (x) { if (x.message !== "login") toast("Нет связи с оркестратором: " + x.message, true); }
  clearTimeout(timer);
  timer = setTimeout(refresh, document.hidden ? 15000 : 3000);
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
window.addEventListener("hashchange", () => {
  const h = location.hash.slice(1);
  if (VIEWS[h] && h !== TAB) { TAB = h; document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === h)); render(); }
});
(async () => {
  const h = location.hash.slice(1);
  if (VIEWS[h]) { TAB = h; document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === h)); }
  ME = await api("/api/ui/me");
  $("#me").textContent = ME.name;
  await refresh();
  $("#ctl").textContent = S.orchestrator.ctl_name;
})();
