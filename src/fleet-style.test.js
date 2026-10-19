import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { columnsAt } from "./fleet/model.js";

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

test("the wall fits three columns at 1920 px and reflows below", () => {
  const wallCss = read("./fleet/wall.css");
  const px = (name) => parseFloat(token(wallCss, name));
  const tokens = { min: px("--card-min"), gap: px("--card-gap"), pad: px("--wall-pad") };
  const SCROLLBAR = 17;
  assert.equal(columnsAt(1920 - SCROLLBAR, tokens), 3);
  assert.equal(columnsAt(1920, tokens), 3);
  assert.equal(columnsAt(1280 - SCROLLBAR, tokens), 2);
  assert.equal(columnsAt(800 - SCROLLBAR, tokens), 1);
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
