// Pure dashboard state and geometry; app.js owns the DOM.
export const MAX_POINTS = 500;
export const MAX_DATA = 1000;

// `html` set means page mode: an agent-authored page in a sandboxed frame, `version` counts
// its renders, and `data` holds the dashboard.data.v1 payloads streamed since the last one.
// `revision` is the message id of the current page, the base a delta must name; `stale` records
// the last delta that could not apply.
export function emptyState() {
  return {
    title: "Waterworks dashboard", panels: [], html: null, version: 0, revision: null, stale: null,
    data: [], replies: [], cleared: { ids: [], before: 0 }, source: null, sequence: 0,
  };
}

// Comments live in the browser tab; the agent clears them by id, or all made before a clear.
export function isCleared(state, comment) {
  return state.cleared.ids.includes(comment.id) || (comment.created_at ?? 0) <= state.cleared.before;
}

// Line edits against a base page: {keep: n} copies n lines, {drop: n} skips n, {insert: [lines]}
// adds lines. The ops must consume the whole base; returns null when they do not fit it.
export function applyLineOps(html, ops) {
  if (!Array.isArray(ops)) return null;
  const lines = html.split("\n");
  let out = [];
  let i = 0;
  for (const op of ops) {
    if (Number.isInteger(op?.keep) && op.keep >= 0 && i + op.keep <= lines.length) {
      out = out.concat(lines.slice(i, (i += op.keep)));
    } else if (Number.isInteger(op?.drop) && op.drop >= 0 && i + op.drop <= lines.length) {
      i += op.drop;
    } else if (Array.isArray(op?.insert) && op.insert.every((line) => typeof line === "string")) {
      out = out.concat(op.insert);
    } else {
      return null;
    }
  }
  return i === lines.length ? out.join("\n") : null;
}

// Applies one mailbox message. Messages at or below the last applied sequence are
// duplicates from history replay plus pending redelivery, so they are ignored.
export function applyMessage(state, message) {
  if (message.sequence <= state.sequence) return state;
  const next = { ...state, sequence: message.sequence };
  const payload = message.payload || {};

  switch (message.type) {
    case "dashboard.render.v1": {
      const html = typeof payload.html === "string" ? payload.html : null;
      return {
        ...next,
        source: message.from,
        title: text(payload.title, next.title),
        panels: html ? [] : (payload.panels || []).filter(validPanel).map(clampPanel),
        html,
        version: html ? next.version + 1 : next.version,
        revision: html ? message.id : null,
        stale: null,
        data: [],
      };
    }

    case "dashboard.delta.v1": {
      const html = next.html !== null && payload.base === next.revision ? applyLineOps(next.html, payload.ops) : null;
      if (html === null) {
        return { ...next, stale: { id: message.id, from: message.from, base: payload.base, expected: next.revision } };
      }
      return {
        ...next,
        source: message.from,
        title: text(payload.title, next.title),
        html,
        version: next.version + 1,
        revision: message.id,
        stale: null,
        data: [],
      };
    }

    case "dashboard.data.v1":
      return {
        ...next,
        source: message.from,
        data: [...next.data, { id: message.id, sequence: message.sequence, payload }].slice(-MAX_DATA),
      };

    case "dashboard.patch.v1": {
      let panels = next.panels;
      if (Array.isArray(payload.remove)) panels = panels.filter((p) => !payload.remove.includes(p.id));
      for (const panel of (payload.panels || []).filter(validPanel)) panels = upsert(panels, clampPanel(panel));
      for (const append of payload.append || []) panels = appendPoints(panels, append);
      return {
        ...next,
        source: message.from,
        title: payload.title === undefined ? next.title : text(payload.title, next.title),
        panels,
      };
    }

    case "dashboard.clear.v1": {
      const ids = Array.isArray(payload.comments) ? payload.comments.filter((id) => typeof id === "string") : [];
      const before = payload.all === true ? Date.parse(message.received_at) || 0 : next.cleared.before;
      return { ...next, cleared: { ids: [...next.cleared.ids, ...ids], before: Math.max(before, next.cleared.before) } };
    }

    case "dashboard.reply.v1":
      return {
        ...next,
        replies: [...next.replies, { reply_to: message.reply_to, text: text(payload.text, ""), from: message.from }],
      };

    default:
      return next;
  }
}

function text(value, fallback) {
  return typeof value === "string" ? value : fallback;
}

function validPanel(panel) {
  return panel && typeof panel.id === "string" && typeof panel.kind === "string";
}

function clampPanel(panel) {
  if (panel.kind !== "line") return panel;
  return {
    ...panel,
    series: (panel.series || []).map((series) => ({
      ...series,
      points: (series.points || []).slice(-MAX_POINTS),
    })),
  };
}

function upsert(panels, panel) {
  const index = panels.findIndex((p) => p.id === panel.id);
  if (index === -1) return [...panels, panel];
  return panels.map((p, i) => (i === index ? panel : p));
}

function appendPoints(panels, { panel: id, series: name, points, max }) {
  const limit = Math.min(Number(max) || MAX_POINTS, MAX_POINTS);
  return panels.map((panel) => {
    if (panel.id !== id || panel.kind !== "line" || !Array.isArray(points)) return panel;
    const series = panel.series || [];
    const existing = series.find((s) => s.name === name);
    const updated = existing
      ? series.map((s) => (s === existing ? { ...s, points: [...s.points, ...points].slice(-limit) } : s))
      : [...series, { name, points: points.slice(-limit) }];
    return { ...panel, series: updated };
  });
}

// Converts two client points into a region expressed as fractions of the dashboard.
export function regionFromPoints(a, b, bounds) {
  const clamp = (v) => Math.min(1, Math.max(0, v));
  const x1 = clamp((Math.min(a.x, b.x) - bounds.left) / bounds.width);
  const y1 = clamp((Math.min(a.y, b.y) - bounds.top) / bounds.height);
  const x2 = clamp((Math.max(a.x, b.x) - bounds.left) / bounds.width);
  const y2 = clamp((Math.max(a.y, b.y) - bounds.top) / bounds.height);
  return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
}

// Panels whose fractional rectangles overlap the region.
export function intersectingPanels(region, panelRects) {
  return panelRects
    .filter(
      (r) =>
        r.x < region.x + region.width &&
        region.x < r.x + r.width &&
        r.y < region.y + region.height &&
        region.y < r.y + r.height,
    )
    .map(({ id, title, kind }) => ({ id, title, kind }));
}

// SVG path data for line series scaled into width x height with shared bounds.
export function linePaths(series, width, height) {
  const points = series.flatMap((s) => s.points);
  if (points.length === 0) return { paths: [], min: 0, max: 0 };
  const xs = points.map((p) => p[0]);
  const ys = points.map((p) => p[1]);
  const [xmin, xmax, ymin, ymax] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const sx = (x) => (xmax === xmin ? width / 2 : ((x - xmin) / (xmax - xmin)) * width);
  const sy = (y) => (ymax === ymin ? height / 2 : height - ((y - ymin) / (ymax - ymin)) * height);
  const paths = series.map((s) => ({
    name: s.name,
    d: s.points.map((p, i) => `${i ? "L" : "M"}${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join(""),
  }));
  return { paths, min: ymin, max: ymax };
}
