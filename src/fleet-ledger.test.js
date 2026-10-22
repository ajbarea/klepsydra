import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MODEL_CAP, NAME_CAP, OTHER, PARTIAL_LABEL, costText, modelName, tokensByModel, activeTime, attributionName, cacheShare, chipLabel, compactNumber, compactPick, costLine, fullNumber,
  characterOf, ledgerLine, receiptParts, receiptText, sumTotals, todaySessions, tokensByCharacter, topAttribution, totalTokens,
} from "./fleet/ledger.js";

test("compactNumber reads at a glance and rounds up into the next unit", () => {
  const cases = [[0, "0"], [999, "999"], [1000, "1k"], [1234, "1.2k"], [34_000, "34k"], [34_400, "34k"], [999_499, "999k"],
    [999_950, "1M"], [1_200_000, "1.2M"], [9_960_000, "10M"], [86_000_000, "86M"], [1_500_000_000, "1.5B"], [999_960_000, "1B"]];
  for (const [value, text] of cases) assert.equal(compactNumber(value), text, String(value));
  for (const bad of [-5, NaN, undefined, null, "x"]) assert.equal(compactNumber(bad), "0", String(bad));
});

test("the cached share is cache reads over every input-side token, output left out", () => {
  assert.equal(cacheShare({ input: 100, output: 9999, cache_read: 800, cache_creation: 100 }), 0.8);
  assert.equal(cacheShare({ input: 0, output: 50, cache_read: 0, cache_creation: 0 }), null);
  assert.equal(cacheShare({}), null);
  assert.equal(totalTokens({ input: 1, output: 2, cache_read: 3, cache_creation: 4 }), 10);
});

test("the receipt names what happened, with the zeros left out", () => {
  const full = {
    lines_added: 312, lines_removed: 40, commits: 2, pull_requests: 1,
    tokens: { input: 100_000, output: 40_000, cache_read: 1_000_000, cache_creation: 60_000 },
  };
  // 1,000,000 / 1,160,000 = 86% of the input side.
  assert.equal(receiptText(receiptParts(full)), "+312 −40 lines · 2 commits · 1 PR · 1.2M tokens (86% cached)");
  const some = { ...full, commits: 0, lines_removed: 0, tokens: { output: 12 } };
  assert.equal(receiptText(receiptParts(some)), "+312 −0 lines · 1 PR · 12 tokens");
  assert.deepEqual(receiptParts({}), []);
  assert.deepEqual(receiptParts({ commits: 0, tokens: { input: 0 } }), []);
  assert.equal(receiptText(receiptParts({ commits: 1 })), "1 commit");
});

test("the compact receipt keeps the three most informative parts in reading order", () => {
  const parts = receiptParts({
    lines_added: 5, lines_removed: 1, commits: 2, pull_requests: 1, tokens: { input: 5 },
  });
  assert.deepEqual(parts.map((p) => p.key), ["lines", "commits", "prs", "tokens"]);
  assert.deepEqual(compactPick(parts).map((p) => p.key), ["lines", "commits", "prs"], "tokens go first");
  const noPr = receiptParts({ lines_added: 5, commits: 2, tokens: { input: 5 } });
  assert.deepEqual(compactPick(noPr).map((p) => p.key), ["lines", "commits", "tokens"]);
  assert.deepEqual(compactPick(noPr.slice(0, 1)).map((p) => p.key), ["lines"]);
});

test("the guardrail chip counts blocked calls and names them in full", () => {
  assert.equal(chipLabel(0), null);
  assert.equal(chipLabel(undefined), null);
  assert.deepEqual(chipLabel(1), { short: "1 blocked", full: "1 blocked: tool call a hook or config rule turned down" });
  assert.deepEqual(chipLabel(3), { short: "3 blocked", full: "3 blocked: tool calls a hook or config rule turned down" });
  for (const n of [1, 2, 40]) assert.ok(chipLabel(n).full.startsWith(chipLabel(n).short), "label in name");
});

test("a card's ledger line is absent when all zero, and shows a chip with no receipt", () => {
  assert.equal(ledgerLine(undefined), null);
  assert.equal(ledgerLine({ tokens: {}, guardrail_rejects: 0, commits: 0 }), null);
  const chipOnly = ledgerLine({ guardrail_rejects: 2 });
  assert.equal(chipOnly.full, "");
  assert.equal(chipOnly.chip.short, "2 blocked");
  const both = ledgerLine({ commits: 2, pull_requests: 1, lines_added: 1, tokens: { input: 1 }, guardrail_rejects: 1 });
  assert.equal(both.short, "+1 \u22120 lines \u00b7 2 commits \u00b7 1 PR");
});

