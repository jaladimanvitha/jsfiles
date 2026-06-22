"use strict";

// ---------- tiny helpers ----------
const $ = (id) => document.getElementById(id);
const qs = (sel, root = document) => root.querySelector(sel);
const qsa = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const state = {
  pods: [],
  filter: "",
  autoTimer: null,
  logsTimer: null,
  currentPod: null,
  currentNamespace: "",
  recentNamespaces: [],
};

// ---------- HTTP ----------
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    method: opts.method || (opts.body ? "POST" : "GET"),
  });
  let data = null;
  const text = await res.text();
  try { data = text ? JSON.parse(text) : {}; } catch { data = { raw: text }; }
  if (!res.ok) {
    const err = new Error(data && data.error ? data.error : `HTTP ${res.status}`);
    err.payload = data;
    err.status = res.status;
    throw err;
  }
  return data;
}

// ---------- toast ----------
let toastTimer = null;
function toast(msg, kind = "") {
  const t = $("toast");
  t.textContent = msg;
  t.className = `toast ${kind}`;
  t.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), 3500);
}

// ---------- health + auth ----------
async function refreshHealth() {
  try {
    const h = await api("/api/health");
    setPill("health-gcloud",  h.gcloud  ? `gcloud ✓` : `gcloud ✗`, h.gcloud  ? "ok" : "err");
    setPill("health-kubectl", h.kubectl ? `kubectl ✓` : `kubectl ✗`, h.kubectl ? "ok" : "err");
    const banner = $("install-banner");
    if (!h.gcloud || !h.kubectl) {
      const missing = [!h.gcloud && "gcloud", !h.kubectl && "kubectl"].filter(Boolean).join(" and ");
      $("install-msg").textContent = `${missing} not found on PATH.`;
      banner.classList.remove("hidden");
    } else {
      banner.classList.add("hidden");
    }
  } catch (e) {
    setPill("health-gcloud", "gcloud ?", "warn");
    setPill("health-kubectl", "kubectl ?", "warn");
  }
  try {
    const a = await api("/api/auth/status");
    if (a.authenticated) {
      setPill("health-auth", a.account || "logged in", "ok");
      $("btn-login").textContent = "Re-login";
    } else {
      setPill("health-auth", "not logged in", "warn");
      $("btn-login").textContent = "Login";
    }
  } catch {
    setPill("health-auth", "auth ?", "warn");
  }
}
function setPill(id, text, kind) {
  const el = $(id); if (!el) return;
  el.textContent = text;
  el.className = `pill pill-${kind || "muted"}`;
}

// ---------- config ----------
async function loadConfig() {
  try {
    const cfg = await api("/api/config");
    $("cfg-project").value = cfg.project || "";
    $("cfg-cluster").value = cfg.cluster || "";
    $("cfg-region").value  = cfg.region  || "";
    $("ns-input").value    = cfg.namespace || "";
    state.recentNamespaces = Array.isArray(cfg.recent_namespaces) ? cfg.recent_namespaces : [];
    state.currentNamespace = cfg.namespace || "";
    renderNamespaceHistory();
  } catch (e) { /* ok, first run */ }
}

function readConfigFromUI() {
  return {
    project:   $("cfg-project").value.trim(),
    cluster:   $("cfg-cluster").value.trim(),
    region:    $("cfg-region").value.trim(),
    namespace: $("ns-input").value.trim(),
    recent_namespaces: state.recentNamespaces,
  };
}

async function saveConfig() {
  try { await api("/api/config", { body: readConfigFromUI() }); }
  catch (e) { console.warn("save config failed:", e.message); }
}

function renderNamespaceHistory() {
  const list = $("ns-history");
  list.innerHTML = "";
  for (const ns of state.recentNamespaces) {
    const o = document.createElement("option");
    o.value = ns;
    list.appendChild(o);
  }
}

function pushRecentNamespace(ns) {
  if (!ns) return;
  state.recentNamespaces = [ns, ...state.recentNamespaces.filter((x) => x !== ns)].slice(0, 12);
  renderNamespaceHistory();
}

