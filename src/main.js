import { rampColor, evaluate, formatPct, windowLabel } from "./gauge.js";

const POLL_MS = 5_000;   // how often we re-read usage.json
const TICK_MS = 15_000;  // how often the countdown re-renders between reads

const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

if (new URLSearchParams(location.search).has("still")) {
  document.documentElement.dataset.still = "";
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

/** Reading the file is the only thing that differs between app and browser. */
async function readUsage() {
  try {
    if (inTauri) {
      const { invoke } = window.__TAURI__.core;
      const text = await invoke("read_usage");
      return text ? JSON.parse(text) : null;
    }
    // Browser dev: serve src/ and drop a dev-fixture.json beside it.
    const res = await fetch("./dev-fixture.json", { cache: "no-store" });
    return res.ok ? await res.json() : null;
  } catch {
    return null; // missing, unreadable or malformed all mean "no data"
  }
}

const el = (id) => document.getElementById(id);
const panel = el("panel");

function paint(prefix, reading) {
  el(`${prefix}-label`).textContent = reading.label;
  el(`${prefix}-pct`).textContent = formatPct(reading.pct);
  el(`${prefix}-sub`).textContent = reading.sub;
  const fill = el(`${prefix}-fill`);
  const pct = reading.pct ?? 0;
  const clamped = Math.max(0, Math.min(100, pct));
  fill.style.width = `${clamped}%`;
  // A nonzero reading stays visible as a dot instead of collapsing sub-pixel.
  fill.style.minWidth = clamped > 0 ? "var(--bar-height)" : "0";
  fill.style.backgroundColor = rampColor(pct, stops(), rampMode());
}

let lastPayload = null;

function render() {
  const now = Date.now();
  // Query params override storage so the visual-check harness can drive layouts.
  const q = new URLSearchParams(location.search);
  const primaryKey = q.get("primary") ?? localStorage.getItem("klepsydra.primary") ?? "five_hour";
  const secondaryKey = q.get("secondary") ?? localStorage.getItem("klepsydra.secondary"); // null = hidden

  const primary = evaluate(lastPayload, primaryKey, now);
  paint("p", primary);
  panel.dataset.state = primary.state;

  const secondary = el("secondary");
  if (secondaryKey) {
    secondary.hidden = false;
    paint("s", evaluate(lastPayload, secondaryKey, now));
  } else {
    secondary.hidden = true;
  }

  document.title = `klepsydra ${formatPct(primary.pct)}`;
}

async function poll() {
  lastPayload = await readUsage();
  render();
}

// Tray commands arrive as plain events so the menu stays in Rust.
if (inTauri) {
  window.__TAURI__.event.listen("window-changed", ({ payload }) => {
    localStorage.setItem("klepsydra.primary", payload.primary);
    if (payload.secondary) localStorage.setItem("klepsydra.secondary", payload.secondary);
    else localStorage.removeItem("klepsydra.secondary");
    render();
  });
}

// Exposed so the visual-check harness can drive states without a live file.
window.__klepsydra = {
  set(payload) { lastPayload = payload; render(); },
  windowLabel,
};

poll();
setInterval(poll, POLL_MS);
setInterval(render, TICK_MS);
