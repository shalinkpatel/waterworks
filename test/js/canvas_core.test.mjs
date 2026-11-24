import assert from "node:assert/strict";
import test from "node:test";
import {
  applyLineOps,
  applyMessage,
  emptyState,
  intersectingPanels,
  isCleared,
  linePaths,
  MAX_DATA,
  MAX_POINTS,
  regionFromPoints,
} from "../../priv/canvas/core.js";

const msg = (sequence, type, payload, extra = {}) => ({ sequence, type, payload, from: "ep_agent", ...extra });

test("render, patch, append, remove, and reply", () => {
  let state = emptyState();
  state = applyMessage(state, msg(1, "canvas.render.v1", {
    title: "Fleet",
    panels: [
      { id: "qps", kind: "stat", title: "QPS", value: 10 },
      { id: "lat", kind: "line", title: "Latency", series: [{ name: "p50", points: [[0, 1]] }] },
      { kind: "stat" },
    ],
  }));
  assert.equal(state.title, "Fleet");
  assert.equal(state.source, "ep_agent");
  assert.deepEqual(state.panels.map((p) => p.id), ["qps", "lat"]);

  state = applyMessage(state, msg(2, "canvas.patch.v1", {
    panels: [{ id: "qps", kind: "stat", title: "QPS", value: 12 }, { id: "errs", kind: "text", text: "ok" }],
    append: [{ panel: "lat", series: "p50", points: [[1, 2]] }, { panel: "lat", series: "p99", points: [[1, 9]] }],
  }));
  assert.equal(state.panels.find((p) => p.id === "qps").value, 12);
  assert.deepEqual(state.panels.find((p) => p.id === "lat").series, [
    { name: "p50", points: [[0, 1], [1, 2]] },
    { name: "p99", points: [[1, 9]] },
  ]);

  state = applyMessage(state, msg(3, "canvas.patch.v1", { remove: ["errs"], title: "Fleet 2" }));
  assert.deepEqual(state.panels.map((p) => p.id), ["qps", "lat"]);
  assert.equal(state.title, "Fleet 2");

  state = applyMessage(state, msg(4, "canvas.reply.v1", { text: "fixed" }, { reply_to: "msg_c1" }));
  assert.deepEqual(state.replies, [{ reply_to: "msg_c1", text: "fixed", from: "ep_agent" }]);
});

test("page mode: html renders version, data streams, and resets per render", () => {
  let state = applyMessage(emptyState(), msg(1, "canvas.render.v1", { title: "Report", html: "<h1>v1</h1>" }));
  assert.equal(state.html, "<h1>v1</h1>");
  assert.equal(state.version, 1);
  assert.deepEqual(state.panels, []);

  state = applyMessage(state, msg(2, "canvas.data.v1", { qps: 1 }, { id: "d1" }));
  state = applyMessage(state, msg(3, "canvas.data.v1", { qps: 2 }, { id: "d2" }));
  assert.deepEqual(state.data, [
    { id: "d1", sequence: 2, payload: { qps: 1 } },
    { id: "d2", sequence: 3, payload: { qps: 2 } },
  ]);

  state = applyMessage(state, msg(4, "canvas.render.v1", { html: "<h1>v2</h1>" }));
  assert.equal(state.version, 2);
  assert.equal(state.title, "Report");
  assert.deepEqual(state.data, []);

  state = applyMessage(state, msg(5, "canvas.render.v1", { panels: [{ id: "a", kind: "text" }] }));
  assert.equal(state.html, null);
  assert.equal(state.version, 2);

  for (let i = 0; i < MAX_DATA + 5; i++) state = applyMessage(state, msg(10 + i, "canvas.data.v1", { i }));
  assert.equal(state.data.length, MAX_DATA);
  assert.deepEqual(state.data.at(-1).payload, { i: MAX_DATA + 4 });
});

test("line ops rebuild a page and reject ops that do not fit the base", () => {
  const base = "a\nb\nc\nd";
  assert.equal(applyLineOps(base, [{ keep: 1 }, { drop: 1 }, { insert: ["B", "B2"] }, { keep: 2 }]), "a\nB\nB2\nc\nd");
  assert.equal(applyLineOps(base, [{ drop: 4 }, { insert: [""] }]), "");
  assert.equal(applyLineOps(base, [{ keep: 3 }]), null); // leaves a line unconsumed
  assert.equal(applyLineOps(base, [{ keep: 5 }]), null); // past the end
  assert.equal(applyLineOps(base, [{ insert: [1] }, { keep: 4 }]), null);
  assert.equal(applyLineOps(base, "nope"), null);
});

