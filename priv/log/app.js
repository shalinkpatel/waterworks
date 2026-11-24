// Log view. Runs two ways with the same state ({log, entries, tags, updated} from `ww log`):
// standalone at /log#endpoint=..&token=..&log=.. (its own socket), or published into a canvas
// (state arrives as canvas.data.v1 via the "waterworks" event; actions go through the host).
let entries = [];
let tags = [];
let updated = "waiting for data";
let logId = null;
let socket = null;

const STATUSES = [["pending", "Queue"], ["changes_requested", "Changes requested"], ["approved", "Approved"], ["rejected", "Rejected"], ["all", "All"]];
const LABEL = { pending: "pending review", changes_requested: "changes requested", approved: "approved", rejected: "rejected" };
let tab = "pending";
let day = null; // "YYYY-MM-DD" in this machine's time zone, or null
let month = new Date(); month.setDate(1);
const tagFilter = new Set();
let openEntry = null; // id shown in the entry modal
let editing = null; // entry id being edited, or "new"

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children.filter((c) => c != null));
  return node;
};

const localDay = (iso) => {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
const when = (iso) => new Date(iso).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" });
const who = (author) => (author?.user ? "you" : author?.name || author?.endpoint || "unknown");

// --- transport ---------------------------------------------------------------------------

function send(type, payload) {
  if (socket) {
    socket.send(JSON.stringify({ op: "send", to: logId, type, payload }));
  } else if (window.waterworks) {
    window.waterworks.action({ to: logId, action: type.replace(/^log\.|\.v1$/g, ""), ...payload });
  } else {
    toast("not connected");
  }
}

function receive(type, payload) {
  if (type === "log.state.v1") return apply(payload);
  if (type === "log.table_rows.v1") return payload.csv != null ? download(payload) : tablePage(payload);
  // The form stays open until the log accepts the save, so a rejected one keeps your text.
  if (type === "log.receipt.v1" && saving) { saving = false; return $("form").close(); }
  if (type === "core.error.v1") { saving = false; return toast(payload.error); }
}

function apply(state) {
  if (!Array.isArray(state?.entries)) return;
  entries = state.entries;
  tags = state.tags || [];
  if (!socket) logId = state.log || logId; // standalone: the log id comes from the URL only
  updated = `updated ${when(state.updated)}`;
  render();
  if (openEntry) renderEntry();
}

let toastTimer;
function toast(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ($("toast").hidden = true), 5000);
}

// --- list, tabs, calendar, tags --------------------------------------------------------

function filtered({ ignoreDay = false, ignoreTab = false } = {}) {
  const q = $("q").value.trim().toLowerCase();
  return entries.filter((e) =>
    (ignoreTab || tab === "all" || e.status === tab) &&
    (ignoreDay || !day || localDay(e.created_at) === day) &&
    [...tagFilter].every((t) => e.tags.includes(t)) &&
    (!q || [e.title, e.body, who(e.author)].some((v) => v.toLowerCase().includes(q))));
}

function render() {
  $("updated").textContent = updated;
  renderTabs();
  renderCalendar();
  renderTags();
  renderFilters();
  const list = filtered().sort((a, b) => b.created_at.localeCompare(a.created_at));
  $("list").replaceChildren(...(list.length ? list.map(item) : [el("div", { className: "empty" }, emptyText())]));
}

function emptyText() {
  if (!entries.length) return "No log entries yet";
  return day ? `Nothing for ${new Date(day + "T00:00").toLocaleDateString(undefined, { dateStyle: "long" })} here` : "Nothing here";
}

function renderTabs() {
  const counts = Object.fromEntries(STATUSES.map(([s]) => [s, filtered({ ignoreTab: true }).filter((e) => s === "all" || e.status === s).length]));
  $("tabs").replaceChildren(...STATUSES.map(([status, label]) => {
    const b = el("button", { className: "tab", type: "button", role: "tab" }, label, el("span", { className: "c" }, String(counts[status])));
    b.setAttribute("aria-selected", tab === status);
    b.onclick = () => { tab = status; render(); };
    return b;
  }));
}

