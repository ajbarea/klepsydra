import { test } from "node:test";
import assert from "node:assert/strict";
import {
  NAME_CAP, OTHER, activeTime, attributionName, cacheShare, chipLabel, compactNumber, compactPick, costLine, fullNumber,
  ledgerLine, receiptParts, receiptText, sumTotals, todaySessions, tokensByCharacter, topAttribution, totalTokens,
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
  assert.equal(costLine(1_234_567), "≈ $1.23 API-equivalent (an estimate, not your bill)");
  assert.match(costLine(500), /under \$0\.01/);
});

test("tokens by character sum a character's sessions, largest first, and fold the unknown", () => {
  const who = new Map([["a", { name: "Hermes", accent: "#E07B39" }], ["b", { name: "Hermes", accent: "#E07B39" }], ["c", { name: "Puck", accent: "#009E73" }]]);
  const t = (input) => ({ tokens: { input } });
  const rows = tokensByCharacter([["a", t(10)], ["b", t(5)], ["c", t(40)], ["gone", t(2)], ["zero", t(0)], ["gone2", t(3)]], who);
  assert.deepEqual(rows.map((r) => [r.name, r.tokens]), [["Puck", 40], ["Hermes", 15], ["Earlier sessions", 5]]);
  assert.equal(rows[0].accent, "#009E73");
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
