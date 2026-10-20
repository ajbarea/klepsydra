import { test } from "node:test";
import assert from "node:assert/strict";
import { rampColor, rampPosition, formatCountdown, formatCountdownShort, formatAge, formatAgeShort, evaluate, formatPct, formatPctShort, ringDash, toRows, SHOW_AGE_AFTER_MS, DROP_AFTER_MS } from "./gauge.js";

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

test("short countdown formatting, for the compact layout", () => {
  assert.equal(formatCountdownShort(secs(NOW + 4 * 3600e3 + 58 * 60e3), NOW), "4h 58m");
  assert.equal(formatCountdownShort(secs(NOW + 58 * 60e3), NOW), "58m");
  assert.equal(formatCountdownShort(secs(NOW + 2 * 3600e3), NOW), "2h");
  assert.equal(formatCountdownShort(secs(NOW + 30e3), NOW), "<1m");
  assert.equal(formatCountdownShort(secs(NOW + 3 * 86400e3 + 4 * 3600e3 + 5 * 60e3), NOW), "3d 4h");
  assert.equal(formatCountdownShort(secs(NOW + 2 * 86400e3 + 30 * 60e3), NOW), "2d");
  assert.equal(formatCountdownShort(secs(NOW - 1), NOW), null);
  assert.equal(formatCountdownShort(undefined, NOW), null);
});

test("long and short countdowns agree on every unit boundary", () => {
  for (const mins of [0, 1, 59, 60, 61, 119, 120, 1439, 1440, 1441, 1500, 2880, 10079]) {
    const at = secs(NOW + mins * 60e3 + 30e3);
    const long = formatCountdown(at, NOW).replace("Resets in ", "");
    const short = formatCountdownShort(at, NOW);
    const expand = short
      .replace("<1m", "under a minute")
      .replace(/(\d+)d/, (_, d) => `${d} day${d === "1" ? "" : "s"}`)
      .replace(/(\d+)h/, "$1 hr")
      .replace(/(\d+)m$/, "$1 min");
    assert.equal(expand, long, `${mins} min`);
  }
});