test("the drawer's totals add every session", () => {
  const day = {
    sessions: {
      a: { tokens: { input: 1, output: 2, cache_read: 3, cache_creation: 4 }, commits: 1, active: { user_ms: 60_000, cli_ms: 5000 }, api_errors: 2, cost_usd_estimate_micros: 1_500_000 },
      b: { tokens: { input: 10 }, commits: 2, active: { cli_ms: 120_000 }, api_refusals: 1 },
    },
  };
  const all = sumTotals(todaySessions(day).map(([, t]) => t));
  assert.deepEqual(all.tokens, { input: 11, output: 2, cache_read: 3, cache_creation: 4 });
  assert.equal(all.commits, 3);
  assert.deepEqual(all.active, { user_ms: 60_000, cli_ms: 125_000 });
  assert.equal(all.api_errors, 2);
  assert.equal(all.api_refusals, 1);
  assert.deepEqual(todaySessions(day, "b").map(([id]) => id), ["b"]);
  assert.deepEqual(todaySessions(day, "zzz"), []);
  assert.deepEqual(todaySessions(undefined), []);
});

test("active time, counts and the cost line print plainly", () => {
  assert.equal(activeTime(0), "0m");
  assert.equal(activeTime(30_000), "<1m");
  assert.equal(activeTime(4 * 60_000), "4m");
  assert.equal(activeTime(72 * 60_000), "1h 12m");
  assert.equal(activeTime(125 * 60_000), "2h 05m");
  assert.equal(fullNumber(1234567), "1,234,567");
  assert.equal(costLine(0), null);
  assert.match(costLine(500), /^≈ under \$0\.01 /);
  assert.equal(costText(1_234_567), "$1.23");
  assert.equal(costText(500), "under $0.01");
  assert.equal(costText(0), "none");
});

const CAST = { characters: { af_heart: { name: "Cupid", accent: "#D55E00" }, am_puck: { name: "Puck", accent: "#009E73" } } };

test("tokens by character group by the recorded voice, largest first, with Other sessions last", () => {
  const t = (input) => ({ tokens: { input } });
  const voices = { a: "af_heart", b: "af_heart", c: "am_puck", odd: "am_michael" };
  // "gone" has no card on the wall and no voice recorded; "odd" has a voice the cast lacks.
  const sessions = [["a", t(10)], ["b", t(5)], ["c", t(40)], ["odd", t(7)], ["gone", t(2)], ["zero", t(0)], ["huge", t(900)]];
  const rows = tokensByCharacter(sessions, voices, CAST);
  assert.deepEqual(rows.map((r) => [r.name, r.tokens]), [["Puck", 40], ["Cupid", 15], ["Other sessions", 909]]);
  assert.equal(rows[0].accent, "#009E73");
  // Other sessions is last whatever its size, and says what it holds.
  assert.equal(rows[2].label, "Other sessions: 3 (2 with no voice, 1 with a voice outside the cast)");
  assert.equal(rows[2].other, true);
  assert.ok(!rows[0].other && rows[0].label === undefined);
  assert.equal(rows.reduce((n, r) => n + r.tokens, 0), 10 + 5 + 40 + 7 + 2 + 900, "totals unchanged");
});

test("a character keeps its tokens after its card is cleared, and 'Earlier sessions' is gone", () => {
  const t = (input) => ({ tokens: { input } });
  // Nothing on the wall is consulted: the day file's voices alone place the session.
  const rows = tokensByCharacter([["cleared", t(12)], ["scratch", t(3)]], { cleared: "af_heart" }, CAST);
  assert.deepEqual(rows.map((r) => [r.name, r.tokens]), [["Cupid", 12], ["Other sessions", 3]]);
  assert.equal(rows[1].label, "Other sessions: 1 (with no voice)");
  assert.ok(!rows.some((r) => /Earlier/.test(r.name)));
  // Old day files have no voices at all: everything is Other sessions.
  assert.deepEqual(tokensByCharacter([["x", t(4)]], undefined, CAST).map((r) => [r.name, r.tokens]), [["Other sessions", 4]]);
  assert.deepEqual(tokensByCharacter([["x", t(0)]], {}, CAST), []);
  // A voice key that is an Object.prototype name is not a character.
  const proto = tokensByCharacter([["x", t(1)]], { x: "constructor" }, CAST)[0];
  assert.equal(proto.name, "Other sessions");
  assert.equal(proto.label, "Other sessions: 1 (with a voice outside the cast)");
});

