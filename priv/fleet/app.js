// Fleet view. Runs two ways with the same state ({fleet, endpoints, updated} from `ww fleet`):
// standalone at /fleet#endpoint=..&token=..&fleet=.. (its own socket, fleet.state.v1), or
// published into a canvas (state arrives as canvas.data.v1 via the "waterworks" event, and page
// actions go through the canvas host so an agent can take comments on it).
let endpoints = [];
let updated = "waiting for data";
let fleetId = null;
let socket = null;

function apply(state) {
  if (!Array.isArray(state?.endpoints)) return;
  pending.delete("remove_offline");
  endpoints = state.endpoints;
  updated = state.updated || "live";
  fleetId = state.fleet || fleetId;
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

const cols = ["name", "kind", "type", "status", "id", "cwd"];
const filters = { kind: new Set(), type: new Set(), status: new Set() };  // empty = all
let sort = { col: "status", dir: -1 };                    // online first

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, text) => Object.assign(document.createElement(tag), props, text != null ? { textContent: text } : {});

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
  const count = endpoints.filter((e) => e.status === "offline").length;
  b.hidden = count === 0;
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

function render() {
  stats(); chips(); removeOfflineButton();
  $("updated").textContent = updated;
  $("head").replaceChildren(...cols.map((c) => {
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
    .filter((e) => !q || [e.name, e.id, e.cwd].some((v) => v.toLowerCase().includes(q)))
    .sort((a, b) => sort.dir * a[sort.col].localeCompare(b[sort.col]) || a.name.localeCompare(b.name));
  $("rows").replaceChildren(...(rows.length ? rows.map((e) => {
    const tr = el("tr");
    tr.append(
      el("td", {}, e.name),
      el("td", {}, "").appendChild(el("span", { className: `badge ${e.kind}` }, e.kind)).parentNode,
      el("td", { className: "mono" }, e.type),
      el("td", {}, "").appendChild(el("span", { className: `badge ${e.status}` }, e.status)).parentNode,
      el("td", { className: "mono" }, e.id),
      el("td", { className: "mono" }, e.cwd || "—"),
      actions(e),
    );
    return tr;
  }) : [Object.assign(el("tr"), { innerHTML: '<td class="empty" colspan="7">No endpoints match</td>' })]));
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
addEventListener("waterworks", (e) => apply(e.detail));

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
      if (frame.message.type === "fleet.state.v1") apply(frame.message.payload);
      if (frame.message.type === "core.shutdown.v1") stop("shut down");
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