test("short ages read in the largest whole unit", () => {
  assert.equal(formatAgeShort(30e3), "now");
  assert.equal(formatAgeShort(59 * 60e3), "59m");
  assert.equal(formatAgeShort(3 * 3600e3 + 59 * 60e3), "3h");
  assert.equal(formatAgeShort(25 * 3600e3), "1d");
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

test("an old reading says how old it is instead of dimming", () => {
  const fresh = evaluate(live(50, 2 * 3600e3, SHOW_AGE_AFTER_MS - 1000), "five_hour", NOW);
  assert.equal(fresh.sub, "Resets in 2 hr");
  const old = evaluate(live(50, 2 * 3600e3, SHOW_AGE_AFTER_MS + 1000), "five_hour", NOW);
  assert.equal(old.state, "live");
  assert.equal(old.pct, 50);
  assert.equal(old.sub, "Resets in 2 hr \u00b7 updated 15 min ago");
});

test("a window whose reset has passed reads as an empty window", () => {
  const r = evaluate(live(73, -1000), "five_hour", NOW);
  assert.equal(r.state, "reset");
  assert.equal(r.pct, 0);
  assert.equal(r.sub, "Reset just now");
  assert.equal(formatPct(r.pct), "0% used");
  assert.equal(evaluate(live(73, -2 * 3600e3), "five_hour", NOW).sub, "Reset 2 hr ago");
});

test("every reading carries a short form that keeps its warnings", () => {
  const fresh = evaluate(live(73.2), "five_hour", NOW);
  assert.equal(fresh.short, "2h");
  assert.equal(formatPctShort(fresh.pct), "73%");
  const old = evaluate(live(50, 2 * 3600e3, SHOW_AGE_AFTER_MS + 1000), "five_hour", NOW);
  assert.equal(old.short, "2h · 15m old");
  const unknown = evaluate({ windows: { five_hour: { used_percentage: 5, resets_at: secs(NOW + 3600e3) } } }, "five_hour", NOW);
  assert.equal(unknown.short, "1h · age unknown");
  assert.equal(evaluate(live(73, -1000), "five_hour", NOW).short, "just reset");
  assert.equal(evaluate(live(73, -2 * 3600e3), "five_hour", NOW).short, "reset 2h ago");
  assert.equal(formatPctShort(null), "--");
  assert.equal(formatPctShort(118.7), "118%");
});

test("ages read in the largest whole unit", () => {
  assert.equal(formatAge(30e3), "just now");
  assert.equal(formatAge(59 * 60e3), "59 min ago");
  assert.equal(formatAge(3 * 3600e3 + 59 * 60e3), "3 hr ago");
  assert.equal(formatAge(25 * 3600e3), "1 day ago");
  assert.equal(formatAge(3 * 86400e3), "3 days ago");
});

test("missing, empty and malformed payloads all degrade to waiting", () => {
  for (const bad of [null, undefined, "nope", 42, {}, { windows: {} }, { windows: { five_hour: {} } }]) {
    const r = evaluate(bad, "five_hour", NOW);
    assert.equal(r.state, "waiting", `payload: ${JSON.stringify(bad)}`);
    assert.equal(r.pct, null);
  }
});

test("a reading with no usable time says so rather than passing as fresh", () => {
  const r = evaluate({ windows: { five_hour: { used_percentage: 50, resets_at: secs(NOW + 2 * 3600e3) } } }, "five_hour", NOW);
  assert.equal(r.pct, 50);
  assert.equal(r.sub, "Resets in 2 hr \u00b7 age unknown");
});

test("asking for a window the file does not carry is waiting, not a crash", () => {
  assert.equal(evaluate(live(50), "seven_day", NOW).state, "waiting");
});

// ── multi-account rows ──────────────────────────────────────────────────────
const acct = (id, label, windows, writtenAgoMs = 0) => ({
  account: id, label, written_at: secs(NOW - writtenAgoMs), observed_at: secs(NOW - writtenAgoMs), windows,
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

test("an account is named by its newest reading, whichever comes first", () => {
  const older = acct("t", "Old Org", { five_hour: win(10) }, 3600e3);
  const newer = acct("t", "New Org", { five_hour: win(20) });
  for (const list of [[older, newer], [newer, older]]) {
    const rows = toRows([...list, acct("p", "Personal", { five_hour: win(5) }, 7200e3)], NOW);
    assert.equal(rows[0].label, "New Org · session");
  }
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
  assert.equal(rows[0].sub, "Reset just now");
  assert.equal(rows[0].pct, 0);
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
    was: acct("was", "RIT-CS-DQL", { five_hour: win(70) }, 40 * 60e3), // old reading, window live
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Personal · session", "RIT-CS-DQL · session"]);
  assert.equal(rows[1].sub, "Resets in 2 hr \u00b7 updated 40 min ago");
});

test("a switched-away account stays once its window resets", () => {
  // An emptied window is the reason to switch back, so it is the last thing
  // to hide.
  const rows = toRows({
    now: acct("now", "Personal", { five_hour: win(10) }),
    was: acct("was", "RIT-CS-DQL", { five_hour: win(70, -60e3) }, 40 * 60e3),
  }, NOW);
  assert.deepEqual(rows.map((r) => [r.label, r.pct, r.sub]), [
    ["Personal · session", 10, "Resets in 2 hr"],
    ["RIT-CS-DQL · session", 0, "Reset 1 min ago"],
  ]);
});

test("an account unused for days keeps its rows", () => {
  const rows = toRows({
    now: acct("now", "Personal", { five_hour: win(10) }),
    was: acct("was", "RIT-CS-DQL", { five_hour: win(70, -2 * 86400e3) }, 3 * 86400e3),
  }, NOW);
  assert.deepEqual(rows.map((r) => r.label), ["Personal · session", "RIT-CS-DQL · session"]);
});

// ── reconciling several sessions of one account ─────────────────────────────
const sess = (id, pct, resetsInMs = 2 * 3600e3, writtenAgoMs = 0, label = "Personal") => ({
  account: "acct", label, session: id,
  written_at: secs(NOW - writtenAgoMs), observed_at: secs(NOW - writtenAgoMs),
  windows: { five_hour: { used_percentage: pct, resets_at: secs(NOW + resetsInMs) } },
});

test("idle sessions holding stale numbers do not drag the reading down", () => {
  // Three terminals on one login publishing 62/3/35 and the bar flipping
  // between them. The hook publishes only new readings, so the terminal heard
  // from last is current.
  const rows = toRows([sess("a", 62, 2 * 3600e3, 10e3), sess("b", 3, 2 * 3600e3, 3 * 3600e3), sess("c", 35, 2 * 3600e3, 3600e3)], NOW);
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

test("a reset inside a window is believed, not overruled by older readings", () => {
  // Seen twice in a fortnight: the weekly fell from 94 to 29, and from 100 to 1
  // after a plan upgrade, with resets_at unchanged. Idle sessions kept the old
  // number, and taking the highest showed it for days.
  const rows = toRows([
    sess("before", 94, 30 * 3600e3, 3 * 86400e3),
    sess("after", 29, 30 * 3600e3, 60e3),
  ], NOW);
  assert.equal(rows[0].pct, 29);
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

test("a reset window the account no longer reports is left out", () => {
  // A team seat reports no weekly window. One misfiled under it before the
  // hook stopped republishing re-renders must not linger as an empty row.
  const rows = toRows([
    { account: "t", label: "RIT-CS-DQL", session: "misfiled", written_at: secs(NOW - 5 * 86400e3),
      windows: { seven_day: win(92, -5 * 86400e3) } },
    { account: "t", label: "RIT-CS-DQL", session: "real", written_at: secs(NOW - 6 * 3600e3),
      windows: { five_hour: win(100, -3600e3) } },
    { account: "p", label: "Personal", session: "now", written_at: secs(NOW),
      windows: { five_hour: win(10), seven_day: win(31, 30 * 3600e3) } },
  ], NOW);
  assert.deepEqual(rows.map((r) => r.label), [
    "Personal \u00b7 session", "Personal \u00b7 week", "RIT-CS-DQL \u00b7 session",
  ]);
});

test("a live window stays even when the latest reading omits it", () => {
  const rows = toRows([
    { ...sess("older", 40), windows: { five_hour: win(40), seven_day: win(20, 86400e3) }, written_at: secs(NOW - 600e3) },
    { ...sess("newer", 45), windows: { five_hour: win(45) } },
  ], NOW);
  assert.deepEqual(rows.map((r) => r.pct), [45, 20]);
});

// ── an old hook still installed ─────────────────────────────────────────────
// Before `observed_at`, the hook restamped every session on every re-render,
// so `written_at` says when a terminal last redrew, not when its reading came.
const legacy = (id, pct, writtenAgoMs, resetsInMs = 2 * 3600e3) => {
  const { observed_at, ...s } = sess(id, pct, resetsInMs, writtenAgoMs);
  return s;
};
const observed = (id, pct, agoMs, resetsInMs = 2 * 3600e3) => sess(id, pct, resetsInMs, agoMs);

test("files from an old hook keep the highest reading rather than flapping", () => {
  // An old hook with refreshInterval restamps idle sessions every 30s, so the
  // newest stamp is whichever terminal redrew last.
  for (const order of [["a", "b", "c"], ["b", "c", "a"], ["c", "a", "b"]]) {
    const pcts = { a: 62, b: 3, c: 35 };
    const rows = toRows(order.map((id, i) => legacy(id, pcts[id], i * 1000)), NOW);
    assert.equal(rows[0].pct, 62, `newest stamp on ${order[0]}`);
  }
});

test("observed readings take the newest, not the highest", () => {
  const rows = toRows([
    observed("before", 94, 3 * 86400e3, 30 * 3600e3),
    observed("after", 29, 60e3, 30 * 3600e3),
  ], NOW);
  assert.equal(rows[0].pct, 29);
});

test("an old hook still writing beside the new one makes the times untrusted", () => {
  // A new reading from weeks ago, and an old hook restamping a live session
  // now: the newer file wins its windows rather than being thrown away.
  const rows = toRows([
    { ...observed("old", 90, 20 * 86400e3, -13 * 86400e3), windows: { seven_day: win(90, -13 * 86400e3) } },
    { ...legacy("live", 40, 0), windows: { five_hour: win(40), seven_day: win(30, 30 * 3600e3) } },
  ], NOW);
  assert.deepEqual(rows.map((r) => [r.label, r.pct]), [["Current session", 40], ["This week", 30]]);
});

test("old files the new hook has since overtaken are ignored", () => {
  const rows = toRows([
    legacy("frozen", 100, 3600e3, 30 * 3600e3),
    observed("fresh", 29, 60e3, 30 * 3600e3),
  ], NOW);
  assert.equal(rows[0].pct, 29);
});

test("a session with no usable time reads as age unknown, not decades old", () => {
  const { written_at, ...undated } = legacy("undated", 50, 0);
  const rows = toRows([legacy("dated", 10, 0), undated], NOW);
  assert.equal(rows[0].pct, 50);
  assert.equal(rows[0].sub, "Resets in 2 hr \u00b7 age unknown");
});


test("the ring's drawn arc, caps included, is the percentage", () => {
  const cap = 5;
  assert.equal(ringDash(97, cap) + cap, 97, "97% leaves a gap, not a closed ring");
  assert.equal(ringDash(50, cap) + cap, 50);
  assert.equal(ringDash(100, cap), 100, "a full window closes the ring");
  assert.equal(ringDash(118, cap), 100, "over the limit is still one full ring");
  assert.equal(ringDash(0, cap), 0);
  assert.equal(ringDash(null, cap), 0);
  assert.ok(ringDash(1, cap) > 0 && ringDash(1, cap) < 0.1, "1% is a dot, the caps alone");
});
