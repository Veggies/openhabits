/// The server's own web page: first-run setup, then settings (remote
/// access, devices, people). It talks to the same JSON API as the app.
///
/// Everything rendered from the server goes through textContent or
/// attribute setters, never innerHTML, so names and messages can't inject
/// markup.
const setupPageHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenHabits Server</title>
<link rel="icon" type="image/png" href="/icon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
  :root {
    --bg: #f5f5f7; --panel: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea;
    --field: #fff; --field-line: #d2d2d7; --accent: #3b6cf6; --on-accent: #fff;
    --bad: #c9271f; --warn: #a15c00;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #161618; --panel: #1f1f22; --text: #f2f2f4; --muted: #9b9ba1; --line: #2e2e33;
      --field: #2a2a2e; --field-line: #3a3a40; --accent: #5b85ff; --on-accent: #fff;
      --bad: #ff6b61; --warn: #f0b04a;
      color-scheme: dark;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
    font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }

  .topbar { background: var(--panel); border-bottom: 1px solid var(--line); }
  .topbar-inner { max-width: 680px; margin: 0 auto; padding: 10px 16px;
    display: flex; align-items: center; gap: 10px; }
  .topbar img { width: 28px; height: 28px; display: block; }
  .topbar h1 { font-size: 15px; font-weight: 600; margin: 0; flex: 1; }
  .topbar .who { color: var(--muted); }

  main { max-width: 680px; margin: 0 auto; padding: 24px 16px 64px; }
  h2 { font-size: 13px; font-weight: 600; color: var(--muted); margin: 28px 0 8px 2px; }
  #dashboard > :first-child > h2, #dashboard > h2:first-child { margin-top: 0; }
  details.group > summary { list-style: none; cursor: pointer; font-size: 13px; font-weight: 600;
    color: var(--muted); margin: 28px 0 8px 2px; display: inline-flex; align-items: center; gap: 6px; }
  details.group > summary::-webkit-details-marker { display: none; }
  details.group > summary::before { content: ""; width: 6px; height: 6px; border: solid currentColor;
    border-width: 0 1.5px 1.5px 0; transform: rotate(-45deg); transition: transform .15s; }
  details.group[open] > summary::before { transform: rotate(45deg); }
  .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; }
  .item { display: flex; align-items: center; gap: 16px; padding: 12px 16px; min-height: 52px; }
  .item + .item, .item + .detail, .detail + .item { border-top: 1px solid var(--line); }
  .item .label { flex: 1; min-width: 0; }
  .item .hint { color: var(--muted); font-size: 13px; }
  .item .control { flex: 0 0 auto; display: flex; gap: 8px; align-items: center; }
  .item .control input { width: 240px; }
  @media (max-width: 560px) {
    .item.field { flex-direction: column; align-items: stretch; gap: 6px; }
    .item.field .control input { width: 100%; }
  }
  .detail { padding: 12px 16px; }
  #people:not(:empty) + .detail { border-top: 1px solid var(--line); }
  .detail ol { margin: 6px 0 0; padding-left: 20px; }
  .problem { color: var(--warn); }
  .problem.bad { color: var(--bad); }

  input { padding: 7px 10px; border-radius: 7px; border: 1px solid var(--field-line);
    background: var(--field); color: var(--text); font: inherit; }
  input:focus { outline: 2px solid var(--accent); outline-offset: -1px; border-color: transparent; }
  button { font: inherit; border-radius: 7px; padding: 6px 14px; border: 1px solid var(--field-line);
    background: var(--field); color: var(--text); cursor: pointer; white-space: nowrap; }
  button.primary { background: var(--accent); color: var(--on-accent); border-color: var(--accent); }
  button.danger { color: var(--bad); }
  button:disabled { opacity: .55; cursor: default; }
  button.link { border: 0; background: none; padding: 0; color: var(--accent); }

  .switch { position: relative; width: 42px; height: 24px; flex: 0 0 auto; }
  .switch input { position: absolute; opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; }
  .switch span { position: absolute; inset: 0; border-radius: 99px; background: var(--field-line);
    transition: background .15s; pointer-events: none; }
  .switch span::after { content: ""; position: absolute; top: 2px; left: 2px; width: 20px; height: 20px;
    border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.3); transition: transform .15s; }
  .switch input:checked + span { background: var(--accent); }
  .switch input:checked + span::after { transform: translateX(18px); }
  .switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }
  .switch input:disabled { cursor: default; }

  .form { max-width: 380px; margin: 40px auto 0; }
  .form .panel { padding: 20px; }
  .form h1 { font-size: 20px; margin: 0 0 4px; }
  .form p { color: var(--muted); margin: 0 0 16px; }
  .form label { display: block; font-size: 13px; margin: 12px 0 4px; }
  .form input { width: 100%; }
  .form .actions { margin-top: 18px; }

  .error { color: var(--bad); }
  .error:empty { display: none; }
  .section-error { margin: 8px 2px 0; }
  .muted { color: var(--muted); }
  code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; overflow-wrap: anywhere; }
  .pair { display: flex; gap: 20px; flex-wrap: wrap; align-items: center; }
  .qr { background: #fff; padding: 8px; border-radius: 8px; width: 200px; height: 200px; }
  .code { font-size: 24px; letter-spacing: 3px; font-weight: 600; margin: 4px 0; }
  .add-person { display: flex; gap: 8px; flex-wrap: wrap; }
  .add-person input { flex: 1 1 140px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<div class="topbar">
  <div class="topbar-inner">
    <img src="/icon.png" alt="">
    <h1 id="title">OpenHabits Server</h1>
    <span id="who" class="who"></span>
    <button id="signOut" hidden>Sign out</button>
  </div>
</div>
<main>
  <p id="loading" class="muted">Loading…</p>

  <!-- First run -->
  <div id="setup" class="form" hidden>
    <form id="setupForm" class="panel">
      <h1>Create your account</h1>
      <p>You'll be the owner of this server. You can add other people afterwards.</p>
      <label for="su-user">Username</label>
      <input id="su-user" autocomplete="username" required>
      <label for="su-pass">Password</label>
      <input id="su-pass" type="password" autocomplete="new-password" minlength="8" required>
      <label for="su-pass2">Password again</label>
      <input id="su-pass2" type="password" autocomplete="new-password" minlength="8" required>
      <div class="actions"><button class="primary" type="submit">Create account</button></div>
      <p class="error" id="setupError" style="margin:12px 0 0"></p>
    </form>
  </div>

  <!-- Sign in -->
  <div id="login" class="form" hidden>
    <form id="loginForm" class="panel">
      <h1>Sign in</h1>
      <p>Use your OpenHabits account.</p>
      <label for="li-user">Username</label>
      <input id="li-user" autocomplete="username" required>
      <label for="li-pass">Password</label>
      <input id="li-pass" type="password" autocomplete="current-password" required>
      <div class="actions"><button class="primary" type="submit">Sign in</button></div>
      <p class="error" id="loginError" style="margin:12px 0 0"></p>
    </form>
  </div>

  <div id="dashboard" hidden>
    <div id="remoteSection">
      <h2>Network</h2>
      <div class="panel">
        <div class="item">
          <div class="label">
            <div>Remote access</div>
            <div class="hint" id="remoteState">Lets your devices sync when you're away from home.</div>
          </div>
          <label class="switch"><input type="checkbox" id="remoteToggle" aria-label="Remote access"><span></span></label>
        </div>
        <div class="detail" id="remoteProblem" hidden>
          <div id="remoteMessage" class="problem"></div>
          <ol id="portForwardSteps" hidden>
            <li>Open your router's settings (often <code>192.168.0.1</code> or <code>192.168.1.1</code>).</li>
            <li>Under "Port forwarding" (or "NAT", "Virtual server"), <span id="forwardStep"></span>.</li>
            <li>Come back and choose <em>I've forwarded the port</em>.</li>
          </ol>
          <ol id="relaySteps" hidden>
            <li>Install <strong>Tailscale</strong> on this server (on TrueNAS: <em>Apps → Discover</em>) and sign in.</li>
            <li>In the Tailscale admin console, turn on <strong>HTTPS certificates</strong> and allow <strong>Funnel</strong> for this machine.</li>
            <li>Run <code>tailscale funnel --bg 8080</code> and copy the address it prints.</li>
            <li>Paste it under <em>Advanced → Reverse proxy address</em> below.</li>
          </ol>
          <div style="margin-top:10px; display:flex; gap:8px; flex-wrap:wrap" id="remoteButtons"></div>
        </div>
      </div>
      <p class="error section-error" id="remoteError"></p>
    </div>

    <h2>Devices</h2>
    <div class="panel">
      <div class="item">
        <div class="label">
          <div>Add a device</div>
          <div class="hint">Sign in a phone or computer without typing a password.</div>
        </div>
        <div class="control"><button id="pairButton">Show code</button></div>
      </div>
      <div class="detail" id="pairBox" hidden>
        <div class="pair">
          <img id="pairQr" class="qr" alt="QR code to sign in">
          <div>
            <div>Scan it with the OpenHabits app, or enter <code id="pairServer"></code> and this code:</div>
            <div class="code mono" id="pairCode"></div>
            <div class="muted">Works once, for 10 minutes.</div>
          </div>
        </div>
      </div>
    </div>
    <p class="error section-error" id="pairError"></p>

    <div id="ownerOnly">
      <h2>People</h2>
      <div class="panel" id="peoplePanel">
        <div id="people"></div>
        <form class="detail" id="personForm">
          <div class="add-person">
            <input id="p-user" placeholder="Username" aria-label="Username" autocomplete="off" required>
            <input id="p-pass" type="password" placeholder="Password" aria-label="Password" autocomplete="new-password" minlength="8" required>
            <button type="submit">Add person</button>
          </div>
        </form>
      </div>
      <p class="error section-error" id="peopleError"></p>

      <details class="group">
      <summary>Advanced</summary>
      <div class="panel" id="advanced">
        <div class="item field">
          <div class="label">
            <div>Router port</div>
            <div class="hint">The port opened on your router for remote access.</div>
          </div>
          <div class="control"><input id="ra-port" type="number" min="1" max="65535" style="width:110px"></div>
        </div>
        <div class="item field">
          <div class="label">
            <div>Reverse proxy address</div>
            <div class="hint">Only if you reach this server through a reverse proxy or tunnel, like Tailscale Funnel.</div>
          </div>
          <div class="control"><input id="ra-url" placeholder="https://habits.example.com" autocapitalize="off" spellcheck="false"></div>
        </div>
        <div class="item" id="fingerprintRow" hidden>
          <div class="label">
            <div>Security code</div>
            <div class="hint">The app shows this if you type the remote address yourself.</div>
          </div>
          <div class="control"><code id="fingerprint"></code></div>
        </div>
        <div class="item" style="justify-content:flex-end"><button class="primary" id="ra-save">Save</button></div>
      </div>
      </details>
      <p class="error section-error" id="advancedError"></p>
    </div>
  </div>
</main>
<script>
"use strict";
const $ = (id) => document.getElementById(id);
const show = (id, on = true) => { $(id).hidden = !on; };
let token = null;
// "tasksToken" is the name an earlier version used.
try { token = localStorage.getItem("openhabitsToken") ?? localStorage.getItem("tasksToken"); } catch (_) {}
let me = null;

function saveToken(t) {
  token = t;
  try {
    localStorage.removeItem("tasksToken");
    t ? localStorage.setItem("openhabitsToken", t) : localStorage.removeItem("openhabitsToken");
  } catch (_) {}
}

async function api(method, path, body) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = "Bearer " + token;
  const res = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let data = {};
  try { data = text ? JSON.parse(text) : {}; } catch (_) {}
  if (res.status === 401 && token) { saveToken(null); start(); throw new Error("Please sign in again."); }
  if (!res.ok) throw new Error(data.error || ("Something went wrong (error " + res.status + "). Please try again."));
  return data;
}

function guard(errorId, fn) {
  return async (event) => {
    if (event && event.type === "submit") event.preventDefault();
    $(errorId).textContent = "";
    const button = event && event.submitter ? event.submitter : (event && event.target.tagName === "BUTTON" ? event.target : null);
    if (button) button.disabled = true;
    try { await fn(event); } catch (e) { $(errorId).textContent = e.message; }
    finally { if (button) button.disabled = false; }
  };
}

function el(tag, text, cls) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = text;
  if (cls) node.className = cls;
  return node;
}