// ---------- contexts ----------
async function refreshContexts() {
  try {
    const r = await api("/api/contexts");
    const sel = $("ctx-select");
    sel.innerHTML = "";
    (r.contexts || []).forEach((c) => {
      const o = document.createElement("option");
      o.value = c.name; o.textContent = c.name + (c.current ? "  (current)" : "");
      if (c.current) o.selected = true;
      sel.appendChild(o);
    });
    if (!r.contexts || !r.contexts.length) {
      const o = document.createElement("option");
      o.textContent = "(no contexts yet — connect first)";
      o.disabled = true;
      sel.appendChild(o);
    }
  } catch (e) { /* silent */ }
}

// ---------- pods ----------
async function loadPods() {
  const ns = $("ns-input").value.trim();
  if (!ns) { toast("Enter a namespace first.", "err"); return; }
  state.currentNamespace = ns;
  pushRecentNamespace(ns);
  saveConfig();
  $("pods-status").textContent = "Loading…";
  try {
    const r = await api(`/api/pods?namespace=${encodeURIComponent(ns)}`);
    if (Array.isArray(r.pods)) {
      // PowerShell server: already parsed.
      state.pods = r.pods;
    } else if (typeof r.raw === "string" && r.raw) {
      // Bash server: raw `kubectl get pods -o json` output.
      state.pods = parsePodsFromKubectl(r.raw);
    } else {
      state.pods = [];
    }
    $("pods-status").textContent = `${state.pods.length} pod(s) in ${ns} · ${new Date().toLocaleTimeString()}`;
    renderPods();
  } catch (e) {
    $("pods-status").textContent = "";
    toast("Failed to load pods: " + e.message, "err");
  }
}

function parsePodsFromKubectl(raw) {
  let obj;
  try { obj = JSON.parse(raw); } catch { return []; }
  const items = obj?.items || [];
  return items.map((p) => {
    const cstats = p.status?.containerStatuses || [];
    const totalContainers = (p.spec?.containers || []).length || cstats.length;
    const readyCount = cstats.filter((c) => c.ready === true).length;
    const restarts = cstats.reduce((s, c) => s + (c.restartCount || 0), 0);

    let status = p.status?.phase || "Unknown";
    if (p.metadata?.deletionTimestamp) status = "Terminating";
    for (const c of cstats) {
      if (c.state?.waiting?.reason)    { status = c.state.waiting.reason; break; }
      if (c.state?.terminated?.reason) { status = c.state.terminated.reason; break; }
    }
    for (const ic of (p.status?.initContainerStatuses || [])) {
      const r = ic.state?.waiting?.reason;
      if (r && r !== "PodInitializing") { status = `Init:${r}`; break; }
    }

    let age = "";
    if (p.metadata?.creationTimestamp) {
      const ms = Date.now() - new Date(p.metadata.creationTimestamp).getTime();
      const s = Math.floor(ms / 1000);
      if (s < 60) age = `${s}s`;
      else if (s < 3600) age = `${Math.floor(s/60)}m`;
      else if (s < 86400) age = `${Math.floor(s/3600)}h${Math.floor((s%3600)/60)}m`;
      else age = `${Math.floor(s/86400)}d`;
    }

    return {
      name: p.metadata?.name || "",
      ready: `${readyCount}/${totalContainers}`,
      status,
      restarts,
      age,
      node: p.spec?.nodeName || "",
      ip: p.status?.podIP || "",
      containers: (p.spec?.containers || []).map((c) => c.name),
    };
  });
}