function renderCalendar() {
  $("month").textContent = month.toLocaleDateString(undefined, { month: "long", year: "numeric" });
  const counts = {};
  for (const e of filtered({ ignoreDay: true, ignoreTab: true })) counts[localDay(e.created_at)] = (counts[localDay(e.created_at)] || 0) + 1;
  const start = new Date(month);
  start.setDate(1 - start.getDay()); // back to Sunday
  const today = localDay(new Date().toISOString());
  const cells = ["S", "M", "T", "W", "T", "F", "S"].map((d) => el("div", { className: "dow" }, d));
  for (let i = 0; i < 42; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    const key = localDay(d.toISOString());
    const n = counts[key] || 0;
    const b = el("button", { type: "button", className: "day" }, String(d.getDate()), n ? el("span", { className: "n" }) : null);
    b.classList.toggle("other", d.getMonth() !== month.getMonth());
    b.classList.toggle("today", key === today);
    b.classList.toggle("selected", key === day);
    b.setAttribute("aria-label", `${d.toDateString()}: ${n} entr${n === 1 ? "y" : "ies"}`);
    b.title = `${n} entr${n === 1 ? "y" : "ies"}`;
    b.onclick = () => {
      day = day === key ? null : key;
      if (day) tab = "all"; // a day's items, whatever their status
      render();
    };
    cells.push(b);
  }
  $("cal").replaceChildren(...cells);
}

$("prev").onclick = () => { month.setMonth(month.getMonth() - 1); render(); };
$("next").onclick = () => { month.setMonth(month.getMonth() + 1); render(); };

function renderTags() {
  if (!tags.length) return $("tags").replaceChildren(el("span", { className: "hint" }, "No tags yet"));
  $("tags").replaceChildren(...tags.map(({ name, count }) => {
    const b = el("button", { className: "chip", type: "button" }, name, el("span", { className: "c" }, String(count)));
    b.setAttribute("aria-pressed", tagFilter.has(name));
    b.onclick = () => { tagFilter.has(name) ? tagFilter.delete(name) : tagFilter.add(name); render(); };
    return b;
  }));
}

function renderFilters() {
  const parts = [];
  if (day) parts.push(chip(new Date(day + "T00:00").toLocaleDateString(undefined, { dateStyle: "medium" }), () => { day = null; }));
  for (const t of tagFilter) parts.push(chip(`#${t}`, () => tagFilter.delete(t)));
  $("filters").hidden = !parts.length;
  $("filters").replaceChildren("Showing", ...parts);
}

function chip(text, clear) {
  const b = el("button", { className: "chip", type: "button", title: "Clear filter" }, `${text} ✕`);
  b.setAttribute("aria-pressed", "true");
  b.onclick = () => { clear(); render(); };
  return b;
}

function item(e) {
  const node = el("div", { className: "item", tabIndex: 0 },
    el("div", { className: "top" }, el("span", { className: "title" }, e.title), el("span", { className: `badge ${e.status}` }, LABEL[e.status])),
    el("div", { className: "meta" }, `${who(e.author)} · ${when(e.created_at)} · r${e.revision}` +
      (e.links.length ? ` · ${e.links.length} link${e.links.length > 1 ? "s" : ""}` : "") +
      (e.tables.length ? ` · ${e.tables.length} table${e.tables.length > 1 ? "s" : ""}` : "")),
    el("div", { className: "chips" }, ...e.tags.map((t) => el("span", { className: "badge tag" }, t))));
  node.setAttribute("role", "button");
  node.onclick = node.onkeydown = (ev) => {
    if (ev.type === "keydown" && ev.key !== "Enter") return;
    openEntry = e.id;
    renderEntry();
    $("entry").showModal();
  };
  return node;
}

// --- entry modal -------------------------------------------------------------------------

function renderEntry() {
  const e = entries.find((x) => x.id === openEntry);
  if (!e) return;
  $("entry-title").textContent = e.title;
  $("entry-status").replaceChildren(el("span", { className: `badge ${e.status}` }, LABEL[e.status]));
  const undeliverable = e.status === "changes_requested" && e.reviews.at(-1)?.action === "undeliverable";
  const body = [
    el("div", { className: "hint" }, `${who(e.author)} · created ${when(e.created_at)} · updated ${when(e.updated_at)} · revision ${e.revision}`),
    undeliverable ? el("p", { className: "badge rejected" }, "The author's session is gone: edit and approve it yourself") : null,
    e.tags.length ? el("div", { className: "chips", style: "margin-top:10px" }, ...e.tags.map((t) => el("span", { className: "badge tag" }, t))) : null,
    section("Details", el("div", { className: "bodytext" }, e.body || "(no details)")),
  ];
  if (e.links.length) {
    body.push(section("Links", el("ul", { className: "links" }, ...e.links.map((l) =>
      el("li", {}, el("span", { className: "badge tag" }, l.kind), " ", el("a", { href: l.url, target: "_blank", rel: "noopener noreferrer" }, l.label))))));
  }
  for (const t of e.tables) body.push(section(`Table: ${t.name}`, tableView(e, t)));
  body.push(section("History", el("ul", { className: "timeline" }, ...history(e))));
  $("entry-body").replaceChildren(...body.filter(Boolean));
  $("entry-actions").replaceChildren(...actions(e));
}