function button(label, onClick, cls) {
  const b = el("button", label, cls);
  b.type = "button";
  b.addEventListener("click", onClick);
  return b;
}

async function start() {
  for (const id of ["loading", "setup", "login", "dashboard"]) show(id, false);
  show("signOut", false);
  $("who").textContent = "";
  let info;
  try { info = await api("GET", "/auth/info"); }
  catch (e) { show("loading"); $("loading").textContent = e.message; return; }
  document.title = info.name + " Server";
  $("title").textContent = info.name + " Server";
  if (info.needsSetup) { show("setup"); $("su-user").focus(); return; }
  if (!token) { show("login"); return; }
  try { me = (await api("GET", "/auth/me")).user; }
  catch (_) { show("login"); return; }
  $("who").textContent = me.username;
  show("signOut");
  show("dashboard");
  show("ownerOnly", me.isOwner);
  show("remoteSection", me.isOwner);
  if (me.isOwner) { loadRemote(); loadPeople(); }
}

// ---- First run and sign in ----
$("setupForm").addEventListener("submit", guard("setupError", async () => {
  if ($("su-pass").value !== $("su-pass2").value) throw new Error("The passwords don't match.");
  const res = await api("POST", "/setup", {
    username: $("su-user").value.trim(), password: $("su-pass").value,
    device: "Setup page",
  });
  saveToken(res.token);
  start();
}));