test("deltas apply only to the named base revision", () => {
  let state = applyMessage(emptyState(), msg(1, "canvas.render.v1", { html: "<h1>one</h1>\n<p>x</p>" }, { id: "r1" }));
  state = applyMessage(state, msg(2, "canvas.data.v1", { v: 1 }));
  assert.equal(state.revision, "r1");

  state = applyMessage(state, msg(3, "canvas.delta.v1", { base: "r1", ops: [{ keep: 1 }, { drop: 1 }, { insert: ["<p>y</p>"] }] }, { id: "d1" }));
  assert.equal(state.html, "<h1>one</h1>\n<p>y</p>");
  assert.equal(state.version, 2);
  assert.equal(state.revision, "d1");
  assert.deepEqual(state.data, []);

  const stale = applyMessage(state, msg(4, "canvas.delta.v1", { base: "r1", ops: [{ keep: 2 }] }, { id: "d2", from: "ep_other" }));
  assert.equal(stale.html, state.html);
  assert.equal(stale.version, 2);
  assert.deepEqual(stale.stale, { id: "d2", from: "ep_other", base: "r1", expected: "d1" });

  const misfit = applyMessage(state, msg(5, "canvas.delta.v1", { base: "d1", ops: [{ keep: 9 }] }, { id: "d3" }));
  assert.equal(misfit.stale.id, "d3");
  assert.equal(misfit.revision, "d1");

  const recovered = applyMessage(misfit, msg(6, "canvas.render.v1", { html: "<h1>fresh</h1>" }, { id: "r2" }));
  assert.equal(recovered.stale, null);
  assert.equal(recovered.version, 3);
});

test("agent clears comments by id or all made before the clear", () => {
  const at = "2026-11-23T10:00:00.000Z";
  const old = { id: "c1", created_at: Date.parse(at) - 1000 };
  const named = { id: "c2", created_at: Date.parse(at) + 5000 };
  const later = { id: "c3", created_at: Date.parse(at) + 5000 };

  let state = applyMessage(emptyState(), msg(1, "canvas.clear.v1", { comments: ["c2", 7] }, { received_at: at }));
  assert.deepEqual([old, named, later].map((c) => isCleared(state, c)), [false, true, false]);

  state = applyMessage(state, msg(2, "canvas.clear.v1", { all: true }, { received_at: at }));
  assert.deepEqual([old, named, later].map((c) => isCleared(state, c)), [true, true, false]);

  // A later clear-by-id never moves the all-cutoff back.
  state = applyMessage(state, msg(3, "canvas.clear.v1", { comments: [] }, { received_at: "2020-01-01T00:00:00Z" }));
  assert.equal(isCleared(state, old), true);
});

test("duplicate and stale sequences are ignored", () => {
  let state = applyMessage(emptyState(), msg(5, "canvas.render.v1", { title: "A", panels: [] }));
  const same = applyMessage(state, msg(5, "canvas.render.v1", { title: "B", panels: [] }));
  assert.equal(same, state);
  assert.equal(applyMessage(state, msg(4, "canvas.render.v1", { title: "C" })).title, "A");
});

test("line points are bounded", () => {
  const points = Array.from({ length: MAX_POINTS + 10 }, (_, i) => [i, i]);
  let state = applyMessage(emptyState(), msg(1, "canvas.render.v1", {
    panels: [{ id: "l", kind: "line", series: [{ name: "s", points }] }],
  }));
  assert.equal(state.panels[0].series[0].points.length, MAX_POINTS);
  state = applyMessage(state, msg(2, "canvas.patch.v1", { append: [{ panel: "l", series: "s", points: [[999, 1]], max: 3 }] }));
  assert.deepEqual(state.panels[0].series[0].points, [[MAX_POINTS + 8, MAX_POINTS + 8], [MAX_POINTS + 9, MAX_POINTS + 9], [999, 1]]);
});

test("region geometry and panel intersection", () => {
  const bounds = { left: 100, top: 50, width: 200, height: 100 };
  const region = regionFromPoints({ x: 300, y: 150 }, { x: 150, y: 75 }, bounds);
  assert.deepEqual(region, { x: 0.25, y: 0.25, width: 0.75, height: 0.75 });
  assert.deepEqual(regionFromPoints({ x: 0, y: 0 }, { x: 50, y: 20 }, bounds), { x: 0, y: 0, width: 0, height: 0 });

  const rects = [
    { id: "a", title: "A", kind: "stat", x: 0, y: 0, width: 0.2, height: 0.2 },
    { id: "b", title: "B", kind: "line", x: 0.5, y: 0.5, width: 0.4, height: 0.4 },
  ];
  assert.deepEqual(intersectingPanels(region, rects), [{ id: "b", title: "B", kind: "line" }]);
});

test("line paths share bounds", () => {
  const { paths, min, max } = linePaths([{ name: "s", points: [[0, 0], [10, 10]] }], 100, 50);
  assert.equal(min, 0);
  assert.equal(max, 10);
  assert.equal(paths[0].d, "M0.0,50.0L100.0,0.0");
  assert.deepEqual(linePaths([], 10, 10), { paths: [], min: 0, max: 0 });
});
