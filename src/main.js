import { toRows, formatPct, WAITING } from "./gauge.js";
import { readMode, readStops, syncEntries } from "./gaugeview.js";
import { follow } from "./ipc.js";
import { wheelPixels, wheelStep, clampLevel, scaleAt } from "./zoom.js";

const POLL_MS = 5_000;   // how often we re-read the account files
const TICK_MS = 15_000;  // how often the countdown re-renders between reads
const ZOOM_SHOWN_MS = 800;   // how long the new size stays on screen
const ZOOM_SAVE_MS = 400;    // settle time before the size is written to disk
const LAYOUT_WAIT_MS = 500;  // longest the first draw waits for the saved layout

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

const frame = document.getElementById("frame");
const panel = document.getElementById("panel");
const stripEl = document.getElementById("strip");
const rowsEl = document.getElementById("rows");
const emptyEl = document.getElementById("empty");
emptyEl.textContent = WAITING;
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
let pendingZoom = null; // {level, layout} waiting out ZOOM_SAVE_MS
let fleetSessions = [];
let fleetSpeaking = null; // keryx's line, from the same snapshot
let drawStrip = null;
let fleetFresh = false; // a snapshot the strip has not drawn yet
let layout = null; // "compact" or "full" once known
let layoutSeq = 0; // the latest layout change; an older one still loading gives way
let started = false; // the first draw waits for the layout

const compact = () => layout === "compact";

/**
 * "compact" draws rings in one row; anything else is the full layout. Each
 * layout keeps its own zoom, read before the switch so it draws once.
 */
async function applyLayout(next) {
  const want = next === "compact" ? "compact" : "full";
  const seq = ++layoutSeq;
  if (want === layout) return;
  saveZoomNow();
  const level = await savedZoom(want);
  if (seq !== layoutSeq) return;
  layout = want;
  document.documentElement.dataset.layout = want;
  zoomLevel = level;
  applyZoom();
  if (started) render();
}

/**
 * The harness pins a layout with ?layout=; the app follows the tray. Resolves
 * once the first layout is in, or after LAYOUT_WAIT_MS, so a compact gauge
 * does not open tall for a moment.
 */
function followLayout() {
  const q = new URLSearchParams(location.search).get("layout");
  if (q !== null || !inTauri) return applyLayout(q);
  return new Promise((resolve) => {
    follow("layout_subscribe", (next) => applyLayout(next).then(resolve)).catch(resolve);
    setTimeout(resolve, LAYOUT_WAIT_MS);
  });
}

const rectOf = (el) => {
  const r = el.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height];
};
/** The grab handle's rectangle, in CSS pixels from the window's top-left. */
const gripRect = () => rectOf(grip);
/** The fleet strip's rectangle, or null while it is hidden. */
const stripRect = () => (stripEl.hidden ? null : rectOf(stripEl));

/**
 * Tell the window how big the gauge and strip are, so it never clips or gaps.
 * `pin` marks a zoom, which keeps the point under the pointer still. The
 * grip's and strip's new rectangles travel with the size, so the pointer
 * watcher never pairs a new position with an old hit area.
 */
