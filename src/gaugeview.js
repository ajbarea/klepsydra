// The gauge's rows as DOM, shared by the desktop gauge (main.js) and the
// phone wall (fleet/wall.js), so both draw the same row the same way.
import { entryText, rampColor, ringCap, ringStyle } from "./gauge.js";

const SVG_NS = "http://www.w3.org/2000/svg";

/** The ramp's stops, from the --ramp-* tokens on `root`. */
export function readStops(root = document.documentElement) {
  const s = getComputedStyle(root);
  return {
    low: s.getPropertyValue("--ramp-low"),
    mid: s.getPropertyValue("--ramp-mid"),
    high: s.getPropertyValue("--ramp-high"),
    midAt: parseFloat(s.getPropertyValue("--ramp-mid-at")),
    highAt: parseFloat(s.getPropertyValue("--ramp-high-at")),
  };
}

/** --ramp-mode on `root`, unless `query` names one. */
export function readMode(root = document.documentElement, query = null) {
  return query || getComputedStyle(root).getPropertyValue("--ramp-mode").trim();
}

/**
 * One row: a ring, the label, a bar, the percent, and the countdown under
 * them. `spoken` adds a sentence for screen readers and hides the rest from
 * them, which read "8m" as a word.
 */
export function makeEntry(key, spoken = false) {
  const el = (tag, cls) => Object.assign(document.createElement(tag), { className: cls });
  const entry = el(spoken ? "li" : "div", "entry");
  entry.dataset.key = key;
  const row = el("div", "row");
  const ring = document.createElementNS(SVG_NS, "svg");
  ring.setAttribute("class", "ring");
  ring.setAttribute("viewBox", "0 0 24 24");
  ring.setAttribute("aria-hidden", "true");
  for (const cls of ["ring-track", "ring-fill"]) {
    const c = document.createElementNS(SVG_NS, "circle");
    c.setAttribute("class", cls);
    for (const [k, v] of [["cx", 12], ["cy", 12], ["r", 9.5], ["pathLength", 100]]) c.setAttribute(k, v);
    ring.append(c);
  }
  const track = el("span", "track");
  track.append(el("span", "fill"));
  row.append(ring, el("span", "label"), track, el("span", "pct"));
  entry.append(row, el("span", "sub"));
  if (spoken) {
    row.setAttribute("aria-hidden", "true");
    entry.querySelector(".sub").setAttribute("aria-hidden", "true");
    entry.append(el("span", "said visually-hidden"));
  }
  return entry;
}

/** Draw `row` on `entry`: its words, the bar's and the ring's fill, the ramp's colour. */
export function paintEntry(entry, row, { compact, stops, mode }) {
  const text = entryText(row, compact);
  entry.querySelector(".label").textContent = text.label;
  entry.querySelector(".pct").textContent = text.pct;
  entry.querySelector(".sub").textContent = text.sub;
  const said = entry.querySelector(".said");
  if (said) said.textContent = text.spoken;
  entry.dataset.state = row.state;

  const colour = rampColor(row.pct ?? 0, stops, mode);
  const fill = entry.querySelector(".fill");
  const clamped = Math.max(0, Math.min(100, row.pct ?? 0));
  fill.style.width = `${clamped}%`;
  // A nonzero reading stays visible as a dot instead of collapsing sub-pixel.
  fill.style.minWidth = clamped > 0 ? "calc(var(--bar-height) * var(--scale))" : "0";
  fill.style.backgroundColor = colour;

  const ring = entry.querySelector(".ring-fill");
  const style = ringStyle(row.pct, ringCap(parseFloat(getComputedStyle(ring).strokeWidth), ring.r.baseVal.value));
  ring.style.strokeDasharray = style.dasharray;
  ring.style.strokeDashoffset = style.dashoffset;
  ring.style.visibility = style.visible ? "visible" : "hidden";
  ring.style.stroke = colour;
}

/**
 * Make `container`'s entries `rows`, in order. An entry is reused by its
 * row's key, so an unchanged one keeps its transition state. Each is painted
 * once in place: a detached ring has no computed stroke width to measure.
 */
export function syncEntries(container, rows, opts, spoken = false) {
  const existing = new Map([...container.children].map((el) => [el.dataset.key, el]));
  const wanted = rows.map((row) => {
    const entry = existing.get(row.key) ?? makeEntry(row.key, spoken);
    existing.delete(row.key);
    return entry;
  });
  for (const dead of existing.values()) dead.remove();
  wanted.forEach((el, i) => {
    if (container.children[i] !== el) container.insertBefore(el, container.children[i] ?? null);
  });
  wanted.forEach((el, i) => paintEntry(el, rows[i], opts));
}
