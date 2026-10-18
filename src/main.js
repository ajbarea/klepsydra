import { rampColor, toRows, formatPct } from "./gauge.js";
import { wheelPixels, wheelStep, clampLevel, scaleAt } from "./zoom.js";

const POLL_MS = 5_000;   // how often we re-read the account files
const TICK_MS = 15_000;  // how often the countdown re-renders between reads
const ZOOM_SHOWN_MS = 800;   // how long the new size stays on screen
const ZOOM_SAVE_MS = 400;    // settle time before the size is written to disk

const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

if (new URLSearchParams(location.search).has("still")) {
  document.documentElement.dataset.still = "";
}

// Harness only: pin the panel width so captures do not depend on how the
// headless browser interprets --window-size.
const forcedWidth = new URLSearchParams(location.search).get("w");
if (forcedWidth) {
  document.documentElement.style.setProperty("--panel-width-base", `${parseInt(forcedWidth, 10)}px`);
}

function stops() {
  const s = getComputedStyle(document.documentElement);
  return {
    low: s.getPropertyValue("--ramp-low"),
    mid: s.getPropertyValue("--ramp-mid"),
    high: s.getPropertyValue("--ramp-high"),
    midAt: parseFloat(s.getPropertyValue("--ramp-mid-at")),
    highAt: parseFloat(s.getPropertyValue("--ramp-high-at")),
  };
}

function rampMode() {
  const q = new URLSearchParams(location.search).get("mode");
  if (q) return q;
  return getComputedStyle(document.documentElement).getPropertyValue("--ramp-mode").trim();
}

/** Reading the files is the only thing that differs between app and browser. */
async function readUsage() {
  try {
    if (inTauri) return await window.__TAURI__.core.invoke("read_usage");
    // Browser dev: serve src/ with a dev-fixture.json holding the same shape.
    const res = await fetch("./dev-fixture.json", { cache: "no-store" });
    return res.ok ? await res.json() : null;
  } catch {
    return null; // missing, unreadable or malformed all mean "no data"
  }
}

const panel = document.getElementById("panel");
const rowsEl = document.getElementById("rows");
const emptyEl = document.getElementById("empty");
const tpl = document.getElementById("row-tpl");
const grip = document.getElementById("grip");
const zoomEl = document.getElementById("zoom");

let lastPayload = null;
let lastSize = "";
let lastGrip = "";
let lastTray = "";
let zoomLevel = 0;
let wheel = null;
let zoomShown = 0;
let zoomSave = 0;

function paint(entry, row) {
  entry.querySelector(".label").textContent = row.label;
  entry.querySelector(".pct").textContent = formatPct(row.pct);
  entry.querySelector(".sub").textContent = row.sub;
  entry.dataset.state = row.state;

  const fill = entry.querySelector(".fill");
  const clamped = Math.max(0, Math.min(100, row.pct ?? 0));
  fill.style.width = `${clamped}%`;
  // A nonzero reading stays visible as a dot instead of collapsing sub-pixel.
  fill.style.minWidth = clamped > 0 ? "calc(var(--bar-height) * var(--scale))" : "0";
  fill.style.backgroundColor = rampColor(row.pct ?? 0, stops(), rampMode());
}

/** The grab handle's rectangle, in CSS pixels from the window's top-left. */
function gripRect() {
  const r = grip.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height];
}

/**
 * Tell the window how big the panel is, so it never clips or gaps. `pin` marks
 * a zoom, which keeps the point under the pointer still. The grip's new
 * rectangle travels with the size, so the pointer watcher never pairs a new
 * position with an old grip.
 */
function syncSize(pin = false) {
  if (!inTauri) return;
  const r = panel.getBoundingClientRect();
  const w = Math.ceil(r.width);
  const h = Math.ceil(r.height);
  const size = `${w}x${h}`;
  if (w < 1 || h < 1 || (size === lastSize && !pin)) return;
  lastSize = size;
  const g = gripRect();
  lastGrip = g.join(",");
  window.__TAURI__.core
    .invoke("set_size", { width: w, height: h, pin, grip: g })
    .catch(() => {
      lastSize = ""; // not applied; the next render tries again
    });
}

/**
 * Mirror the primary reading onto the tray icon, so the level is readable when
 * the overlay is covered or a fullscreen app is in front.
 *
 * The ramp lives in CSS, so rather than reimplement it, read back the colour
 * the browser actually computed -- that resolves `color-mix` for free.
 */