function section(title, ...content) {
  return el("div", { className: "section" }, el("h4", {}, title), ...content);
}

function tableView(e, t) {
  const summary = el("div", { className: "hint" }, `${t.description ? t.description + " · " : ""}${t.row_count} rows · ` +
    t.columns.map((c) => `${c.name} ${c.type}`).join(", "));
  const open = el("button", { className: "ghost", type: "button", style: "margin-top:8px" }, "Open table");
  open.onclick = () => openTable(e, t);
  return el("div", {}, summary, open);
}

// --- table viewer: pages of 100 rows, sorted by any column, downloadable as CSV ----------

const PAGE = 100;
let viewing = null; // {entry, revision, table, columns, total, offset, order_by, desc, rows}

function openTable(e, t) {
  viewing = { entry: e.id, revision: e.revision, table: t.name, description: t.description, columns: t.columns, total: t.row_count, offset: 0, order_by: null, desc: false, rows: null };
  requestPage();
  renderTable();
  $("table").showModal();
}

function requestPage(extra = {}) {
  const { entry, revision, table, offset, order_by, desc } = viewing;
  send("log.table.v1", { entry, table, revision, limit: PAGE, offset, ...(order_by ? { order_by, desc } : {}), ...extra });
}

function tablePage(page) {
  // Only the page the viewer is waiting for: a slow answer to an older click is dropped.
  if (!viewing || page.entry !== viewing.entry || page.table !== viewing.table || page.offset !== viewing.offset ||
      (page.order_by || null) !== viewing.order_by || Boolean(page.desc) !== viewing.desc) return;
  viewing.rows = page.rows;
  viewing.total = page.total;
  renderTable();
}

function renderTable() {
  const v = viewing;
  $("table-title").textContent = v.table;
  $("table-sub").textContent = `${v.total} rows${v.description ? " · " + v.description : ""}`;
  const head = el("tr", {}, ...v.columns.map((c) => {
    const th = el("th", { tabIndex: 0, title: "Sort" }, c.name, el("span", { className: "type" }, c.type));
    if (v.order_by === c.name) th.setAttribute("aria-sort", v.desc ? "descending" : "ascending");
    th.onclick = th.onkeydown = (ev) => {
      if (ev.type === "keydown" && ev.key !== "Enter") return;
      // none -> ascending -> descending -> none
      if (v.order_by !== c.name) Object.assign(v, { order_by: c.name, desc: false });
      else if (!v.desc) v.desc = true;
      else Object.assign(v, { order_by: null, desc: false });
      Object.assign(v, { offset: 0, rows: null });
      requestPage();
      renderTable();
    };
    return th;
  }));
  const body = v.rows
    ? v.rows.map((r) => el("tr", {}, ...r.map((x) => el("td", {}, x == null ? "∅" : String(x)))))
    : [el("tr", {}, el("td", { colSpan: v.columns.length, className: "hint" }, "Loading…"))];
  $("table-grid").replaceChildren(el("thead", {}, head), el("tbody", {}, ...body));
  const last = Math.min(v.offset + PAGE, v.total);
  $("table-range").textContent = v.total ? `rows ${v.offset + 1}–${last} of ${v.total}` : "no rows";
  $("table-prev").disabled = v.offset === 0;
  $("table-next").disabled = last >= v.total;
}

const turn = (delta) => { Object.assign(viewing, { offset: Math.max(0, viewing.offset + delta), rows: null }); requestPage(); renderTable(); };
$("table-prev").onclick = () => turn(-PAGE);
$("table-next").onclick = () => turn(PAGE);
$("table-close").onclick = () => { viewing = null; $("table").close(); };
$("table-csv").onclick = () => requestPage({ format: "csv" });

