import { rampColor, toRows, formatPct } from "./gauge.js";

const POLL_MS = 5_000;   // how often we re-read the account files
const TICK_MS = 15_000;  // how often the countdown re-renders between reads

const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

if (new URLSearchParams(location.search).has("still")) {
  document.documentElement.dataset.still = "";
}

// Harness only: pin the panel width so captures do not depend on how the
// headless browser interprets --window-size.
const forcedWidth = new URLSearchParams(location.search).get("w");
if (forcedWidth) {
  document.documentElement.style.setProperty("--panel-width", `${parseInt(forcedWidth, 10)}px`);
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

let lastPayload = null;
let lastHeight = 0;
let lastTray = "";

function paint(entry, row) {
  entry.querySelector(".label").textContent = row.label;
  entry.querySelector(".pct").textContent = formatPct(row.pct);
  entry.querySelector(".sub").textContent = row.sub;
  entry.dataset.state = row.state;

  const fill = entry.querySelector(".fill");
  const clamped = Math.max(0, Math.min(100, row.pct ?? 0));
  fill.style.width = `${clamped}%`;
  // A nonzero reading stays visible as a dot instead of collapsing sub-pixel.
  fill.style.minWidth = clamped > 0 ? "var(--bar-height)" : "0";
  fill.style.backgroundColor = rampColor(row.pct ?? 0, stops(), rampMode());
}

/** Tell the window how tall the panel actually is, so it never clips or gaps. */
function syncHeight() {
  if (!inTauri) return;
  const h = Math.ceil(panel.getBoundingClientRect().height);
  if (h === lastHeight || h < 1) return;
  lastHeight = h;
  window.__TAURI__.core.invoke("set_height", { height: h }).catch(() => {});
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
  const r = document.getElementById("grip").getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return;
  window.__TAURI__.core
    .invoke("set_grip", { x: r.left, y: r.top, w: r.width, h: r.height })
    .catch(() => {});
}

function render() {
  const rows = toRows(lastPayload, Date.now());

  emptyEl.hidden = rows.length > 0;
  panel.dataset.state = rows.length === 0
    ? "waiting"
    : rows.every((r) => r.state === "stale") ? "stale" : "live";

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
  syncHeight();
  syncGrip();
}

async function poll() {
  lastPayload = await readUsage();
  render();
}

// Exposed so the visual-check harness can drive states without live files.
window.__klepsydra = { set(p) { lastPayload = p; render(); } };

poll();
setInterval(poll, POLL_MS);
setInterval(render, TICK_MS);
