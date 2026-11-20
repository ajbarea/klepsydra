import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// #505: a 420px minimum track must shrink to the available width in a docked desktop wall.
test("desktop wall grid caps card minimum at the available width", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const wall = css.match(/(?:^|\n)\.wall \{([^}]*)\}/)?.[1];
  assert.ok(wall, "desktop wall grid rule exists");
  assert.match(wall, /display:\s*grid;/);
  assert.match(
    wall,
    /grid-template-columns:\s*repeat\(auto-fill,\s*minmax\(min\(var\(--card-min\),\s*100%\),\s*1fr\)\);/,
    "the card minimum is capped at 100% of the grid's content width",
  );
  assert.match(css, /--card-min:\s*420px;/, "the preferred desktop width stays 420px");
});