function renderPods() {
  const tbody = $("pods-body");
  const f = (state.filter || "").toLowerCase();
  const pods = state.pods.filter((p) => !f || p.name.toLowerCase().includes(f));
  if (!pods.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="8">No pods match.</td></tr>`;
    return;
  }
  tbody.innerHTML = pods.map((p) => {
    const status = p.status || "Unknown";
    const cls = statusClass(status);
    return `
      <tr>
        <td class="name" title="${esc(p.name)}">${esc(p.name)}</td>
        <td>${esc(p.ready || "")}</td>
        <td><span class="pill pill-${cls}">${esc(status)}</span></td>
        <td>${p.restarts ?? 0}</td>
        <td>${esc(p.age || "")}</td>
        <td>${esc(p.node || "")}</td>
        <td>${esc(p.ip || "")}</td>
        <td class="actions">
          <button class="btn btn-ghost" data-act="logs" data-pod="${esc(p.name)}">Logs</button>
          <button class="btn btn-ghost" data-act="describe" data-pod="${esc(p.name)}">Describe</button>
        </td>
      </tr>
    `;
  }).join("");
}

function statusClass(s) {
  if (!s) return "muted";
  const v = s.toLowerCase();
  if (v === "running" || v === "completed" || v === "succeeded") return "ok";
  if (v === "pending" || v === "containercreating" || v === "podinitializing" || v === "init") return "info";
  if (v.includes("backoff") || v.includes("error") || v.includes("failed") || v === "evicted" || v === "oomkilled") return "err";
  if (v === "terminating" || v === "notready") return "warn";
  return "muted";
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}

// ---------- logs modal ----------
async function openLogs(pod) {
  state.currentPod = pod;
  $("logs-title").textContent = `Logs · ${pod}`;
  // populate containers list from pod data
  const sel = $("logs-container");
  sel.innerHTML = `<option value="">(default / first)</option>`;
  const found = state.pods.find((p) => p.name === pod);
  (found?.containers || []).forEach((c) => {
    const o = document.createElement("option");
    o.value = c; o.textContent = c;
    sel.appendChild(o);
  });
  $("logs-output").textContent = "Loading…";
  $("logs-modal").classList.remove("hidden");
  await fetchLogs();
  setupLogsFollow();
}

async function fetchLogs() {
  if (!state.currentPod) return;
  const ns = state.currentNamespace;
  const tail = Math.max(1, parseInt($("logs-tail").value || "200", 10));
  const container = $("logs-container").value;
  const params = new URLSearchParams({ pod: state.currentPod, namespace: ns, tail: String(tail) });
  if (container) params.set("container", container);
  try {
    const r = await api(`/api/logs?${params.toString()}`);
    $("logs-output").textContent = r.logs || "(no output)";
    $("logs-output").scrollTop = $("logs-output").scrollHeight;
  } catch (e) {
    $("logs-output").textContent = "Error: " + e.message;
  }
}

function setupLogsFollow() {
  clearInterval(state.logsTimer);
  state.logsTimer = null;
  if ($("logs-follow").checked) {
    state.logsTimer = setInterval(fetchLogs, 3000);
  }
}

function closeLogs() {
  $("logs-modal").classList.add("hidden");
  clearInterval(state.logsTimer); state.logsTimer = null;
  state.currentPod = null;
}

// ---------- describe modal ----------
async function openDescribe(pod) {
  state.currentPod = pod;
  $("describe-title").textContent = `Describe · ${pod}`;
  $("describe-output").textContent = "Loading…";
  $("describe-modal").classList.remove("hidden");
  await fetchDescribe();
}
async function fetchDescribe() {
  if (!state.currentPod) return;
  const ns = state.currentNamespace;
  try {
    const r = await api(`/api/describe?pod=${encodeURIComponent(state.currentPod)}&namespace=${encodeURIComponent(ns)}`);
    $("describe-output").textContent = r.describe || "(empty)";
  } catch (e) {
    $("describe-output").textContent = "Error: " + e.message;
  }
}
function closeDescribe() {
  $("describe-modal").classList.add("hidden");
  state.currentPod = null;
}

// ---------- auto refresh ----------
function setupAutoRefresh() {
  clearInterval(state.autoTimer); state.autoTimer = null;
  if (!$("auto-refresh").checked) return;
  const sec = Math.max(2, parseInt($("auto-interval").value || "10", 10));
  state.autoTimer = setInterval(loadPods, sec * 1000);
}

// ---------- actions ----------
async function doLogin() {
  $("btn-login").disabled = true;
  toast("Opening gcloud login (a browser window will open from your shell)…");
  try {
    const r = await api("/api/login", { method: "POST" });
    toast(r.ok ? "Login complete." : "Login finished with errors.", r.ok ? "ok" : "err");
  } catch (e) {
    toast("Login failed: " + e.message, "err");
  } finally {
    $("btn-login").disabled = false;
    refreshHealth();
  }
}

async function doConnect() {
  const body = { project: $("cfg-project").value.trim(), cluster: $("cfg-cluster").value.trim(), region: $("cfg-region").value.trim() };
  if (!body.project || !body.cluster || !body.region) { toast("Fill project, cluster, and region.", "err"); return; }
  $("btn-connect").disabled = true;
  toast("Connecting to cluster…");
  try {
    const r = await api("/api/connect", { body });
    toast(r.ok ? "Connected." : "Connect finished with errors.", r.ok ? "ok" : "err");
    await saveConfig();
    await refreshContexts();
  } catch (e) {
    toast("Connect failed: " + e.message, "err");
  } finally {
    $("btn-connect").disabled = false;
  }
}

async function doInstall() {
  $("btn-install").disabled = true;
  toast("Running installer placeholder…");
  try {
    const r = await api("/api/install", { body: { tool: "all" } });
    toast(r.ok ? "Installer completed." : "Installer reported errors. See README.", r.ok ? "ok" : "err");
  } catch (e) {
    toast("Installer failed: " + e.message, "err");
  } finally {
    $("btn-install").disabled = false;
    refreshHealth();
  }
}

async function switchContext() {
  const name = $("ctx-select").value;
  if (!name) return;
  try {
    await api("/api/context", { body: { name } });
    toast("Context switched: " + name, "ok");
  } catch (e) {
    toast("Switch failed: " + e.message, "err");
  }
}

// ---------- wire up ----------
function copyText(text) {
  if (!navigator.clipboard) { toast("Clipboard not available", "err"); return; }
  navigator.clipboard.writeText(text).then(
    () => toast("Copied.", "ok"),
    () => toast("Copy failed.", "err"),
  );
}

function bindEvents() {
  $("btn-login").addEventListener("click", doLogin);
  $("btn-connect").addEventListener("click", doConnect);
  $("btn-install").addEventListener("click", doInstall);
  $("btn-load").addEventListener("click", loadPods);
  $("btn-ctx-refresh").addEventListener("click", refreshContexts);
  $("ctx-select").addEventListener("change", switchContext);

  $("filter").addEventListener("input", (e) => { state.filter = e.target.value; renderPods(); });
  $("auto-refresh").addEventListener("change", setupAutoRefresh);
  $("auto-interval").addEventListener("change", setupAutoRefresh);

  $("ns-input").addEventListener("change", () => { state.currentNamespace = $("ns-input").value.trim(); saveConfig(); });

  // delegated pod actions
  $("pods-body").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    const pod = b.getAttribute("data-pod");
    const act = b.getAttribute("data-act");
    if (act === "logs") openLogs(pod);
    if (act === "describe") openDescribe(pod);
  });

  // logs modal
  $("btn-logs-refresh").addEventListener("click", fetchLogs);
  $("logs-follow").addEventListener("change", setupLogsFollow);
  $("logs-tail").addEventListener("change", fetchLogs);
  $("logs-container").addEventListener("change", fetchLogs);
  $("btn-logs-copy").addEventListener("click", () => copyText($("logs-output").textContent));

  // describe modal
  $("btn-describe-refresh").addEventListener("click", fetchDescribe);
  $("btn-describe-copy").addEventListener("click", () => copyText($("describe-output").textContent));

  // close buttons on modals
  qsa("[data-close]").forEach((b) => b.addEventListener("click", () => {
    closeLogs(); closeDescribe();
  }));
  // click outside modal box closes
  qsa(".modal").forEach((m) => m.addEventListener("click", (e) => {
    if (e.target === m) { closeLogs(); closeDescribe(); }
  }));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeLogs(); closeDescribe(); }
  });
}

// ---------- boot ----------
(async function boot() {
  bindEvents();
  await loadConfig();
  await refreshHealth();
  await refreshContexts();
})();
