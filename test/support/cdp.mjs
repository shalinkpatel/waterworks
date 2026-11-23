// Minimal headless-Chrome driver over the DevTools protocol, shared by the dashboard tests.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

let step = "start";
let chromeErrors = "";
setTimeout(() => {
  console.error(`watchdog: stuck at ${step}\n${chromeErrors}`);
  process.exit(2);
}, 60_000).unref();

export async function until(label, fn, timeout = 8000) {
  step = label;
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await sleep(50);
  }
}

export function api(base, who) {
  return async (method, path, body) => {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: { "content-type": "application/json", "x-ww-endpoint": who.id, authorization: `Bearer ${who.token}` },
      body: body && JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`);
    return response.json();
  };
}

export async function launch(chromePath) {
  const profile = mkdtempSync(join(tmpdir(), "ww-chrome-"));
  const chrome = spawn(chromePath, [
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  chrome.stderr.on("data", (chunk) => { chromeErrors = (chromeErrors + chunk).slice(-4000); });
  const exited = new Promise((resolve) => chrome.once("exit", resolve));
  let socket;

  const close = async () => {
    socket?.close();
    if (chrome.exitCode === null) chrome.kill();
    await exited;
    rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  };

  try {
    const port = await until("DevToolsActivePort", () => {
      if (chrome.exitCode !== null) throw new Error(`Chrome exited ${chrome.exitCode}: ${chromeErrors}`);
      try {
        return readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0];
      } catch {
        return null;
      }
    });
    const page = await until("page target", async () => {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2000) })).json();
      return targets.find((t) => t.type === "page");
    });

    socket = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      socket.onopen = resolve;
      socket.onerror = () => reject(new Error("DevTools socket failed"));
      setTimeout(() => reject(new Error("DevTools socket timed out")), 5000);
    });
  } catch (error) {
    await close();
    throw error;
  }

  let nextId = 0;
  const pending = new Map();
  const events = []; // protocol events (console, exceptions, logs) for debugging
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.method) events.push(message);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  };
  const cdp = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) =>
    (await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.value;
  const rect = (selector) =>
    evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; })()`);
  const mouse = (type, x, y, clickCount = 1) => cdp("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount });
  const click = async (selector) => {
    const r = await rect(selector);
    const [x, y] = [(r.left + r.right) / 2, (r.top + r.bottom) / 2];
    await mouse("mousePressed", x, y);
    await mouse("mouseReleased", x, y);
  };
  const KEYS = { ArrowUp: 38, ArrowDown: 40, Enter: 13 };
  const key = async (name) => {
    const params = { key: name, code: name, windowsVirtualKeyCode: KEYS[name] };
    await cdp("Input.dispatchKeyEvent", { type: "rawKeyDown", ...params });
    await cdp("Input.dispatchKeyEvent", { type: "keyUp", ...params });
  };
  const drag = async (from, to) => {
    await mouse("mousePressed", from.x, from.y);
    await mouse("mouseMoved", (from.x + to.x) / 2, (from.y + to.y) / 2);
    await mouse("mouseMoved", to.x, to.y);
    await mouse("mouseReleased", to.x, to.y);
  };

  await cdp("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  return { cdp, evaluate, rect, mouse, click, key, drag, close, events };
}
