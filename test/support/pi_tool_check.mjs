// Drives the extension's dashboard tools with a stub Pi API: open a dashboard, publish a file.
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { default: waterworks } = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/waterworks.js`).href);
const tools = new Map();
const handlers = new Map();
waterworks({ on: (name, fn) => handlers.set(name, fn), registerTool: (tool) => tools.set(tool.name, tool) });

const notices = [];
const ctx = {
  cwd: mkdtempSync(join(tmpdir(), "ww-pi-tool-")),
  sessionManager: { getSessionFile: () => null },
  ui: { notify: (text) => notices.push(text), setStatus() {} },
};
await handlers.get("session_start")({}, ctx);

const opened = await tools.get("ww_dashboard_open").execute("open", { title: "Stub dashboard" }, undefined, undefined, ctx);
const { endpoint_id } = opened.details;
const publish = (title) =>
  tools.get("ww_dashboard_publish").execute("publish", { endpoint_id, path: "page.html", ...(title ? { title } : {}) }, undefined, undefined, ctx);
writeFileSync(join(ctx.cwd, "page.html"), "<h1>from pi</h1>");
const published = await publish("Pi page");

// Republishing a large page with one changed line sends a delta.
const big = Array.from({ length: 300 }, (_, i) => `<p>row ${i}</p>`);
writeFileSync(join(ctx.cwd, "page.html"), big.join("\n"));
const fullBig = await publish();
big[150] = "<p>edited</p>";
writeFileSync(join(ctx.cwd, "page.html"), big.join("\n"));
const delta = await publish();
await handlers.get("session_shutdown")({}, ctx);

console.log(JSON.stringify({
  content: opened.content[0].text,
  details: opened.details,
  notices,
  published: published.details,
  republished: [fullBig.details.type, delta.details.type],
  expected: big.join("\n"),
}));
