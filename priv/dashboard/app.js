import { applyMessage, emptyState, intersectingPanels, isCleared, linePaths, regionFromPoints } from "./core.js";

const $ = (selector) => document.querySelector(selector);
const SVG = "http://www.w3.org/2000/svg";
const COLORS = ["#2f7de1", "#e1622f", "#2fa36b", "#a34fd6", "#d6a12f", "#d64f7a"];

const creds = readCredentials();
const commentsKey = creds && `ww-dashboard-comments:${creds.id}`;
let comments = creds ? JSON.parse(sessionStorage.getItem(commentsKey) || "[]") : [];
let state = emptyState();
let socket;
let draft = null;
let frame = null; // { element, version, html, loaded, forwarded: last forwarded data sequence }
const inspections = new Map();
const unreported = new Map(); // rejected delta id -> core.error.v1 for its sender

// A delta that does not fit the current page is answered with an error so its publisher can
// send a full page. The id derives from the delta, so history replays do not duplicate it.
function apply(message) {
  const before = state.stale;
  try {
    state = applyMessage(state, message);
  } catch (error) {
    // A malformed message is skipped, or replaying history would break every reload.
    console.warn(`skipping malformed ${message.type} ${message.id}`, error);
    state = { ...state, sequence: message.sequence };
    return;
  }
  const stale = state.stale;
  if (stale && stale !== before) {
    unreported.set(stale.id, {
      op: "send",
      id: `${stale.id}-mismatch`,
      to: stale.from,
      type: "core.error.v1",
      reply_to: stale.id,
      payload: { error: "delta_base_mismatch", base: stale.base, expected: stale.expected },
    });
    reportErrors();
  }
}

function reportErrors() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  for (const [id, error] of unreported) {
    socket.send(JSON.stringify(error));
    unreported.delete(id);
  }
}

// Credentials arrive in the URL fragment (never sent to the server) and move to tab-scoped storage.
function readCredentials() {
  const hash = new URLSearchParams(location.hash.slice(1));
  if (hash.get("endpoint") && hash.get("token")) {
    sessionStorage.setItem("ww-dashboard", JSON.stringify({ id: hash.get("endpoint"), token: hash.get("token") }));
    history.replaceState(null, "", location.pathname);
  }
  const stored = sessionStorage.getItem("ww-dashboard");
  return stored ? JSON.parse(stored) : null;
}

function setStatus(text) {
  $("#status").textContent = text;
}

// History rebuilds the page after reloads; the socket then streams live messages.
async function connect() {
  setStatus("connecting");
  try {
    const response = await fetch(`/v1/endpoints/${creds.id}/history`, {
      headers: { authorization: `Bearer ${creds.token}` },
    });
    if (!response.ok) throw new Error(`history HTTP ${response.status}`);
    for (const message of (await response.json()).messages) apply(message);
    render();
  } catch (error) {
    setStatus(`error: ${error.message}; retrying`);
    setTimeout(connect, 2000);
    return;
  }

  const url = new URL(`/v1/endpoints/${creds.id}/socket`, location.href);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const current = new WebSocket(url, ["ww", `ww-token.${creds.token}`]);
  socket = current;

  current.onopen = () => {
    setStatus("live");
    render();
    reportErrors();
  };
  current.onmessage = ({ data }) => {
    const frame = JSON.parse(data);
    if (frame.op === "message") {
      apply(frame.message);
      render();
      current.send(JSON.stringify({ op: "ack", id: frame.message.id }));
    } else if (frame.op === "accepted") {
      updateComment(frame.message.id, { status: "sent" });
    } else if (frame.op === "error") {
      setStatus(`error: ${frame.error}`);
    }
  };
  current.onclose = () => {
    if (socket !== current) return;
    socket = undefined;
    setStatus("offline; reconnecting");
    render();
    setTimeout(connect, 1000);
  };
}

