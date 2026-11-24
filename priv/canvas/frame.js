// Loads an agent page into this sandboxed frame (opaque origin, see the frame's CSP), then the
// helper, which reports size, inspects regions, and delivers streamed data.
function onRender(event) {
  if (event.source !== parent || event.data?.source !== "waterworks-host" || event.data.kind !== "render") return;
  removeEventListener("message", onRender);
  const helper = new URL("/canvas/helper.js", location.href);
  document.open();
  document.write(event.data.html);
  document.write(`<script src="${helper}"><\/script>`);
  document.close();
}
addEventListener("message", onRender);
parent.postMessage({ source: "waterworks-frame", kind: "ready" }, "*");
