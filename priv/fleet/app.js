// Fleet view. Runs two ways with the same state ({fleet, endpoints, updated} from `ww fleet`):
// standalone at /fleet#endpoint=..&token=..&fleet=.. (its own socket, fleet.state.v1), or
// published into a canvas (state arrives as canvas.data.v1 via the "waterworks" event, and page
// actions go through the canvas host so an agent can take comments on it).
let endpoints = [];
let updated = "waiting for data";
let fleetId = null;
let broadcasts = []; // this fleet's recent broadcasts (in memory on the fleet), newest first
let tab = "endpoints";
let socket = null;

// The fleet sends UTC; show it in this machine's time zone, e.g. "updated Nov 23, 6:10:18 PM PST".
function localTime(iso) {
  const t = new Date(iso);
  if (!iso || isNaN(t)) return "live";
  // dateStyle/timeStyle cannot be combined with timeZoneName (throws "Invalid option").
  const format = { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit", timeZoneName: "short" };
  return t.toLocaleString(undefined, format);
}

function apply(state) {
  if (!Array.isArray(state?.endpoints)) return;
  pending.delete("remove_offline");
  endpoints = state.endpoints;
  updated = `updated ${localTime(state.updated)}`;
  if (!socket) fleetId = state.fleet || fleetId; // standalone: the fleet id comes from the URL only
  broadcasts = Array.isArray(state.broadcasts) ? state.broadcasts : broadcasts;
  // Keep an open receipts modal current from the broadcast history.
  const open = broadcasts.find((b) => b.broadcast === receipt);
  if (open && $("receipts").open) showReceipts(open);
  render();
}

// action is "remove" (offline), "disconnect" or "shutdown" (online); the fleet re-checks all of it.
function requestAction(action, id) {
  if (socket) {
    socket.send(JSON.stringify({ op: "send", to: fleetId, type: `fleet.${action}.v1`, payload: { id } }));
  } else {
    window.waterworks?.action({ to: fleetId, action, id });
  }
}

const cols = ["name", "kind", "type", "status", "id"];
const filters = { kind: new Set(), type: new Set(), status: new Set() };  // empty = all
let sort = { col: "status", dir: -1 };                    // online first

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children.filter((c) => c != null));
  return node;
};

function stats() {
  const count = (f) => endpoints.filter(f).length;
  const items = [
    ["Registered", endpoints.length, "#19e76e"], ["Online", count((e) => e.status === "online"), "#0e863f"],
    ["Agents", count((e) => e.kind === "agent"), "#1960d3"], ["Tools", count((e) => e.kind === "tool"), "#ffa9fd"],
  ];
  $("stats").replaceChildren(...items.map(([label, value, c]) => {
    const s = el("div", { className: "stat" });
    s.style.setProperty("--c", c);
    s.append(el("div", { className: "label" }, label), el("div", { className: "value" }, value));
    return s;
  }));
}

function chips() {
  for (const group of document.querySelectorAll("[data-filter]")) {
    const key = group.dataset.filter;
    const values = [...new Set(endpoints.map((e) => e[key]))].sort();
    group.querySelectorAll("button").forEach((b) => b.remove());
    for (const v of values) {
      const b = el("button", { className: "chip", type: "button" }, `${v} (${endpoints.filter((e) => e[key] === v).length})`);
      b.setAttribute("aria-pressed", filters[key].has(v));
      b.onclick = () => { filters[key].has(v) ? filters[key].delete(v) : filters[key].add(v); render(); };
      group.append(b);
    }
  }
}

// Offline rows: Remove. Online rows: Shut down (asks the endpoint to stop via core.shutdown.v1)
// and Disconnect (deregisters it now). The first click arms, the second (within 3 s) sends.
const ACTIONS = { remove: ["Remove", "Removing…"], shutdown: ["Shut down", "Asked to stop"], disconnect: ["Disconnect", "Disconnecting…"] };
const pending = new Set();
function actionButton(e, action) {
  const [label, busy] = ACTIONS[action];
  const key = `${action}:${e.id}`;
  const b = el("button", { className: "remove", type: "button" }, pending.has(key) ? busy : label);
  b.disabled = pending.has(key);
  b.setAttribute("aria-label", `${label} ${e.name}`);
  b.onclick = () => {
    if (!b.classList.contains("armed")) {
      b.classList.add("armed"); b.textContent = `Confirm ${label.toLowerCase()}`;
      setTimeout(() => { if (b.isConnected && !b.disabled) { b.classList.remove("armed"); b.textContent = label; } }, 3000);
      return;
    }
    pending.add(key);
    requestAction(action, e.id);
    render();
  };
  return b;
}