$("loginForm").addEventListener("submit", guard("loginError", async () => {
  const res = await api("POST", "/auth/login", {
    username: $("li-user").value.trim(), password: $("li-pass").value, device: "Setup page",
  });
  saveToken(res.token);
  start();
}));

$("signOut").addEventListener("click", async () => {
  try { await api("POST", "/auth/logout"); } catch (_) {}
  saveToken(null);
  start();
});

// ---- Remote access ----
// Shown under the switch only when something needs attention.
const problemStates = { needsPortForward: "warn", cgnat: "bad", error: "bad" };

/// "forward TCP port 8443 to 192.168.0.12, port 8454", as precise as we
/// can be: the address this page was opened on is usually the server's.
function forwardText(r) {
  const host = location.hostname;
  const ip = /^\d+\.\d+\.\d+\.\d+$/.test(host) && !host.startsWith("127.") ? host : r.status.localAddress;
  const samePort = r.httpsPort === r.port;
  const target = ip
    ? (samePort ? ip : ip + ", port " + r.httpsPort)
    : (samePort ? "this server" : "this server's port " + r.httpsPort);
  return "forward TCP port " + r.port + " to " + target;
}

function renderRemote(r) {
  const state = r.status.state;
  $("remoteToggle").checked = state !== "off";
  $("remoteState").textContent = "Lets your devices sync when you're away from home. " +
    "Needs UPnP turned on in your router, or " + forwardText(r) + " yourself.";

  const problem = problemStates[state];
  show("remoteProblem", !!problem);
  $("remoteMessage").textContent = problem ? r.status.message : "";
  $("remoteMessage").className = "problem" + (problem === "bad" ? " bad" : "");
  show("portForwardSteps", state === "needsPortForward");
  show("relaySteps", state === "cgnat");
  $("forwardStep").textContent = forwardText(r);

  const buttons = $("remoteButtons");
  buttons.replaceChildren();
  if (problem) buttons.append(act("refresh", "Check again"));
  if (state === "needsPortForward") buttons.append(act("manual", "I've forwarded the port", "primary"));

  const editing = document.activeElement;
  if (editing !== $("ra-port")) $("ra-port").value = r.port;
  if (editing !== $("ra-url")) $("ra-url").value = r.publicUrl || "";
  const pinned = state === "on" && !r.publicUrl && r.fingerprint;
  show("fingerprintRow", !!pinned);
  $("fingerprint").textContent = pinned ? r.fingerprint.split(":").slice(0, 8).join(":") : "";
}

