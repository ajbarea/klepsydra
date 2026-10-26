// What the wall says about the ledger: a card's receipt line and guardrail
// chip, and the figures the ledger drawer shows. Kept free of the DOM so it
// can be unit tested. A session's `ledger` is its totals since its first
// export; the drawer's `day` is today's file (see ledger.rs).

import { castAccent, castCharacter, ownValue, voiceName } from "./cast.js";

const MINUS = "−";
const n = (v) => (Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);
export const plural = (count, word, many = `${word}s`) => `${count} ${count === 1 ? word : many}`;

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
  // The name starts with the visible words, so speaking them finds the button (WCAG 2.5.3).
  const calls = blocked === 1 ? "tool call" : "tool calls";
  return { short: `${blocked} blocked`, full: `${blocked} blocked: ${calls} a hook or config rule turned down` };
}

/** The partial mark's reason, in full: the mark itself is one word. */
export const PARTIAL_LABEL = "Some telemetry for this session was not received: klepsydra was not running for part of it.";

/**
 * What a card shows from its session's ledger; null when there is nothing to
 * say. `partial` (the view's ledger_partial) adds the short "partial" mark,
 * kept apart from the receipt so a compact card never trims it away.
 */
export function ledgerLine(ledger, partial = false) {
  if (!ledger) return null;
  const parts = receiptParts(ledger);
  const chip = chipLabel(ledger.guardrail_rejects);
  const mark = partial ? { text: "partial", label: PARTIAL_LABEL } : null;
  if (!parts.length && !chip && !mark) return null;
  return { full: receiptText(parts), short: receiptText(compactPick(parts)), chip, partial: mark };
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
 * Who session `id` was today: its recorded voice (`voices`, the day file's
 * session to voice map) as its cast character, `{ name, accent, character:
 * true }`; a recorded voice outside the cast named as a card names one, with
 * `character: false`; else `wall` (its identity on the live wall, if any)
 * when the day has no voice for it, which may be null. A home voice (`homes`,
 * the day file's `home_voices`) is only its launch folder's guess, shared by
 * every session started there, so its character is named with `label` (what
 * tells its card apart) and `own: true`, and its tokens are never merged.
 */
export function characterOf(id, voices, cast, wall = null, { homes = null, label = null } = {}) {
  const voice = ownValue(voices, id);
  if (typeof voice !== "string" || voice === "") return wall;
  const c = castCharacter(voice, cast);
  if (!c) return { name: voiceName(voice), accent: null, character: false };
  if (!(Array.isArray(homes) && homes.includes(id))) return { name: c.name, accent: castAccent(c), character: true };
  return { name: `${c.name} · ${label || `session ${id.slice(0, 8)}`}`, accent: castAccent(c), character: true, own: true };
}

/** Each card's label (`[id, label]`), with the session's short id added where two cards share one, so their rows read apart. */
export function cardLabels(entries) {
  const seen = new Map();
  for (const [, label] of entries) if (label) seen.set(label, (seen.get(label) ?? 0) + 1);
  return new Map(entries.map(([id, label]) => [id, label && seen.get(label) > 1 ? `${label}, ${id.slice(0, 8)}` : label]));
}

/**
 * Tokens by character: one row per character, largest first, each session
 * placed by `characterOf`, whether or not its card is still on the wall; a
 * home-voiced session has a row of its own, named from `labels` (session id
 * to what tells its card apart). Every other session lands in one "Other
 * sessions" row, always last, whose label counts the sessions with no voice
 * and those with a voice outside the cast.
 */
export function tokensByCharacter(sessions, voices, cast, { homes = null, labels = null } = {}) {
  const rows = new Map();
  const other = { name: "Other sessions", accent: null, tokens: 0, other: true, count: 0 };
  let voiceless = 0;
  for (const [id, totals] of sessions) {
    const tokens = totalTokens(totals.tokens);
    if (!tokens) continue;
    const who = characterOf(id, voices, cast, null, { homes, label: labels?.get(id) });
    if (who?.character) {
      const key = who.own ? `session:${id}` : `character:${who.name}`;
      const row = rows.get(key) ?? { name: who.name, accent: who.accent, tokens: 0 };
      row.tokens += tokens;
      rows.set(key, row);
    } else {
      other.tokens += tokens;
      other.count += 1;
      if (!who) voiceless += 1;
    }
  }
  const out = [...rows.values()].sort((a, b) => b.tokens - a.tokens || a.name.localeCompare(b.name));
  if (other.count) {
    const outside = other.count - voiceless;
    const parts = [voiceless && `${voiceless} with no voice`, outside && `${outside} with a voice outside the cast`].filter(Boolean);
    const what = other.count === 1 ? parts[0].replace(/^1 /, "") : parts.join(", ");
    out.push({ ...other, label: `Other sessions: ${other.count} (${what})` });
  }
  return out;
}

// Claude Code redacts these names unless OTEL_LOG_TOOL_DETAILS is set, which
// klepsydra leaves unset; `(other)` is klepsydra's own cap (ledger.rs OTHER, MAX_NAMES).
// https://code.claude.com/docs/en/monitoring-usage
const REDACTED = {
  "third-party": "third-party (names redacted by Claude Code)",
  custom: "custom (names redacted by Claude Code)",
};
const REDACTS = { skills: "third-party", plugins: "third-party", mcp_servers: "custom" };
export const NAME_CAP = 32; // ledger.rs MAX_NAMES
export const OTHER = "(other)"; // ledger.rs OTHER

/** A name as the drawer shows it, honest about a redacted or capped one. */
export function attributionName(kind, name) {
  if (name === OTHER) return `other (past the ${NAME_CAP} names kept per session)`;
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

/** An estimate in dollars: "$1.23", "under $0.01", or "none" at zero. */
export function costText(micros) {
  const value = n(micros);
  if (!value) return "none";
  return value < 10_000 ? "under $0.01" : `$${(value / 1e6).toFixed(2)}`;
}

/**
 * The one dim cost line. Claude Code works the figure out locally from token
 * counts at list prices, so it can differ from the bill; the billing record is
 * the Console usage page or claude.ai usage settings.
 * https://code.claude.com/docs/en/costs
 */
export function costLine(micros) {
  if (!n(micros)) return null;
  return `≈ ${costText(micros)} is Claude Code's local list-price estimate, not your bill. The Console usage page or claude.ai usage settings are the billing record.`;
}

export const MODEL_CAP = 16; // ledger.rs MAX_MODELS

/** A model name as the drawer shows it, honest about the cap's fold. */
export function modelName(name) {
  return name === OTHER ? `other (past the ${MODEL_CAP} models kept per session)` : name;
}

/**
 * Tokens and estimate by model over the sessions `ids` of `models`
 * (ledger.rs `Day.models`): one row per model, largest first.
 */
export function tokensByModel(models, ids) {
  const byName = new Map();
  for (const id of ids) {
    for (const [name, m] of Object.entries(models?.[id] ?? {})) {
      const row = byName.get(name) ?? { name, tokens: 0, micros: 0 };
      row.tokens += totalTokens(m.tokens);
      row.micros += n(m.cost_usd_estimate_micros);
      byName.set(name, row);
    }
  }
  return [...byName.values()].filter((r) => r.tokens > 0 || r.micros > 0).sort((a, b) => b.tokens - a.tokens || a.name.localeCompare(b.name));
}
