import { test } from "node:test";
import assert from "node:assert/strict";
import { rampColor, rampPosition, formatCountdown, evaluate, formatPct, toRows, pickWindow, STALE_AFTER_MS, DROP_AFTER_MS } from "./gauge.js";

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

// ── multi-account rows ──────────────────────────────────────────────────────
const acct = (id, label, windows, writtenAgoMs = 0) => ({
  account: id, label, written_at: secs(NOW - writtenAgoMs), windows,
});
const win = (pct, resetsInMs = 2 * 3600e3) => ({
  used_percentage: pct, resets_at: secs(NOW + resetsInMs),
});

test("a single account reads like the desktop app", () => {
  const rows = toRows({ a: acct("a", "Personal", { five_hour: win(30), seven_day: win(10) }) }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Current session", "This week"]);
});

test("two accounts are each labelled so their numbers cannot be confused", () => {
  const rows = toRows({
    t: acct("t", "RIT-CS-DQL", { five_hour: win(80) }),
    p: acct("p", "Personal", { five_hour: win(20), seven_day: win(5) }),
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), [
    "Personal · session", "Personal · week", "RIT-CS-DQL · session",
  ]);
  assert.deepEqual(rows.map((r) => r.pct), [20, 5, 80]);
});

test("the account in use now sits above the one signed out of", () => {
  const rows = toRows({
    p: acct("p", "Personal", { five_hour: win(100), seven_day: win(66) }, 3 * 3600e3),
    t: acct("t", "RIT-CS-DQL", { five_hour: win(20) }),
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), [
    "RIT-CS-DQL \u00b7 session", "Personal \u00b7 session", "Personal \u00b7 week",
  ]);
});

test("row order is stable regardless of object key order", () => {
  const a = { t: acct("t", "RIT-CS-DQL", { five_hour: win(80) }), p: acct("p", "Personal", { five_hour: win(20) }) };
  const b = { p: a.p, t: a.t };
  assert.deepEqual(toRows(a, NOW).map((r) => r.key), toRows(b, NOW).map((r) => r.key));
});

test("windows always appear in a fixed order", () => {
  const rows = toRows({ a: acct("a", "P", { spend_limit: win(3), seven_day: win(2), five_hour: win(1) }) }, NOW);
  assert.deepEqual(rows.map((r) => r.pct), [1, 2, 3]);
});

test("a long-unused account is dropped rather than left dim forever", () => {
  const rows = toRows({
    live: acct("live", "Personal", { five_hour: win(20) }),
    gone: acct("gone", "Old", { five_hour: win(90) }, DROP_AFTER_MS + 1000),
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Current session"]);
});

test("an expired window still shows while the account is active", () => {
  const rows = toRows({ a: acct("a", "P", { five_hour: win(73, -1000) }) }, NOW);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].sub, "window reset");
  assert.equal(rows[0].pct, null);
});

test("junk in the file produces no rows instead of throwing", () => {
  for (const bad of [null, undefined, {}, { a: null }, { a: "x" }, { a: { windows: "no" } }]) {
    assert.deepEqual(toRows(bad, NOW), []);
  }
});

test("multi-day countdowns read in days, not tens of hours", () => {
  assert.equal(formatCountdown(secs(NOW + 83 * 3600e3 + 19 * 60e3), NOW), "Resets in 3 days 11 hr");
  assert.equal(formatCountdown(secs(NOW + 25 * 3600e3), NOW), "Resets in 1 day 1 hr");
  assert.equal(formatCountdown(secs(NOW + 48 * 3600e3), NOW), "Resets in 2 days");
  // The 24-hour boundary must not regress the hour formatting below it.
  assert.equal(formatCountdown(secs(NOW + 23 * 3600e3 + 59 * 60e3), NOW), "Resets in 23 hr 59 min");
});

test("a switched-away account stays while its window is still burning", () => {
  const rows = toRows({
    now: acct("now", "Personal", { five_hour: win(10) }),
    was: acct("was", "RIT-CS-DQL", { five_hour: win(70) }, 40 * 60e3), // stale, window live
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Personal · session", "RIT-CS-DQL · session"]);
  assert.equal(rows[1].state, "stale");
});

test("a switched-away account disappears once its window resets", () => {
  const rows = toRows({
    now: acct("now", "Personal", { five_hour: win(10) }),
    was: acct("was", "RIT-CS-DQL", { five_hour: win(70, -60e3) }, 40 * 60e3),
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Current session"]);
});

// ── reconciling several sessions of one account ─────────────────────────────
const sess = (id, pct, resetsInMs = 2 * 3600e3, writtenAgoMs = 0, label = "Personal") => ({
  account: "acct", label, session: id,
  written_at: secs(NOW - writtenAgoMs),
  windows: { five_hour: { used_percentage: pct, resets_at: secs(NOW + resetsInMs) } },
});

test("idle sessions holding stale numbers do not drag the reading down", () => {
  // The reported bug: three terminals on one login publishing 62/3/35 and the
  // bar flipping between them. Usage only grows inside a window, so 62 is current.
  const rows = toRows([sess("a", 62), sess("b", 3), sess("c", 35)], NOW);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].pct, 62);
});

test("order of sessions does not change the reading", () => {
  const a = toRows([sess("a", 62), sess("b", 3), sess("c", 35)], NOW)[0].pct;
  const b = toRows([sess("c", 35), sess("a", 62), sess("b", 3)], NOW)[0].pct;
  assert.equal(a, b);
});

test("a newer window wins even though its number is lower", () => {
  // After a reset the fresh session reports ~0 against a later resets_at; the
  // stale session still reports the old window's 95.
  const rows = toRows([
    sess("stale", 95, -60e3, 30 * 60e3),
    sess("fresh", 2, 5 * 3600e3),
  ], NOW);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].pct, 2);
});

test("sessions timestamping one window seconds apart are not treated as two", () => {
  const rows = toRows([
    sess("a", 62, 2 * 3600e3),
    sess("b", 20, 2 * 3600e3 + 45e3), // 45s later, same window
  ], NOW);
  assert.equal(rows[0].pct, 62);
});

test("a genuinely later window is still preferred over a near miss", () => {
  const rows = toRows([
    sess("old", 90, 2 * 3600e3),
    sess("new", 5, 2 * 3600e3 + 120e3), // beyond the match tolerance
  ], NOW);
  assert.equal(rows[0].pct, 5);
});

test("reconciliation is per account, never across them", () => {
  const rows = toRows([
    { ...sess("x", 90), account: "team", label: "RIT-CS-DQL" },
    { ...sess("y", 10), account: "pers", label: "Personal" },
  ], NOW);
  assert.deepEqual(rows.map((r) => [r.label, r.pct]), [
    ["Personal · session", 10],
    ["RIT-CS-DQL · session", 90],
  ]);
});

test("an account whose freshest session is recent counts as live", () => {
  const rows = toRows([
    sess("old", 40, 2 * 3600e3, 40 * 60e3),
    sess("new", 61, 2 * 3600e3, 10e3),
  ], NOW);
  assert.equal(rows[0].state, "live");
  assert.equal(rows[0].pct, 61);
});
