import { test } from "node:test";
import assert from "node:assert/strict";
import { wheelPixels, wheelStep, clampLevel, scaleAt, ZOOM_MIN_LEVEL, ZOOM_MAX_LEVEL, NOTCH_PX, STEP_GAP_MS } from "./zoom.js";

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

// Feed a list of [delta px, ms since the previous event]; return the total steps.
function scroll(events) {
  let state;
  let now = 10_000;
  let total = 0;
  for (const [dy, gap] of events) {
    now += gap;
    const r = wheelStep(state, dy, now);
    state = r.state;
    total += r.steps;
  }
  return total;
}

test("one mouse notch is one step, whichever way it is reported", () => {
  // WebView2 reports a notch as 100px; other engines report less.
  for (const notch of [100, 53, 40]) {
    assert.equal(scroll([[-notch, 1000]]), 1, `up ${notch}`);
    assert.equal(scroll([[notch, 1000]]), -1, `down ${notch}`);
  }
});

test("notches at a normal pace are one step each", () => {
  assert.equal(scroll([[-100, 1000], [-100, 150], [-100, 150], [-100, 150]]), 4);
  assert.equal(scroll([[-53, 1000], [-53, 150], [-53, 150]]), 3);
});

test("a touchpad flick moves a few levels, not the whole range", () => {
  // About 15 events of 50-120px within 400ms, as a precision touchpad flings.
  const flick = Array.from({ length: 15 }, (_, i) => [-(50 + (i * 37) % 70), 27]);
  const steps = scroll([[-60, 1000], ...flick]);
  assert.ok(steps >= 2 && steps <= Math.ceil(420 / STEP_GAP_MS) + 1, `flick gave ${steps}`);
});

test("a fast spin coalesced into one event is a single step", () => {
  assert.equal(scroll([[-300, 1000]]), 1);
});

test("slow touchpad deltas accumulate into whole steps", () => {
  const events = Array.from({ length: 8 }, () => [-25, 100]);
  assert.equal(scroll(events), 2);
});

test("a reversal unwinds what was accumulated rather than stepping", () => {
  assert.equal(scroll([[-30, 1000], [30, 50]]), 0);
});