function actions(e) {
  const cell = el("td", { className: "actions" });
  // The fleet can be shut down from its own view, but not disconnected or removed.
  const list = e.status === "offline" ? ["remove"] : e.id === fleetId ? ["shutdown"] : ["shutdown", "disconnect"];
  cell.append(...list.map((action) => actionButton(e, action)));
  return cell;
}

// Toolbar: remove every offline endpoint at once (two clicks, like the row buttons). The fleet
// keeps its current subscribers, such as this view.
function removeOfflineButton() {
  const b = $("remove-offline");
  // Subscribers (e.g. this fleet's viewer) are kept, so they are not counted.
  const count = endpoints.filter((e) => e.status === "offline" && !e.kept).length;
  b.hidden = count === 0 || tab !== "endpoints";
  if (b.classList.contains("armed")) return;
  b.disabled = pending.has("remove_offline");
  b.textContent = b.disabled ? "Removing offline…" : `Remove all offline (${count})`;
  b.onclick = () => {
    if (!b.classList.contains("armed")) {
      b.classList.add("armed"); b.textContent = `Confirm: remove ${count} offline`;
      setTimeout(() => { if (!b.disabled) { b.classList.remove("armed"); removeOfflineButton(); } }, 3000);
      return;
    }
    b.classList.remove("armed");
    pending.add("remove_offline");
    requestAction("remove_offline", null);
    render();
  };
}

// Broadcast: online agents can be selected; the message goes to each as agent.prompt.v1, and
// the fleet reports receipts that fill the modal as sessions acknowledge (fleet.broadcast_status.v1
// standalone, canvas.data.v1 {broadcast_status} inside a canvas).
const selected = new Set();
const canBroadcast = () => Boolean(socket || window.waterworks);
const selectable = (e) => e.kind === "agent" && e.status === "online";

function pickCell(e) {
  const td = el("td", { className: "pick" });
  if (canBroadcast() && selectable(e)) {
    const box = el("input", { type: "checkbox", checked: selected.has(e.id) });
    box.setAttribute("aria-label", `Select ${e.name}`);
    box.onchange = () => { box.checked ? selected.add(e.id) : selected.delete(e.id); render(); };
    td.append(box);
  }
  return td;
}

function pickAllCell() {
  const th = el("th", { className: "pick", scope: "col" });
  const live = endpoints.filter(selectable);
  if (canBroadcast() && live.length) {
    const box = el("input", { type: "checkbox", checked: live.every((e) => selected.has(e.id)) });
    box.setAttribute("aria-label", "Select all online agents");
    box.onchange = () => { live.forEach((e) => (box.checked ? selected.add(e.id) : selected.delete(e.id))); render(); };
    th.append(box);
  }
  return th;
}

function composer() {
  // Drop selections that went offline or were removed.
  for (const id of selected) if (!endpoints.some((e) => e.id === id && selectable(e))) selected.delete(id);
  $("broadcast-open").hidden = !canBroadcast() || selected.size === 0 || tab !== "endpoints";
  $("broadcast-open").textContent = `Broadcast to ${selected.size}`;
}

const plural = (n) => `${n} session${n === 1 ? "" : "s"}`;
$("broadcast-open").onclick = () => {
  const names = endpoints.filter((e) => selected.has(e.id));
  $("compose-title").textContent = `Broadcast to ${plural(names.length)}`;
  $("recipients").replaceChildren(...names.map((e) => el("span", { className: "chip" }, e.name)));
  $("compose").showModal();
  $("broadcast-text").focus();
};
$("broadcast-cancel").onclick = () => $("compose").close();

