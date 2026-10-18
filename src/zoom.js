// Scroll-on-grip zoom, kept free of the DOM so it can be unit tested.

// Each level is 10% larger than the one below. Levels are integers so any
// path back to 0 lands on exactly 100%.
const ZOOM_STEP = 1.1;
export const ZOOM_MIN_LEVEL = -3; // 75.1%
export const ZOOM_MAX_LEVEL = 9; // 235.8%

// One mouse notch as WebView2 reports it.
export const NOTCH_PX = 100;
// An event this large is a notch however the engine scales it; touchpads send
// many smaller ones, which accumulate instead.
const MIN_NOTCH_PX = 40;

export function scaleAt(level) {
  return Math.round(ZOOM_STEP ** level * 1000) / 1000;
}

export function clampLevel(level) {
  if (!Number.isFinite(level)) return 0;
  return Math.max(ZOOM_MIN_LEVEL, Math.min(ZOOM_MAX_LEVEL, Math.round(level)));
}

/** A wheel delta in pixels, whatever unit the event used (3 lines to a notch). */
export function wheelPixels(deltaY, deltaMode) {
  if (deltaMode === 1) return (deltaY * NOTCH_PX) / 3;
  if (deltaMode === 2) return deltaY * NOTCH_PX;
  return deltaY;
}

// At most one step this often, so a touchpad fling cannot sweep the range.
export const STEP_GAP_MS = 80;
// A pause this long ends a gesture and drops what it had accumulated.
const IDLE_MS = 400;

/**
 * Fold one wheel event into the gesture so far. Returns the steps to apply
 * (positive grows: wheel up), at most one, and the state for the next event.
 * A notch-sized delta steps at once; smaller ones (touchpads) accumulate to a
 * notch, and the remainder never banks more than one step.
 */
export function wheelStep(state, dyPx, nowMs) {
  const prev = state ?? { rest: 0, last: -Infinity, lastStep: -Infinity };
  const fresh = nowMs - prev.last > IDLE_MS;
  const ready = nowMs - prev.lastStep >= STEP_GAP_MS;
  let rest = Math.max(-NOTCH_PX, Math.min(NOTCH_PX, (fresh ? 0 : prev.rest) + dyPx));
  let steps = 0;
  if (ready && Math.abs(dyPx) >= MIN_NOTCH_PX) steps = dyPx < 0 ? 1 : -1;
  else if (ready && Math.abs(rest) >= NOTCH_PX) steps = rest < 0 ? 1 : -1;
  if (steps !== 0) rest = 0;
  return { steps, state: { rest, last: nowMs, lastStep: steps !== 0 ? nowMs : prev.lastStep } };
}
