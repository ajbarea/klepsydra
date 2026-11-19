import { test } from "node:test";
import assert from "node:assert/strict";
import { toRows } from "./gauge.js";
import {
  accountBadge,
  agyGroups,
  buildEntries,
  buttonTitle,
  firstModel,
  launchArgs,
  limitingRoom,
  menuEntries,
  pickDefault,
  roomWords,
} from "./fleet/newsession.js";

// Readings as read_usage returns them on AJ's PC (11-19): one file per
// session, the account's uuid and its organisation's label, agy's quota under
// agy-primary with its Claude & GPT group as claude_gpt.
const NOW = 1_795_076_600_000;
const S = NOW / 1000;
const PERSONAL = "6f5fe38b-9f23-4588-b57a-6efd1225cadd";
const RIT = "96130a18-106b-49a2-9b8e-a0b4d52aa214";
const reading = (account, label, session, at, windows, extra = {}) => ({
  account, label, session, written_at: at, observed_at: at, api_ms: 1000, windows, ...extra,
});
const REAL = [
  reading(PERSONAL, "Personal", "537f9cf4", S - 15, {
    five_hour: { used_percentage: 3, resets_at: S + 15_400 },
    seven_day: { used_percentage: 57, resets_at: S + 380_200 },
  }),
  // A second session of the same account, older: the gauge reconciles it away.
  reading(PERSONAL, "Personal", "1111aaaa", S - 900, {
    five_hour: { used_percentage: 1, resets_at: S + 15_400 },
    seven_day: { used_percentage: 55, resets_at: S + 380_200 },
  }),
  reading(RIT, "RIT-CS-DQL", "14887126", S - 13, {
    five_hour: { used_percentage: 7, resets_at: S + 4_600 },
    seven_day: { used_percentage: 28, resets_at: S + 553_000 },
  }),
  reading("agy-primary", "Google AI Pro", "0e9aa7fa", S - 95, {
    five_hour: { used_percentage: 25.95, resets_at: S + 10_316 },
    seven_day: { used_percentage: 31.81, resets_at: S + 543_116 },
    claude_gpt: { used_percentage: 0, resets_at: S + 17_905 },
  }, { harness: "agy" }),
];
const AGY_MODELS = [
  { id: "gemini-3.8-flash-high", label: "Gemini 3.8 Flash (High)", group: "gemini" },
  { id: "gemini-3.8-flash-low", label: "Gemini 3.8 Flash (Low)", group: "gemini" },
  { id: "claude-opus-4-6-thinking", label: "Claude Opus 4.6 (Thinking)", group: "3p" },
  { id: "gpt-oss-120b-medium", label: "GPT-OSS 120B (Medium)", group: "3p" },
];
const ENGINES = { claude: [PERSONAL, RIT], agy: true, copilot: true };
const entriesOf = (readings = REAL, opts = {}) =>
  buildEntries({ rows: toRows(readings, NOW), engines: ENGINES, agy: { state: "ok", models: AGY_MODELS }, nowMs: NOW, ...opts });
const byId = (es, id) => es.find((e) => e.id === id);

test("the real readings give one Claude entry per account, named by the account's own label", () => {
  const es = entriesOf();
  assert.deepEqual(es.map((e) => e.id), [`claude:${PERSONAL}`, `claude:${RIT}`, "agy", "copilot"]);
  assert.deepEqual(es.map((e) => e.name), ["Claude on Personal", "Claude on RIT", "Antigravity", "Copilot"]);
  assert.equal(byId(es, `claude:${RIT}`).badge, "RIT");
  assert.equal(byId(es, `claude:${RIT}`).accountLabel, "RIT-CS-DQL account");
});

test("a badge comes from any account's label, not from a known name or id", () => {
  assert.equal(accountBadge("Acme-Team Org"), "Acme");
  assert.equal(accountBadge("ajbareaa@gmail.com's Organization"), "ajbareaa");
  assert.equal(accountBadge(""), "");
  const one = entriesOf([REAL[2]], { engines: { ...ENGINES, claude: [RIT] } });
  assert.equal(byId(one, `claude:${RIT}`).name, "Claude", "one account needs no badge");
});

test("room is the reconciled reading: an extra session adds no row and an older one does not win", () => {
  const p = byId(entriesOf(), `claude:${PERSONAL}`);
  assert.equal(p.room.pct, 43, "the newest session's week, 57% used");
  assert.equal(p.room.word, "week", "the week binds when it has less room than the session");
});

test("an ended window binds nothing: a spent session that has reset leaves the week", () => {
  const ended = [reading(RIT, "RIT-CS-DQL", "x", S - 20_000, {
    five_hour: { used_percentage: 100, resets_at: S - 60 },
    seven_day: { used_percentage: 28, resets_at: S + 553_000 },
  })];
  const e = byId(entriesOf(ended), `claude:${RIT}`);
  assert.equal(e.room.spent, false);
  assert.equal(e.room.pct, 72);
});

test("a spent window says out and when it comes back", () => {
  const rows = toRows([reading(RIT, "RIT-CS-DQL", "x", S, {
    five_hour: { used_percentage: 100, resets_at: S + 3_600 },
    seven_day: { used_percentage: 40, resets_at: S + 553_000 },
  })], NOW);
  const r = limitingRoom(rows, NOW);
  assert.equal(r.spent, true);
  assert.equal(roomWords(r).bold, "out");
  assert.match(roomWords(r).detail, /^until \d/);
  assert.equal(limitingRoom([], NOW), null);
  assert.deepEqual(roomWords(null), { bold: "–", detail: "no reading yet" });
});

