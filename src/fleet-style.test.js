import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const badgeCss = read("./fleet/badge.css");
const token = (css, name) => css.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim();

/** WCAG 2.2 relative luminance of "#rrggbb". */
function luminance(hex) {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** Columns that `repeat(auto-fill, minmax(min, 1fr))` makes in a viewport `width` wide. */
const columnsAt = (width, { min, gap, pad }) => Math.max(1, Math.floor((width - 2 * pad + gap) / (min + gap)));

/** `rgba(r, g, b, a)` laid over an opaque "#rrggbb", as "#rrggbb". */
function over(rgba, hex) {
  const [r, g, b, a] = rgba.match(/[\d.]+/g).map(Number);
  const base = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return `#${[r, g, b].map((c, i) => Math.round(c * a + base[i] * (1 - a)).toString(16).padStart(2, "0")).join("")}`;
}

/** Each tone's shape fill and stroke and its ink, resolved through badge.css's tokens. */
function tones(css) {
  const value = (decl, prop) => decl.match(new RegExp(`${prop}:\\s*var\\((--[\\w-]+)\\)`))?.[1];
  const ring = token(css, "--badge-ring");
  const out = {};
  for (const [, tone, part, decl] of css.matchAll(/\.tone-(\w+) \.(shape|ink) \{([^}]*)\}/g)) {
    out[tone] ??= { fill: null, stroke: ring, ink: null };
    if (part === "shape") {
      out[tone].fill = token(css, value(decl, "fill"));
      if (value(decl, "stroke")) out[tone].stroke = token(css, value(decl, "stroke"));
    } else out[tone].ink = token(css, value(decl, "fill"));
  }
  return { ring, tones: out };
}

test("every badge meets 3:1 against the strip's backdrop, and its symbol against the badge", () => {
  const { ring, tones: all } = tones(badgeCss);
  assert.deepEqual(Object.keys(all).sort(), ["done", "error", "needs", "quiet", "working"]);
  // The ring is the panel's own colour: what every badge sits on.
  const panel = token(read("./style.css"), "--panel-bg");
  assert.equal(over(panel, ring), ring.toLowerCase(), "ring matches the panel over a dark desktop");
  const onWhite = over(panel, "#ffffff");
  for (const [tone, t] of Object.entries(all)) {
    const edge = tone === "quiet" ? t.stroke : t.fill;
    assert.ok(contrast(edge, ring) >= 3, `${tone} against the ring: ${contrast(edge, ring).toFixed(2)}`);
    if (tone === "quiet") {
      assert.ok(contrast(edge, onWhite) >= 3, `quiet outline over a light desktop: ${contrast(edge, onWhite).toFixed(2)}`);
    }
    assert.ok(contrast(t.ink, t.fill) >= 3, `${tone} symbol: ${contrast(t.ink, t.fill).toFixed(2)}`);
  }
});

test("the Okabe-Ito tones are the spec's", () => {
  assert.deepEqual(
    ["--badge-needs", "--badge-error", "--badge-working", "--badge-done"].map((t) => token(badgeCss, t)),
    ["#e69f00", "#d55e00", "#0072b2", "#009e73"],
  );
});