let receipt = null; // id of the broadcast shown in the modal
$("broadcast-send").onclick = () => {
  const text = $("broadcast-text").value.trim();
  if (!text || !selected.size || !canBroadcast()) return;
  receipt = `msg_${crypto.randomUUID()}`;
  const names = endpoints.filter((e) => selected.has(e.id));
  const request = { ids: [...selected], text, broadcast: receipt };
  if (socket) {
    socket.send(JSON.stringify({ op: "send", id: receipt, to: fleetId, type: "fleet.broadcast.v1", payload: request }));
  } else {
    window.waterworks.action({ to: fleetId, action: "broadcast", ...request });
  }
  $("compose").close();
  showReceipts({ broadcast: receipt, text, sessions: names.map((e) => ({ id: e.id, name: e.name, status: "sending" })) });
  $("broadcast-text").value = "";
  selected.clear();
  render();
};
$("broadcast-clear").onclick = () => { selected.clear(); $("compose").close(); render(); };
$("broadcast-text").onkeydown = (ev) => { if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) $("broadcast-send").click(); };
$("receipts-close").onclick = () => $("receipts").close();

function showReceipts(status) {
  if (status.broadcast !== receipt) return;
  const acked = status.sessions.filter((s) => s.status === "acked").length;
  $("receipts-text").textContent = status.text;
  $("receipts-tally").textContent = `${acked} of ${status.sessions.length} acknowledged`;
  $("receipts-list").replaceChildren(...status.sessions.map((s) => {
    const li = el("li");
    const cls = s.status === "sending" ? "pending" : s.status;
    li.append(el("span", {}, s.name), el("span", { className: `badge ${cls}` }, STATUS[s.status] || s.status));
    return li;
  }));
  if (!$("receipts").open) $("receipts").showModal();
}

const STATUS = { sending: "sending…", pending: "waiting", acked: "received ✓", failed: "failed" };

function renderBroadcasts() {
  const list = $("broadcasts");
  if (!broadcasts.length) return list.replaceChildren(el("div", { className: "empty" }, "No broadcasts yet (they are kept until the fleet restarts)"));
  list.replaceChildren(...broadcasts.map((b) => {
    const acked = b.sessions.filter((s) => s.status === "acked").length;
    const item = el("div", { className: "bc", tabIndex: 0 });
    item.setAttribute("role", "button");
    item.setAttribute("aria-label", `Receipts for: ${b.text.slice(0, 60)}`);
    const meta = el("div", { className: "meta" });
    meta.append(el("span", {}, localTime(b.sent_at)), el("span", {}, `${acked} of ${b.sessions.length} acknowledged`));
    const who = el("div", { className: "who" });
    who.append(...b.sessions.map((s) => el("span", { className: `badge ${s.status}` }, `${s.name} · ${STATUS[s.status] || s.status}`)));
    item.append(meta, el("div", { className: "text" }, b.text), who);
    item.onclick = item.onkeydown = (ev) => {
      if (ev.type === "keydown" && ev.key !== "Enter") return;
      receipt = b.broadcast;
      showReceipts(b);
    };
    return item;
  }));
}

for (const name of ["endpoints", "broadcasts"]) {
  $(`tab-${name}`).onclick = () => { tab = name; render(); };
}

