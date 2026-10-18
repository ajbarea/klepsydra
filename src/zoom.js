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

/**
 * Fold one wheel delta into the running remainder. Returns the whole steps to
 * apply, positive to grow (wheel up), and what is left over.
 */
export function wheelSteps(rest, dyPx) {
  if (Math.abs(dyPx) >= MIN_NOTCH_PX) {
    const notches = Math.max(1, Math.round(Math.abs(dyPx) / NOTCH_PX));
    return { steps: dyPx < 0 ? notches : -notches, rest: 0 };
  }
  const total = rest + dyPx;
  const whole = Math.trunc(total / NOTCH_PX);
  return { steps: whole === 0 ? 0 : -whole, rest: total - whole * NOTCH_PX };
}
