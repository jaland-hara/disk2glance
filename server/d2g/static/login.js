"use strict";
const f = document.getElementById("f"), e = document.getElementById("e"), tf = document.getElementById("tf");
f.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  e.textContent = "";
  const body = { user: f.u.value.trim(), password: f.p.value, totp: document.getElementById("t").value };
  try {
    const r = await fetch("/api/ui/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), credentials: "same-origin" });
    const j = await r.json().catch(() => ({}));
    if (r.ok) { location.href = "/"; return; }
    if (j.totp) { tf.hidden = false; document.getElementById("t").focus(); e.textContent = "Введите код из приложения."; return; }
    e.textContent = r.status === 429 ? "Слишком много попыток. " + (j.error || "") : "Неверный пользователь, пароль или код.";
  } catch (x) { e.textContent = "Нет связи с оркестратором."; }
});
