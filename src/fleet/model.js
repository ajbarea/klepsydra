// What the fleet strip and wall show for each session, kept free of the DOM
// so it can be unit tested. Sessions arrive from the reader already ordered.

import { inkOn } from "./contrast.js";
import { medallion } from "./medallion.js";

// Each status's badge: shape, symbol and tone carry it together with the
// label, so no one of them is needed alone.
export const STATUS = {
  needs_you: { label: "needs you", shape: "diamond", symbol: "!", tone: "needs" },
  error: { label: "error", shape: "square", symbol: "\u00d7", tone: "error" },
  working: { label: "working", shape: "circle", symbol: "\u2026", tone: "working" },
  done: { label: "done", shape: "circle", symbol: "\u2713", tone: "done" },
  new: { label: "not started", shape: "ring", symbol: "\u25cb", tone: "quiet" },
  silent: { label: "silent", shape: "ring", symbol: "?", tone: "quiet" },
  ended: { label: "ended", shape: "ring", symbol: "\u2013", tone: "quiet" },
};
const UNKNOWN = { label: "unknown", shape: "ring", symbol: "?", tone: "quiet" };
// A working session with no hook activity for a while (an interrupt runs no
// Stop hook), or one waiting on AJ with no word for half an hour: same badge, "?" symbol.
const QUIET = {
  working: { ...STATUS.working, label: "working?", symbol: "?" },
  needs_you: { ...STATUS.needs_you, label: "needs you?", symbol: "?" },
};
export const statusOf = (status, quiet = false) => (quiet && QUIET[status]) || STATUS[status] || UNKNOWN;
const isQuiet = (s) => s.status in QUIET && s.quiet_since != null;

// A card says when it last changed once that is older than this.
export const SHOW_UPDATED_AFTER_MS = 5 * 60 * 1000;

const FACES = "fleet/faces";
// NaN for a missing or unusable time, which the age formatters print as "unknown".
const ageMs = (atSec, nowMs) =>
  typeof atSec === "number" && Number.isFinite(atSec) ? nowMs - atSec * 1000 : NaN;

