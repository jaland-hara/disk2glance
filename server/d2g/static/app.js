"use strict";
// d2g orchestrator web UI: polls /api/ui/state, renders tabs, runs actions through the UI API.
let S = null, ME = null, CLOUD = null, TAB = "overview", WATCH = new Set(), LOGOPEN = new Set();
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
  synced: ["Синхронизировано", "ok"], finishing: ["Переключение", "warn"], deleting: ["Удаление", "warn"], finished: ["ВМ создана", "ok"] };
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
    const rate = j.rate ? ` · обход диска ~${Math.round(j.rate)} МиБ/с` : "";
    return `<div class="small">${first ? `первый проход: ${j.parts}/${j.nparts} частей` : `проход ${j.pass_no + 1}: изменилось ${j.pass_parts} частей`}${rate}</div>` +
      (first ? `<div class="bar"><i data-pct="${pct}"></i></div>` : "");
  }
  if (j.state === "synced" || j.state === "finished") return `<div class="small">${j.parts}/${j.nparts} частей · проходов ${j.pass_no}</div>`;
  return `<div class="small muted">${j.parts}/${j.nparts} частей</div>`;
}
function tasksPanel(limit) {
  const ts = S.tasks.slice(0, limit);
  if (!ts.length) return `<div class="panel"><div class="empty">Операций ещё не было</div></div>`;
  const st = { running: ["Выполняется", "info"], done: ["Готово", "ok"], failed: ["Ошибка", "bad"], interrupted: ["Прервано", "warn"] };
  return `<div class="panel"><table><tr><th>Операция</th><th>Кто</th><th>Состояние</th><th>Начата</th><th></th></tr>` +
    ts.map((t) => `<tr><td>${esc(t.what)}</td><td>${esc(t.who)}</td><td>${badge(st, t.state)}</td><td class="nowrap">${ago(t.started)}</td>
      <td><button class="btn" data-act="tasklog" data-id="${esc(t.id)}">${LOGOPEN.has(t.id) ? "Скрыть лог" : "Лог"}</button></td></tr>` +
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
  return `<div class="panel"><table><tr><th>ВМ</th><th>Состояние</th><th>Система</th><th class="num">Диск</th><th>Путь до приёмника</th><th>Связь</th><th>Последний отчёт</th><th></th></tr>` +
    S.agents.map((a) => {
      const rep = a.report && a.report.rc !== undefined && a.report.rc !== null
        ? `<span class="badge ${a.report.rc === 0 ? "ok" : "bad"}">${a.report.rc === 0 ? "успешно" : "ошибка " + esc(a.report.rc)}</span> <span class="small muted">${ago(a.report.at)}</span><div class="small">${esc(a.report.summary || "")}</div>` : `<span class="muted">—</span>`;
      const cmd = a.command ? `<div class="small"><span class="badge info">в очереди: ${esc(a.command === "sync" ? "проход" : a.command)}</span></div>` : "";
      return `<tr><td><b>${esc(a.name)}</b><div class="small muted">${esc(a.hostname || "")}</div></td>
        <td>${badge(AGENT_STATE, a.state)}${cmd}${a.state === "token" && a.token_exp ? `<div class="small muted">токен до ${when(a.token_exp)}</div>` : ""}</td>
        <td><div>${esc(a.os || "—")}</div><div class="small muted">${esc(a.kernel || "")}${a.module === "no" ? ' · <span class="badge warn">нет модуля</span>' : ""}</div></td>
        <td class="num">${GiB(a.disk_bytes)}</td><td class="small">${esc(PATHS[a.path] || a.path)}<div class="muted">${a.threads} потоков</div></td>
        <td class="small nowrap">${ago(a.seen)}<div class="muted mono">${esc(a.peer || "")}</div></td><td>${rep}</td>
        <td><div class="actions">${a.state === "enrolled" ? `<button class="btn" data-act="agent-sync" data-name="${esc(a.name)}">Проход</button>` : ""}
          ${a.state !== "revoked" ? `<button class="btn" data-act="agent-add" data-name="${esc(a.name)}">Новый токен</button>` : ""}
          ${a.state === "enrolled" ? `<button class="btn danger" data-act="agent-uninstall" data-name="${esc(a.name)}">Удалить агента</button>` : ""}
          ${a.state !== "revoked" ? `<button class="btn danger" data-act="agent-revoke" data-name="${esc(a.name)}">Отключить</button>` : ""}</div></td></tr>`;
    }).join("") + `</table></div>`;
}
function vAgents() {
  return `<h2><span class="grow">Исходные ВМ</span><button class="btn primary" data-act="agent-add">Добавить ВМ</button></h2>${agentsTable()}
  <p class="small muted">Агент ставится одной командой с этого оркестратора и ждёт команд. Сертификат агента позволяет только писать в его том через приёмник; учётные данные облака на исходную ВМ не попадают.</p>`;
}
function jobsTable(list, compact) {
  if (!list.length) return `<div class="panel"><div class="empty">${compact ? "Активных заданий нет" : "Заданий ещё нет. Сначала подключите исходную ВМ, затем создайте задание."}</div></div>`;
  return `<div class="panel"><table><tr><th>Задание</th><th>ВМ</th><th>Состояние</th><th>Прогресс</th><th>Синхронизировано</th>${compact ? "" : "<th>Приёмник / том</th><th>Расписание</th>"}<th></th></tr>` +
    list.map((j) => { const ag = S.agents.find((a) => a.name === j.agent) || {}; const queued = ag.command === "sync" && j.state !== "receiving" && j.state !== "finished";
      return `<tr><td class="mono">${esc(j.id)}</td><td><b>${esc(j.agent)}</b><div class="small muted">${GiB(j.disk_bytes)}</div></td>
      <td>${badge(JOB_STATE, j.state)}${queued ? '<div class="small"><span class="badge info">проход в очереди</span></div>' : ""}${j.vm_name ? `<div class="small">ВМ ${esc(j.vm_name)}</div>` : ""}</td><td>${jobProgress(j)}</td>
      <td class="small">${j.synced_at ? ago(j.synced_at) + `<div class="muted">снапшот ${esc((j.synced_snapshot || "").replace("T", " ").replace(/\.\d+Z$/, " UTC"))}</div>` : "—"}</td>
      ${compact ? "" : `<td class="small">${esc(j.receiver)}<div class="muted mono">${esc((j.volume_id || "").slice(0, 8))} · ${esc(j.az)}</div></td>
      <td class="small">${j.sync_every ? "каждые " + dur(j.sync_every) : "—"}</td>`}
      <td><div class="actions">${["synced", "ready"].includes(j.state) && !queued ? `<button class="btn" data-act="job-sync" data-id="${esc(j.id)}">Дельта</button>` : ""}
        ${!compact && ["synced", "ready", "receiving"].includes(j.state) ? `<button class="btn" data-act="job-every" data-id="${esc(j.id)}">Расписание</button>` : ""}
        ${j.state === "synced" ? `<button class="btn primary" data-act="job-finish" data-id="${esc(j.id)}">Создать ВМ</button>` : ""}
        ${!compact && j.state !== "finished" ? `<button class="btn danger" data-act="job-delete" data-id="${esc(j.id)}">Удалить</button>` : ""}</div></td></tr>`; }).join("") + `</table></div>`;
}
function vJobs() {
  return `<h2><span class="grow">Задания</span><button class="btn primary" data-act="job-new">Новое задание</button></h2>${jobsTable(S.jobs, false)}
  <p class="small muted">Задание: том в целевом проекте, подключённый к приёмнику. Первый проход передаёт весь диск, следующие — только изменившиеся блоки. «Создать ВМ» отключает том и создаёт с него ВМ; источник при этом не меняется.</p>`;
}
function vReceivers() {
  return `<h2><span class="grow">Приёмники</span><button class="btn primary" data-act="rx-add">Добавить приёмник</button></h2>
  <div class="panel"><table><tr><th>Имя</th><th>Состояние</th><th>ВМ</th><th>Адреса</th><th class="num">Томов</th><th class="num">Нагрузка</th><th>Связь</th><th></th></tr>` +
    S.receivers.map((r) => `<tr><td><b>${esc(r.name)}</b><div class="small muted mono">${esc(r.dns)}</div></td><td>${badge(RX_STATE, r.state)}</td>
      <td class="small">${r.local ? "на ВМ оркестратора" : esc(r.flavor)}<div class="muted">${esc(r.az)}</div></td>
      <td class="small mono">${esc(r.grey_ip || "—")}${r.fip ? "<br>FIP " + esc(r.fip) : ""}</td><td class="num">${r.volumes}/${r.max_volumes}</td>
      <td class="num">${r.load != null ? Number(r.load).toFixed(2) : "—"}</td><td class="small nowrap">${ago(r.seen)}</td>
      <td>${r.local ? "" : `<button class="btn danger" data-act="rx-delete" data-name="${esc(r.name)}" ${r.volumes ? "disabled" : ""}>Удалить</button>`}</td></tr>`).join("") +
    `</table></div><p class="small muted">Если в нужной зоне нет приёмника со свободным местом, «Новое задание» создаст его само (около 1,5 мин).</p>`;
}
function vLog() {
  return `<h2>Операции</h2>${tasksPanel(20)}<h2>Журнал</h2><div class="panel"><table><tr><th>Время</th><th>Кто</th><th>Что</th></tr>` +
    S.events.map((e) => `<tr><td class="nowrap small">${when(e.ts)}</td><td class="small">${esc(e.who)}</td><td class="small">${esc(e.what)}</td></tr>`).join("") + `</table></div>`;
}
function vSettings() {
  const o = S.orchestrator, row = (k, v) => `<div>${esc(k)}</div><div>${v}</div>`;
  return `<h2>Настройки</h2><div class="panel"><div class="kv">
    ${row("Имя оркестратора", `<span class="mono">${esc(o.ctl_name)}</span>`)}
    ${row("Адреса", `серый <span class="mono">${esc(o.grey_ip)}</span>, публичный <span class="mono">${esc(o.public_ip || "—")}</span>`)}
    ${row("Зона, сеть", `${esc(o.az)}, ${esc(o.network)}`)}
    ${row("Приёмники", `${esc(o.rx_flavor)}, тома ${esc(o.rx_volume_type)}, до ${esc(o.max_volumes)} томов на приёмник, часть ${esc(o.part_mb)} МиБ`)}
    ${row("443 на приёмниках открыт для", `<span class="mono">${esc((o.allow || []).join(", ") || "—")}</span>`)}
    ${row("Пул FIP для приёмников", `<span class="mono">${esc((o.fip_pool || []).join(", ") || "—")}</span>`)}
    ${row("Веб-интерфейс доступен из", `<span class="mono">${esc((o.ui_allow || []).join(", "))}</span>`)}
    ${row("Сертификат администратора", o.ui_mtls ? "обязателен" : "не требуется")}
  </div></div>
  <p class="small muted">Меняются командой на ВМ оркестратора: <span class="mono">d2g setup --allow CIDR --ui-allow CIDR --fip-pool ID --ui-mtls on|off</span>; администраторы — <span class="mono">d2g admin add|passwd|totp|cert ИМЯ</span>.</p>`;
}
const VIEWS = { overview: vOverview, agents: vAgents, jobs: vJobs, receivers: vReceivers, log: vLog, settings: vSettings };
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
const sel = (id, opts, cur, empty) => `<select id="${id}">${empty !== undefined ? `<option value="">${esc(empty)}</option>` : ""}${opts.map((o) => `<option ${o === cur ? "selected" : ""}>${esc(o)}</option>`).join("")}</select>`;
const val = (m, id) => m.querySelector("#" + id).value.trim();
async function cloud() { if (!CLOUD) CLOUD = await api("/api/ui/cloud"); return CLOUD; }

function startTask(r, what) {
  if (r.task) { WATCH.add(r.task); LOGOPEN.add(r.task); toast(`${what}: запущено, ход — во вкладке «Журнал»`); }
  else if (r.message) toast(r.message);
  refresh();
}
function addAgent(name) {
  modal(name ? `Новый токен для ${name}` : "Добавить исходную ВМ",
    `<div class="field"><label>Имя</label><input id="n" value="${esc(name || "")}" ${name ? "readonly" : ""} placeholder="web01" maxlength="32">
       <div class="hint">строчные латинские буквы, цифры и дефис</div></div>
     <div class="field"><label>Путь до приёмника</label>${`<select id="p">${Object.entries(PATHS).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join("")}</select>`}
       <div class="hint">«автоматически» — агент берёт первый ответивший адрес: серый IP приёмника, его FIP, оркестратор</div></div>
     <div class="field"><label>Потоков</label><input id="t" type="number" min="1" max="64" value="8">
       <div class="hint">на медленном канале больше потоков не помогает</div></div>`,
    [{ text: "Отмена" }, { text: "Получить команду", cls: "primary", ok: true }],
    async (m) => {
      const r = await api("/api/ui/agent/add", { name: val(m, "n"), path: val(m, "p"), threads: +val(m, "t") });
      const cmds = r.commands.map((c) => `<div class="small muted">${c.kind === "public" ? "если ВМ ходит через интернет (публичный адрес оркестратора)" : "если ВМ в ЦОДе или в той же сети (серый адрес)"}</div>
        <pre class="cmd">${esc(c.command)}</pre><button class="btn" data-copy="${esc(c.command)}">Скопировать</button>`).join("<hr>");
      modal("Команда для исходной ВМ", `<p>Выполните на исходной ВМ от root. Токен действует ${r.valid_min} мин и только один раз.</p>${cmds}`,
        [{ text: "Готово", cls: "primary" }]);
      document.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", () => navigator.clipboard.writeText(b.dataset.copy).then(() => toast("Скопировано"))));
      refresh();
    });
}
async function newJob() {
  const busy = new Set(S.jobs.filter((j) => j.state !== "finished").map((j) => j.agent));
  const free = S.agents.filter((a) => a.state === "enrolled" && !busy.has(a.name)).map((a) => a.name);
  if (!free.length) return toast("Нет подключённых ВМ без задания: сначала добавьте исходную ВМ", true);
  const c = await cloud();
  modal("Новое задание",
    `<div class="field"><label>Исходная ВМ</label>${sel("a", free)}</div>
     <div class="field"><label>Тип тома</label>${sel("vt", c.volume_types, S.orchestrator.rx_volume_type)}</div>
     <div class="field"><label>Зона</label>${sel("az", c.zones, S.orchestrator.az)}<div class="hint">том, приёмник и будущая ВМ будут в этой зоне</div></div>
     <div class="field"><label>Дельты по расписанию</label><select id="ev"><option value="0">нет, по кнопке</option><option value="900">каждые 15 мин</option>
       <option value="3600">каждый час</option><option value="14400">каждые 4 ч</option><option value="86400">раз в сутки</option></select></div>
     <p class="small muted">Том создаётся по размеру диска исходной ВМ и подключается к приёмнику; первый проход стартует сам.</p>`,
    [{ text: "Отмена" }, { text: "Создать", cls: "primary", ok: true }],
    async (m) => { const r = await api("/api/ui/job/new", { agent: val(m, "a"), type: val(m, "vt"), az: val(m, "az"), every: +val(m, "ev") }); close(); startTask(r, "Новое задание"); });
}
async function finishJob(id) {
  const j = S.jobs.find((x) => x.id === id), c = await cloud();
  modal(`Создать ВМ из ${j.agent}`,
    `<p class="small">Снапшот: <b>${esc((j.synced_snapshot || "").replace("T", " ").replace(/\.\d+Z$/, " UTC"))}</b> (${ago(j.synced_at)}). Чтобы ВМ была свежей, сначала сделайте дельту. Том отключится от приёмника, дальнейшие проходы будут невозможны.</p>
     <div class="field"><label>Имя ВМ</label><input id="nm" value="${esc(j.agent)}-d2g" maxlength="64"></div>
     <div class="field"><label>Флейвор</label><select id="fl">${c.flavors.map((f) => `<option value="${esc(f.name)}">${esc(f.name)} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ</option>`).join("")}</select></div>
     <div class="field"><label>Сеть</label>${sel("net", c.networks, S.orchestrator.network)}</div>
     <div class="field"><label>Группы безопасности</label><div class="checks">${c.security_groups.map((g) => `<label><input type="checkbox" value="${esc(g)}" ${g === "default" ? "checked" : ""}>${esc(g)}</label>`).join("")}</div></div>
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
async function addRx() {
  const c = await cloud();
  modal("Добавить приёмник",
    `<div class="field"><label>Зона</label>${sel("az", c.zones, S.orchestrator.az)}</div>
     <div class="field"><label>Флейвор</label><select id="fl">${c.flavors.map((f) => `<option value="${esc(f.name)}" ${f.name === S.orchestrator.rx_flavor ? "selected" : ""}>${esc(f.name)} — ${f.vcpus} vCPU, ${Math.round(f.ram / 1024)} ГБ</option>`).join("")}</select></div>
     <div class="field"><label>FIP</label><select id="fip"><option value="">без FIP (серый IP и через оркестратор)</option>${(S.orchestrator.fip_pool || []).length ? '<option value="auto">свободный из пула</option>' : ""}</select></div>`,
    [{ text: "Отмена" }, { text: "Создать", cls: "primary", ok: true }],
    async (m) => { const r = await api("/api/ui/receiver/add", { az: val(m, "az"), flavor: val(m, "fl"), fip: val(m, "fip") }); close(); startTask(r, "Новый приёмник"); });
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
  if (a === "agent-uninstall") return confirmAct(`Удалить агента с ${name}`, "Агент удалит себя с исходной ВМ (модуль, бинарники, настройки) при следующем опросе. Сама ВМ не меняется.", "Удалить агента", () => api(`/api/ui/agent/${name}/uninstall`, {}));
  if (a === "job-new") return run(newJob());
  if (a === "job-sync") return run(api(`/api/ui/job/${id}/sync`, {}).then((r) => startTask(r, "Дельта")));
  if (a === "job-every") return every(id);
  if (a === "job-finish") return run(finishJob(id));
  if (a === "job-delete") return confirmAct(`Удалить задание ${id}`, "Том будет отключён от приёмника и удалён вместе с перенесёнными данными. Исходная ВМ не меняется.", "Удалить", () => api(`/api/ui/job/${id}/delete`, {}));
  if (a === "rx-add") return run(addRx());
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
      if (t && t.state !== "running") { WATCH.delete(id); toast(`${t.what}: ${t.state === "done" ? "готово" : "ошибка, см. лог"}`, t.state !== "done"); }
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