function act(action, label, cls) {
  return button(label, guard("remoteError", async () => {
    $("remoteState").textContent = "Checking…";
    renderRemote(await api("POST", "/admin/remote", { action }));
  }), cls);
}

async function loadRemote() { renderRemote(await api("GET", "/admin/remote")); }

$("remoteToggle").addEventListener("change", guard("remoteError", async () => {
  const toggle = $("remoteToggle");
  const action = toggle.checked ? "enable" : "disable";
  toggle.disabled = true;
  $("remoteState").textContent = toggle.checked ? "Checking with your router…" : "Turning off…";
  try { renderRemote(await api("POST", "/admin/remote", { action })); }
  catch (e) { await loadRemote().catch(() => {}); throw e; }
  finally { toggle.disabled = false; }
}));

$("ra-save").addEventListener("click", guard("advancedError", async () => {
  $("remoteState").textContent = "Checking…";
  renderRemote(await api("PUT", "/admin/remote", {
    port: Number($("ra-port").value), publicUrl: $("ra-url").value.trim(),
  }));
}));

// ---- Add a device ----
let pairTimer = null;
$("pairButton").addEventListener("click", guard("pairError", async () => {
  const res = await api("POST", "/auth/pairing-code");
  const params = new URLSearchParams({ server: location.origin, code: res.code });
  if (res.remoteUrl) params.set("remote", res.remoteUrl);
  if (res.fingerprint) params.set("fp", res.fingerprint);
  const payload = "openhabits://pair?" + params.toString();
  const svg = await fetch("/qr.svg?data=" + encodeURIComponent(payload), { headers: { authorization: "Bearer " + token } });
  if (!svg.ok) throw new Error("Couldn't make the QR code.");
  $("pairQr").src = URL.createObjectURL(await svg.blob());
  $("pairCode").textContent = res.code;
  $("pairServer").textContent = location.origin;
  show("pairBox");
  $("pairButton").textContent = "New code";
  clearTimeout(pairTimer);
  pairTimer = setTimeout(() => { show("pairBox", false); $("pairButton").textContent = "Show code"; },
    res.expiresInSeconds * 1000);
}));

