// What the wall says about the ledger: a card's receipt line and guardrail
// chip, and the figures the ledger drawer shows. Kept free of the DOM so it
// can be unit tested. A session's `ledger` is its totals since its first
// export; the drawer's `day` is today's file (see ledger.rs).

const MINUS = "−";
const n = (v) => (Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);
const plural = (count, word, many = `${word}s`) => `${count} ${count === 1 ? word : many}`;

// A count scaled to 1 decimal under 10 and none from 10 up, so 1.2M and 34k
// read at a glance; a trailing ".0" never shows.
const scaled = (value, divisor) => {
  const v = value / divisor;
  return v < 10 ? Math.round(v * 10) / 10 : Math.round(v);
};
const UNITS = [
  [1e9, "B"],
  [1e6, "M"],
  [1e3, "k"],
];

/** 999 stays 999; 1234 is "1.2k", 34000 "34k", 999950 "1M" (rounding up into the next unit). */
export function compactNumber(value) {
  const count = n(value);
  if (count < 1000) return String(count);
  const at = UNITS.findIndex(([size]) => count >= size);
  let [size, unit] = UNITS[at];
  let shown = scaled(count, size);
  if (shown >= 1000 && at > 0) {
    [size, unit] = UNITS[at - 1];
    shown = scaled(count, size);
  }
  return `${shown}${unit}`;
}

/** The four token kinds added up. */
export const totalTokens = (t = {}) => n(t.input) + n(t.output) + n(t.cache_read) + n(t.cache_creation);

/**
 * The share of a session's input-side tokens that came from the prompt cache:
 *   cache_read / (input + cache_read + cache_creation)
 * Output tokens are not input, so they stay out of the denominator. null when
 * there is no input at all.
 */
export function cacheShare(t = {}) {
  const input = n(t.input) + n(t.cache_read) + n(t.cache_creation);
  return input === 0 ? null : n(t.cache_read) / input;
}

/** The receipt's parts, in reading order, with the ones that are zero left out. */
export function receiptParts(ledger = {}) {
  const parts = [];
  const added = n(ledger.lines_added);
  const removed = n(ledger.lines_removed);
  if (added || removed) parts.push({ key: "lines", text: `+${compactNumber(added)} ${MINUS}${compactNumber(removed)} lines` });
  const commits = n(ledger.commits);
  if (commits) parts.push({ key: "commits", text: plural(commits, "commit") });
  const prs = n(ledger.pull_requests);
  if (prs) parts.push({ key: "prs", text: plural(prs, "PR") });
  const tokens = totalTokens(ledger.tokens);
  if (tokens) {
    const share = cacheShare(ledger.tokens);
    const cached = share === null ? "" : ` (${Math.round(share * 100)}% cached)`;
    parts.push({ key: "tokens", text: `${compactNumber(tokens)} tokens${cached}` });
  }
  return parts;
}

// The compact card has room for three parts. A pull request says the most,
// then commits, then lines, and the token count the least (every session has one).
const INFORMATIVE = ["prs", "commits", "lines", "tokens"];
export const COMPACT_PARTS = 3;

/** The most informative `max` parts, still in reading order. */
export function compactPick(parts, max = COMPACT_PARTS) {
  const keep = new Set(
    [...parts].sort((a, b) => INFORMATIVE.indexOf(a.key) - INFORMATIVE.indexOf(b.key)).slice(0, max).map((p) => p.key),
  );
  return parts.filter((p) => keep.has(p.key));
}

export const receiptText = (parts) => parts.map((p) => p.text).join(" · ");

/** The guardrail chip: its short visible text and its full accessible name. null with none blocked. */
export function chipLabel(count) {
  const blocked = n(count);
  if (!blocked) return null;
  return { short: `${blocked} blocked`, full: `${plural(blocked, "tool call")} blocked by guardrails` };
}

/** What a card shows from its session's ledger; null when there is nothing to say. */
export function ledgerLine(ledger) {
  if (!ledger) return null;
  const parts = receiptParts(ledger);
  const chip = chipLabel(ledger.guardrail_rejects);
  if (!parts.length && !chip) return null;
  return { full: receiptText(parts), short: receiptText(compactPick(parts)), chip };
}

// ---- The drawer's figures ----

