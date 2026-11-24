// Page mode (HTML reports) in real headless Chrome. The page runs in a sandboxed frame the
// test cannot see into, so every check reads what the in-frame helper put into comments.
import { api, launch, until } from "./cdp.mjs";

const { WW_URL: base, AGENT_ID, AGENT_TOKEN, CANVAS_ID, CANVAS_TOKEN, CHROME } = process.env;
const canvas = { id: CANVAS_ID, token: CANVAS_TOKEN };
const agent = api(base, { id: AGENT_ID, token: AGENT_TOKEN });
const send = async (type, payload, extra = {}) =>
  (await agent("POST", "/v1/messages", { to: canvas.id, type, payload, ...extra })).message;

const page = (heading, padding = "") => `<!doctype html>
<html><head><title>${heading}</title></head>
<body style="margin:0; font: 16px sans-serif">
  <h1 style="margin:0; height:60px">${heading}</h1>
  <h2 style="position:absolute; top:120px; left:20px; margin:0">Latency</h2>
  <p id="latency" style="position:absolute; top:200px; left:20px; margin:0; font-size:24px">waiting</p>
  <p id="isolation" style="position:absolute; top:300px; left:20px; margin:0"></p>
  <div style="height:1600px"></div>
  <script>
    let isolation = "blocked";
    try { parent.document.body; isolation = "LEAKED-document"; } catch {}
    try { if (parent.sessionStorage.length >= 0) isolation = "LEAKED-storage"; } catch {}
    document.getElementById("isolation").textContent = "isolation " + isolation;
    addEventListener("waterworks", (e) => {
      document.getElementById("latency").textContent = "latency " + e.detail.p50 + "ms";
    });
  </script>
  <!-- ${padding} -->
</body></html>`;

// One hunk between the common prefix and suffix of lines (the same op format as the publishers).
function lineDelta(oldHtml, newHtml) {
  const a = oldHtml.split("\n");
  const b = newHtml.split("\n");
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++;
  return [{ keep: start }, { drop: a.length - start - end }, { insert: b.slice(start, b.length - end) }, { keep: end }];
}