// Downloads may be blocked inside a canvas (sandboxed frame); the standalone view allows them.
function download({ table, csv }) {
  const a = el("a", { href: URL.createObjectURL(new Blob([csv], { type: "text/csv" })), download: `${table}.csv` });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

function history(e) {
  const events = [
    ...e.revisions.map((r) => ({ at: r.at, text: `r${r.revision} by ${r.by === "user" ? "you" : r.by === e.author?.endpoint ? who(e.author) : r.by}${r.revision > 1 ? `: ${r.title}` : ""}` })),
    ...e.reviews.filter((r) => !["submit", "revise", "edit"].includes(r.action))
      .map((r) => ({ at: r.at, text: `${r.action.replace("_", " ")}${r.note ? ` — “${r.note}”` : ""}` })),
  ].sort((a, b) => a.at.localeCompare(b.at));
  return events.map((ev) => el("li", {}, el("span", { className: "when" }, when(ev.at)), " ", ev.text));
}

function actions(e) {
  const review = (decision, note) => send("log.review.v1", { entry: e.id, decision, ...(note ? { note } : {}) });
  const button = (label, cls, fn) => { const b = el("button", { className: cls, type: "button" }, label); b.onclick = fn; return b; };
  const list = [button("Close", "ghost left", () => $("entry").close()), button("Edit", "ghost", () => openForm(e))];
  if (["approved", "rejected"].includes(e.status)) list.push(button("Reopen", "ghost", () => review("reopen")));
  if (e.status !== "rejected") list.push(button("Reject", "ghost danger", () => noteThen("Reason (optional)", false, (n) => review("reject", n))));
  if (e.status === "pending" && !e.author?.user) list.push(button("Request changes", "ghost", () => noteThen("What should change?", true, (n) => review("request_changes", n))));
  if (["pending", "changes_requested"].includes(e.status)) list.push(button("Approve", "primary", () => review("approve")));
  return list;
}

// A note box replaces the action bar until sent or cancelled.
function noteThen(placeholder, required, done) {
  const box = el("textarea", { placeholder, rows: 3, style: "flex:1;min-width:260px" });
  const ok = el("button", { className: "primary", type: "button" }, "Send");
  const cancel = el("button", { className: "ghost", type: "button" }, "Cancel");
  ok.onclick = () => {
    if (required && !box.value.trim()) return box.focus();
    done(box.value.trim());
  };
  cancel.onclick = renderEntry;
  $("entry-actions").replaceChildren(box, cancel, ok);
  box.focus();
}

// --- edit / new form ---------------------------------------------------------------------

function openForm(e) {
  editing = e ? e.id : "new";
  $("form-title").textContent = e ? `Edit: ${e.title}` : "New log entry";
  $("f-title").value = e?.title || "";
  $("f-body").value = e?.body || "";
  $("f-tags").value = (e?.tags || []).join(", ");
  $("f-links").value = (e?.links || []).map(linkLine).join("\n");
  formTables = (e?.tables || []).map((t) => ({ name: t.name, keep: true, label: `${t.row_count} rows` }));
  tablesChanged = false;
  renderFormTables();
  $("f-add").open = false;
  $("f-hint").textContent = e
    ? (e.status === "approved" || e.status === "rejected" ? "Saving puts this entry back in the queue." : "Saving creates a new revision; the entry stays in the queue.")
    : "Your entries go into the queue like everyone else's.";
  if (e) $("entry").close();
  $("form").showModal();
  $("f-title").focus();
}

// One link per line: "url", "label | url", or "label | url | kind" (pr, dashboard, other).
const linkLine = (l) => [l.label !== l.url ? l.label : null, l.url, l.kind === "other" || (l.kind === "pr" && /\/pull\/\d+/.test(l.url)) ? null : l.kind]
  .filter(Boolean).join(" | ");
function parseLink(line) {
  const parts = line.split("|").map((s) => s.trim());
  const url = parts.find((p) => /^https?:\/\//.test(p)) || parts[0];
  const label = parts[0] !== url ? parts[0] : undefined;
  const kind = ["pr", "dashboard", "other"].includes(parts.at(-1)) ? parts.at(-1) : undefined;
  return { url, ...(label ? { label } : {}), ...(kind ? { kind } : {}) };
}

let saving = false;

// --- tables in the form: keep or remove existing ones, add CSV (pasted or file) or Parquet --

let formTables = []; // {name, keep: true, label} | {name, description, csv | parquet, label}
let tablesChanged = false;

function renderFormTables() {
  $("f-tables").replaceChildren(el("div", { className: "tablelist" }, ...(formTables.length
    ? formTables.map((t, i) => {
      const remove = el("button", { className: "ghost", type: "button" }, "Remove");
      remove.onclick = () => { formTables.splice(i, 1); tablesChanged = true; renderFormTables(); };
      return el("div", { className: "t" }, el("span", { className: "badge tag" }, t.name), el("span", { className: "hint" }, t.label), remove);
    })
    : [el("span", { className: "hint" }, "No tables")])));
}

$("t-add").onclick = async () => {
  const name = $("t-name").value.trim();
  const file = $("t-file").files[0];
  const csv = $("t-csv").value;
  if (!/^[a-z][a-z0-9_]{0,40}$/.test(name)) return toast("Table names look like latency_by_batch");
  if (formTables.some((t) => t.name === name)) return toast(`There is already a table named ${name}`);
  if (!file && !csv.trim()) return toast("Paste CSV or choose a .csv or .parquet file");
  const spec = { name, description: $("t-desc").value.trim() };
  if (file && /\.parquet$/i.test(file.name)) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    Object.assign(spec, { parquet: btoa(binary), label: file.name });
  } else if (file) {
    Object.assign(spec, { csv: await file.text(), label: file.name });
  } else {
    Object.assign(spec, { csv, label: `pasted CSV, ${csv.trim().split("\n").length - 1} rows` });
  }
  formTables.push(spec);
  tablesChanged = true;
  for (const id of ["t-name", "t-desc", "t-csv", "t-file"]) $(id).value = "";
  renderFormTables();
};
$("f-cancel").onclick = () => { saving = false; $("form").close(); };
$("f-save").onclick = () => {
  const text = { title: $("f-title").value, body: $("f-body").value, tags: $("f-tags").value, links: $("f-links").value };
  const parse = {
    title: (v) => v,
    body: (v) => v,
    tags: (v) => v.split(",").map((t) => t.trim()).filter(Boolean),
    links: (v) => v.split("\n").map((l) => l.trim()).filter(Boolean).map(parseLink),
  };
  const fields = Object.fromEntries(Object.entries(text).map(([k, v]) => [k, parse[k](v)]));
  const tables = formTables.map(({ label, ...spec }) => spec);
  saving = true;
  if (editing === "new") return send("log.submit.v1", { ...fields, tables });
  // Send only fields whose text changed, so an edit never overwrites what the author revised
  // meanwhile, and untouched links keep their kind.
  const e = entries.find((x) => x.id === editing);
  const before = { title: e.title, body: e.body, tags: e.tags.join(", "), links: e.links.map(linkLine).join("\n") };
  const changed = Object.fromEntries(Object.keys(text).filter((k) => text[k].trim() !== before[k].trim()).map((k) => [k, fields[k]]));
  // Tables go as a whole set: existing ones as {name, keep: true}, new ones with their data.
  if (tablesChanged) changed.tables = tables;
  if (!Object.keys(changed).length) { saving = false; return $("form").close(); }
  send("log.edit.v1", { entry: editing, ...changed });
};
$("new").onclick = () => openForm(null);
$("q").oninput = render;

// --- theme + connection ------------------------------------------------------------------

const stored = (() => { try { return localStorage.getItem("ww-log-theme"); } catch { return null; } })();
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  $("theme").textContent = theme === "dark" ? "☀ Light mode" : "☾ Dark mode";
}
setTheme(stored || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
$("theme").onclick = () => {
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  setTheme(next);
  try { localStorage.setItem("ww-log-theme", next); } catch {}
};

// In a canvas: state as canvas.data.v1; replies (table rows, errors) as {reply: {type, payload}}.
addEventListener("waterworks", (e) => (e.detail?.reply ? receive(e.detail.reply.type, e.detail.reply.payload) : apply(e.detail)));

// Standalone: the URL fragment (never sent to the server) carries this viewer's credentials.
const params = new URLSearchParams(location.hash.slice(1));
if (params.get("endpoint") && params.get("token")) {
  logId = params.get("log");
  const connect = () => {
    const ws = new WebSocket(`${location.origin.replace(/^http/, "ws")}/v1/endpoints/${params.get("endpoint")}/socket`, ["ww", `ww-token.${params.get("token")}`]);
    ws.onopen = () => {
      socket = ws;
      ws.send(JSON.stringify({ op: "send", to: logId, type: "log.subscribe.v1", payload: {} }));
    };
    ws.onmessage = ({ data }) => {
      const frame = JSON.parse(data);
      if (frame.op !== "message") return;
      ws.send(JSON.stringify({ op: "ack", id: frame.message.id }));
      // Anyone can message this view's endpoint; only the log it belongs to is trusted.
      if (frame.message.from === logId) receive(frame.message.type, frame.message.payload);
    };
    ws.onclose = (event) => {
      socket = null;
      if (event.reason === "deregistered") { updated = "this view was disconnected; restart `ww log`"; return render(); }
      updated = "disconnected; retrying";
      render();
      setTimeout(connect, 2000);
    };
  };
  connect();
}
render();