/** Sum of Totals, the drawer's totals for the sessions it shows. */
export function sumTotals(list) {
  const out = {
    tokens: { input: 0, output: 0, cache_read: 0, cache_creation: 0 },
    cost_usd_estimate_micros: 0,
    lines_added: 0,
    lines_removed: 0,
    commits: 0,
    pull_requests: 0,
    active: { user_ms: 0, cli_ms: 0 },
    api_errors: 0,
    api_refusals: 0,
  };
  for (const t of list) {
    for (const k of Object.keys(out.tokens)) out.tokens[k] += n(t.tokens?.[k]);
    for (const k of ["cost_usd_estimate_micros", "lines_added", "lines_removed", "commits", "pull_requests", "api_errors", "api_refusals"]) {
      out[k] += n(t[k]);
    }
    out.active.user_ms += n(t.active?.user_ms);
    out.active.cli_ms += n(t.active?.cli_ms);
  }
  return out;
}

/** Today's sessions as [id, totals], all of them or only `only`'s. */
export const todaySessions = (day, only = null) =>
  Object.entries(day?.sessions ?? {}).filter(([id]) => only === null || id === only);

/** "1h 12m", "4m", "<1m", "0m". */
export function activeTime(ms) {
  const total = Math.floor(n(ms) / 60000);
  if (total === 0) return n(ms) > 0 ? "<1m" : "0m";
  const h = Math.floor(total / 60);
  return h ? `${h}h ${String(total % 60).padStart(2, "0")}m` : `${total}m`;
}

/** Whole numbers with thousands separators, as the drawer's tables print them. */
export const fullNumber = (v) => n(v).toLocaleString("en-US");

/**
 * Tokens by character: one row per character name, largest first. `who` maps
 * a session id to {name, accent}; a session it does not know is "Earlier sessions".
 */
export function tokensByCharacter(sessions, who) {
  const rows = new Map();
  for (const [id, totals] of sessions) {
    const known = who.get(id);
    const name = known?.name ?? "Earlier sessions";
    const row = rows.get(name) ?? { name, accent: known?.accent ?? null, tokens: 0 };
    row.tokens += totalTokens(totals.tokens);
    rows.set(name, row);
  }
  return [...rows.values()].filter((r) => r.tokens > 0).sort((a, b) => b.tokens - a.tokens || a.name.localeCompare(b.name));
}

// Claude Code redacts these names unless OTEL_LOG_TOOL_DETAILS is set, which
// klepsydra leaves unset; `other` is klepsydra's own cap (ledger.rs MAX_NAMES).
// https://code.claude.com/docs/en/monitoring-usage
const REDACTED = {
  "third-party": "third-party (names redacted by Claude Code)",
  custom: "custom (names redacted by Claude Code)",
};
const REDACTS = { skills: "third-party", plugins: "third-party", mcp_servers: "custom" };
export const NAME_CAP = 32; // ledger.rs MAX_NAMES

/** A name as the drawer shows it, honest about a redacted or capped one. */
export function attributionName(kind, name) {
  if (name === "other") return `other (past the ${NAME_CAP} names kept per session)`;
  return name === REDACTS[kind] ? REDACTED[name] : name;
}

/**
 * Tokens by skill, plugin or MCP server (`kind`) over `sessions` of
 * `attribution`: the top `top` rows, largest first, and what is left over.
 */
export function topAttribution(attribution, kind, ids, top = 8) {
  const byName = new Map();
  for (const id of ids) {
    for (const [name, tokens] of Object.entries(attribution?.[id]?.[kind] ?? {})) {
      byName.set(name, (byName.get(name) ?? 0) + n(tokens));
    }
  }
  const all = [...byName].filter(([, tokens]) => tokens > 0).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const rows = all.slice(0, top).map(([name, tokens]) => ({ name: attributionName(kind, name), tokens }));
  const rest = all.slice(top);
  return { rows, more: rest.length, moreTokens: rest.reduce((sum, [, tokens]) => sum + tokens, 0) };
}

/** The one dim cost line: what the tokens would cost at API prices, never a bill. null at zero. */
export function costLine(micros) {
  const value = n(micros);
  if (!value) return null;
  const dollars = value < 10_000 ? "under $0.01" : `$${(value / 1e6).toFixed(2)}`;
  return `≈ ${dollars} API-equivalent (an estimate, not your bill)`;
}
