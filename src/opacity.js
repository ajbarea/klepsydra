// The gauge's background opacity (#438): 0 to 100 in steps of 5, saved by
// the app (prefs.json `gauge_opacity`, opacity_subscribe, set_gauge_opacity).
// As the panel thins, the text takes stronger ink so it stays readable over
// any desktop: first full ink for the faint words, then light ink with a
// dark halo, never a light one (WCAG 1.4.3 over a see-through backdrop).

export const DEFAULT_OPACITY = 80; // klepsydra_fleet::opacity::DEFAULT
export const STEP = 5;
// Below these the panel no longer carries the text: halo ink, in either scheme.
// A light panel holds dark text longer than a dark panel holds light text.
export const HALO_BELOW = { dark: 60, light: 50 };
// Below this, faint text (resets, labels) takes the full ink.
export const FULL_INK_BELOW = 70;

/** `v` on the slider's grid, 0 to 100; anything else is the default. */
export function snap(v) {
  const n = typeof v === "number" ? v : Number.NaN;
  if (!Number.isFinite(n)) return DEFAULT_OPACITY;
  return Math.round(Math.min(100, Math.max(0, n)) / STEP) * STEP;
}

/** The ink for `opacity` in `scheme` ("dark" | "light"): "halo", "full" or null (the theme's own). */
export function inkFor(opacity, scheme) {
  const o = snap(opacity);
  if (o < (HALO_BELOW[scheme] ?? HALO_BELOW.dark)) return "halo";
  if (o < FULL_INK_BELOW) return "full";
  return null;
}

/** Wear `opacity` on `root`: the panel's alpha, its ink, and whether it is clear. Returns the ink. */
export function applyOpacity(root, opacity, scheme) {
  const o = snap(opacity);
  root.style.setProperty("--panel-alpha", String(o / 100));
  const ink = inkFor(o, scheme);
  if (ink) root.dataset.ink = ink;
  else delete root.dataset.ink;
  // Nothing to blur through at 0%: the frosted glass would be all that showed.
  if (o === 0) root.dataset.clear = "";
  else delete root.dataset.clear;
  return ink;
}

/** The page's colour scheme, as the gauge's CSS reads it. */
export const schemeOf = (win = globalThis) => (win.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark");

/**
 * Follow the saved opacity: the app's channel in Tauri; in a browser,
 * `?opacity=` (a harness), else the default. `onValue` gets the number.
 */
export function subscribeOpacity(onValue, { inTauri, follow, search = "" }) {
  if (inTauri) {
    follow("opacity_subscribe", (v) => onValue(snap(v))).catch(() => onValue(DEFAULT_OPACITY));
    return;
  }
  const asked = new URLSearchParams(search).get("opacity");
  onValue(asked === null ? DEFAULT_OPACITY : snap(Number(asked)));
}