function render() {
  for (const name of ["endpoints", "broadcasts"]) $(`tab-${name}`).setAttribute("aria-selected", tab === name);
  $("tab-broadcasts").replaceChildren("Broadcasts", ...(broadcasts.length ? [el("span", { className: "count" }, broadcasts.length)] : []));
  document.querySelectorAll(".ep-only").forEach((n) => (n.hidden = tab !== "endpoints"));
  $("endpoints-table").hidden = tab !== "endpoints";
  $("broadcasts").hidden = tab !== "broadcasts";
  renderBroadcasts();
  stats(); chips(); removeOfflineButton(); composer();
  $("updated").textContent = updated;
  $("head").replaceChildren(pickAllCell(), ...cols.map((c) => {
    const th = el("th", { scope: "col", tabIndex: 0 }, c);
    if (sort.col === c) th.setAttribute("aria-sort", sort.dir > 0 ? "ascending" : "descending");
    th.onclick = th.onkeydown = (ev) => {
      if (ev.type === "keydown" && ev.key !== "Enter") return;
      sort = { col: c, dir: sort.col === c ? -sort.dir : 1 }; render();
    };
    return th;
  }), el("th", { scope: "col" }, ""));
  const q = $("q").value.toLowerCase();
  const rows = endpoints
    .filter((e) => Object.entries(filters).every(([k, set]) => !set.size || set.has(e[k])))
    .filter((e) => !q || [e.name, e.id].some((v) => v.toLowerCase().includes(q)))
    .sort((a, b) => sort.dir * a[sort.col].localeCompare(b[sort.col]) || a.name.localeCompare(b.name));
  $("rows").replaceChildren(...(rows.length ? rows.map((e) => {
    const tr = el("tr");
    tr.append(
      pickCell(e),
      el("td", {}, e.name),
      el("td", {}, el("span", { className: `badge ${e.kind}` }, e.kind)),
      el("td", { className: "mono" }, e.type),
      el("td", {}, el("span", { className: `badge ${e.status}` }, e.status)),
      el("td", { className: "mono" }, e.id),
      actions(e),
    );
    return tr;
  }) : [el("tr", {}, el("td", { className: "empty", colSpan: 7 }, "No endpoints match"))]));
}

// Theme: follows the OS until toggled; storage may be blocked in the sandboxed frame.
const stored = (() => { try { return localStorage.getItem("ww-fleet-theme"); } catch { return null; } })();
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  $("theme").textContent = theme === "dark" ? "☀ Light mode" : "☾ Dark mode";
}
setTheme(stored || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
$("theme").onclick = () => {
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  setTheme(next);
  try { localStorage.setItem("ww-fleet-theme", next); } catch {}
};

$("q").oninput = render;
// Messages from the fleet, standalone or (in a canvas) unwrapped from canvas.data.v1 {reply}.
function receive(type, payload) {
  if (type === "fleet.state.v1") apply(payload);
  if (type === "fleet.broadcast_status.v1") showReceipts(payload);
}

// In a canvas: state as canvas.data.v1; other messages (receipts, errors) as {reply: {type, payload}}.
addEventListener("waterworks", (e) => (e.detail?.reply ? receive(e.detail.reply.type, e.detail.reply.payload) : apply(e.detail)));

// Standalone: the URL fragment (never sent to the server) carries this viewer's credentials.
const params = new URLSearchParams(location.hash.slice(1));
if (params.get("endpoint") && params.get("token")) {
  fleetId = params.get("fleet");
  let stopped = false;
  const stop = (reason) => {
    stopped = true;
    socket?.close();
    updated = `${reason}; restart \`ww fleet\` to reopen`;
    render();
  };
  const connect = () => {
    const url = `${location.origin.replace(/^http/, "ws")}/v1/endpoints/${params.get("endpoint")}/socket`;
    const ws = new WebSocket(url, ["ww", `ww-token.${params.get("token")}`]);
    ws.onopen = () => {
      socket = ws;
      // Re-subscribing after a reconnect makes the fleet send its current state.
      ws.send(JSON.stringify({ op: "send", to: fleetId, type: "fleet.subscribe.v1", payload: {} }));
    };
    ws.onmessage = ({ data }) => {
      const frame = JSON.parse(data);
      if (frame.op !== "message") return;
      ws.send(JSON.stringify({ op: "ack", id: frame.message.id }));
      // Anyone can message this view's endpoint; only the fleet it belongs to is trusted.
      if (frame.message.from !== fleetId) return;
      if (frame.message.type === "core.shutdown.v1") return stop("shut down");
      receive(frame.message.type, frame.message.payload);
    };
    ws.onclose = (event) => {
      socket = null;
      if (stopped) return;
      if (event.reason === "deregistered") return stop("this view was disconnected");
      updated = "disconnected; retrying";
      render();
      setTimeout(connect, 2000);
    };
  };
  connect();
}
render();
