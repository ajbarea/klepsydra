import { test } from "node:test";
import assert from "node:assert/strict";
import { wheelPixels, wheelSteps, clampLevel, scaleAt, ZOOM_MIN_LEVEL, ZOOM_MAX_LEVEL, NOTCH_PX } from "./zoom.js";

test("level 0 is exactly 100%, and each level is 10% more", () => {
  assert.equal(scaleAt(0), 1);
  assert.equal(scaleAt(1), 1.1);
  assert.equal(scaleAt(-1), 0.909);
  assert.equal(scaleAt(3), 1.331);
});

test("levels clamp to roughly 75% and 250%", () => {
  assert.equal(clampLevel(-50), ZOOM_MIN_LEVEL);
  assert.equal(clampLevel(50), ZOOM_MAX_LEVEL);
  assert.ok(scaleAt(ZOOM_MIN_LEVEL) >= 0.75 && scaleAt(ZOOM_MIN_LEVEL - 1) < 0.75);
  assert.ok(scaleAt(ZOOM_MAX_LEVEL) <= 2.5 && scaleAt(ZOOM_MAX_LEVEL + 1) > 2.5);
  assert.equal(clampLevel(Number.NaN), 0);
});

test("lines and pages are converted to pixels", () => {
  assert.equal(wheelPixels(-100, 0), -100);
  assert.equal(wheelPixels(-3, 1), -NOTCH_PX);
  assert.equal(wheelPixels(1, 2), NOTCH_PX);
});

test("one mouse notch is one step, whichever way it is reported", () => {
  // WebView2 reports a notch as 100px; other engines report less.
  for (const notch of [100, 53, 40]) {
    assert.deepEqual(wheelSteps(0, -notch), { steps: 1, rest: 0 }, `up ${notch}`);
    assert.deepEqual(wheelSteps(0, notch), { steps: -1, rest: 0 }, `down ${notch}`);
  }
});

test("a fast spin coalesced into one event still counts every notch", () => {
  assert.equal(wheelSteps(0, -300).steps, 3);
});

test("touchpad deltas accumulate into whole steps", () => {
  let rest = 0;
  let steps = 0;
  for (let i = 0; i < 8; i++) {
    const r = wheelSteps(rest, -25);
    rest = r.rest;
    steps += r.steps;
  }
  assert.equal(steps, 2);
  assert.equal(rest, 0);
});

test("a reversal unwinds what was accumulated rather than stepping", () => {
  const a = wheelSteps(0, -30);
  const b = wheelSteps(a.rest, 30);
  assert.deepEqual(b, { steps: 0, rest: 0 });
});