function syncTray(rows) {
  if (!inTauri) return;
  const pct = rows[0]?.pct ?? 0;
  let rgb = [110, 110, 110];
  const probe = rowsEl.querySelector(".fill");
  if (probe) {
    const m = getComputedStyle(probe).backgroundColor.match(/\d+/g);
    if (m && m.length >= 3) rgb = m.slice(0, 3).map(Number);
  }
  const signature = `${Math.round(pct)}|${rgb.join(",")}`;
  if (signature === lastTray) return; // redraw only when it would look different
  lastTray = signature;
  window.__TAURI__.core
    .invoke("set_tray_level", { pct, r: rgb[0], g: rgb[1], b: rgb[2] })
    .catch(() => {});
}

/**
 * Report where the grab handle sits. The backend cannot know the layout, and
 * hard-coding it here would silently desync the moment the CSS changes.
 */
function syncGrip() {
  if (!inTauri) return;
  const [x, y, w, h] = gripRect();
  const key = [x, y, w, h].join(",");
  if (w < 1 || h < 1 || key === lastGrip) return;
  lastGrip = key;
  window.__TAURI__.core.invoke("set_grip", { x, y, w, h }).catch(() => {
    lastGrip = "";
  });
}

function render(pin = false) {
  const rows = toRows(lastPayload, Date.now());

  emptyEl.hidden = rows.length > 0;
  panel.dataset.state = rows.length === 0 ? "waiting" : "live";

  // Reuse entries by key so an unchanged row keeps its transition state.
  const existing = new Map(
    [...rowsEl.children].map((el) => [el.dataset.key, el]),
  );
  const wanted = [];
  for (const row of rows) {
    let entry = existing.get(row.key);
    if (entry) existing.delete(row.key);
    else {
      entry = tpl.content.firstElementChild.cloneNode(true);
      entry.dataset.key = row.key;
    }
    paint(entry, row);
    wanted.push(entry);
  }
  for (const dead of existing.values()) dead.remove();
  wanted.forEach((el, i) => {
    if (rowsEl.children[i] !== el) rowsEl.insertBefore(el, rowsEl.children[i] ?? null);
  });

  document.title = rows.length ? `klepsydra ${formatPct(rows[0].pct)}` : "klepsydra";
  syncTray(rows);
  syncSize(pin);
  syncGrip();
}

function applyZoom() {
  document.documentElement.style.setProperty("--scale", String(scaleAt(zoomLevel)));
}

/** The harness pins a level with ?zoom=; the app keeps the last one on disk. */
async function savedZoom() {
  const q = new URLSearchParams(location.search).get("zoom");
  if (q !== null) return clampLevel(Number(q));
  if (!inTauri) return 0;
  try {
    return clampLevel(await window.__TAURI__.core.invoke("get_zoom"));
  } catch {
    return 0;
  }
}

function showZoom() {
  zoomEl.textContent = `${Math.round(scaleAt(zoomLevel) * 100)}%`;
  zoomEl.classList.add("on");
  clearTimeout(zoomShown);
  zoomShown = setTimeout(() => zoomEl.classList.remove("on"), ZOOM_SHOWN_MS);
}

// Scrolling on the grip resizes the whole gauge. The grip is the one part of
// the window that takes the mouse, so the wheel elsewhere still reaches
// whatever is underneath.
grip.addEventListener("wheel", (e) => {
  e.preventDefault();
  const r = wheelStep(wheel, wheelPixels(e.deltaY, e.deltaMode), performance.now());
  wheel = r.state;
  const next = clampLevel(zoomLevel + r.steps);
  if (next === zoomLevel) return;
  zoomLevel = next;
  applyZoom();
  showZoom();
  render(true);
  if (inTauri) {
    clearTimeout(zoomSave);
    zoomSave = setTimeout(() => {
      window.__TAURI__.core.invoke("set_zoom", { level: zoomLevel }).catch(() => {});
    }, ZOOM_SAVE_MS);
  }
}, { passive: false });

async function poll() {
  lastPayload = await readUsage();
  render();
}

// Exposed so the visual-check harness can drive states without live files.
window.__klepsydra = { set(p) { lastPayload = p; render(); } };

zoomLevel = await savedZoom();
applyZoom();
poll();
setInterval(poll, POLL_MS);
setInterval(render, TICK_MS);
