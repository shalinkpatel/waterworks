// Runs inside the agent page after its own scripts. Pages receive streamed data as
// `addEventListener("waterworks", (event) => event.detail)`.
(() => {
  const post = (data) => parent.postMessage({ source: "waterworks-frame", ...data }, "*");
  const root = document.documentElement;
  const size = () => post({ kind: "size", height: Math.max(root.scrollHeight, document.body?.scrollHeight || 0) });
  new ResizeObserver(size).observe(root);
  addEventListener("load", size);
  size();

  addEventListener("message", (event) => {
    if (event.source !== parent || event.data?.source !== "waterworks-host") return;
    const { kind, request } = event.data;
    if (kind === "data") {
      dispatchEvent(new CustomEvent("waterworks", { detail: event.data.payload }));
    } else if (kind === "inspect") {
      post({ kind: "inspected", request, ...inspect(event.data.rect) });
    } else if (kind === "pick") {
      setPicking(event.data.on);
    } else if (kind === "pick-key") {
      pickKey(event.data.key);
    } else if (kind === "locate") {
      const rects = {};
      for (const [id, selector] of Object.entries(event.data.selectors)) {
        let element = null;
        try {
          element = document.querySelector(selector);
        } catch {}
        rects[id] = element ? docRect(element) : null;
      }
      post({ kind: "located", request, rects });
    }
  });

  const docRect = (element) => {
    const r = element.getBoundingClientRect();
    return { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height };
  };

  // A selector that finds the element again after republishes: an id, or tag:nth-of-type steps.
  function cssPath(element) {
    const parts = [];
    for (let node = element; node && node !== document.body; node = node.parentElement) {
      if (node.id) {
        parts.unshift(`#${CSS.escape(node.id)}`);
        return parts.join(" > ");
      }
      const tag = node.tagName.toLowerCase();
      const same = [...node.parentElement.children].filter((child) => child.tagName === node.tagName);
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
    }
    return ["body", ...parts].join(" > ");
  }

  const describe = (element) => ({
    selector: cssPath(element),
    tag: element.tagName.toLowerCase(),
    id: element.id || "",
    classes: typeof element.className === "string" ? element.className : "",
    text: (element.innerText ?? element.textContent ?? "").trim().replace(/\s+/g, " ").slice(0, 300),
  });

  // Element picker: outline what the pointer is over; ArrowUp/ArrowDown widen or narrow the
  // outline; a click or Enter captures the outlined element instead of acting.
  let picking = false;
  let outline = null;
  let hovered = null;
  let narrower = []; // elements ArrowUp left, for ArrowDown
  function setPicking(on) {
    picking = on;
    outline?.remove();
    outline = null;
    hovered = null;
    narrower = [];
    root.style.cursor = on ? "crosshair" : "";
    if (!on) return;
    outline = document.createElement("div");
    Object.assign(outline.style, {
      position: "absolute", pointerEvents: "none", zIndex: "2147483647", display: "none",
      border: "2px solid #2f7de1", background: "rgba(47, 125, 225, 0.15)", borderRadius: "3px",
    });
    document.body.append(outline);
  }
  const pickable = (target) => target instanceof Element && target !== outline && target !== root && target !== document.body;
  function hover(element) {
    hovered = element;
    const r = docRect(element);
    Object.assign(outline.style, { display: "block", left: `${r.x}px`, top: `${r.y}px`, width: `${r.width}px`, height: `${r.height}px` });
  }
  function pick(element) {
    setPicking(false);
    const rect = docRect(element);
    post({ kind: "picked", element: describe(element), ...inspect(rect) });
  }
  function pickKey(key) {
    if (!picking || !hovered) return;
    if (key === "ArrowUp" && pickable(hovered.parentElement)) {
      narrower.push(hovered);
      hover(hovered.parentElement);
    } else if (key === "ArrowDown" && narrower.length) {
      hover(narrower.pop());
    } else if (key === "Enter") {
      pick(hovered);
    }
  }
  addEventListener("mouseover", (event) => {
    if (!picking || !pickable(event.target)) return;
    narrower = [];
    hover(event.target);
  }, true);
  for (const type of ["pointerdown", "mousedown", "mouseup"]) {
    addEventListener(type, (event) => picking && (event.preventDefault(), event.stopPropagation()), true);
  }
  addEventListener("click", (event) => {
    if (!picking) return;
    event.preventDefault();
    event.stopPropagation();
    if (hovered?.contains(event.target)) pick(hovered); // what is outlined, possibly widened
    else if (pickable(event.target)) pick(event.target);
  }, true);
  addEventListener("keydown", (event) => {
    if (!picking) return;
    if (event.key === "Escape") {
      setPicking(false);
      post({ kind: "pick-cancelled" });
    } else if (["ArrowUp", "ArrowDown", "Enter"].includes(event.key)) {
      event.preventDefault();
      pickKey(event.key);
    }
  }, true);

  // What lies under a rect (document pixels): the section heading, visible text, and element
  // ids. With no rect, the current text selection supplies it.
  function inspect(rect) {
    const selection = getSelection();
    const selected = selection && !selection.isCollapsed ? selection.toString() : "";
    if (!rect && selected) {
      const r = selection.getRangeAt(0).getBoundingClientRect();
      rect = { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height };
    }
    if (!rect) return { rect: null, selection: "" };

    const hit = (r) =>
      r.width > 0 && r.height > 0 &&
      r.left + scrollX < rect.x + rect.width && rect.x < r.right + scrollX &&
      r.top + scrollY < rect.y + rect.height && rect.y < r.bottom + scrollY;

    const texts = [];
    let length = 0;
    const range = document.createRange();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node; (node = walker.nextNode()) && length < 2000; ) {
      const value = node.textContent.trim();
      if (!value || node.parentElement.closest("script, style")) continue;
      range.selectNodeContents(node);
      if ([...range.getClientRects()].some(hit)) {
        texts.push(value);
        length += value.length;
      }
    }

    let heading = "";
    for (const h of document.querySelectorAll("h1, h2, h3, h4")) {
      if (h.getBoundingClientRect().top + scrollY <= rect.y + rect.height) heading = h.textContent.trim();
    }

    const ids = [...document.querySelectorAll("[id]")]
      .filter((element) => element !== outline && hit(element.getBoundingClientRect()))
      .map((element) => element.id)
      .slice(0, 20);

    return { rect, selection: selected, heading, text: texts.join(" ").slice(0, 2000), ids };
  }
})();