function render() {
  document.title = state.title;
  $("#title").textContent = state.title;
  $("#version").textContent = state.html ? `v${state.version}${state.stale ? " · missed an update" : ""}` : "";
  document.body.dataset.sequence = state.sequence;
  $("#panels").replaceChildren(...state.panels.map(safePanelElement));
  syncFrame();
  const offline = !state.source || socket?.readyState !== WebSocket.OPEN;
  $("#comment").disabled = offline;
  $("#pick").disabled = offline;
  if (!state.html) relocatePanelComments();
  renderComments();
}

function el(tag, attrs = {}, text) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  if (text !== undefined) node.textContent = text;
  return node;
}

function svgEl(tag, attrs = {}) {
  const node = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
}

function fmt(value) {
  return typeof value === "number" ? value.toLocaleString(undefined, { maximumFractionDigits: 3 }) : String(value ?? "");
}

function safePanelElement(panel) {
  try {
    return panelElement(panel);
  } catch {
    const section = el("section", { className: "panel" });
    section.dataset.panel = panel.id;
    section.append(el("h2", {}, String(panel.title ?? panel.id)), el("p", {}, `Malformed ${panel.kind} panel`));
    return section;
  }
}

function panelElement(panel) {
  const section = el("section", { className: `panel ${panel.kind}` });
  section.dataset.panel = panel.id;
  section.style.gridColumn = `span ${Math.min(4, Math.max(1, Number(panel.width) || 1))}`;
  section.append(el("h2", {}, panel.title ?? panel.id));

  switch (panel.kind) {
    case "stat":
      section.append(el("div", { className: "value" }, `${fmt(panel.value)}${panel.unit ? ` ${panel.unit}` : ""}`));
      if (panel.delta !== undefined) section.append(el("div", { className: "delta" }, fmt(panel.delta)));
      break;
    case "line": {
      const series = panel.series || [];
      const { paths, min, max } = linePaths(series, 400, 140);
      const svg = svgEl("svg", { viewBox: "0 0 400 140", preserveAspectRatio: "none", role: "img", "aria-label": panel.title ?? panel.id });
      paths.forEach((path, i) =>
        svg.append(svgEl("path", { d: path.d, fill: "none", stroke: COLORS[i % COLORS.length], "stroke-width": 2, "vector-effect": "non-scaling-stroke" })),
      );
      const legend = el("div", { className: "legend" });
      series.forEach((s, i) => {
        const item = el("span", {}, `${s.name}: ${fmt(s.points.at(-1)?.[1])}`);
        item.style.setProperty("--c", COLORS[i % COLORS.length]);
        legend.append(item);
      });
      section.append(svg, legend, el("div", { className: "range" }, `range ${fmt(min)} – ${fmt(max)}`));
      break;
    }
    case "bar": {
      const bars = panel.bars || [];
      const max = Math.max(0, ...bars.map((b) => Number(b.value) || 0)) || 1;
      for (const bar of bars) {
        const row = el("div", { className: "bar" });
        const fill = el("div");
        fill.style.width = `${Math.max(0, ((Number(bar.value) || 0) / max) * 100)}%`;
        row.append(el("span", {}, bar.label), el("span", {}), el("span", {}, fmt(bar.value)));
        row.children[1].append(fill);
        section.append(row);
      }
      break;
    }
    case "table": {
      const table = el("table");
      const head = el("tr");
      for (const column of panel.columns || []) head.append(el("th", {}, column));
      table.append(head);
      for (const values of panel.rows || []) {
        const row = el("tr");
        for (const value of values) row.append(el("td", {}, fmt(value)));
        table.append(row);
      }
      section.append(table);
      break;
    }
    case "text":
      section.append(el("p", {}, panel.text ?? ""));
      break;
    default:
      section.append(el("p", {}, `Unsupported panel kind: ${panel.kind}`));
  }
  return section;
}