test("agy's models sit in their quota group by agy's own grouping, never by id", () => {
  const odd = [...AGY_MODELS, { id: "gemini-lookalike", label: "Lookalike", group: "3p" }, { id: "mystery-1", label: "Mystery" }];
  const groups = agyGroups(odd, toRows(REAL, NOW).filter((r) => r.harness === "agy"), NOW);
  assert.deepEqual(groups.map((g) => g.key), ["gemini", "3p", "other"]);
  assert.ok(groups[1].models.some((m) => m.id === "gemini-lookalike"), "a gemini- id in the 3p group stays there");
  assert.equal(groups[0].label, "Gemini · 74% of the session, 68% of the week");
  assert.equal(groups[1].label, "Claude & GPT · 100% of the session");
});

test("a spent Claude & GPT group turns off only its own models", () => {
  const spent = REAL.map((r) => (r.account === "agy-primary"
    ? { ...r, windows: { ...r.windows, claude_gpt: { used_percentage: 100, resets_at: S + 3_000 } } }
    : r));
  const agy = byId(entriesOf(spent), "agy");
  const g3p = agy.groups.find((g) => g.key === "3p");
  assert.ok(g3p.spent && g3p.models.every((m) => m.disabled && m.why === "spent"));
  assert.match(g3p.label, /^Claude & GPT · spent, back \d/);
  assert.ok(agy.groups.find((g) => g.key === "gemini").models.every((m) => !m.disabled));
  assert.equal(firstModel(agy), "gemini-3.8-flash-high", "Gemini first");
  assert.equal(agy.room.spent, false, "agy's own room is Gemini's");
});

test("the default: your choice, else the last engine you started, else the first set up", () => {
  const es = entriesOf();
  assert.equal(pickDefault(es, { userDefault: "agy", lastUsed: "copilot" }).entry.id, "agy");
  assert.equal(pickDefault(es, { userDefault: null, lastUsed: "copilot" }).reason, "the engine you used last");
  assert.equal(pickDefault(es, {}).entry.id, `claude:${PERSONAL}`);
  const noCopilot = entriesOf(REAL, { engines: { ...ENGINES, copilot: false } });
  assert.equal(pickDefault(noCopilot, { userDefault: "copilot", lastUsed: "agy" }).entry.id, "agy", "a choice not set up now is passed over");
  assert.equal(pickDefault(es, { userDefault: "claude:gone" }).reason, "the first engine set up here");
});

test("the menu never repeats the default and puts the free-first Recommended engine first", () => {
  const es = entriesOf();
  const rec = es.filter((e) => e.recommended).map((e) => e.id);
  assert.deepEqual(rec, ["agy"], "the gauge's free-first route picks agy's Gemini");
  const menu = menuEntries(es, `claude:${RIT}`);
  assert.deepEqual(menu.map((e) => e.id), ["agy", `claude:${PERSONAL}`, "copilot"]);
});

test("a missing engine stays listed, off, with the one step that fixes it", () => {
  const es = buildEntries({
    rows: toRows(REAL, NOW),
    engines: { claude: [RIT], agy: false, copilot: false },
    agy: { state: "missing", models: [] },
    nowMs: NOW,
  });
  assert.equal(byId(es, "agy").fix, "install");
  assert.equal(byId(es, "copilot").fix, "install");
  assert.equal(byId(es, `claude:${PERSONAL}`).fix, "signin", "a reading with no login here");
  assert.ok(!byId(es, `claude:${PERSONAL}`).usable && byId(es, `claude:${RIT}`).usable);
});

test("agy that is installed but fails to list says so and offers a retry, never 'not signed in'", () => {
  const es = buildEntries({ rows: [], engines: ENGINES, agy: { state: "error", models: [], error: "agy models did not answer." }, nowMs: NOW });
  const agy = byId(es, "agy");
  assert.equal(agy.fix, "retry");
  assert.equal(agy.signedIn, true);
  assert.equal(agy.failed, "agy models did not answer.");
});

test("Start sends the engine, account and model the launcher takes", () => {
  const es = entriesOf();
  assert.deepEqual(launchArgs(byId(es, `claude:${RIT}`), "opus"), { engine: "claude", account: RIT, model: "opus" });
  assert.deepEqual(launchArgs(byId(es, `claude:${RIT}`)), { engine: "claude", account: RIT });
  assert.deepEqual(launchArgs(byId(es, "agy"), "gemini-3.8-flash-low"), { engine: "agy", model: "gemini-3.8-flash-low" });
  assert.deepEqual(launchArgs(byId(es, "copilot")), { engine: "copilot" });
  const none = buildEntries({ rows: [], engines: null, nowMs: NOW });
  assert.equal(launchArgs(byId(none, "claude")), null, "no account known: plain claude, as before");
});

test("the button's title names the engine and its room", () => {
  const es = entriesOf();
  assert.equal(buttonTitle(byId(es, `claude:${RIT}`)), "Claude on RIT: 72% of the week left", "its week has less room than its session");
  assert.equal(buttonTitle(byId(es, "copilot")), "Start a Copilot session");
});
