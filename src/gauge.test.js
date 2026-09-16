import { test } from "node:test";
import assert from "node:assert/strict";
import { rampColor, rampPosition, formatCountdown, evaluate, formatPct, STALE_AFTER_MS } from "./gauge.js";

const STOPS = { low: "#3b82f6", mid: "#eab308", high: "#ef4444", midAt: 60, highAt: 85 };
const NOW = 1_800_000_000_000; // fixed clock
const secs = (ms) => ms / 1000;

test("blend ramp lands exactly on each stop", () => {
  assert.equal(rampColor(0, STOPS), "color-mix(in oklab, #eab308 0%, #3b82f6)");
  assert.equal(rampColor(60, STOPS), "color-mix(in oklab, #eab308 100%, #3b82f6)");
  assert.equal(rampColor(100, STOPS), "color-mix(in oklab, #ef4444 100%, #eab308)");
});

test("blend ramp mixes proportionally between stops", () => {
  assert.equal(rampPosition(30, 60).t, 0.5);
  assert.equal(rampPosition(80, 60).t, 0.5);
  assert.equal(rampColor(30, STOPS), "color-mix(in oklab, #eab308 50%, #3b82f6)");
});

test("bands ramp switches at its own thresholds", () => {
  assert.equal(rampColor(0, STOPS, "bands"), "#3b82f6");
  assert.equal(rampColor(59, STOPS, "bands"), "#3b82f6");
  assert.equal(rampColor(60, STOPS, "bands"), "#eab308");
  assert.equal(rampColor(84, STOPS, "bands"), "#eab308");
  assert.equal(rampColor(85, STOPS, "bands"), "#ef4444");
  assert.equal(rampColor(100, STOPS, "bands"), "#ef4444");
});

test("ramp clamps out-of-range input", () => {
  // spend_limit can report above 100; it must pin, not overshoot into nonsense.
  assert.equal(rampColor(140, STOPS), rampColor(100, STOPS));
  assert.equal(rampColor(-20, STOPS), rampColor(0, STOPS));
  assert.equal(rampColor(NaN, STOPS), rampColor(0, STOPS));
});

test("blend ramp advances monotonically across the whole scale", () => {
  // Guards against a stop reordering silently producing a non-draining look.
  let prevPos = -1;
  for (let p = 0; p <= 100; p++) {
    const { from, t } = rampPosition(p, STOPS.midAt);
    const pos = (from === "low" ? 0 : 1) + t;
    assert.ok(pos >= prevPos, `regressed at ${p}%`);
    prevPos = pos;
    assert.match(rampColor(p, STOPS), /^color-mix\(in oklab, #[0-9a-f]{6} \d+%, #[0-9a-f]{6}\)$/);
  }
});

test("countdown formatting", () => {
  assert.equal(formatCountdown(secs(NOW + 4 * 3600e3 + 58 * 60e3), NOW), "Resets in 4 hr 58 min");
  assert.equal(formatCountdown(secs(NOW + 58 * 60e3), NOW), "Resets in 58 min");
  assert.equal(formatCountdown(secs(NOW + 2 * 3600e3), NOW), "Resets in 2 hr");
  assert.equal(formatCountdown(secs(NOW + 30e3), NOW), "Resets in under a minute");
});

test("countdown returns null once the window has passed", () => {
  assert.equal(formatCountdown(secs(NOW - 1), NOW), null);
  assert.equal(formatCountdown(secs(NOW), NOW), null);
  assert.equal(formatCountdown(undefined, NOW), null);
});

const live = (pct, resetsInMs = 2 * 3600e3, writtenAgoMs = 0) => ({
  written_at: secs(NOW - writtenAgoMs),
  windows: { five_hour: { used_percentage: pct, resets_at: secs(NOW + resetsInMs) } },
});

test("live reading renders percentage and countdown", () => {
  const r = evaluate(live(73.2), "five_hour", NOW);
  assert.equal(r.state, "live");
  assert.equal(r.label, "Current session");
  assert.equal(r.pct, 73.2);
  assert.equal(r.sub, "Resets in 2 hr");
});

test("0% is a real reading, not a missing one", () => {
  const r = evaluate(live(0), "five_hour", NOW);
  assert.equal(r.state, "live");
  assert.equal(r.pct, 0);
  assert.equal(formatPct(r.pct), "0% used");
});

test("an old file goes stale rather than showing a confident number", () => {
  const fresh = evaluate(live(50, 2 * 3600e3, STALE_AFTER_MS - 1000), "five_hour", NOW);
  assert.equal(fresh.state, "live");
  const old = evaluate(live(50, 2 * 3600e3, STALE_AFTER_MS + 1000), "five_hour", NOW);
  assert.equal(old.state, "stale");
  assert.equal(old.pct, 50); // number kept, panel dimmed
});

test("a window whose reset has passed reports no number at all", () => {
  const r = evaluate(live(73, -1000), "five_hour", NOW);
  assert.equal(r.state, "stale");
  assert.equal(r.pct, null);
  assert.equal(r.sub, "window reset");
  assert.equal(formatPct(r.pct), "-- ".trim());
});

test("missing, empty and malformed payloads all degrade to waiting", () => {
  for (const bad of [null, undefined, "nope", 42, {}, { windows: {} }, { windows: { five_hour: {} } }]) {
    const r = evaluate(bad, "five_hour", NOW);
    assert.equal(r.state, "waiting", `payload: ${JSON.stringify(bad)}`);
    assert.equal(r.pct, null);
  }
});

test("asking for a window the file does not carry is waiting, not a crash", () => {
  assert.equal(evaluate(live(50), "seven_day", NOW).state, "waiting");
});
