"use strict";
// guide screenshots: ?shot=<id> opens a screen of the d2g UI on mock data
(async () => {
  const q = new URLSearchParams(location.search), shot = q.get("shot") || "";
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const $$ = (s) => document.querySelector(s);
  const set = (s, v) => { const e = $$(s); if (e) e.value = v; };
  if (location.pathname === "/setup") {
    if (shot === "code" || !shot) { set("#code", "6476-a9c1-1226"); return; }
    W.code = "6476-a9c1-1226";
    W.info = await api("/api/setup/info");
    $$("#ctl").textContent = W.info.ctl_name;
    $$("#ver").textContent = "версия " + W.info.version;
    W.place.public_ip = W.info.public_ip;
    W.access.ui_allow = W.info.client_ip + "/32";
    W.access.allow = "10.0.10.0/24\n203.0.113.1/32";
    Object.assign(W.admin, { password: "correct-horse-battery", totp: true, totp_secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", totp_code: "492817" });
    Object.assign(W.cloud, { project_id: "4f2a9c1e7b3d4a6e8f0c2b5d9e1a3c70", username: "svc-4f2a9c1e7b3d4a6e8f0c2b5d9e1a3c70-migration", password: "xxxxxxxxxxxxxxxx" });
    const n = { admin: 0, cloud: 1, place: 2, rx: 3, access: 4, apply: 5, done: 5 }[shot];
    if (n > 0) W.check = await api("/api/setup/cloud", {});
    go(n);
    if (shot === "done") { await sleep(300); $$("#next").click(); }
    return;
  }
  if (location.pathname === "/login") { set("#u", "admin"); set("#p", "correct-horse-battery"); return; }
  for (let i = 0; i < 80 && !S; i++) await sleep(100);
  await sleep(300);
  const tab = q.get("tab");
  if (tab) {
    TAB = tab;
    document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
    render();
  }
  if (shot === "addagent-form") { addAgent(); await sleep(100); set("#n", "web01"); }
  if (shot === "addagent") { addAgent(); await sleep(100); set("#n", "web01"); $$('#modal [data-mbtn="1"]').click(); }
  if (shot === "newjob") await newJob();
  if (shot === "finish") await finishJob(S.jobs.find((j) => j.state === "synced").id);
  if (shot === "addtarget") await editTarget();
  if (shot === "addrx") await addRx();
  if (shot === "tasklog") { LOGOPEN.add(S.tasks[0].id); render(); }
})();