/** "2m", "1h", "3d"; "<1m" under a minute; "unknown" without a time. A time ahead of the clock is now. */
export function shortAge(ms) {
  if (!Number.isFinite(ms)) return "unknown";
  const mins = Math.floor(Math.max(0, ms) / 60000);
  if (mins < 1) return "<1m";
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  if (h < 24) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

/** The same age in words, for accessible names: "2 minutes". */
export function longAge(ms) {
  if (!Number.isFinite(ms)) return "unknown";
  const mins = Math.floor(Math.max(0, ms) / 60000);
  const unit = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
  if (mins < 1) return "under a minute";
  if (mins < 60) return unit(mins, "minute");
  const h = Math.floor(mins / 60);
  if (h < 24) return unit(h, "hour");
  return unit(Math.floor(h / 24), "day");
}

/** Label, reason and age. A silent session says how long since any word, a quiet needs-you one keeps its reason too, and a quiet working one says how long since any activity. */
export function statusParts(s, nowMs, age = shortAge) {
  const a = age(ageMs(s.status_at, nowMs));
  if (s.status === "silent") return [statusOf(s.status).label, `no word for ${a}`];
  if (isQuiet(s)) {
    const since = age(ageMs(s.quiet_since, nowMs));
    if (s.status === "working") return [statusOf(s.status, true).label, `no activity for ${since}`];
    return [statusOf(s.status, true).label, s.reason, `no word for ${since}`].filter(Boolean);
  }
  return [statusOf(s.status).label, s.reason, a].filter(Boolean);
}

/** "am_fenrir" is "Fenrir"; a blend "af_bella(0.7)+af_heart(0.3)" is "Bella and Heart". */
export function voiceName(voice) {
  return String(voice)
    .split("+")
    .map((part) => {
      const label = part.replace(/\(.*$/, "").trim();
      const name = label.includes("_") ? label.slice(label.indexOf("_") + 1) : label;
      return name.charAt(0).toUpperCase() + name.slice(1);
    })
    .join(" and ");
}

const basename = (path) => (typeof path === "string" ? path.replace(/\/+$/, "").split("/").pop() : "");

/**
 * Who a session is, from its identity alone, never its state: the kourai
 * character cast for its keryx voice; else a medallion bearing the initial of
 * the voice's name, or of the session's name or folder when it has no voice,
 * in a metal picked by the voice, or by the session id when it has none.
 */
export function identity(s, cast) {
  const voice = typeof s.voice === "string" && s.voice ? s.voice : null;
  const character = voice && Object.hasOwn(cast.characters, voice) ? cast.characters[voice] : null;
  if (character) {
    const base = `${FACES}/kourai/${character.face}`;
    const accent = /^#[0-9a-f]{6}$/i.test(character.accent) ? character.accent : null;
    return {
      name: character.name,
      voice: voiceName(voice),
      face: `${base}-96.webp`,
      face2x: `${base}-192.webp`,
      accent,
      accentInk: accent && inkOn(accent),
    };
  }
  const name = voice ? voiceName(voice) : s.name || basename(s.launch_dir) || s.session_id.slice(0, 8);
  const face = medallion(name, voice ?? s.session_id);
  return { name, voice: null, face, face2x: face, accent: null, accentInk: null };
}

/** "Hephaestus, needs you, approve Bash, 2 minutes" */
export const accessibleName = (s, cast, nowMs) =>
  [identity(s, cast).name, ...statusParts(s, nowMs, longAge)].join(", ");

/** Each session's status by id (a quiet session keyed "working?" or "needs_you?"), to compare the next snapshot against. */
export const statuses = (sessions) =>
  new Map(sessions.map((s) => [s.session_id, isQuiet(s) ? `${s.status}?` : s.status]));

/** Sessions that started needing AJ since `before`; none on the first look. */
export function startedNeeding(before, sessions) {
  if (!before) return new Set();
  return new Set(
    sessions
      .filter((s) => s.status === "needs_you" && !String(before.get(s.session_id)).startsWith("needs_you"))
      .map((s) => s.session_id),
  );
}

/** True when `after` is not the same ids in the same order as `before`. */
export const orderChanged = (before, after) =>
  before.length !== after.length || before.some((id, i) => id !== after[i]);

/** Slide only a snapshot that reorders cards already on the wall; never the first paint or a tick. */
export const shouldSlide = (was, next, snapshot) => Boolean(snapshot) && was.length > 0 && orderChanged(was, next);

/** The card's view-transition name, or "" unless the id is uuid-shaped. */
export const transitionName = (id) => (/^[0-9a-f-]{36}$/i.test(id) ? `card-${id}` : "");

/** What the wall's live region says about changes since `before`; nothing on the first look. */
export function announcements(before, sessions, cast, nowMs = Date.now()) {
  if (!before) return [];
  const key = statuses(sessions);
  return sessions
    .filter((s) => before.get(s.session_id) !== key.get(s.session_id))
    .map((s) => {
      if (isQuiet(s)) return accessibleName(s, cast, nowMs);
      return [identity(s, cast).name, statusOf(s.status).label, s.status === "silent" ? null : s.reason]
        .filter(Boolean)
        .join(", ");
    });
}

/** "updated 7m ago" once the newest field is over five minutes old. */
export function updatedText(s, nowMs) {
  const age = ageMs(s.updated_at, nowMs);
  if (Number.isNaN(age)) return "updated unknown";
  return age > SHOW_UPDATED_AFTER_MS ? `updated ${shortAge(age)} ago` : null;
}

const SHAPES = {
  diamond: '<path class="shape" d="M8 1.2 14.8 8 8 14.8 1.2 8Z"/>',
  square: '<rect class="shape" x="2" y="2" width="12" height="12" rx="1.5"/>',
  circle: '<circle class="shape" cx="8" cy="8" r="6.6"/>',
  ring: '<circle class="shape" cx="8" cy="8" r="6"/>',
};

/** The badge for a status, as SVG markup; its words are in the owner's accessible name. */
export function badgeSvg(status, quiet = false) {
  const st = statusOf(status, quiet);
  return `<svg class="badge tone-${st.tone} shape-${st.shape}" viewBox="0 0 16 16" aria-hidden="true">`
    + `${SHAPES[st.shape]}<text class="ink" x="8" y="8.5" font-size="10">${st.symbol}</text></svg>`;
}

/** The strip's portraits, in the reader's order. `before` comes from `statuses` of the last render. */
export function stripItems(sessions, cast, nowMs, before) {
  const pulse = startedNeeding(before, sessions);
  return sessions.map((s) => {
    const who = identity(s, cast);
    return {
      id: s.session_id,
      status: s.status,
      quiet: isQuiet(s),
      badge: badgeSvg(s.status, isQuiet(s)),
      label: accessibleName(s, cast, nowMs),
      face: who.face,
      face2x: who.face2x,
      pulse: pulse.has(s.session_id),
    };
  });
}

/** Whether the card can jump to the session's terminal, and why not: by its name, or by its tmux pane and Claude process. */
function jumpable(s) {
  if (s.status === "ended") return { enabled: false, why: "session ended" };
  if (!s.name && !(s.tmux && s.claude && s.distro)) return { enabled: false, why: "no session name yet" };
  return { enabled: true, why: null };
}

// The arc fills over the reader's thresholds (view.rs QUIET_AFTER, WAITING_DOUBT_AFTER).
export const WORKING_FULL_S = 600;
export const WAITING_FULL_S = 1800;

/** How full a card's arc is, 0..1: a working session's time since its last activity, or a waiting one's since it asked, against the reader's threshold. */
export function arcFraction(s, nowMs) {
  if (s.status === "working" && isQuiet(s)) return 1;
  const full = { working: WORKING_FULL_S, needs_you: WAITING_FULL_S }[s.status];
  const age = ageMs(s.status === "working" ? s.active_at : s.status_at, nowMs);
  if (!full || !Number.isFinite(age)) return 0;
  return Math.min(1, Math.max(0, age / 1000 / full));
}

/** The needs-you line: what the session waits for. */
export function askText(reason) {
  if (reason === "question") return "Waiting for your answer";
  if (reason === "approve plan") return "Waiting for you to approve the plan";
  return reason ? `Waiting for you to ${reason}` : "Waiting for you";
}

const DIM = new Set(["new", "silent", "ended"]);
// A pill that names its reason: "ended · gone", "error · rate limit".
const PILL_REASON = new Set(["ended", "error"]);

/** Counts for the summary bar. */
export function tally(sessions) {
  const t = { needs: 0, working: 0, done: 0, error: 0, idle: 0 };
  for (const s of sessions) {
    if (s.status === "needs_you") t.needs++;
    else if (s.status === "working") t.working++;
    else if (s.status === "done") t.done++;
    else if (s.status === "error") t.error++;
    else t.idle++;
  }
  return t;
}

// Markdown to clean one-line text for a preview. The wall sets it with
// textContent, so this only removes markers; it never produces markup.
// Emphasis needs a word boundary outside (snake_case, a*b, 2 * 3 stay); a
// double marker is stripped even with a space inside, as `** x**` is still noise
// in a preview. A "- " after "label: " is a list item the agent's reply had
// flattened onto one line, so it goes too; a spaced dash elsewhere is prose.
export function plainText(md) {
  if (md == null) return md;
  const codes = [];
  const hold = (t) => `\u0000${codes.push(t) - 1}\u0000`;
  let fenced = false;
  const lines = [];
  for (const raw of String(md).split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(raw)) { fenced = !fenced; continue; }
    if (fenced) { lines.push(hold(raw)); continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(raw)) continue;
    lines.push(
      raw.replace(/^\s*(>\s?)+/, "").replace(/^\s*#{1,6}\s+/, "").replace(/^\s*(?:[-*+]|\d+[.)])\s+/, ""),
    );
  }
  let t = lines.join(" ")
    .replace(/`+([^`]+?)`+/g, (_, c) => hold(c))
    .replace(/!?\[([^\]]*)\]\([^)\s]*\)/g, "$1")
    .replace(/<(https?:\/\/[^>\s]+)>/g, "$1")
    .replace(/(?<=[:;.!?] )[-*+] (?=\S)/g, "")
    .replace(/(\*\*\*|___)(?=\S)(.+?)\1/g, "$2")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])/g, "$1")
    .replace(/~~(.+?)~~/g, "$1")
    .replace(/(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])/g, "$1")
    .replace(/(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])/g, "$1");
  return t.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[i]).replace(/\s+/g, " ").trim();
}

/** One card on the wall. */
export function card(s, cast, nowMs) {
  const who = identity(s, cast);
  const st = statusOf(s.status, isQuiet(s));
  return {
    id: s.session_id,
    task: s.name || "No session name yet",
    tone: st.tone,
    pill: {
      label: PILL_REASON.has(s.status) && s.reason ? `${st.label} \u00b7 ${s.reason}` : st.label,
      age: statusParts(s, nowMs).at(-1),
    },
    ask: s.status === "needs_you" ? askText(s.reason) : null,
    arc: arcFraction(s, nowMs),
    dim: DIM.has(s.status),
    place: s.where ? { repo: s.where.repo, worktree: s.where.worktree ?? null, branch: s.where.branch ?? null } : null,
    also: [...new Set((s.touched ?? []).map((t) => t.repo))].filter((r) => r && r !== s.where?.repo).map((r) => `also in ${r}`),
    voiceTitle: who.voice ? `Voice: ${who.voice}` : null,
    name: who.name,
    session: s.name ?? null,
    face: who.face,
    face2x: who.face2x,
    accent: who.accent,
    accentInk: who.accentInk,
    status: s.status,
    quiet: isQuiet(s),
    badge: badgeSvg(s.status, isQuiet(s)),
    prompt: plainText(s.prompt?.text ?? null),
    reply: plainText(s.reply?.text ?? null),
    error: s.status === "error" ? s.error ?? null : null,
    updated: s.status === "ended" ? null : updatedText(s, nowMs), // the pill's age says it
    jump: jumpable(s),
    clear: s.status === "ended" || s.status === "silent",
    jumpLabel: `Open terminal, ${who.name}`,
    label: accessibleName(s, cast, nowMs),
  };
}