// Page mode: one sandboxed frame per page version. Agent HTML never touches this document.
function syncFrame() {
  $("#panels").hidden = Boolean(state.html);
  if (!state.html) {
    frame?.element.remove();
    frame = null;
    return;
  }
  if (frame?.version !== state.version) {
    frame?.element.remove();
    const element = document.createElement("iframe");
    element.id = "page";
    element.title = state.title;
    element.setAttribute("sandbox", "allow-scripts allow-popups allow-popups-to-escape-sandbox");
    element.src = "/dashboard/frame";
    frame = { element, version: state.version, html: state.html, loaded: false, forwarded: 0 };
    $("#board").prepend(element);
  }
  forwardData();
}

function toFrame(message) {
  frame.element.contentWindow.postMessage({ source: "waterworks-host", ...message }, "*");
}

function forwardData() {
  if (!frame?.loaded) return;
  for (const item of state.data.filter((d) => d.sequence > frame.forwarded)) {
    toFrame({ kind: "data", payload: item.payload });
    frame.forwarded = item.sequence;
  }
}

addEventListener("message", (event) => {
  if (!frame || event.source !== frame.element.contentWindow || event.data?.source !== "waterworks-frame") return;
  const data = event.data;
  if (data.kind === "ready") {
    toFrame({ kind: "render", html: frame.html });
  } else if (data.kind === "size") {
    frame.element.style.height = `${Math.max(400, data.height)}px`;
    if (!frame.loaded) {
      frame.loaded = true;
      forwardData();
      if (mode === "element") toFrame({ kind: "pick", on: true }); // a new version arrived mid-pick
    }
    relocateFrameComments();
  } else if (data.kind === "picked" && mode === "element") { // only a pick the user started
    openComposer(frameRectToRegion(data.rect), "", data, data.element);
  } else if (data.kind === "pick-cancelled") {
    setMode(null);
  } else if (data.kind === "located") {
    const regions = {};
    for (const [id, rect] of Object.entries(data.rects)) if (rect) regions[id] = frameRectToRegion(rect);
    relocateComments(regions);
  } else if (data.kind === "inspected") {
    inspections.get(data.request)?.(data);
    inspections.delete(data.request);
  }
});

// Asks the page what lies under a board region (or its text selection when region is null).
function inspectFrame(region) {
  if (!frame?.loaded) return Promise.resolve({});
  const board = boardBounds();
  const inner = frame.element.getBoundingClientRect();
  const rect = region && {
    x: board.left + region.x * board.width - inner.left,
    y: board.top + region.y * board.height - inner.top,
    width: region.width * board.width,
    height: region.height * board.height,
  };
  const request = crypto.randomUUID();
  return new Promise((resolve) => {
    inspections.set(request, resolve);
    setTimeout(() => inspections.delete(request) && resolve({}), 1000);
    toFrame({ kind: "inspect", request, rect });
  });
}

function frameRectToRegion(rect) {
  const inner = frame.element.getBoundingClientRect();
  const a = { x: inner.left + rect.x, y: inner.top + rect.y };
  return regionFromPoints(a, { x: a.x + rect.width, y: a.y + rect.height }, boardBounds());
}

function boardBounds() {
  return $("#board").getBoundingClientRect();
}

function panelRects() {
  const bounds = boardBounds();
  return [...document.querySelectorAll("[data-panel]")].map((node) => {
    const rect = node.getBoundingClientRect();
    const panel = state.panels.find((p) => p.id === node.dataset.panel);
    return {
      id: panel.id,
      title: panel.title ?? panel.id,
      kind: panel.kind,
      ...regionFromPoints({ x: rect.left, y: rect.top }, { x: rect.right, y: rect.bottom }, bounds),
    };
  });
}

function placeRegion(node, region) {
  Object.assign(node.style, {
    left: `${region.x * 100}%`,
    top: `${region.y * 100}%`,
    width: `${region.width * 100}%`,
    height: `${region.height * 100}%`,
  });
}

function regionOfRect(rect) {
  return regionFromPoints({ x: rect.left, y: rect.top }, { x: rect.right, y: rect.bottom }, boardBounds());
}

function saveComments() {
  sessionStorage.setItem(commentsKey, JSON.stringify(comments));
}

