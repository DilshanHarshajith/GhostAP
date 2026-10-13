"use strict";

const $ = (id) => document.getElementById(id);
const qs = (sel, root = document) => root.querySelector(sel);
const qsa = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function esc(value) {
  return String(value === null || value === undefined ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

let INTERFACES = { wireless: [], ethernet: [], all: [] };
let STATUS = { running: false, stopping: false };
let logSource = null;

/* ------------------------------------------------------------------ utils */

function toast(msg, ms = 3500) {
  const el = $("toast");
  el.textContent = msg || "";
  if (msg) {
    clearTimeout(toast._t);
    toast._t = setTimeout(() => { el.textContent = ""; }, ms);
  }
}

async function api(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  let data = {};
  try { data = await res.json(); } catch (e) { /* ignore */ }
  if (!res.ok) {
    const err = data.error || (data.errors && data.errors.join(" ")) || `HTTP ${res.status}`;
    throw new Error(err);
  }
  return data;
}

function fmtBytes(b) {
  b = Number(b) || 0;
  const units = ["B", "K", "M", "G", "T"];
  let i = 0;
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
  return `${Math.round(b)}${units[i]}`;
}

function fmtTime(secs) {
  if (secs === null || secs === undefined) return "N/A";
  secs = Number(secs);
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = Math.floor(secs % 60);
  return [h, m, s].map((n) => String(n).padStart(2, "0")).join(":");
}

function setTab(name) {
  qsa(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === name));
  qsa(".tab-body").forEach((b) => { b.hidden = b.id !== `tab-${name}`; });
}

/* ------------------------------------------------------------- config I/O */

function currentMode() {
  return qs('input[name="mode"]:checked').value;
}

function collectConfig() {
  return {
    ethernet_mode: currentMode() === "ethernet",
    interface: $("interface").value,
    source_interface: $("source-interface").value,
    ssid: $("ssid").value.trim(),
    channel: $("channel").value.trim(),
    security: $("security").value,
    password: $("password").value,
    subnet: $("subnet").value.trim(),
    dns: $("dns").value.trim(),
    mac: $("mac").value.trim(),
    internet: $("internet").checked,
    capture: $("capture").checked,
    capture_file: $("capture-file").value.trim(),
    clone: $("clone").checked,
    clone_ssid: $("clone-ssid").value.trim(),
    spoof: $("spoof").checked,
    spoof_domains: $("spoof-domains").value.trim(),
    spoof_target: $("spoof-target").value.trim(),
    block_doh: $("block-doh").checked,
    proxy: $("proxy").checked,
    proxy_mode: $("proxy-mode").value,
    proxy_host: $("proxy-host").value.trim(),
    proxy_port: $("proxy-port").value.trim(),
    proxy_type: $("proxy-type").value,
    proxy_user: $("proxy-user").value.trim(),
    proxy_pass: $("proxy-pass").value,
    vpn: $("vpn").checked,
    vpn_config: $("vpn-config").value.trim(),
    vpn_interface: $("vpn-interface").value.trim(),
    vpn_creds: $("vpn-creds").value.trim(),
    captive: $("captive").checked,
    captive_port: $("captive-port").value.trim(),
    captive_template: $("captive-template").value.trim(),
  };
}

function applyConfig(cfg) {
  if (!cfg) return;
  qs(`input[name="mode"][value="${cfg.ethernet_mode ? "ethernet" : "wifi"}"]`).checked = true;
  $("interface").value = cfg.interface || "";
  $("source-interface").value = cfg.source_interface || "";
  $("ssid").value = cfg.ssid || "";
  $("channel").value = cfg.channel || "";
  $("security").value = cfg.security || "open";
  $("password").value = cfg.password || "";
  $("subnet").value = cfg.subnet || "";
  $("dns").value = cfg.dns || "";
  $("mac").value = cfg.mac || "";
  $("internet").checked = !!cfg.internet;
  $("capture").checked = !!cfg.capture;
  $("capture-file").value = cfg.capture_file || "";
  $("clone").checked = !!cfg.clone;
  $("clone-ssid").value = cfg.clone_ssid || "";
  $("spoof").checked = !!cfg.spoof;
  $("spoof-domains").value = cfg.spoof_domains || "";
  $("spoof-target").value = cfg.spoof_target || "";
  $("block-doh").checked = !!cfg.block_doh;
  $("proxy").checked = !!cfg.proxy;
  $("proxy-mode").value = cfg.proxy_mode || "TRANSPARENT_LOCAL";
  $("proxy-host").value = cfg.proxy_host || "";
  $("proxy-port").value = cfg.proxy_port || "8080";
  $("proxy-type").value = cfg.proxy_type || "http";
  $("proxy-user").value = cfg.proxy_user || "";
  $("proxy-pass").value = cfg.proxy_pass || "";
  $("vpn").checked = !!cfg.vpn;
  $("vpn-config").value = cfg.vpn_config || "";
  $("vpn-interface").value = cfg.vpn_interface || "";
  $("vpn-creds").value = cfg.vpn_creds || "";
  $("captive").checked = !!cfg.captive;
  $("captive-port").value = cfg.captive_port || "8880";
  $("captive-template").value = cfg.captive_template || "";
  applyMode();
  $("password-wrap").hidden = $("security").value === "open";
  qsa("fieldset.feature").forEach((fs) => {
    const box = qs("input[type=checkbox]", fs);
    fs.classList.toggle("off", !(box && box.checked));
  });
  updatePreview();
}

/* ------------------------------------------------------------- interfaces */

function fillSelect(select, items, placeholder) {
  const prev = select.value;
  select.innerHTML = "";
  const opt0 = document.createElement("option");
  opt0.value = "";
  opt0.textContent = placeholder;
  select.appendChild(opt0);
  items.forEach((name) => {
    const o = document.createElement("option");
    o.value = name;
    o.textContent = name;
    select.appendChild(o);
  });
  if (prev && items.includes(prev)) select.value = prev;
}

function refreshInterfaceSelects() {
  const eth = currentMode() === "ethernet";
  const mainList = eth ? INTERFACES.ethernet : INTERFACES.wireless;
  fillSelect($("interface"), mainList, mainList.length ? "— select —" : "— none found —");
  fillSelect($("source-interface"), INTERFACES.all, "— none —");
  fillSelect($("scan-interface"), INTERFACES.wireless, "— select —");
}

async function loadInterfaces() {
  try {
    INTERFACES = await api("GET", "/api/interfaces");
  } catch (e) {
    toast("Failed to list interfaces");
  }
  refreshInterfaceSelects();
}

/* ---------------------------------------------------------- feature toggles */

function applyMode() {
  const eth = currentMode() === "ethernet";
  $("wifi-group").hidden = eth;
  $("feature-clone").hidden = eth;
  if (eth && $("clone").checked) $("clone").checked = false;
  refreshInterfaceSelects();
}

function bindToggles() {
  qsa('input[name="mode"]').forEach((r) => r.addEventListener("change", () => { applyMode(); updatePreview(); }));
  qsa("fieldset.feature").forEach((fs) => {
    const box = qs("input[type=checkbox]", fs);
    if (box) box.addEventListener("change", () => fs.classList.toggle("off", !box.checked));
  });
  $("security").addEventListener("change", () => {
    $("password-wrap").hidden = $("security").value === "open";
  });
  $("internet").addEventListener("change", () => {
    $("source-wrap").style.opacity = $("internet").checked ? "1" : "0.75";
  });
}

/* ------------------------------------------------------------- preview cmd */

function buildArgsPreview(cfg) {
  const a = [];
  if (cfg.ethernet_mode) a.push("--eth-ap");
  if (cfg.interface) a.push("-i", cfg.interface);
  if (cfg.clone) {
    a.push("--clone");
    if (cfg.clone_ssid) a.push(cfg.clone_ssid);
    if (cfg.password) a.push("--password", "******");
  } else {
    if (cfg.ssid) a.push("-s", cfg.ssid);
    if (cfg.channel) a.push("-c", cfg.channel);
    if (cfg.security) a.push("--security", cfg.security);
    if (cfg.security !== "open" && cfg.password) a.push("--password", "******");
  }
  if (cfg.subnet) a.push("--subnet", cfg.subnet);
  if (cfg.dns) a.push("--dns", cfg.dns);
  if (cfg.mac && !cfg.ethernet_mode && !cfg.clone) a.push("-m", cfg.mac);
  if (cfg.internet || cfg.source_interface) {
    if (cfg.source_interface) a.push("-si", cfg.source_interface);
    else a.push("--internet");
  }
  if (cfg.capture) { a.push("--capture"); if (cfg.capture_file) a.push(cfg.capture_file); }
  if (cfg.spoof) {
    a.push("--spoof");
    if (cfg.spoof_domains) a.push(cfg.spoof_domains);
    if (cfg.spoof_target) a.push("--spoof-target", cfg.spoof_target);
    if (cfg.block_doh) a.push("--block-doh");
  }
  if (cfg.proxy) {
    a.push(cfg.proxy_mode === "TRANSPARENT_LOCAL" ? "--local-proxy"
      : cfg.proxy_mode === "REMOTE_DNAT" ? "--remote-proxy" : "--proxy");
    if (cfg.proxy_host) a.push("--proxy-host", cfg.proxy_host);
    if (cfg.proxy_port) a.push("--proxy-port", cfg.proxy_port);
    if (cfg.proxy_type) a.push("--proxy-type", cfg.proxy_type);
    if (cfg.proxy_user) a.push("--proxy-user", cfg.proxy_user);
  }
  if (cfg.vpn) {
    if (cfg.vpn_interface) a.push("--vpn-interface", cfg.vpn_interface);
    else { a.push("--vpn"); if (cfg.vpn_config) a.push(cfg.vpn_config); }
    if (cfg.vpn_creds) a.push("--vpn-creds", "******");
  }
  if (cfg.captive) {
    a.push("--captive");
    if (cfg.captive_port) a.push("--captive-port", cfg.captive_port);
    if (cfg.captive_template) a.push("--captive-template", cfg.captive_template);
  }
  return a;
}

function updatePreview() {
  const args = buildArgsPreview(collectConfig());
  $("cmd-preview").textContent = "sudo bash GhostAP.sh " + args.join(" ");
}

/* ------------------------------------------------------------------- start */

async function startAP() {
  const cfg = collectConfig();
  setTab("log");
  toast("Starting…");
  try {
    const res = await api("POST", "/api/start", cfg);
    toast(res.message || "Started");
    await refreshStatus();
  } catch (e) {
    toast(e.message);
  }
}

async function stopAP() {
  toast("Stopping…");
  try {
    const res = await api("POST", "/api/stop");
    toast(res.message || "Stopping");
    await refreshStatus();
  } catch (e) {
    toast(e.message);
  }
}

/* ------------------------------------------------------------------ status */

function renderStatus() {
  const dot = $("status-dot");
  const text = $("status-text");
  const meta = $("status-meta");
  dot.classList.remove("on", "pending");
  if (STATUS.stopping) {
    dot.classList.add("pending");
    text.textContent = "Stopping";
  } else if (STATUS.running) {
    dot.classList.add("on");
    text.textContent = "Running";
  } else {
    text.textContent = "Idle";
  }
  if (STATUS.running && STATUS.pid) {
    meta.textContent = `pid ${STATUS.pid} · up ${fmtTime(STATUS.uptime)}`;
  } else {
    meta.textContent = STATUS.use_sudo ? "sudo -n" : "";
  }
  $("btn-start").disabled = STATUS.running || STATUS.stopping;
  $("btn-stop").disabled = !STATUS.running || STATUS.stopping;
}

async function refreshStatus() {
  try {
    STATUS = await api("GET", "/api/status");
  } catch (e) { /* keep last */ }
  renderStatus();
}

/* -------------------------------------------------------------------- logs */

function appendLog(line) {
  const log = $("log");
  const span = document.createElement("div");
  if (line.startsWith("[gui]")) span.className = "l-gui";
  else if (/ERROR|WARNING|error|failed/i.test(line)) span.className = "l-err";
  span.textContent = line;
  log.appendChild(span);
  while (log.childElementCount > 4000) log.removeChild(log.firstChild);
  if ($("autoscroll").checked) log.scrollTop = log.scrollHeight;
}

function connectLogs() {
  if (logSource) logSource.close();
  logSource = new EventSource("/api/logs");
  logSource.onopen = () => { $("log-state").textContent = "connected"; };
  logSource.onerror = () => { $("log-state").textContent = "reconnecting…"; };
  logSource.onmessage = (ev) => appendLog(ev.data);
}

/* ----------------------------------------------------------------- clients */

function renderClients(clients) {
  const body = $("clients-body");
  body.innerHTML = "";
  if (!clients.length) {
    body.innerHTML = '<tr><td colspan="7" class="empty">No clients connected.</td></tr>';
    return;
  }
  clients.forEach((c) => {
    const tr = document.createElement("tr");
    const sig = c.signal === null || c.signal === undefined ? "N/A" : `${c.signal} dBm`;
    tr.innerHTML = `
      <td>${esc(c.mac)}</td>
      <td>${esc(c.ip || "N/A")}</td>
      <td>${esc(c.hostname || "Unknown")}</td>
      <td>${esc(sig)}</td>
      <td>${fmtTime(c.connected)}</td>
      <td>${fmtBytes(c.rx)} / ${fmtBytes(c.tx)}</td>
      <td><span class="badge ${c.status === "Online" ? "on" : ""}">${esc(c.status)}</span></td>`;
    body.appendChild(tr);
  });
}

async function refreshClients() {
  try {
    const res = await api("GET", "/api/clients");
    renderClients(res.clients || []);
    $("clients-meta").textContent = res.interface ? `iface ${res.interface}` : "—";
  } catch (e) {
    $("clients-meta").textContent = "unavailable";
  }
}

/* -------------------------------------------------------------------- scan */

function renderScan(aps) {
  const body = $("scan-body");
  body.innerHTML = "";
  if (!aps.length) {
    body.innerHTML = '<tr><td colspan="6" class="empty">No access points found.</td></tr>';
    return;
  }
  aps.forEach((ap) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${esc(ap.bssid)}</td>
      <td>${esc(ap.ssid)}</td>
      <td>${esc(ap.channel)}</td>
      <td>${esc(ap.security)}</td>
      <td>${esc(ap.signal)}</td>
      <td><span class="tag" data-ssid="${encodeURIComponent(ap.ssid)}" data-ch="${esc(ap.channel)}" data-sec="${esc(ap.security)}">Clone</span></td>`;
    body.appendChild(tr);
  });
  qsa(".tag", body).forEach((el) => el.addEventListener("click", () => {
    $("clone").checked = true;
    $("clone").dispatchEvent(new Event("change"));
    $("clone-ssid").value = decodeURIComponent(el.dataset.ssid);
    if (el.dataset.sec) $("security").value = el.dataset.sec;
    if (el.dataset.ch) $("channel").value = el.dataset.ch;
    $("password-wrap").hidden = $("security").value === "open";
    qs('input[name="mode"][value="wifi"]').checked = true;
    applyMode();
    updatePreview();
    toast(`Clone target set: ${decodeURIComponent(el.dataset.ssid)}`);
  }));
}

async function runScan() {
  const iface = $("scan-interface").value;
  const duration = parseInt($("scan-duration").value, 10) || 15;
  if (!iface) { toast("Select a wireless interface first"); return; }
  $("btn-scan").disabled = true;
  $("scan-meta").textContent = `scanning ${duration}s…`;
  try {
    const res = await api("POST", "/api/scan", { interface: iface, duration });
    renderScan(res.access_points || []);
    $("scan-meta").textContent = `${(res.access_points || []).length} AP(s) in ${res.duration}s`;
  } catch (e) {
    $("scan-meta").textContent = "failed";
    toast(e.message);
  } finally {
    $("btn-scan").disabled = false;
  }
}

/* ------------------------------------------------------------------ setups */

async function refreshSetups(selectName) {
  try {
    const res = await api("GET", "/api/setups");
    const sel = $("setup-select");
    const prev = selectName || sel.value;
    sel.innerHTML = '<option value="">— none —</option>';
    (res.setups || []).forEach((name) => {
      const o = document.createElement("option");
      o.value = name;
      o.textContent = name;
      sel.appendChild(o);
    });
    if (prev) sel.value = prev;
  } catch (e) { /* ignore */ }
}

async function loadSetup() {
  const name = $("setup-select").value;
  if (!name) { toast("Select a setup"); return; }
  try {
    const res = await api("GET", `/api/setups/${encodeURIComponent(name)}`);
    applyConfig(res.config);
    toast(`Loaded '${name}'`);
  } catch (e) { toast(e.message); }
}

async function saveSetup() {
  let name = $("setup-select").value;
  name = window.prompt("Setup name:", name || "my-setup");
  if (!name) return;
  try {
    const res = await api("POST", `/api/setups/${encodeURIComponent(name)}`, collectConfig());
    await refreshSetups(res.name);
    $("setup-select").value = res.name;
    toast(`Saved '${res.name}'`);
  } catch (e) { toast(e.message); }
}

async function deleteSetup() {
  const name = $("setup-select").value;
  if (!name) { toast("Select a setup"); return; }
  if (!window.confirm(`Delete setup '${name}'?`)) return;
  try {
    await api("DELETE", `/api/setups/${encodeURIComponent(name)}`);
    await refreshSetups();
    toast(`Deleted '${name}'`);
  } catch (e) { toast(e.message); }
}

/* ------------------------------------------------------------------- wiring */

function bindEvents() {
  $("btn-start").addEventListener("click", startAP);
  $("btn-stop").addEventListener("click", stopAP);
  qsa(".tab").forEach((t) => t.addEventListener("click", () => {
    setTab(t.dataset.tab);
    if (t.dataset.tab === "clients") refreshClients();
  }));
  $("btn-clear-log").addEventListener("click", () => { $("log").innerHTML = ""; });
  $("btn-refresh-clients").addEventListener("click", refreshClients);
  $("btn-scan").addEventListener("click", runScan);
  $("btn-load").addEventListener("click", loadSetup);
  $("btn-save").addEventListener("click", saveSetup);
  $("btn-delete").addEventListener("click", deleteSetup);

  const previewFields = qsa(".config-panel input, .config-panel select");
  previewFields.forEach((el) => {
    el.addEventListener("change", updatePreview);
    el.addEventListener("input", updatePreview);
  });
}

async function init() {
  bindEvents();
  bindToggles();
  applyMode();
  $("security").dispatchEvent(new Event("change"));
  await loadInterfaces();
  updatePreview();
  await refreshStatus();
  await refreshSetups();
  connectLogs();
  refreshClients();
  setInterval(refreshStatus, 2000);
  setInterval(() => { if (STATUS.running) refreshClients(); }, 3000);
}

document.addEventListener("DOMContentLoaded", init);