// ---- People ----
async function loadPeople() {
  const people = (await api("GET", "/users")).users;
  const list = $("people");
  list.replaceChildren();
  for (const p of people) {
    const row = el("div", null, "item");
    row.append(el("div", p.username, "label"));
    const control = el("div", null, "control");
    if (p.isOwner) control.append(el("span", "Owner", "muted"));
    else {
      control.append(button("Sign out everywhere", guard("peopleError", async () => {
        if (!confirm("Sign " + p.username + " out on all their devices? Their habits stay; they just sign in again.")) return;
        await api("POST", "/users/" + encodeURIComponent(p.id) + "/sign-out");
        alert(p.username + " has been signed out everywhere.");
      })));
      control.append(button("Remove", guard("peopleError", async () => {
        if (!confirm("Remove " + p.username + "? Their account and all their data on this server will be deleted.")) return;
        await api("DELETE", "/users/" + encodeURIComponent(p.id));
        await loadPeople();
      }), "danger"));
    }
    row.append(control);
    list.append(row);
  }
}

$("personForm").addEventListener("submit", guard("peopleError", async () => {
  await api("POST", "/users", { username: $("p-user").value.trim(), password: $("p-pass").value });
  $("personForm").reset();
  await loadPeople();
}));

start();
</script>
</body>
</html>
''';
