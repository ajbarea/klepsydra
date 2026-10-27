// The fleet strip: a portrait per Claude Code session beside the gauge, each
// with its status badge. A click opens the card wall at that session.
import { statuses, stripItems } from "./model.js";
import { showFace } from "./face.js";
import { syncChildren } from "./dom.js";

/**
 * Draw into `el`; returns render(sessions, nowMs, fromReader, speaking). `open(id)` opens
 * the wall; `cast()` is the character theme now worn. Only a snapshot from the reader (`fromReader`, the default) sets
 * the baseline a pulse is judged against; a redraw of the same sessions, or of
 * none before the first snapshot, never does. `speaking` is the snapshot's
 * line: its portrait wears a gold ring.
 */
export function mountStrip(el, { open, cast }) {
  let before;
  el.addEventListener("click", (e) => {
    const face = e.target.closest(".face");
    if (face) open(face.dataset.id);
  });
  // The pulse plays once; a re-order must not replay it.
  el.addEventListener("animationend", (e) => e.target.closest(".face")?.classList.remove("pulse"));

  const make = () => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "face";
    b.append(Object.assign(document.createElement("img"), { alt: "" }), document.createElement("span"));
    return b;
  };

  return function render(sessions, nowMs, fromReader = true, speaking = null) {
    const items = stripItems(sessions, cast(), nowMs, fromReader ? before : statuses(sessions), speaking);
    if (fromReader) before = statuses(sessions);
    el.hidden = items.length === 0;
    const root = getComputedStyle(document.documentElement);
    const px = parseFloat(root.getPropertyValue("--face-size")) * (parseFloat(root.getPropertyValue("--scale")) || 1);
    syncChildren(el, items, (item) => item.id, make, (b, item) => {
      b.dataset.id = item.id;
      b.setAttribute("aria-label", item.label);
      b.title = item.label;
      showFace(b.firstChild, item.face, item.face2x, px);
      if (b.dataset.status !== item.status || b.dataset.quiet !== String(item.quiet)) {
        b.dataset.status = item.status;
        b.dataset.quiet = String(item.quiet);
        b.lastChild.innerHTML = item.badge;
        if (item.status !== "needs_you") b.classList.remove("pulse");
      }
      if (item.pulse) b.classList.add("pulse");
      if (item.speaking) b.classList.add("speaking");
      else b.classList.remove("speaking");
    });
  };
}
