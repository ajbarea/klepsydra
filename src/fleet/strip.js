// The fleet strip: a portrait per Claude Code session beside the gauge, each
// with its status badge. A click opens the card wall at that session. With no
// session the strip is the cast's keeper at rest: one button that opens the wall.
import { keeperBase } from "./cast.js";
import { castPicks, statuses, stripItems } from "./model.js";
import { showFace } from "./face.js";
import { syncChildren } from "./dom.js";

const OPEN_WALL = "Open the fleet wall";
// A plain button's mark: four cards, the wall.
const PLAIN_GLYPH = '<svg class="glyph" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 2h5v5H2zM9 2h5v5H9zM2 9h5v5H2zM9 9h5v5H9z" fill="currentColor"/></svg>';

/**
 * Draw into `el`; returns render(sessions, nowMs, fromReader, speaking). `open(id)` opens
 * the wall (`open()` with no id from the resting keeper); `cast()` is the character theme now worn.
 * Only a snapshot from the reader (`fromReader`, the default) sets
 * the baseline a pulse is judged against; a redraw of the same sessions, or of
 * none before the first snapshot, never does. `speaking` is the snapshot's
 * line: its portrait wears a gold ring.
 *
 * `dock` (#421) docks each portrait beside its account's chip: `slots()` maps
 * a chip's key to its faces container, `of(item)` names the key an item
 * belongs to (or null). An item with no slot, and the resting keeper, stay
 * in `el`. `root` takes the clicks (default `el`), as faces sit in chips.
 */
export function mountStrip(el, { open, cast, dock = null, root = el }) {
  let before;
  let heard = false; // a snapshot from the reader has come: only then is "no sessions" known
  root.addEventListener("click", (e) => {
    const face = e.target.closest(".face");
    if (face) open(face.dataset.id || undefined);
  });
  // The pulse plays once; a re-order must not replay it.
  root.addEventListener("animationend", (e) => e.target.closest(".face")?.classList.remove("pulse"));

  const make = () => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "face";
    b.append(Object.assign(document.createElement("img"), { alt: "" }), document.createElement("span"));
    return b;
  };

  // The strip with no sessions: the keeper's resting face, or a plain button when the theme has none.
  const resting = (cast) => {
    const base = keeperBase(cast);
    return {
      id: "", status: base ? "rest" : "rest-plain", quiet: false, label: OPEN_WALL, pulse: false, speaking: false,
      face: base && `${base}-96.webp`, face2x: base && `${base}-192.webp`,
      badge: base ? "" : PLAIN_GLYPH,
    };
  };

  let px = 0; // a portrait's drawn size, read once per render
  return function render(all, nowMs, fromReader = true, speaking = null) {
    const sessions = castPicks(all, cast());
    if (fromReader) heard = true;
    const items = sessions.length
      ? stripItems(sessions, cast(), nowMs, fromReader ? before : statuses(sessions), speaking)
      : heard ? [resting(cast())] : [];
    // Each container gets its own items, every render, so a face that moved
    // leaves the slot it was in and an emptied slot is cleared.
    const slots = dock ? dock.slots() : new Map();
    const groups = new Map([[el, []], ...[...slots.values()].map((s) => [s, []])]);
    for (const item of items) groups.get((item.id && dock && slots.get(dock.of(item))) || el).push(item);
    el.hidden = groups.get(el).length === 0; // index.html starts it hidden; before the first snapshot it stays so
    if (fromReader) before = statuses(sessions);
    const styles = getComputedStyle(document.documentElement);
    px = parseFloat(styles.getPropertyValue("--face-size")) * (parseFloat(styles.getPropertyValue("--scale")) || 1);
    for (const [container, group] of groups) syncChildren(container, group, (item) => item.id, make, paint);
  };

  function paint(b, item) {
    b.dataset.id = item.id;
    b.setAttribute("aria-label", item.label);
    b.title = item.label;
    b.firstChild.hidden = !item.face;
    if (item.face) showFace(b.firstChild, item.face, item.face2x, px);
    else {
      // The keeper's face leaves with the keeper.
      b.firstChild.removeAttribute("src");
      b.firstChild.srcset = "";
    }
    b.classList.toggle("rest", item.status.startsWith("rest"));
    if (b.dataset.status !== item.status || b.dataset.quiet !== String(item.quiet)) {
      b.dataset.status = item.status;
      b.dataset.quiet = String(item.quiet);
      b.lastChild.innerHTML = item.badge;
      if (item.status !== "needs_you") b.classList.remove("pulse");
    }
    if (item.pulse) b.classList.add("pulse");
    if (item.speaking) b.classList.add("speaking");
    else b.classList.remove("speaking");
  }
}