function syncSize(pin = false) {
  if (!inTauri) return;
  const r = frame.getBoundingClientRect();
  const w = Math.ceil(r.width);
  const h = Math.ceil(r.height);
  const size = `${w}x${h}`;
  if (w < 1 || h < 1 || (size === lastSize && !pin)) return;
  lastSize = size;
  const g = gripRect();
  const strip = stripRect();
  lastGrip = `${g.join(",")}|${strip ?? ""}`;
  window.__TAURI__.core
    .invoke("set_size", { width: w, height: h, pin, grip: g, strip })
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
 * Report where the grab handle and the strip sit. The backend cannot know the
 * layout, and hard-coding it here would silently desync the moment the CSS
 * changes.
 */
function syncGrip() {
  if (!inTauri) return;
  const [x, y, w, h] = gripRect();
  const strip = stripRect();
  const key = `${[x, y, w, h].join(",")}|${strip ?? ""}`;
  if (w < 1 || h < 1 || key === lastGrip) return;
  lastGrip = key;
  window.__TAURI__.core.invoke("set_grip", { x, y, w, h, strip }).catch(() => {
    lastGrip = "";
  });
}

function render(pin = false) {
  const rows = toRows(lastPayload, Date.now());

  emptyEl.hidden = rows.length > 0;
  panel.dataset.state = rows.length === 0 ? "waiting" : "live";

  syncEntries(rowsEl, rows, {
    compact: compact(),
    stops: readStops(),
    mode: readMode(document.documentElement, new URLSearchParams(location.search).get("mode")),
  });

  document.title = rows.length ? `klepsydra ${formatPct(rows[0].pct)}` : "klepsydra";
  try {
    drawStrip?.(fleetSessions, Date.now(), fleetFresh, fleetSpeaking);
  } catch {
    drawStrip = null; // the gauge carries on without the strip
    stripEl.hidden = true;
  }
  fleetFresh = false;
  syncTray(rows);
  syncSize(pin);
  syncGrip();
}

function applyZoom() {
  document.documentElement.style.setProperty("--scale", String(scaleAt(zoomLevel)));
}

/** The harness pins a level with ?zoom=; the app keeps each layout's on disk. */
async function savedZoom(forLayout) {
  const q = new URLSearchParams(location.search).get("zoom");
  if (q !== null) return clampLevel(Number(q));
  if (!inTauri) return 0;
  try {
    return clampLevel(await window.__TAURI__.core.invoke("get_zoom", { layout: forLayout }));
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
/** Write a zoom still waiting out its settle time, before anything reads it. */
function saveZoomNow() {
  clearTimeout(zoomSave);
  if (pendingZoom && inTauri) {
    window.__TAURI__.core.invoke("set_zoom", pendingZoom).catch(() => {});
  }
  pendingZoom = null;
}

grip.addEventListener("wheel", (e) => {
  e.preventDefault();
  if (layout === null) return; // a zoom is saved per layout, so wait for it
  const r = wheelStep(wheel, wheelPixels(e.deltaY, e.deltaMode), performance.now());
  wheel = r.state;
  const next = clampLevel(zoomLevel + r.steps);
  if (next === zoomLevel) return;
  zoomLevel = next;
  applyZoom();
  showZoom();
  render(true);
  // Saved under the layout it was set in; a layout switch saves it at once.
  pendingZoom = { level: zoomLevel, layout };
  clearTimeout(zoomSave);
  zoomSave = setTimeout(saveZoomNow, ZOOM_SAVE_MS);
}, { passive: false });

async function poll() {
  lastPayload = await readUsage();
  render();
}

/** A snapshot from the fleet reader; it alone sets the strip's pulse baseline. */
function receiveFleet(message) {
  if (!Array.isArray(message?.sessions)) return;
  fleetSessions = message.sessions;
  fleetSpeaking = message.speaking ?? null;
  fleetFresh = true;
  render();
}

/**
 * Load the strip and follow the fleet. The strip is a module of its own, so a
 * failure there leaves the gauge as it was.
 */
async function startFleet() {
  try {
    const { mountStrip } = await import("./fleet/strip.js");
    const { subscribe } = await import("./fleet/feed.js");
    drawStrip = mountStrip(stripEl, {
      open: (id) => inTauri && window.__TAURI__.core.invoke("open_wall", { focus: id }).catch(() => {}),
    });
    subscribe(receiveFleet);
  } catch {
    drawStrip = null;
    stripEl.hidden = true;
  }
}

// Exposed so the visual-check harness can drive states without live files.
window.__klepsydra = {
  set(p) { lastPayload = p; render(); },
  fleet: receiveFleet,
};

await followLayout();
// No word from the app in time: draw the full layout; a late word still applies.
if (layoutSeq === 0) await applyLayout("full");
started = true;
startFleet();
poll();
setInterval(poll, POLL_MS);
setInterval(render, TICK_MS);
