import { test } from "node:test";
import assert from "node:assert/strict";
import { ROUTE_ORDER, toRows } from "./gauge.js";
import { AGE_TEXT_AFTER_MS, CHIP_ORDER, LANE_HARNESS, STALE_AFTER_MS, ageText, cellWhen, chipName, clockAt, dockKey, hiddenRows, leadOf, markOf, primaryChip, toChips } from "./fleet/chips.js";

const NOW = Date.UTC(2026, 10, 18, 18, 23); // Wed 18 Nov, 1:23 PM EST
const S = NOW / 1000;
const win = (pct, inSec) => ({ used_percentage: pct, resets_at: S + inSec });
const reading = (account, label, windows, extra = {}) => ({
  account, label, written_at: S - 60, observed_at: S - 60, windows, ...extra,
});

// The 11-18 readings the mockups show (readings.js SOURCE), times relative to NOW.
const LIVE = [
  reading("agy-primary", "Google AI Pro", { five_hour: win(7.2, 6720), seven_day: win(4.06, 590_000), claude_gpt: win(100, 7740) }, { harness: "agy", observed_at: S - 3000, written_at: S - 3000 }),
  reading("6f5fe38b-9f23", "Personal", { five_hour: win(9, 10_620), seven_day: win(45, 430_000) }),
  reading("96130a18-106b", "RIT-CS-DQL", { five_hour: win(2, 17_820), seven_day: win(0, 601_000) }, { observed_at: S - 30, written_at: S - 30 }),
];
const chips = (payload, now = NOW) => toChips(toRows(payload, now), now);

test("every route lane names an engine, so chips follow the fleet's order", () => {
  for (const lane of ROUTE_ORDER) assert.ok(LANE_HARNESS[lane], lane);
  assert.deepEqual(CHIP_ORDER, ["agy", "copilot", "api", "claude"]);
});

test("one chip per account, in route order, with Copilot's placeholder", () => {
  const c = chips(LIVE);
  assert.deepEqual(c.map((x) => x.name), ["Google AI Pro", "Copilot", "Claude · Personal", "Claude · RIT-CS-DQL"]);
  assert.equal(c[1].placeholder, true);
  assert.equal(c[1].when, "no reading yet");
});

test("order holds whichever account was read last", () => {
  const swapped = LIVE.map((r) => (r.label === "Personal" ? { ...r, written_at: S - 5, observed_at: S - 5 } : r));
  assert.deepEqual(chips(swapped).map((x) => x.name), chips(LIVE).map((x) => x.name));
});

test("the lead is the tightest account window; a spent model group never leads", () => {
  const [agy, , personal] = chips(LIVE);
  assert.equal(agy.lead.window, "five_hour", "claude_gpt is at 100% but is one group's pool");
  assert.equal(agy.value, "7%");
  assert.equal(agy.when, "1h 52m");
  assert.deepEqual(agy.pips.map((r) => r.window), ["five_hour", "seven_day", "claude_gpt"]);
  assert.equal(agy.out, false);
  assert.equal(personal.lead.window, "seven_day");
  assert.equal(personal.value, "45%");
});

test("a spent week reads out until its reset and hides the session", () => {
  const out = chips([reading("rit", "RIT-CS-DQL", { five_hour: win(0, 3600), seven_day: win(100, 33_120) })], NOW);
  const rit = out.find((c) => c.account === "rit");
  assert.equal(rit.out, true);
  assert.equal(rit.value, "out");
  assert.match(rit.when, /^until /);
  assert.deepEqual(rit.pips.map((r) => r.window), ["seven_day"]);
  assert.equal(rit.hidden.length, 1);
  assert.ok(rit.detail.some((l) => /hidden until the week resets/.test(l)));
});

test("a spent session (week not spent) leads and reads out", () => {
  const c = chips([reading("p", "Personal", { five_hour: win(100, 600), seven_day: win(40, 90_000) })]).find((x) => x.account === "p");
  assert.equal(c.lead.window, "five_hour");
  assert.equal(c.out, true);
  assert.deepEqual(c.hidden, []);
});

test("an account with only group windows leads with one of them", () => {
  const api = chips([reading("api-1", "Personal API", { personal: win(30, 9000), ldqis: win(70, 9000) }, { harness: "api" })]);
  const c = api.find((x) => x.harness === "api");
  assert.equal(c.lead.window, "ldqis");
});

test("a window that has reset shows the reset, not a countdown", () => {
  const r = reading("p", "Personal", { five_hour: win(50, -7200), seven_day: win(10, 90_000) });
  const c = chips([r]).find((x) => x.account === "p");
  // The ended session reads 0% and the week leads; the ended window stays a pip.
  assert.equal(c.lead.window, "seven_day");
  assert.ok(c.pips.some((p) => p.state === "reset"));
});