test("badges take their size from where they sit", () => {
  assert.doesNotMatch(badgeCss.replace(/\/\*[\s\S]*?\*\//g, ""), /\d+(\.\d+)?px/);
});

test("the wall fits four columns at 1920 px and reflows below", () => {
  const wallCss = read("./fleet/wall.css");
  const px = (name) => parseFloat(token(wallCss, name));
  const tokens = { min: px("--card-min"), gap: px("--card-gap"), pad: px("--wall-pad") };
  const SCROLLBAR = 17;
  assert.equal(columnsAt(1920 - SCROLLBAR, tokens), 4);
  assert.equal(columnsAt(1280 - SCROLLBAR, tokens), 2);
  assert.equal(columnsAt(800 - SCROLLBAR, tokens), 1);
});

test("the wall's text meets 4.5:1 on live and quiet cards", () => {
  const css = read("./fleet/wall.css");
  for (const bg of ["--card-bg", "--card-quiet"]) {
    for (const fg of ["--text", "--text-dim", "--text-error", "--text-quiet"]) {
      const r = contrast(token(css, fg), token(css, bg));
      assert.ok(r >= 4.5, `${fg} on ${bg}: ${r.toFixed(2)}`);
    }
  }
  assert.ok(contrast(token(css, "--tone-working"), token(css, "--card-bg")) >= 3, "working arc and edge");
  assert.doesNotMatch(css.replace(/\/\*[\s\S]*?\*\//g, ""), /opacity:/, "dimming is by colour, so dimmed text keeps its contrast");
});

test("the arc and the dimming respect reduced motion and keep the face visible", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(css, /\.card\.dim \.face \{[^}]*filter:/);
});

test("a badge on the wall is ringed in its card's colour", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /\.card \{[^}]*--badge-ring: var\(--card-bg\)/);
  assert.match(css, /\.card\.dim \{[^}]*--badge-ring: var\(--card-quiet\)/);
});

test("the wall's error text is readable on its card at 14 px", () => {
  const wallCss = read("./fleet/wall.css");
  const ratio = contrast(token(wallCss, "--text-error"), token(wallCss, "--card-bg"));
  assert.ok(ratio >= 4.5, `error text on the card: ${ratio.toFixed(2)}`);
  assert.match(wallCss, /\.error \{ color: var\(--text-error\)/);
});

test("a portrait is 28 px at 100%, and the strip's rules are in the zoomed stylesheet", () => {
  const css = read("./style.css");
  assert.equal(token(css, "--face-size"), "28px");
  for (const rule of ["#frame {", "#strip {", ".face {", ".face .badge {"]) assert.ok(css.includes(rule), rule);
});

test("the strip starts hidden, so the gauge looks as before until a fleet arrives", () => {
  assert.match(read("./index.html"), /<div id="strip"[^>]*\shidden>/);
  assert.match(read("./main.js"), /try\s*\{[\s\S]{0,80}?import\(\s*["']\.\/fleet\/strip\.js["']\s*\)/);
  assert.match(read("./index.html"), /href="fleet\/badge\.css"/);
});

test("every set_size and set_grip call carries the strip", () => {
  const calls = [...read("./main.js").matchAll(/invoke\(\s*"(set_size|set_grip)"\s*,\s*\{([^}]*)\}/g)];
  assert.equal(calls.length, 2);
  for (const [, name, args] of calls) assert.match(args, /\bstrip\b/, name);
});

test("the focus ring is neutral, not the needs tone, and meets 3:1 on the wall and the card", () => {
  const css = read("./fleet/wall.css");
  const ring = token(css, "--card-focus");
  assert.match(ring, /^#[0-9a-f]{6}$/i);
  assert.notEqual(ring.toLowerCase(), token(badgeCss, "--badge-needs").toLowerCase(), "amber means needs you");
  assert.ok(contrast(ring, token(css, "--wall-bg")) >= 3);
  assert.ok(contrast(ring, token(css, "--card-bg")) >= 3);
  assert.match(css, /button:focus-visible \{ outline: 2px solid var\(--card-focus\); outline-offset: 2px; \}/);
});

test("the needs pulse plays only where motion is allowed, once", () => {
  const css = read("./fleet/wall.css");
  const block = css.match(/@media \(prefers-reduced-motion: no-preference\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
  assert.match(block, /@keyframes card-pulse/);
  assert.match(block, /\.card\.pulse \{[^}]*animation: card-pulse 1200ms ease-out 1;/);
  assert.ok(!/@keyframes card-pulse/.test(css.replace(block, "")), "keyframes only inside no-preference");
  assert.match(css, /prefers-reduced-motion: reduce\) \{[^}]*animation: none/);
});

test("the reorder slide is bounded, and cards keep their own transition names", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /::view-transition-group\(\*\)\s*\{[^}]*animation-duration:\s*\d+ms/);
});

test("a disabled button reads as off: no fill, a quieter border, a label still at 4.5:1", () => {
  const css = read("./fleet/wall.css");
  const rule = css.match(/button\[aria-disabled="true"\], #new-session\[aria-disabled="true"\] \{([^}]*)\}/)?.[1] ?? "";
  // #new-session (1 id) outranks button[...] (1 type, 1 attr): the id form must be listed and come last.
  assert.ok(css.indexOf('#new-session[aria-disabled="true"]') > css.indexOf("#new-session {"));
  assert.match(rule, /background: transparent/);
  assert.match(rule, /border-color: var\(--card-line\)/);
  assert.ok(contrast(token(css, "--text-dim"), token(css, "--card-bg")) >= 4.5);
});
