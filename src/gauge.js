// Pure rendering logic, kept free of Tauri and DOM so it can be unit tested.

export const STALE_AFTER_MS = 15 * 60 * 1000;

const WINDOW_LABELS = {
  five_hour: "Current session",
  seven_day: "This week",
  spend_limit: "Spend limit",
};

export function windowLabel(key) {
  return WINDOW_LABELS[key] ?? key;
}

/**
 * Which pair of stops a percentage falls between, and how far along it is.
 * Clamped, so a spend_limit reading above 100 pins to the high stop.
 */
export function rampPosition(pct, midAt) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const m = Math.max(1, Math.min(99, Number(midAt) || 60));
  return p <= m
    ? { from: "low", to: "mid", t: p / m }
    : { from: "mid", to: "high", t: (p - m) / (100 - m) };
}

/**
 * Colour for a given used-percentage.
 *
 * "blend" interpolates in OKLab, which the browser computes -- sRGB
 * interpolation between blue and yellow passes through a muddy olive.
 * "bands" holds each stop flat and switches at the boundaries, which reads
 * more like a game health bar.
 */
export function rampColor(pct, stops, mode = "blend") {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  if (mode === "bands") {
    const highAt = Number(stops.highAt) || 85;
    if (p >= highAt) return stops.high;
    if (p >= (Number(stops.midAt) || 60)) return stops.mid;
    return stops.low;
  }
  const { from, to, t } = rampPosition(p, stops.midAt);
  return `color-mix(in oklab, ${stops[to]} ${Math.round(t * 100)}%, ${stops[from]})`;
}

/**
 * "Resets in 4 hr 58 min". Returns null once the window has already reset,
 * which the caller treats as "no live data" rather than "0% used".
 */
export function formatCountdown(resetsAtSec, nowMs = Date.now()) {
  if (!Number.isFinite(resetsAtSec)) return null;
  const ms = resetsAtSec * 1000 - nowMs;
  if (ms <= 0) return null;
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return "Resets in under a minute";
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h === 0) return `Resets in ${m} min`;
  if (m === 0) return `Resets in ${h} hr`;
  return `Resets in ${h} hr ${m} min`;
}

/**
 * Decide what to draw from a parsed usage.json (or null when it is missing
 * or unreadable). Never throws; an unusable payload degrades to "waiting".
 */
export function evaluate(payload, key, nowMs = Date.now()) {
  const waiting = { state: "waiting", label: windowLabel(key), pct: null, sub: "waiting for Claude Code" };
  if (!payload || typeof payload !== "object") return waiting;

  const win = payload.windows?.[key];
  if (!win || !Number.isFinite(Number(win.used_percentage))) return waiting;

  const countdown = formatCountdown(Number(win.resets_at), nowMs);
  // The window's own reset time has passed, so the number on disk describes a
  // window that no longer exists.
  if (countdown === null) {
    return { state: "stale", label: windowLabel(key), pct: null, sub: "window reset" };
  }

  const writtenAtMs = Number(payload.written_at) * 1000;
  const stale = !Number.isFinite(writtenAtMs) || nowMs - writtenAtMs > STALE_AFTER_MS;

  return {
    state: stale ? "stale" : "live",
    label: windowLabel(key),
    pct: Number(win.used_percentage),
    sub: countdown,
  };
}

export function formatPct(pct) {
  if (pct === null) return "--";
  return `${Math.floor(pct)}% used`;
}
