/// The server's own web page: first-run setup, then the owner's settings
/// (remote access, devices, people). It talks to
/// the same JSON API as the app.
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
    --bg: #f6f7fb; --card: #fff; --text: #1d2130; --muted: #667085; --line: #e3e6ee;
    --accent: #4772fa; --accent-text: #fff; --ok: #1f9d55; --warn: #b7791f; --bad: #d93025;
    --soft-ok: #e7f6ee; --soft-warn: #fdf3e1; --soft-bad: #fdecea;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #12141a; --card: #1b1e27; --text: #e8eaf0; --muted: #98a0b3; --line: #2c303c;
      --accent: #6d8dff; --accent-text: #0d1020; --ok: #4ade80; --warn: #f6c453; --bad: #ff7b72;
      --soft-ok: #15301f; --soft-warn: #362b12; --soft-bad: #3a1d1b;
      color-scheme: dark;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 720px; margin: 0 auto; padding: 24px 16px 64px; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 20px; }
  header h1 { font-size: 20px; margin: 0; flex: 1; }
  .logo { width: 36px; height: 36px; display: block; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 20px; margin-bottom: 16px; }
  .card h2 { font-size: 17px; margin: 0 0 4px; }
  .sub { color: var(--muted); margin: 0 0 16px; }
  label { display: block; font-size: 13px; color: var(--muted); margin: 12px 0 4px; }
  input, select { width: 100%; padding: 10px 12px; border-radius: 9px; border: 1px solid var(--line);
    background: var(--bg); color: var(--text); font: inherit; }
  button { font: inherit; border-radius: 9px; padding: 9px 16px; border: 1px solid var(--line);
    background: var(--card); color: var(--text); cursor: pointer; }
  button.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); }
  button.danger { color: var(--bad); }
  button:disabled { opacity: .6; cursor: default; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-top: 16px; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 0 12px; }
  @media (max-width: 560px) { .grid2 { grid-template-columns: 1fr; } }
  .pill { display: inline-block; padding: 2px 10px; border-radius: 99px; font-size: 13px; font-weight: 600; }
  .pill.on { background: var(--soft-ok); color: var(--ok); }
  .pill.off { background: var(--line); color: var(--muted); }
  .pill.warn { background: var(--soft-warn); color: var(--warn); }
  .pill.bad { background: var(--soft-bad); color: var(--bad); }
  .note { padding: 12px 14px; border-radius: 10px; margin-top: 12px; }
  .note.warn { background: var(--soft-warn); }
  .note.bad { background: var(--soft-bad); }
  .note ol { margin: 8px 0 0; padding-left: 20px; }
  .error { color: var(--bad); margin-top: 10px; min-height: 1px; }
  .list { list-style: none; padding: 0; margin: 0; }
  .list li { display: flex; align-items: center; gap: 8px; padding: 10px 0; border-bottom: 1px solid var(--line); }
  .list li:last-child { border-bottom: 0; }
  .list .grow { flex: 1; min-width: 0; overflow-wrap: anywhere; }
  .muted { color: var(--muted); font-size: 13px; }
  code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
  .code { font-size: 26px; letter-spacing: 3px; font-weight: 700; }
  .qr { background: #fff; padding: 8px; border-radius: 10px; width: 216px; height: 216px; }
  .pair { display: flex; gap: 20px; flex-wrap: wrap; align-items: center; }
  details summary { cursor: pointer; color: var(--muted); margin-top: 16px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <header>
    <img class="logo" src="/icon.png" alt="">
    <h1 id="title">OpenHabits Server</h1>
    <span id="who" class="muted"></span>
    <button id="signOut" hidden>Sign out</button>
  </header>

  <section id="loading" class="card"><p class="sub">Loading…</p></section>

  <!-- First run -->
  <section id="setup" class="card" hidden>
    <h2>Welcome! Create your account</h2>
    <p class="sub">You'll be the owner of this server. You can add other people afterwards.</p>
    <form id="setupForm">
      <label for="su-user">Username</label>
      <input id="su-user" autocomplete="username" required>
      <div class="grid2">
        <div><label for="su-pass">Password</label>
          <input id="su-pass" type="password" autocomplete="new-password" minlength="8" required></div>
        <div><label for="su-pass2">Password again</label>
          <input id="su-pass2" type="password" autocomplete="new-password" minlength="8" required></div>
      </div>
      <div class="row"><button class="primary" type="submit">Create account</button></div>
      <div class="error" id="setupError"></div>
    </form>
  </section>

  <!-- Sign in -->
  <section id="login" class="card" hidden>
    <h2>Sign in to this server</h2>
    <p class="sub">Use your OpenHabits account.</p>
    <form id="loginForm">
      <label for="li-user">Username</label>
      <input id="li-user" autocomplete="username" required>
      <label for="li-pass">Password</label>
      <input id="li-pass" type="password" autocomplete="current-password" required>
      <div class="row"><button class="primary" type="submit">Sign in</button></div>
      <div class="error" id="loginError"></div>
    </form>
  </section>

  <div id="dashboard" hidden>
    <!-- Remote access -->
    <section class="card" id="remoteCard">
      <h2>Remote access <span id="remotePill" class="pill off">Off</span></h2>
      <p class="sub">Use your habits away from home, on mobile data or any Wi-Fi.</p>
      <p id="remoteMessage"></p>
      <p id="remoteUrlRow" hidden>Address: <code id="remoteUrl"></code></p>
      <p id="fingerprintRow" class="muted" hidden>Security code (shown in the app if you type the address yourself): <code id="fingerprint"></code></p>
      <div id="portForwardHelp" class="note warn" hidden>
        <strong>Forward the port yourself</strong>
        <ol>
          <li>Open your router's settings (often <code>192.168.0.1</code> or <code>192.168.1.1</code>).</li>
          <li>Find "Port forwarding" (sometimes under "NAT" or "Virtual server").</li>
          <li>Forward TCP port <code class="js-port"></code> to this server's address, port <code id="httpsPort"></code>.</li>
          <li>Come back and choose <em>I've forwarded the port</em>.</li>
        </ol>
      </div>
      <div id="cgnatHelp" class="note bad" hidden>
        <strong>Use a free relay with Tailscale</strong>
        <p class="muted" style="margin:6px 0 0">Only this server needs Tailscale. Your phones and computers just use the OpenHabits app.</p>
        <ol>
          <li>On TrueNAS, open <em>Apps → Discover</em>, install <strong>Tailscale</strong>, and sign in with the link it shows (a free account works).</li>
          <li>In the Tailscale admin console, turn on <strong>HTTPS certificates</strong> (DNS page) and allow <strong>Funnel</strong> for this machine (Access controls).</li>
          <li>From a shell in the Tailscale app, run <code>tailscale funnel --bg 8080</code>. It prints an address like <code>https://truenas.your-tailnet.ts.net</code>.</li>
          <li>Paste that address under <em>Advanced → Custom public address</em> below and save.</li>
        </ol>
      </div>
      <div id="ipWarning" class="note warn" hidden>
        <strong>Add a hostname so this keeps working</strong>
        <p class="muted" style="margin:6px 0 0">Devices are using your internet address, and your provider can change it at any time. When that happens, devices away from home lose the connection until they're back on your Wi-Fi.</p>
      </div>
      <div class="row" id="remoteButtons"></div>
      <div>
        <label for="ra-host">Hostname</label>
        <div class="row" style="margin-top:0">
          <input id="ra-host" placeholder="habits.example.com" autocapitalize="off" spellcheck="false" style="flex:1">
          <button id="ra-host-save">Save</button>
        </div>
        <p class="muted">A name that always points at your home: a record on your own domain kept up to date by dynamic DNS, or a free dynamic DNS name (many routers have this built in). Devices use it instead of your internet address.</p>
        <div id="cfConnected" class="row" hidden>
          <span class="muted" style="flex:1">Cloudflare keeps this hostname pointed at your home.</span>
          <button id="cf-remove" class="danger">Remove token</button>
        </div>
        <details id="cfSetup">
          <summary>Domain on Cloudflare? Let OpenHabits keep it up to date</summary>
          <ol class="muted">
            <li>In Cloudflare, open <em>My Profile → API Tokens → Create Token</em> and choose the <strong>Edit zone DNS</strong> template.</li>
            <li>Under <em>Zone Resources</em>, pick just the domain your hostname is on, then create the token.</li>
            <li>Paste it here with your hostname above and save. OpenHabits creates the record (DNS only) and updates it whenever your internet address changes.</li>
          </ol>
          <label for="cf-token">Cloudflare API token</label>
          <input id="cf-token" type="password" autocomplete="off" spellcheck="false">
        </details>
      </div>
      <details>
        <summary>Advanced</summary>
        <div class="grid2">
          <div><label for="ra-port">Router port</label><input id="ra-port" type="number" min="1" max="65535"></div>
          <div><label for="ra-url">Reverse proxy or relay address (it has its own certificate, e.g. Tailscale Funnel)</label>
            <input id="ra-url" placeholder="https://habits.example.com"></div>
        </div>
        <div class="row"><button id="ra-save">Save</button></div>
      </details>
      <div class="error" id="remoteError"></div>
    </section>

    <!-- Add a device -->
    <section class="card">
      <h2>Add a device</h2>
      <p class="sub">Sign in your phone or another computer without typing a password.</p>
      <div class="row" style="margin-top:0"><button class="primary" id="pairButton">Show code</button></div>
      <div id="pairBox" class="pair" hidden style="margin-top:16px">
        <img id="pairQr" class="qr" alt="QR code to sign in">
        <div>
          <p style="margin:0">On your phone: open OpenHabits and scan the code.</p>
          <p style="margin:12px 0 0">On a computer: enter <code id="pairServer"></code> and this code:</p>
          <div class="code mono" id="pairCode"></div>
          <p class="muted">This code works once and expires in 10 minutes.</p>
        </div>
      </div>
      <div class="error" id="pairError"></div>
    </section>

    <div id="ownerOnly">
      <!-- People -->
      <section class="card">
        <h2>People</h2>
        <p class="sub">Everyone gets their own private habits.</p>
        <ul class="list" id="people"></ul>
        <details>
          <summary>Add a person</summary>
          <form id="personForm">
            <div class="grid2">
              <div><label for="p-user">Username</label><input id="p-user" required></div>
              <div><label for="p-pass">Password</label><input id="p-pass" type="password" minlength="8" required></div>
            </div>
            <div class="row"><button class="primary" type="submit">Add</button></div>
          </form>
        </details>
        <div class="error" id="peopleError"></div>
      </section>

    </div>
  </div>
</main>
<script>
"use strict";
const $ = (id) => document.getElementById(id);
const show = (id, on = true) => { $(id).hidden = !on; };
let token = null;
try { token = localStorage.getItem("tasksToken"); } catch (_) {}
let me = null;

function saveToken(t) {
  token = t;
  try { t ? localStorage.setItem("tasksToken", t) : localStorage.removeItem("tasksToken"); } catch (_) {}
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
    if (event) event.preventDefault();
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
  catch (e) { show("loading"); $("loading").firstElementChild.textContent = e.message; return; }
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
  show("remoteCard", me.isOwner);
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
const pills = {
  off: ["Off", "off"], on: ["On", "on"], needsPortForward: ["Needs a router setting", "warn"],
  cgnat: ["Blocked by your provider", "bad"], error: ["Problem", "bad"],
  hostMismatch: ["Hostname doesn't point here", "warn"],
};

function renderRemote(r) {
  const [label, cls] = pills[r.status.state] || ["Unknown", "off"];
  $("remotePill").textContent = label;
  $("remotePill").className = "pill " + cls;
  $("remoteMessage").textContent = r.status.message;
  show("remoteUrlRow", !!r.status.url);
  $("remoteUrl").textContent = r.status.url || "";
  const pinned = r.status.state === "on" && !r.publicUrl && r.fingerprint;
  show("fingerprintRow", !!pinned);
  $("fingerprint").textContent = pinned ? r.fingerprint.split(":").slice(0, 8).join(":") : "";
  show("portForwardHelp", r.status.state === "needsPortForward");
  show("cgnatHelp", r.status.state === "cgnat");
  show("ipWarning", r.status.state === "on" && !!r.status.addressMayChange);
  if (document.activeElement !== $("ra-host")) $("ra-host").value = r.host || "";
  show("cfConnected", !!r.cloudflare);
  show("cfSetup", !r.cloudflare);
  for (const node of document.querySelectorAll(".js-port")) node.textContent = r.port;
  $("httpsPort").textContent = r.httpsPort;
  if (document.activeElement !== $("ra-port")) $("ra-port").value = r.port;
  if (document.activeElement !== $("ra-url")) $("ra-url").value = r.publicUrl || "";

  const act = (action, label, cls) => button(label, guard("remoteError", async () => {
    $("remoteMessage").textContent = "Checking with your router…";
    renderRemote(await api("POST", "/admin/remote", { action }));
  }), cls);
  const buttons = $("remoteButtons");
  buttons.replaceChildren();
  if (r.status.state === "off") buttons.append(act("enable", "Enable remote access", "primary"));
  else {
    buttons.append(act("refresh", "Check again"));
    if (r.status.state === "needsPortForward") buttons.append(act("manual", "I've forwarded the port", "primary"));
    buttons.append(act("disable", "Turn off", "danger"));
  }
}

async function loadRemote() { renderRemote(await api("GET", "/admin/remote")); }

$("ra-save").addEventListener("click", guard("remoteError", async () => {
  renderRemote(await api("PUT", "/admin/remote", {
    port: Number($("ra-port").value), publicUrl: $("ra-url").value.trim(),
  }));
}));
$("ra-host-save").addEventListener("click", guard("remoteError", async () => {
  const change = { host: $("ra-host").value.trim() };
  const token = $("cf-token").value.trim();
  if (token) change.cloudflareToken = token;
  $("remoteMessage").textContent = token ? "Updating Cloudflare…" : "Checking the hostname…";
  renderRemote(await api("PUT", "/admin/remote", change));
  $("cf-token").value = "";
}));
$("cf-remove").addEventListener("click", guard("remoteError", async () => {
  renderRemote(await api("PUT", "/admin/remote", { cloudflareToken: "" }));
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
  clearTimeout(pairTimer);
  pairTimer = setTimeout(() => show("pairBox", false), res.expiresInSeconds * 1000);
}));

// ---- People ----
let people = [];
async function loadPeople() {
  people = (await api("GET", "/users")).users;
  const list = $("people");
  list.replaceChildren();
  for (const p of people) {
    const li = el("li");
    const text = el("div", null, "grow");
    text.append(el("div", p.username), el("div", p.isOwner ? "Owner" : "", "muted"));
    li.append(text);
    if (!p.isOwner) {
      li.append(button("Remove", guard("peopleError", async () => {
        if (!confirm("Remove " + p.username + "? Their account and all their data on this server will be deleted.")) return;
        await api("DELETE", "/users/" + encodeURIComponent(p.id));
        await loadPeople();
      }), "danger"));
    }
    list.append(li);
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