test("characterOf names a cleared session by its recorded voice, and the wall only when the day has none", () => {
  const wall = { name: "klepsydra", accent: null };
  // Cleared from the wall: the day's voice alone names it.
  assert.deepEqual(characterOf("cleared", { cleared: "af_heart" }, CAST), { name: "Cupid", accent: "#D55E00", character: true });
  // The recorded voice wins over whatever the wall shows now.
  assert.equal(characterOf("s", { s: "am_puck" }, CAST, wall).name, "Puck");
  // A voice outside the cast is named as the wall names one, and is no character.
  assert.deepEqual(characterOf("odd", { odd: "am_onyx" }, CAST, wall), { name: "Onyx", accent: null, character: false });
  // No voice today: the live wall's identity, else nothing.
  assert.equal(characterOf("live", {}, CAST, wall), wall);
  assert.equal(characterOf("gone", {}, CAST), null);
  assert.equal(characterOf("gone", { gone: "" }, CAST), null, "an empty voice is none");
});

test("characterOf reads own keys only, whatever the ids, voices or cast hold", () => {
  const voices = JSON.parse('{"__proto__":"af_heart","constructor":"am_puck","":"af_heart","v1":"hasOwnProperty","v2":"constructor"}');
  assert.equal(characterOf("__proto__", voices, CAST).name, "Cupid");
  assert.equal(characterOf("constructor", voices, CAST).name, "Puck");
  assert.equal(characterOf("", voices, CAST).name, "Cupid");
  assert.equal(characterOf("toString", voices, CAST), null, "an Object.prototype name is no session");
  for (const id of ["v1", "v2"]) assert.equal(characterOf(id, voices, CAST).character, false, id);
  for (const bad of [null, undefined, [], ["af_heart"], "af_heart", 5]) {
    assert.equal(characterOf("0", bad, CAST), null, JSON.stringify(bad));
  }
  // A cast entry that is not a named object is no character; a bad accent is dropped, as identity() drops it.
  const cast = JSON.parse('{"characters":{"__proto__":{"name":"P","accent":"#000000"},"x":null,"y":{"accent":"#111111"},"z":"str","w":{"name":"W","accent":"red; x"}}}');
  assert.deepEqual(characterOf("a", { a: "__proto__" }, cast), { name: "P", accent: "#000000", character: true });
  for (const v of ["x", "y", "z"]) assert.equal(characterOf("a", { a: v }, cast).character, false, v);
  assert.equal(characterOf("a", { a: "w" }, cast).accent, null);
  assert.equal(characterOf("a", { a: "af_heart" }, undefined).character, false, "no cast, no character");
  // tokensByCharacter places sessions by the same lookup.
  const t = (input) => ({ tokens: { input } });
  const rows = tokensByCharacter([["a", t(1)], ["b", t(2)], ["c", t(3)]], { a: "__proto__", b: "y", c: "w" }, cast);
  assert.deepEqual(rows.map((r) => [r.name, r.tokens, r.accent]), [["W", 3, null], ["P", 1, "#000000"], ["Other sessions", 2, null]]);
});