test("a stale reading dims and names its age; a fresh one does not", () => {
  const old = S - STALE_AFTER_MS / 1000 - 600;
  const c = chips([reading("agy", "Google AI Pro", { seven_day: win(95, 300_000) }, { harness: "agy", written_at: old, observed_at: old })]);
  assert.equal(c[0].stale, true);
  assert.equal(c[0].age, "3h old");
  assert.equal(chips(LIVE)[0].stale, false);
  assert.equal(chips(LIVE)[0].age, null);
});

test("the route mark lands on the chip toRows recommends, once", () => {
  const c = chips(LIVE);
  const marked = c.filter((x) => x.route);
  assert.equal(marked.length, 1);
  assert.equal(marked[0].harness, "agy", "free first: agy Gemini (#411)");
  assert.ok(marked[0].detail.at(-1).startsWith("Route:"));
});

test("no readings: only the placeholder; no placeholder once Copilot reads", () => {
  assert.deepEqual(chips(null).map((c) => c.key), ["copilot:placeholder"]);
  assert.deepEqual(toChips([], NOW, []), []);
  const withCopilot = chips([...LIVE, reading("copilot-1", "Copilot", { five_hour: win(5, 999) }, { harness: "copilot" })]);
  assert.equal(withCopilot.filter((c) => c.harness === "copilot").length, 1);
  assert.equal(withCopilot.find((c) => c.harness === "copilot").placeholder, false);
});

test("marks: engine logos, an organisation's monogram, never a brand colour", () => {
  assert.deepEqual(markOf("claude", "Personal"), { icon: "claude" });
  assert.deepEqual(markOf("claude", "RIT-CS-DQL"), { mono: "RIT" });
  assert.deepEqual(markOf("claude", "  "), { icon: "claude" });
  assert.deepEqual(markOf("claude", "Acme Research Lab"), { mono: "ACME" });
  assert.deepEqual(markOf("agy", "Google AI Pro"), { icon: "agy" });
  assert.deepEqual(markOf("api", "LDQIS"), { icon: "anthropic" });
  assert.equal(chipName("claude", ""), "Claude");
  assert.equal(chipName("copilot", null), "Copilot");
});

test("leadOf keeps window order on a tie", () => {
  const rows = [
    { window: "five_hour", pct: 10, state: "live" },
    { window: "seven_day", pct: 10, state: "live" },
  ];
  assert.equal(leadOf(rows).lead.window, "five_hour");
});

test("the primary chip is the account read most recently", () => {
  assert.equal(primaryChip(chips(LIVE)).account, "96130a18-106b");
  assert.equal(primaryChip(chips(null)), null);
});

test("faces dock by account, then by engine, else nowhere", () => {
  const c = chips(LIVE);
  assert.equal(dockKey({ account: { id: "6f5fe38b-9f23" } }, c), "6f5fe38b-9f23");
  assert.equal(dockKey({ engine: "agy" }, c), "agy-primary");
  assert.equal(dockKey({ engine: "copilot" }, c), "copilot:placeholder");
  assert.equal(dockKey({ engine: "claude", account: { id: "gone" } }, c), null);
  assert.equal(dockKey({}, c), null);
  assert.equal(dockKey(null, c), null);
});

test("every chip carries a spoken line naming each shown window", () => {
  for (const c of chips(LIVE)) {
    assert.ok(c.spoken.startsWith(c.name));
    if (!c.placeholder) for (const r of c.windows) assert.ok(c.spoken.length > c.name.length, r.window);
  }
});

test("the chip view's imports resolve (a missing export fails here, not in the strip)", async () => {
  const view = await import("./fleet/chipview.js");
  assert.equal(typeof view.syncChips, "function");
  assert.equal(typeof view.dockSlots, "function");
});

// Review of #421 PR 1: each window keeps its own reading's age.
const agyFresh = reading("agy", "Google AI Pro", { five_hour: win(7, 6720), seven_day: win(4, 590_000) }, { harness: "agy" });
const agyOld = (pct, age) => reading("agy", "Google AI Pro", { claude_gpt: win(pct, 4 * 86_400) }, { harness: "agy", written_at: S - age, observed_at: S - age });

