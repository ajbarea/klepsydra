// A card's Full text on the phone wall (fleet/fulltext.js): which cards show
// the disclosure, and that opening one unfolds every part it measures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CHIPS, CUT, cutsText, overflows } from "./fleet/fulltext.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");

// A card's parts by the selector that finds each: its box and whether it is drawn.
const part = (sel, { shown = true, w = 100, h = 20, sw = w, sh = h } = {}) => ({ sel, shown, clientWidth: w, clientHeight: h, scrollWidth: sw, scrollHeight: sh });
const cardOf = (...parts) => ({
  querySelectorAll: (list) => parts.filter((p) => list.split(", ").includes(p.sel)),
});
const drawn = (el) => el.shown;

test("a box overflows when it holds more than it shows, across or down", () => {
  assert.equal(overflows({ scrollWidth: 100, clientWidth: 100, scrollHeight: 20, clientHeight: 20 }), false, "an exact fit");
  assert.equal(overflows({ scrollWidth: 101, clientWidth: 100, scrollHeight: 20, clientHeight: 20 }), true, "an ellipsis");
  assert.equal(overflows({ scrollWidth: 100, clientWidth: 100, scrollHeight: 41, clientHeight: 40 }), true, "a line clamp");
  assert.equal(overflows({ scrollWidth: 0, clientWidth: 0, scrollHeight: 0, clientHeight: 0 }), false, "an empty box");
});

test("a card shows Full text only while something on it is cut short", () => {
  assert.equal(cutsText(cardOf(), drawn), false, "a card with no text parts");
  assert.equal(cutsText(cardOf(...CUT.map((s) => part(s))), drawn), false, "every part fits");
  for (const sel of CUT) {
    const others = CUT.filter((s) => s !== sel).map((s) => part(s));
    assert.equal(cutsText(cardOf(...others, part(sel, { sw: 140 })), drawn), true, `${sel} cut across`);
    assert.equal(cutsText(cardOf(...others, part(sel, { sh: 60 })), drawn), true, `${sel} clamped`);
    assert.equal(cutsText(cardOf(...others, part(sel, { sw: 140, shown: false })), drawn), false, `${sel} not drawn`);
  }
  for (const sel of CHIPS) {
    assert.equal(cutsText(cardOf(part(sel)), drawn), true, `a drawn ${sel} names repos only in its title`);
    assert.equal(cutsText(cardOf(part(sel, { shown: false })), drawn), false, `${sel} not drawn`);
  }
});

test("opening Full text unfolds every part it measures", () => {
  const css = read("./fleet/wall.css");
  for (const sel of [...CUT, ...CHIPS]) assert.ok(css.includes(`.open-text ${sel}`), `wall.css unfolds ${sel} under .open-text`);
});

test("Full text changes only what the card shows: its press reaches no session", () => {
  const wall = read("./fleet/wall.js");
  const at = wall.indexOf('const unfold = e.target.closest(".unfold");');
  assert.ok(at > 0, "the wall handles the disclosure");
  const handler = wall.slice(at, wall.indexOf("return;", at));
  assert.doesNotMatch(handler, /tauri\(|invoke|fetch|\.click\(\)/, handler);
  // Before the phone's tap-anywhere link, so a press on it never opens Remote Control.
  assert.ok(at < wall.indexOf('if (served && !e.target.closest("a, button"))'));
});