// Placed comments keep the selection's box, hatched. Element comments follow their element.
function renderComments() {
  const active = comments.filter((comment) => !isCleared(state, comment));
  const markers = active.map((comment) => {
    const marker = el("div", { className: "region placed" });
    marker.dataset.comment = comment.id;
    placeRegion(marker, comment.region);
    marker.append(el("b", {}, String(comments.indexOf(comment) + 1)));
    return marker;
  });
  // Live updates re-render this layer; keep the selection in progress on top of it.
  const transient = [draft && draftRegion(draft.region), dragStart && dragBox, mode === "element" && $("#hover-region")];
  $("#markers").replaceChildren(...markers, ...transient.filter(Boolean));

  const ids = new Set(comments.map((c) => c.id));
  const items = comments.map((comment, i) => {
    const cleared = isCleared(state, comment);
    const item = el("div", { className: `comment${cleared ? " cleared" : ""}` });
    const status = cleared ? "cleared by agent" : comment.status;
    item.append(
      el("div", { className: "meta" }, `#${i + 1} · ${status} · ${comment.panels.join(", ") || "no panel"}`),
      el("div", {}, comment.text),
    );
    for (const reply of state.replies.filter((r) => r.reply_to === comment.id)) {
      item.append(el("div", { className: "reply" }, reply.text));
    }
    item.onmouseenter = () => document.querySelector(`[data-comment="${comment.id}"]`)?.classList.add("highlight");
    item.onmouseleave = () => document.querySelector(`[data-comment="${comment.id}"]`)?.classList.remove("highlight");
    return item;
  });
  for (const reply of state.replies.filter((r) => !ids.has(r.reply_to))) {
    items.push(el("div", { className: "comment reply" }, reply.text));
  }
  $("#comments").replaceChildren(...items);
}

function draftRegion(region) {
  const node = el("div", { className: "region draft" });
  node.id = "draft-region";
  placeRegion(node, region);
  return node;
}

function updateComment(id, changes) {
  comments = comments.map((c) => (c.id === id ? { ...c, ...changes } : c));
  saveComments();
  renderComments();
}

// Moves element comments' markers onto their elements' current boxes.
function relocateComments(rects) {
  let moved = false;
  comments = comments.map((comment) => {
    const rect = rects[comment.id];
    if (!rect) return comment;
    moved = true;
    return { ...comment, region: rect };
  });
  if (moved) {
    saveComments();
    renderComments();
  }
}

function relocatePanelComments() {
  const rects = {};
  for (const comment of comments) {
    if (!comment.selector || isCleared(state, comment)) continue;
    let node = null;
    try {
      node = $("#panels").querySelector(comment.selector); // stored selectors may come from a page
    } catch {}
    if (node) rects[comment.id] = regionOfRect(node.getBoundingClientRect());
  }
  relocateComments(rects);
}

function relocateFrameComments() {
  const selectors = {};
  for (const comment of comments) {
    if (comment.selector && !isCleared(state, comment)) selectors[comment.id] = comment.selector;
  }
  if (!frame?.loaded || Object.keys(selectors).length === 0) return;
  toFrame({ kind: "locate", request: crypto.randomUUID(), selectors });
}

// Modes: "area" drags a rectangle (Enter: whole dashboard), "element" picks one element.
let mode = null;
function setMode(next) {
  if (mode === "element") {
    if (frame?.loaded) toFrame({ kind: "pick", on: false });
    $("#hover-region")?.remove();
    hovered = null;
    narrower = [];
  }
  mode = next;
  $("#overlay").classList.toggle("active", mode === "area");
  $("#comment").setAttribute("aria-pressed", String(mode === "area"));
  $("#pick").setAttribute("aria-pressed", String(mode === "element"));
  if (mode === "area") {
    setStatus("drag to select an area; Enter for the whole dashboard; Escape to cancel");
    $("#overlay").focus();
  } else if (mode === "element") {
    setStatus("click an element (↑ parent, ↓ child, Enter picks); Escape to cancel");
    if (state.html && frame?.loaded) toFrame({ kind: "pick", on: true });
  } else if (socket?.readyState === WebSocket.OPEN) {
    setStatus("live");
  }
}

