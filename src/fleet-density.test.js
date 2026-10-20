import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DENSITIES, RETURN_SPARE_CARDS, autoDensity, parseDensity, resolveDensity } from "./fleet/density.js";

// The comfortable grid at 960x1000 holds four cards (two rows); `room` cards fit.
const fitsWith = (cards, room = 4) => (extra) => cards + extra <= room;

/** Auto's density after each card count in turn, starting comfortable. */
function walk(counts, room = 4) {
  let shown = "comfortable";
  return counts.map((n) => (shown = autoDensity(shown, fitsWith(n, room))));
}

test("auto turns compact the moment the comfortable grid would scroll", () => {
  assert.deepEqual(walk([1, 2, 3, 4]), ["comfortable", "comfortable", "comfortable", "comfortable"]);
  assert.deepEqual(walk([4, 5]), ["comfortable", "compact"]);
  assert.deepEqual(walk([9]), ["compact"], "a first look that would scroll is compact at once");
});

test("a card leaving and arriving at the boundary does not flip the wall back and forth", () => {
  // 5 -> 4 -> 5 -> 4: compact throughout, since four fit but not four plus a spare.
  assert.deepEqual(walk([4, 5, 4, 5, 4]), ["comfortable", "compact", "compact", "compact", "compact"]);
  // Back to comfortable only once it would still fit one card more.
  assert.deepEqual(walk([5, 4, 3, 4]), ["compact", "compact", "comfortable", "comfortable"]);
  assert.equal(RETURN_SPARE_CARDS, 1);
});

test("the same hysteresis holds for a window resized across the boundary", () => {
  // Room in cards as the window grows and shrinks, four cards on the wall.
  let shown = "comfortable";
  const seen = [4, 3, 4, 3, 4, 5].map((room) => (shown = autoDensity(shown, (extra) => 4 + extra <= room)));
  assert.deepEqual(seen, ["comfortable", "compact", "compact", "compact", "compact", "comfortable"]);
});

test("a manual choice is shown as chosen, and auto asks the grid only then", () => {
  let asked = 0;
  const fits = () => (asked++, true);
  assert.equal(resolveDensity("compact", "comfortable", fits), "compact");
  assert.equal(resolveDensity("comfortable", "compact", fits), "comfortable");
  assert.equal(asked, 0);
  assert.equal(resolveDensity("auto", "comfortable", fits), "comfortable");
  assert.equal(asked, 1);
});

test("a stored density reads back, and anything else is auto", () => {
  for (const d of DENSITIES) assert.equal(parseDensity(d), d);
  for (const bad of [undefined, null, "", "Compact", "dense", 1, {}]) assert.equal(parseDensity(bad), "auto", String(bad));
  assert.equal(resolveDensity("dense", "compact", () => false), "compact", "an unknown choice is auto");
  assert.equal(DENSITIES[0], "auto", "auto is the default");
});

test("the wall and the app keep the same choices under the same key", () => {
  const rs = readFileSync(new URL("../src-tauri/src/fleet.rs", import.meta.url), "utf8");
  const list = rs.match(/const DENSITIES: \[&str; 3\] = \[([^\]]*)\]/)[1].match(/"(\w+)"/g).map((q) => q.slice(1, -1));
  assert.deepEqual(list, DENSITIES);
  assert.match(rs, /const DENSITY_KEY: &str = "wall_density";/);
  const main = readFileSync(new URL("../src-tauri/src/main.rs", import.meta.url), "utf8");
  assert.match(main, /fleet::get_wall_density,\s*fleet::set_wall_density,/);
  const wall = readFileSync(new URL("./fleet/wall.js", import.meta.url), "utf8");
  assert.match(wall, /invoke\("get_wall_density"\)\.then\(choose,/);
  assert.match(wall, /invoke\("set_wall_density", \{ density: choice \}\)/);
});
