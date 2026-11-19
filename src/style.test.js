import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Sizes that legitimately ignore the zoom: a pill radius, the backdrop blur.
const UNSCALED_OK = [/\b999px\b/g, /blur\(\d+px\)/g];

/**
 * Declarations after the restyling tokens that use a px length, or a token
 * holding one, without --scale.
 */
export function unscaledSizes(css) {
  const tokensEnd = css.indexOf("*/", css.indexOf("/* ───", css.indexOf("}")));
  const pxTokens = [...css.slice(0, tokensEnd).matchAll(/(--[\w-]+):\s*([\d.]+px)/g)]
    .filter((m) => !UNSCALED_OK.some((re) => m[2].match(re)))
    .map((m) => m[1]);
  const body = css.slice(tokensEnd + 2).replace(/\/\*[\s\S]*?\*\//g, "");
  return body
    .split(/[;{}]/)
    .map((d) => d.trim())
    .filter((d) => {
      if (d.includes("var(--scale)")) return false;
      const bare = UNSCALED_OK.reduce((s, re) => s.replace(re, ""), d);
      return /\d+(\.\d+)?px/.test(bare) || pxTokens.some((t) => d.includes(`var(${t})`));
    });
}

// The strip's own rules, and the chips' (shared with the wall's header).
const SHEETS = { "style.css": "./style.css", "fleet/chips.css": "./fleet/chips.css" };
const sheets = Object.fromEntries(Object.entries(SHEETS).map(([name, path]) => [name, readFileSync(new URL(path, import.meta.url), "utf8")]));
const css = sheets["style.css"];
const chips = sheets["fleet/chips.css"];

test("every pixel size outside the tokens follows the zoom, in the strip's rules and the chips'", () => {
  for (const [name, text] of Object.entries(sheets)) assert.deepEqual(unscaledSizes(text), [], name);
});

test("the check catches a size added without the zoom", () => {
  for (const text of [css, chips]) assert.deepEqual(unscaledSizes(`${text}\n.new { margin-top: 6px; }\n`), ["margin-top: 6px"]);
});

test("the check catches a size token used without the zoom", () => {
  assert.deepEqual(unscaledSizes(`${chips}\n.new { font-size: var(--size-sub); }\n`), ["font-size: var(--size-sub)"]);
  assert.deepEqual(unscaledSizes(`${css}\n.new { width: var(--face-size); }\n`), ["width: var(--face-size)"]);
});

test("the wall's header gives the chips a scale of 1: it has no zoom", () => {
  const wall = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  assert.match(wall, /\.dock \{ --scale: 1;/);
});