test("attribution is honest about redacted and capped names", () => {
  assert.equal(attributionName("skills", "third-party"), "third-party (names redacted by Claude Code)");
  assert.equal(attributionName("plugins", "third-party"), "third-party (names redacted by Claude Code)");
  assert.equal(attributionName("mcp_servers", "custom"), "custom (names redacted by Claude Code)");
  assert.equal(attributionName("skills", "custom"), "custom", "custom is redaction only for MCP servers");
  assert.equal(attributionName("mcp_servers", "third-party"), "third-party");
  assert.match(attributionName("skills", "(other)"), /^other \(past the 32 names/);
  assert.equal(attributionName("skills", "other"), "other", "a real name is never the cap");
  assert.equal(attributionName("skills", "graphe:latex"), "graphe:latex");
});

test("the cap's key and size match ledger.rs", async () => {
  const { readFileSync } = await import("node:fs");
  const rust = readFileSync(new URL("../src-tauri/fleet/src/ledger.rs", import.meta.url), "utf8");
  assert.match(rust, new RegExp(`pub const MAX_NAMES: usize = ${NAME_CAP};`));
  assert.ok(rust.includes(`pub const OTHER: &str = "${OTHER}";`));
});

test("the top attribution rows merge sessions, rank and count the rest", () => {
  const attribution = {
    a: { skills: { x: 5, y: 1, z: 9 } },
    b: { skills: { x: 6, w: 0 }, plugins: { p: 3 } },
    c: { skills: { x: 100 } },
  };
  const top = topAttribution(attribution, "skills", ["a", "b"], 2);
  assert.deepEqual(top.rows, [{ name: "x", tokens: 11 }, { name: "z", tokens: 9 }]);
  assert.deepEqual([top.more, top.moreTokens], [1, 1]);
  assert.deepEqual(topAttribution(attribution, "mcp_servers", ["a", "b", "c"]), { rows: [], more: 0, moreTokens: 0 });
  assert.deepEqual(topAttribution(undefined, "skills", ["a"]).rows, []);
});

test("the cost line says whose estimate it is and where the bill is", () => {
  const line = costLine(1_234_567);
  assert.ok(line.startsWith("≈ $1.23 "), line);
  assert.match(line, /Claude Code's local list-price estimate/);
  assert.match(line, /not your bill/);
  assert.match(line, /Console usage page or claude\.ai usage settings/);
  assert.ok(!line.includes("\u2014"), "no em-dash");
});

test("a partial session shows a short mark with the reason in full", () => {
  assert.equal(PARTIAL_LABEL, "Some telemetry for this session was not received: klepsydra was not running for part of it.");
  assert.deepEqual(ledgerLine({ commits: 1 }, true).partial, { text: "partial", label: PARTIAL_LABEL });
  assert.equal(ledgerLine({ commits: 1 }).partial, null);
  assert.equal(ledgerLine({ commits: 1 }, false).partial, null);
  // The mark is on the line even when nothing else is, but never without a ledger.
  const alone = ledgerLine({ tokens: {}, commits: 0 }, true);
  assert.equal(alone.full, "");
  assert.equal(alone.partial.text, "partial");
  assert.equal(ledgerLine(undefined, true), null);
  // It does not cost the receipt a part: the compact fit budget stays three.
  const full = ledgerLine({ commits: 2, pull_requests: 1, lines_added: 1, tokens: { input: 1 } }, true);
  assert.equal(full.short, "+1 \u22120 lines \u00b7 2 commits \u00b7 1 PR");
});

test("tokens by model add a model's sessions, largest first, with its estimate", () => {
  const models = {
    a: { "claude-opus-5-5": { tokens: { input: 1, output: 2, cache_read: 3, cache_creation: 4 }, cost_usd_estimate_micros: 1_500_000 }, "claude-haiku-5": { tokens: { input: 100 }, cost_usd_estimate_micros: 500 } },
    b: { "claude-opus-5-5": { tokens: { output: 10 }, cost_usd_estimate_micros: 250_000 }, "(other)": { tokens: { input: 1 } } },
    c: { "claude-opus-5-5": { tokens: { output: 999 } } },
  };
  assert.deepEqual(tokensByModel(models, ["a", "b"]), [
    { name: "claude-opus-5-5", tokens: 20, micros: 1_750_000 },
    { name: "claude-haiku-5", tokens: 100, micros: 500 },
    { name: "(other)", tokens: 1, micros: 0 },
  ].sort((x, y) => y.tokens - x.tokens || x.name.localeCompare(y.name)));
  assert.deepEqual(tokensByModel(models, ["zzz"]), []);
  assert.deepEqual(tokensByModel(undefined, ["a"]), []);
  // A model with no tokens and no cost is not a row.
  assert.deepEqual(tokensByModel({ a: { m: { tokens: {} } } }, ["a"]), []);
});

test("the model cap is named honestly and matches ledger.rs", async () => {
  assert.match(modelName("(other)"), /^other \(past the 16 models/);
  assert.equal(modelName("claude-opus-5-5"), "claude-opus-5-5");
  const { readFileSync } = await import("node:fs");
  const rust = readFileSync(new URL("../src-tauri/fleet/src/ledger.rs", import.meta.url), "utf8");
  assert.match(rust, new RegExp(`pub const MAX_MODELS: usize = ${MODEL_CAP};`));
});
