import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Sizes that legitimately ignore the zoom: a pill radius, the backdrop blur.
const UNSCALED_OK = [/\b999px\b/g, /blur\(\d+px\)/g];

/** Declarations after the restyling tokens that hold a px length without --scale. */
export function unscaledSizes(css) {
  const tokensEnd = css.indexOf("*/", css.indexOf("/* ───", css.indexOf("}")));
  const body = css.slice(tokensEnd + 2).replace(/\/\*[\s\S]*?\*\//g, "");
  return body
    .split(/[;{}]/)
    .map((d) => d.trim())
    .filter((d) => {
      const bare = UNSCALED_OK.reduce((s, re) => s.replace(re, ""), d);
      return /\d+(\.\d+)?px/.test(bare) && !d.includes("var(--scale)");
    });
}

const css = readFileSync(new URL("./style.css", import.meta.url), "utf8");

test("every pixel size outside the tokens follows the zoom", () => {
  assert.deepEqual(unscaledSizes(css), []);
});

test("the check catches a size added without the zoom", () => {
  assert.deepEqual(unscaledSizes(`${css}\n.new { margin-top: 6px; }\n`), ["margin-top: 6px"]);
});
