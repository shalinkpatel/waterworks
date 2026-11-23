// Panel mode in real headless Chrome: history render, live patches, a region comment, a reply, reload.
import { api, launch, until } from "./cdp.mjs";

const { WW_URL: base, AGENT_ID, AGENT_TOKEN, DASH_ID, DASH_TOKEN, CHROME } = process.env;
const dash = { id: DASH_ID, token: DASH_TOKEN };
const agent = api(base, { id: AGENT_ID, token: AGENT_TOKEN });
const send = (type, payload, extra = {}) => agent("POST", "/v1/messages", { to: dash.id, type, payload, ...extra });

// Sent before the page exists, so the page must rebuild it from history.
await send("dashboard.render.v1", {
  title: "Fleet health",
  panels: [
    { id: "qps", kind: "stat", title: "QPS", value: 1200, unit: "req/s" },
    { id: "lat", kind: "line", title: "Latency", series: [{ name: "p50", points: [[0, 10], [1, 12]] }] },
    { id: "xss", kind: "text", title: "Notes", text: "<img src=x onerror=alert(1)>" },
  ],
});

const browser = await launch(CHROME);
try {
  const { cdp, evaluate, rect, mouse, click, key, drag } = browser;
  await cdp("Page.navigate", { url: `${base}/dashboard#${new URLSearchParams({ endpoint: dash.id, token: dash.token })}` });

  await until("history render", () => evaluate(`document.querySelector('[data-panel="qps"] .value')?.textContent === "1,200 req/s"`));
  await until("live socket", () => evaluate(`document.querySelector("#status").textContent === "live"`));
  const checks = {
    fragmentStripped: await evaluate("location.hash === ''"),
    noInjectedHtml: await evaluate(`document.querySelectorAll("#panels img").length === 0`),
  };

  await send("dashboard.patch.v1", {
    panels: [{ id: "qps", kind: "stat", title: "QPS", value: 1500, unit: "req/s" }],
    append: [{ panel: "lat", series: "p50", points: [[2, 30]] }],
  });
  await until("live patch", () => evaluate(`document.querySelector('[data-panel="qps"] .value').textContent === "1,500 req/s"`));
  await until("live append", () => evaluate(`document.querySelector('[data-panel="lat"] .legend').textContent.includes("p50: 30")`));

  // A malformed panel or patch must not break the page or the messages after it.
  await send("dashboard.patch.v1", { panels: [{ id: "bad", kind: "line", title: "Bad", series: "nope" }] });
  await send("dashboard.patch.v1", { panels: [{ id: "bars", kind: "bar", title: "Bars", bars: 7 }] });
  await send("dashboard.patch.v1", { remove: ["bad", "bars"], panels: [{ id: "after", kind: "text", title: "After", text: "still live" }] });
  await until("survives malformed panels", () => evaluate(`document.querySelector('[data-panel="after"] p')?.textContent === "still live"`));
  await send("dashboard.patch.v1", { remove: ["after"] });
  await until("cleanup", () => evaluate(`!document.querySelector('[data-panel="after"]')`));
  checks.survivesMalformed = true;

  await click("#comment");
  await until("selection mode", () => evaluate(`document.querySelector("#overlay").classList.contains("active")`));
  const qps = await rect('[data-panel="qps"]');
  await drag({ x: qps.left + 8, y: qps.top + 8 }, { x: qps.right - 8, y: qps.bottom - 8 });
  await until("composer", () => evaluate(`document.querySelector("#composer").classList.contains("open")`));
  await cdp("Input.insertText", { text: "This spike looks wrong" });
  await click("#composer-send");
  await until("comment accepted", () => evaluate(`document.querySelector("#comments").textContent.includes("sent")`));

  const comment = await until("comment in agent mailbox", async () =>
    (await agent("GET", `/v1/endpoints/${AGENT_ID}/history`)).messages.find((m) => m.type === "dashboard.comment.v1"),
  );
  checks.commentFromDashboard = comment.from === dash.id;
  checks.commentText = comment.payload.text === "This spike looks wrong";
  checks.commentPanels = JSON.stringify(comment.payload.panels.map((p) => p.id)) === '["qps"]';
  checks.commentRegion = comment.payload.region.width > 0 && comment.payload.region.height > 0;

  await send("dashboard.reply.v1", { text: "Smoothed with a 5m window" }, { reply_to: comment.id });
  await until("reply shown", () => evaluate(`document.querySelector("#comments .reply")?.textContent === "Smoothed with a 5m window"`));

  await cdp("Page.reload");
  await until("rebuilt after reload", () =>
    evaluate(`document.querySelector('[data-panel="qps"] .value')?.textContent === "1,500 req/s" &&
      document.querySelector("#comments .reply")?.textContent === "Smoothed with a 5m window" &&
      document.querySelectorAll("[data-comment]").length === 1`),
  );
  checks.reloadRebuilt = true;
  checks.areaMarkerHatched = await evaluate(`document.querySelectorAll(".region.placed").length === 1`);

  // Element picker: hover outlines, a click captures; the selection stays solid while writing,
  // even through live updates, then remains as a hatched marker that follows its element.
  await click("#pick");
  await until("pick mode", () => evaluate(`document.querySelector("#pick").getAttribute("aria-pressed") === "true"`));
  const legend = await rect('[data-panel="lat"] .legend');
  const target = { x: legend.left + 4, y: (legend.top + legend.bottom) / 2 };
  await mouse("mouseMoved", target.x, target.y);
  await until("hover outline", () => evaluate(`Boolean(document.querySelector("#hover-region"))`));
  const outlineWidth = () => evaluate(`document.querySelector("#hover-region").getBoundingClientRect().width`);
  const spanWidth = await outlineWidth();
  await key("ArrowUp"); // widen from the legend entry to the whole legend
  checks.arrowUpWidens = (await outlineWidth()) > spanWidth;
  await mouse("mousePressed", target.x, target.y);
  await mouse("mouseReleased", target.x, target.y);
  await until("composer", () => evaluate(`document.querySelector("#composer").classList.contains("open")`));
  checks.draftShown = await evaluate(`document.querySelector("#draft-region")?.classList.contains("draft")`);
  await send("dashboard.patch.v1", { panels: [{ id: "qps", kind: "stat", title: "QPS", value: 1600, unit: "req/s" }] });
  await until("live update while composing", () => evaluate(`document.querySelector('[data-panel="qps"] .value').textContent === "1,600 req/s"`));
  checks.draftSurvivesLiveUpdate = await evaluate(`Boolean(document.querySelector("#draft-region.draft"))`);
  await cdp("Input.insertText", { text: "Label the series" });
  await click("#composer-send");

  const picked = await until("element comment in agent mailbox", async () =>
    (await agent("GET", `/v1/endpoints/${AGENT_ID}/history`)).messages.filter((m) => m.type === "dashboard.comment.v1")[1],
  );
  const element = picked.payload.element || {};
  checks.elementPanel = element.panel === "lat" && element.selector?.startsWith('[data-panel="lat"]');
  checks.elementText = element.text?.includes("p50");
  checks.clickPicksWidened = element.classes === "legend";
  await until("hatched element marker", () => evaluate(`document.querySelectorAll(".region.placed").length === 2 && !document.querySelector("#draft-region")`));

  const markerOnElement = `(() => {
    const m = document.querySelector('[data-comment="${picked.id}"]')?.getBoundingClientRect();
    const e = document.querySelector("#panels").querySelector(${JSON.stringify(element.selector)})?.getBoundingClientRect();
    return Boolean(m && e) && Math.abs(m.left - e.left) < 3 && Math.abs(m.top - e.top) < 3;
  })()`;
  checks.markerOnElement = await evaluate(markerOnElement);
  const before = await rect(`[data-comment="${picked.id}"]`);
  await send("dashboard.patch.v1", { remove: ["qps"] }); // the latency panel shifts into the first slot
  await until("marker follows its element", async () =>
    (await evaluate(markerOnElement)) && Math.abs((await rect(`[data-comment="${picked.id}"]`)).left - before.left) > 50,
  );
  checks.markerFollowsElement = true;

  await send("dashboard.clear.v1", { comments: [picked.id] });
  await until("agent cleared the comment", () =>
    evaluate(`!document.querySelector('[data-comment="${picked.id}"]') && document.querySelectorAll(".region.placed").length === 1 &&
      document.querySelector("#comments").textContent.includes("cleared by agent")`),
  );
  checks.agentCleared = true;

  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([name]) => name);
  console.log(JSON.stringify({ checks, failed }));
  process.exitCode = failed.length ? 1 : 0;
} finally {
  await browser.close();
}