// Whatever the frame reports comes from the agent's page: keep only bounded strings.
const clip = (value, length) => (typeof value === "string" ? value.slice(0, length) : "");
function cleanElement(element) {
  if (!element) return null;
  const { selector, tag, id, classes, text, panel } = element;
  return {
    selector: clip(selector, 500), tag: clip(tag, 40), id: clip(id, 200), classes: clip(classes, 200), text: clip(text, 300),
    ...(panel === undefined ? {} : { panel: clip(panel, 200) }),
  };
}

async function openComposer(region, selection = "", context = null, element = null) {
  setMode(null);
  const panels = state.html ? [] : intersectingPanels(region, panelRects());
  if (state.html && !context) context = await inspectFrame(region);
  element = cleanElement(element);
  selection = clip(selection, 2000);
  if (context) {
    const ids = Array.isArray(context.ids) ? context.ids.slice(0, 20).map((id) => clip(id, 200)) : [];
    context = { heading: clip(context.heading, 300), text: clip(context.text, 2000), ids, selection: clip(context.selection, 2000) || selection };
    selection ||= context.selection;
  }
  draft = { region, selection, panels, context, element };
  renderComments(); // shows the selection, solid, while the comment is written
  const where = element
    ? `<${element.tag}${element.id ? `#${element.id}` : ""}>${context?.heading ? ` in ${context.heading}` : ""}`
    : context ? context.heading || "Page" : panels.map((p) => p.title).join(", ") || "No panel";
  const quote = selection || element?.text || context?.text || "";
  $("#composer-meta").textContent = `${where}${quote ? ` · “${quote.slice(0, 80)}”` : ""}`;
  $("#composer").classList.add("open");
  $("#composer-text").value = "";
  $("#composer-text").focus();
}

function closeComposer() {
  draft = null;
  $("#composer").classList.remove("open");
  renderComments();
}

function sendComment() {
  const text = $("#composer-text").value.trim();
  if (!draft || !text) return;
  if (socket?.readyState !== WebSocket.OPEN || !state.source) {
    setStatus("cannot send while offline");
    return;
  }
  const id = `msg_${crypto.randomUUID()}`;
  const { region, selection, panels, context, element } = draft;
  socket.send(
    JSON.stringify({
      op: "send",
      id,
      to: state.source,
      type: "dashboard.comment.v1",
      payload: {
        text,
        region,
        panels,
        selection,
        ...(context ? { context } : {}),
        ...(element ? { element } : {}),
        dashboard: { title: state.title, sequence: state.sequence, version: state.version },
      },
    }),
  );
  const anchor = element
    ? [element.id ? `#${element.id}` : `<${element.tag}> “${element.text.slice(0, 24)}”`]
    : context ? [context.heading || "page"] : panels.map((p) => p.id);
  comments = [
    ...comments,
    { id, text, region, panels: anchor, status: "sending", created_at: Date.now(), ...(element ? { selector: element.selector } : {}) },
  ];
  saveComments();
  draft = null;
  $("#composer").classList.remove("open");
  renderComments();
}

$("#comment").onclick = async () => {
  if (mode === "area") return setMode(null);
  if (state.html) {
    const found = await inspectFrame(null);
    if (found.selection && found.rect) {
      openComposer(frameRectToRegion(found.rect), found.selection, found);
      return;
    }
  }
  const selection = window.getSelection();
  if (selection && !selection.isCollapsed && $("#panels").contains(selection.anchorNode)) {
    const region = regionOfRect(selection.getRangeAt(0).getBoundingClientRect());
    const text = selection.toString();
    selection.removeAllRanges();
    openComposer(region, text);
    return;
  }
  setMode("area");
};

$("#pick").onclick = () => setMode(mode === "element" ? null : "element");