const browser = await launch(CHROME);
try {
  const { cdp, evaluate, rect, mouse, click, key, drag } = browser;

  // Render and one data message before the page opens: both must replay from history.
  await send("canvas.render.v1", { title: "Report", html: page("Report v1") });
  const early = await send("canvas.data.v1", { p50: 42 });

  await cdp("Page.navigate", { url: `${base}/canvas#${new URLSearchParams({ endpoint: canvas.id, token: canvas.token })}` });
  const settled = (sequence) =>
    until(`sequence ${sequence}`, () => evaluate(`Number(document.body.dataset.sequence) >= ${sequence}`));
  await settled(early.sequence);
  await until("frame sized by helper", () => evaluate(`document.querySelector("#page")?.offsetHeight > 1600`));
  const checks = { versionChip: await evaluate(`document.querySelector("#version").textContent === "v1"`) };

  let comments = 0;
  const comment = async (text, open) => {
    await open();
    await until("composer", () => evaluate(`document.querySelector("#composer").classList.contains("open")`));
    await cdp("Input.insertText", { text });
    await click("#composer-send");
    comments += 1;
    return until(`comment ${comments} in agent mailbox`, async () => {
      const found = (await agent("GET", `/v1/endpoints/${AGENT_ID}/history`)).messages.filter((m) => m.type === "canvas.comment.v1");
      return found.length === comments && found.at(-1);
    });
  };
  const dragTop = async () => {
    await click("#comment");
    await until("selection mode", () => evaluate(`document.querySelector("#overlay").classList.contains("active")`));
    const frame = await rect("#page");
    await drag({ x: frame.left + 5, y: frame.top + 100 }, { x: frame.left + 600, y: frame.top + 340 });
  };

  // 1: region over the latency section, with replayed data.
  const first = await comment("Why 42?", dragTop);
  const context = first.payload.context || {};
  checks.contextHeading = context.heading === "Latency";
  checks.contextReplayedData = context.text?.includes("latency 42ms");
  checks.contextIds = context.ids?.includes("latency");
  checks.sandboxIsolated = context.text?.includes("isolation blocked");
  checks.versionInComment = first.payload.canvas.version === 1;

  // 2: live data streams into the running page.
  await settled((await send("canvas.data.v1", { p50: 77 })).sequence);
  const second = await comment("Better", dragTop);
  checks.liveData = second.payload.context?.text?.includes("latency 77ms");

  // 3: a word selected inside the frame becomes the comment's anchor.
  const frame = await rect("#page");
  await mouse("mousePressed", frame.left + 40, frame.top + 212, 1);
  await mouse("mouseReleased", frame.left + 40, frame.top + 212, 1);
  await mouse("mousePressed", frame.left + 40, frame.top + 212, 2);
  await mouse("mouseReleased", frame.left + 40, frame.top + 212, 2);
  const third = await comment("This word", () => click("#comment"));
  checks.frameSelection = third.payload.selection === "latency";

  // A republished ~5 MB page replaces the frame live.
  const v2Html = page("Report v2", "x".repeat(5_000_000));
  const v2 = await send("canvas.render.v1", { html: v2Html });
  await settled(v2.sequence);
  await until("v2 chip", () => evaluate(`document.querySelector("#version").textContent === "v2"`));
  await until("v2 frame sized", () => evaluate(`document.querySelector("#page")?.offsetHeight > 1600`));

  // A delta against the 5 MB page changes one line and costs a few hundred bytes.
  const v3Html = v2Html.replace(">waiting<", ">waiting for delta<");
  const ops = lineDelta(v2Html, v3Html);
  checks.deltaIsSmall = JSON.stringify(ops).length < 2000;
  const v3 = await send("canvas.delta.v1", { base: v2.id, ops });
  await settled(v3.sequence);
  await until("v3 chip", () => evaluate(`document.querySelector("#version").textContent === "v3"`));
  await until("v3 frame sized", () => evaluate(`document.querySelector("#page")?.offsetHeight > 1600`));
  const afterDelta = await comment("Delta landed", dragTop);
  checks.deltaApplied = afterDelta.payload.context?.text?.includes("waiting for delta") && afterDelta.payload.canvas.version === 3;

  // A delta against a stale base is refused: the page stays at v3 and the sender hears why.
  const stale = await send("canvas.delta.v1", { base: v2.id, ops });
  await settled(stale.sequence);
  const errors = async () =>
    (await agent("GET", `/v1/endpoints/${AGENT_ID}/history`)).messages.filter((m) => m.type === "core.error.v1");
  const [mismatch] = await until("mismatch error", async () => (await errors()).length === 1 && errors());
  checks.mismatchReported = mismatch.reply_to === stale.id && mismatch.payload.error === "delta_base_mismatch" &&
    mismatch.payload.expected === v3.id;
  checks.staleShown = await evaluate(`document.querySelector("#version").textContent === "v3 · missed an update"`);

  // Reload replays render, render, delta, and the stale delta; markers persist in tab storage.
  await cdp("Page.reload");
  await until("v3 after reload", () =>
    evaluate(`document.querySelector("#version").textContent.startsWith("v3") && document.querySelectorAll("[data-comment]").length === 4`),
  );
  await until("frame sized after reload", () => evaluate(`document.querySelector("#page")?.offsetHeight > 1600`));
  const fourth = await comment("After reload", dragTop);
  checks.reloadRebuilt = fourth.payload.context?.text?.includes("waiting for delta") && fourth.payload.canvas.version === 3;
  checks.mismatchNotDuplicated = (await errors()).length === 1;

  // Element picker inside the sandboxed frame; the marker follows the element when a delta moves it.
  const pickLatency = async () => {
    await click("#pick");
    await until("pick mode", () => evaluate(`document.querySelector("#pick").getAttribute("aria-pressed") === "true"`));
    const f = await rect("#page");
    const [x, y] = [f.left + 40, f.top + 212];
    await mouse("mouseMoved", x, y);
    await key("Enter"); // focus is in the host; it forwards picker keys into the frame
    await until("composer", () => evaluate(`document.querySelector("#composer").classList.contains("open")`));
    checks.frameDraftShown = await evaluate(`document.querySelector("#draft-region")?.classList.contains("draft")`);
  };
  const picked = await comment("Make this bigger", pickLatency);
  const element = picked.payload.element || {};
  checks.frameElement = element.id === "latency" && element.selector === "#latency" && element.text === "waiting for delta";
  checks.frameElementContext = picked.payload.context?.heading === "Latency";
  const markerTop = async () => (await rect(`[data-comment="${picked.id}"]`)).top - (await rect("#page")).top;
  checks.frameMarkerOnElement = Math.abs((await markerTop()) - 200) < 4;

  const v4 = await send("canvas.delta.v1", { base: v3.id, ops: lineDelta(v3Html, v3Html.replace("top:200px", "top:420px")) });
  await settled(v4.sequence);
  await until("v4 chip", () => evaluate(`document.querySelector("#version").textContent === "v4"`));
  await until("frame marker follows the element", async () => Math.abs((await markerTop()) - 420) < 4);
  checks.frameMarkerFollows = true;

  await send("canvas.clear.v1", { all: true });
  await until("agent cleared all", () =>
    evaluate(`document.querySelectorAll(".region.placed").length === 0 && document.querySelectorAll(".comment.cleared").length === 6`),
  );
  checks.agentClearedAll = true;

  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([name]) => name);
  console.log(JSON.stringify({ checks, failed, first: first.payload.context, third: third.payload.selection }));
  process.exitCode = failed.length ? 1 : 0;
} finally {
  await browser.close();
}