test("a window kept from an older reading names its own age in the hover", () => {
  const [agy] = chips([agyFresh, agyOld(100, 2 * 86_400)]);
  assert.equal(agy.lead.window, "five_hour");
  assert.equal(agy.stale, false, "the lead's own reading is fresh");
  assert.ok(agy.detail.some((l) => /^Claude & GPT 100% · out until \w{3} \d{1,2}:\d\d [AP]M · read 2d ago$/.test(l)), agy.detail.join(" | "));
  assert.ok(agy.detail.some((l) => /^Current session 7% · resets [^·]+\)$/.test(l)), "a fresh window carries no age");
});

test("a chip whose lead window is old is stale and says its age", () => {
  const old = reading("agy", "Google AI Pro", { five_hour: win(70, 6720) }, { harness: "agy", written_at: S - 4 * 3600, observed_at: S - 4 * 3600 });
  const [agy] = chips([old]);
  assert.equal(agy.stale, true);
  assert.equal(agy.age, "4h old");
  // Only the lead decides: a fresh lead beside an old window is not stale.
  assert.equal(chips([agyFresh, agyOld(10, 4 * 3600)])[0].stale, false);
  // And an old lead under a fresh reading of another window is.
  const weekOld = reading("me", "Personal", { seven_day: win(90, 86_400) }, { written_at: S - 4 * 3600, observed_at: S - 4 * 3600 });
  const me = chips([reading("me", "Personal", { five_hour: win(5, 3600) }), weekOld]).find((c) => c.account === "me");
  assert.equal(me.lead.window, "seven_day");
  assert.equal(me.stale, true);
  assert.equal(me.age, "4h old");
});

test("ages are written from 30 minutes; the linear row only once stale", () => {
  assert.equal(ageText(AGE_TEXT_AFTER_MS - 60_000), null);
  assert.equal(ageText(AGE_TEXT_AFTER_MS), "30m old");
  assert.equal(ageText(Number.NaN), null);
  const at = (min) => chips([reading("p", "Personal", { five_hour: win(9, 9000) }, { written_at: S - min * 60, observed_at: S - min * 60 })])
    .find((c) => c.account === "p");
  assert.equal(at(20).ageText, null);
  assert.equal(at(50).ageText, "50m old");
  assert.equal(at(50).age, null, "the linear row stays quiet until stale");
  assert.equal(at(200).age, "3h old");
});

test("a spent week hides only its own account's session, on every surface", () => {
  const rows = toRows([
    reading("rit", "RIT", { five_hour: win(0, 3600), seven_day: win(100, 33_120) }),
    reading("me", "Personal", { five_hour: win(5, 3600), seven_day: win(40, 33_120) }),
  ], NOW);
  const hidden = [...hiddenRows(rows)];
  assert.deepEqual(hidden.map((r) => r.key), ["rit:five_hour"]);
  assert.deepEqual(leadOf(rows.filter((r) => r.account === "rit")).hidden, hidden);
});

test("boundary inputs: no rows, a spent window with no reset time, a label that names no organisation", () => {
  assert.deepEqual(leadOf([]), { lead: null, out: false, hidden: [] });
  assert.equal(cellWhen({ state: "live", pct: 100, resetsAt: Number.NaN }, NOW), "until it resets");
  assert.equal(chipName("claude", "Claude"), "Claude");
  assert.deepEqual(markOf("claude", "Claude"), { icon: "claude" });
  assert.deepEqual(markOf("claude", "RIT-CS-DQL"), { mono: "RIT" });
});

test("clockAt: today's time alone, another day's with its weekday, as toLocale* wrote them", () => {
  // Local noon, so an hour either way stays on the same day in any time zone.
  const noon = new Date(2026, 10, 18, 12, 0).getTime();
  const sec = (ms) => ms / 1000;
  const time = (ms) => new Date(ms).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  assert.equal(clockAt(sec(noon + 3_600_000), noon), time(noon + 3_600_000));
  const later = noon + 2 * 86_400_000;
  assert.equal(clockAt(sec(later), noon), `${new Date(later).toLocaleDateString("en-US", { weekday: "short" })} ${time(later)}`);
  assert.equal(clockAt(sec(later), noon), "Fri 12:00 PM");
  assert.equal(clockAt(Number.NaN, noon), null);
  assert.equal(clockAt(1e13, noon), null, "past Date's range: no time, no throw");
  assert.equal(clockAt(null, noon), null, "null is no time, not 1970");
});

test("a reset time past Date's range draws instead of stopping the redraw", () => {
  const bad = reading("me", "Personal", { five_hour: win(100, 3600), seven_day: { used_percentage: 40, resets_at: 1e13 } });
  const me = chips([bad]).find((c) => c.account === "me");
  assert.ok(me.detail.includes("This week 40% · resets at a time the reading does not give"), me.detail.join(" | "));
});
