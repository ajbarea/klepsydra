// WCAG 2.2 contrast, shared by the card's button marker and the style tests.

/** Relative luminance of "#rrggbb". */
export function luminance(hex) {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** "#000000" or "#ffffff", whichever reads better on `hex`. The hook computes the same choice in jq. */
export const inkOn = (hex) => (contrast(hex, "#000000") >= contrast(hex, "#ffffff") ? "#000000" : "#ffffff");

/** Marker widths in px: the usual one, and the wider one for an accent under 3:1 (WCAG 1.4.11) on a button background. */
export const MARKER_PX = 4;
export const MARKER_WIDE_PX = 6;

/** The marker's width on `accent`: wide when any of `backgrounds` leaves it under 3:1. */
export const markerWidth = (accent, backgrounds) =>
  backgrounds.some((bg) => contrast(accent, bg) < 3) ? MARKER_WIDE_PX : MARKER_PX;

const hex2 = (n) => Math.round(n).toString(16).padStart(2, "0");
/** `a` moved toward `b` by `t` (0..1), in sRGB. */
export function mix(a, b, t) {
  const ch = (h, i) => parseInt(h.slice(i, i + 2), 16);
  return `#${[1, 3, 5].map((i) => hex2(ch(a, i) + (ch(b, i) - ch(a, i)) * t)).join("")}`;
}

// sRGB <-> OKLab (Ottosson), for what CSS `color-mix(in oklab, ...)` gives.
const toLinear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const fromLinear = (c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);
function oklab(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => toLinear(parseInt(hex.slice(i, i + 2), 16) / 255));
  const [l, m, s] = [
    0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b,
    0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b,
    0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b,
  ].map(Math.cbrt);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}
function fromOklab([L, A, B]) {
  const [l, m, s] = [L + 0.3963377774 * A + 0.2158037573 * B, L - 0.1055613458 * A - 0.0638541728 * B, L - 0.0894841775 * A - 1.291485548 * B].map((v) => v ** 3);
  const rgb = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  return `#${rgb.map((c) => hex2(Math.min(255, Math.max(0, fromLinear(c) * 255)))).join("")}`;
}

/** `a` moved toward `b` by `t`, in OKLab: CSS `color-mix(in oklab, b t, a)`. */
export function mixOklab(a, b, t) {
  const [p, q] = [oklab(a), oklab(b)];
  return fromOklab(p.map((v, i) => v + (q[i] - v) * t));
}

/**
 * `accent` itself when it reads at `min` on every ground in `bgs` (one colour or a list), else lifted
 * toward white (toward black on light grounds) just until it does.
 */
export function readableOn(accent, bgs, min = 4.5) {
  const grounds = [bgs].flat();
  const reads = (c) => grounds.every((bg) => contrast(c, bg) >= min);
  if (reads(accent)) return accent;
  const to = luminance(grounds[0]) < 0.18 ? "#ffffff" : "#000000";
  for (let t = 0.02; t < 1; t += 0.02) {
    const c = mix(accent, to, t);
    if (reads(c)) return c;
  }
  return to;
}