// Panel mode picks host elements; page mode picks inside the frame (helper.js).
function panelPath(node) {
  const parts = [];
  for (; node && node !== $("#panels"); node = node.parentElement) {
    if (node.dataset.panel) {
      parts.unshift(`[data-panel="${CSS.escape(node.dataset.panel)}"]`);
      return parts.join(" > ");
    }
    const tag = node.tagName.toLowerCase();
    const same = [...node.parentElement.children].filter((child) => child.tagName === node.tagName);
    parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
  }
  return `:scope > ${parts.join(" > ")}`;
}

function describeHost(node) {
  return {
    selector: panelPath(node),
    tag: node.tagName.toLowerCase(),
    id: node.id || "",
    classes: node.getAttribute("class") || "",
    text: node.textContent.trim().replace(/\s+/g, " ").slice(0, 300),
    panel: node.closest("[data-panel]")?.dataset.panel || "",
  };
}

let hovered = null;
let narrower = []; // elements ArrowUp left, for ArrowDown
function hoverHost(node) {
  hovered = node;
  const box = $("#hover-region") || el("div", { className: "region hover", id: "hover-region" });
  placeRegion(box, regionOfRect(node.getBoundingClientRect()));
  $("#markers").append(box);
}
function pickHost(node) {
  openComposer(regionOfRect(node.getBoundingClientRect()), "", null, describeHost(node));
}
$("#panels").addEventListener("mouseover", (event) => {
  if (mode !== "element" || state.html || event.target === $("#panels")) return;
  narrower = [];
  hoverHost(event.target);
});
$("#panels").addEventListener("click", (event) => {
  if (mode !== "element" || state.html || event.target === $("#panels")) return;
  event.preventDefault();
  event.stopPropagation();
  pickHost(hovered?.isConnected && hovered.contains(event.target) ? hovered : event.target);
}, true);

// Keys while picking: ArrowUp/ArrowDown widen or narrow the outline, Enter picks it.
function pickKey(key) {
  if (state.html) return toFrame({ kind: "pick-key", key });
  if (!hovered?.isConnected) return;
  const parent = hovered.parentElement;
  if (key === "ArrowUp" && parent && parent !== $("#panels")) {
    narrower.push(hovered);
    hoverHost(parent);
  } else if (key === "ArrowDown" && narrower.length) {
    hoverHost(narrower.pop());
  } else if (key === "Enter") {
    pickHost(hovered);
  }
}

const overlay = $("#overlay");
let dragStart = null;
let dragBox = null;
overlay.onpointerdown = (event) => {
  dragStart = { x: event.clientX, y: event.clientY };
  dragBox = el("div", { className: "region draft" });
  $("#markers").append(dragBox);
  overlay.setPointerCapture(event.pointerId);
};
overlay.onpointermove = (event) => {
  if (!dragStart) return;
  placeRegion(dragBox, regionFromPoints(dragStart, { x: event.clientX, y: event.clientY }, boardBounds()));
};
overlay.onpointerup = (event) => {
  if (!dragStart) return;
  const region = regionFromPoints(dragStart, { x: event.clientX, y: event.clientY }, boardBounds());
  dragStart = null;
  dragBox.remove();
  const bounds = boardBounds();
  if (region.width * bounds.width < 4 || region.height * bounds.height < 4) return;
  openComposer(region);
};

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    setMode(null);
    closeComposer();
  } else if (mode === "element" && ["ArrowUp", "ArrowDown", "Enter"].includes(event.key)) {
    event.preventDefault();
    pickKey(event.key);
  } else if (event.key === "Enter" && mode === "area") {
    event.preventDefault();
    openComposer({ x: 0, y: 0, width: 1, height: 1 });
  } else if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && draft) {
    sendComment();
  }
});
$("#composer-send").onclick = sendComment;
$("#composer-cancel").onclick = closeComposer;

if (creds) {
  render();
  connect();
} else {
  $("#setup").hidden = false;
}
