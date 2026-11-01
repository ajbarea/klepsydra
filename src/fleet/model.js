// What the fleet strip and wall show for each session, kept free of the DOM
// so it can be unit tested. Sessions arrive from the reader already ordered.

import { markerWidth, mix, mixOklab, readableOn } from "./contrast.js";
import { hash, medallion } from "./medallion.js";
import { castAccent, castCharacter, castFiles, voiceName } from "./cast.js";
import { ledgerLine } from "./ledger.js";

export { voiceName };
import { speakingNow } from "./speaking.js";
import { listWords, sessionActions } from "./end.js";
import { wrapupLine, sessionRoute } from "./wrapup.js";

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

// A turn that ended with background work out: the prompt is free while it runs.
const PROMPT_FREE = "prompt free";
const reasonText = (s) => (s.status === "working" && s.reason === "background" ? PROMPT_FREE : s.reason);

/** Label, reason and age. A silent session says how long since any word, a quiet needs-you one keeps its reason too, and a quiet working one says how long since any activity. */
export function statusParts(s, nowMs, age = shortAge) {
  const a = age(ageMs(s.status_at, nowMs));
  if (s.status === "silent") return [statusOf(s.status).label, `no word for ${a}`];
  if (isQuiet(s)) {
    const since = age(ageMs(s.quiet_since, nowMs));
    if (s.status === "working") return [statusOf(s.status, true).label, `no activity for ${since}`];
    return [statusOf(s.status, true).label, s.reason, `no word for ${since}`].filter(Boolean);
  }
  return [statusOf(s.status).label, reasonText(s), a].filter(Boolean);
}

/** A GitHub repo page as the hook writes one, or null: the walls link only these. */
export const githubPage = (url) =>
  typeof url === "string" && /^https:\/\/github\.com\/[\w.-]{1,100}\/[\w.-]{1,100}$/.test(url) && !/\/\.{1,2}(\/|$)/.test(url) ? url : null;

/** The page of BRANCH in the repo at GITHUB, its slashes kept as GitHub's tree paths have them. */
export const branchPage = (github, branch) =>
  github && branch ? `${github}/tree/${branch.split("/").map(encodeURIComponent).join("/")}` : null;

const basename = (path) => (typeof path === "string" ? path.replace(/\/+$/, "").split("/").pop() : "");

/**
 * Who a session is, from its identity alone, never its state: the character
 * the theme (`cast`) casts for its keryx voice; else a medallion bearing the
 * initial of the voice's name, or of the session's name or folder when it has
 * no voice, in a metal picked by the voice, or by the session id when it has
 * none. A character whose face files cannot be named is a medallion too. A
 * session with no character of its own wears the one castPicks gave it
 * (`pick`), with no keryx voice to name.
 */
/** A folder the app will open (folder.rs `plain_dir`): absolute, no empty, "." or ".." part, no control character. */
export function plainDir(dir) {
  return (
    typeof dir === "string" &&
    dir.length > 1 &&
    dir.length <= 1024 &&
    dir.startsWith("/") &&
    !/[\u0000-\u001f\u007f-\u009f]/.test(dir) &&
    dir
      .slice(1)
      .split("/")
      .every((part) => part !== "" && part !== "." && part !== "..")
  );
}

export function identity(s, cast) {
  const own = typeof s.voice === "string" && s.voice ? s.voice : null;
  const picked = !castFiles(castCharacter(own, cast), cast) && typeof s.pick === "string" ? s.pick : null;
  const voice = picked ?? own;
  const character = castCharacter(voice, cast);
  const base = character && castFiles(character, cast);
  if (base) {
    const accent = castAccent(character);
    const head = character.head;
    const placed = Array.isArray(head) && head.length === 3 && head.every((v) => typeof v === "number" && v > 0 && v < 1);
    return {
      name: character.name,
      voice: picked ? null : voiceName(voice),
      face: `${base}-96.webp`,
      face2x: `${base}-192.webp`,
      full: `${base}-full.webp`,
      accent,
      epithet: typeof character.epithet === "string" ? character.epithet : null,
      figure: placed ? { src: `${base}-figure.webp`, head } : null,
    };
  }
  const name = own ? voiceName(own) : s.name || basename(s.launch_dir) || s.session_id.slice(0, 8);
  const face = medallion(name, own ?? s.session_id);
  return { name, voice: null, face, face2x: face, full: null, accent: null, epithet: null, figure: null };
}

/**
 * Every session a character from the theme `cast` wears (#148). The app's
 * crate assigns each session with no cast voice of its own a `pick` once and
 * keeps it while the session stays on the wall (src-tauri/fleet/src/picks.rs),
 * so faces never move; a crate pick is kept here like an own voice. A session
 * without one (demo fixtures, an older app) gets a pick here the same way:
 * oldest first, each seeing only older cards, the least shown character, a
 * voice it gave up (`ceded`) counted in its own place and avoided, ties by the
 * hash of its id. With no theme loaded nothing is picked and the cards wear
 * medallions.
 */
export function castPicks(sessions, cast) {
  // Heph's character (am_michael) is the orchestrator's alone (#172): never a pick here.
  const chars = Object.keys(cast?.characters ?? {}).filter((k) => k !== "am_michael" && castFiles(castCharacter(k, cast), cast));
  if (!chars.length) return sessions;
  const own = (s) => (castFiles(castCharacter(s.voice, cast), cast) ? s.voice : null);
  const shown = new Map(chars.map((c) => [c, 0]));
  const order = [...sessions].sort(
    (a, b) => (a.started_at ?? Infinity) - (b.started_at ?? Infinity) || (a.session_id < b.session_id ? -1 : 1),
  );
  const pick = new Map();
  for (const s of order) {
    // The crate's pick (src-tauri/fleet/src/picks.rs) is kept like an own voice.
    const kept = castFiles(castCharacter(s.pick, cast), cast) ? s.pick : null;
    let c = own(s) ?? kept;
    // The voice this card gave up to another (the crate's `ceded`): it still counts in this
    // card's place, so newer cards see what they saw before; the card's new face avoids it.
    const gave = kept ? null : own({ voice: s.ceded });
    if (!c) {
      const free = chars.length > 1 && gave ? chars.filter((x) => x !== gave) : chars;
      const least = Math.min(...free.map((x) => shown.get(x)));
      const pool = free.filter((x) => shown.get(x) === least);
      c = pool.reduce((best, x) => (hash(`${s.session_id}:${x}`) > hash(`${s.session_id}:${best}`) ? x : best));
      pick.set(s.session_id, c);
    }
    const counted = gave ?? c;
    if (shown.has(counted)) shown.set(counted, shown.get(counted) + 1);
  }
  return sessions.map((s) => (pick.has(s.session_id) ? { ...s, pick: pick.get(s.session_id) } : s));
}

/** "Hermes, 2 agents and 1 shell running in background, working, prompt free, 2 minutes" */
export function accessibleName(s, cast, nowMs) {
  const crew = crewWords(crewOf(s), " and ");
  return [identity(s, cast).name, crew && `${crew} running in background`, ...statusParts(s, nowMs, longAge)]
    .filter(Boolean)
    .join(", ");
}

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
      return [identity(s, cast).name, statusOf(s.status).label, s.status === "silent" ? null : reasonText(s)]
        .filter(Boolean)
        .join(", ");
    });
}

/** The compact card's "+2" for the repos a session touched besides its own, named in full for hover and its accessible name; null with none. */
export function alsoChip(repos) {
  if (!repos.length) return null;
  return { text: `+${repos.length}`, label: `Also in ${listWords(repos)}` };
}

/**
 * The compact card's pill time, which takes in "updated Nm ago" since that card
 * has no line for it: the status age alone, or "30m · 7m ago" when the newest
 * field is newer than the status and over five minutes old. An ended card's
 * pill already says how long; a quiet one's says "12m quiet", short for the
 * full card's "no activity for 12m".
 */
export function pillWhen(s, nowMs) {
  if (isQuiet(s)) return `${shortAge(ageMs(s.quiet_since, nowMs))} quiet`; // the full card's "no activity for 12m"
  if (s.status === "silent") return shortAge(ageMs(s.status_at, nowMs)); // "silent 2h": the full card's "no word for 2h"
  const age = statusParts(s, nowMs).at(-1);
  if (s.status === "ended" || !updatedText(s, nowMs)) return age;
  const since = shortAge(ageMs(s.updated_at, nowMs));
  return since === "unknown" || since === age ? age : `${age} \u00b7 ${since} ago`;
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

/**
 * The strip's portraits, in the reader's order. `before` comes from `statuses`
 * of the last render; `speaking` is the snapshot's line, whose session's
 * portrait is marked while it plays.
 */
export function stripItems(sessions, cast, nowMs, before, speaking = null) {
  const pulse = startedNeeding(before, sessions);
  const speaker = speakingNow(speaking, nowMs) ? speaking.session_id : null;
  return sessions.map((s) => {
    const who = identity(s, cast);
    const talking = s.session_id === speaker;
    return {
      id: s.session_id,
      status: s.status,
      quiet: isQuiet(s),
      badge: badgeSvg(s.status, isQuiet(s)),
      label: accessibleName(s, cast, nowMs) + (talking ? ", speaking" : ""),
      face: who.face,
      face2x: who.face2x,
      pulse: pulse.has(s.session_id),
      speaking: talking,
    };
  });
}

/** Whether the card can jump to the session's terminal, and why not: by its name, or by its tmux pane and Claude process. */
function jumpable(s) {
  if (s.status === "ended") return { enabled: false, why: "session ended" };
  if (!s.name && !(s.tmux && s.claude && s.distro)) return { enabled: false, why: "no session name yet" };
  return { enabled: true, why: null };
}

/** The Open terminal button's resting and hover backgrounds (wall.css --button-bg, --button-hover); a style test keeps them equal. */
export const BUTTON_BGS = ["#252d39", "#2e3846"];
/**
 * The comfortable card's header band (wall.css): its plate, its light (a glow
 * and rays, each at most this strong), the mask that lets only `underText` of
 * it past the figure to the text, the needs-you amber that replaces a
 * character's light, and a quiet card's dim light. A style test keeps these
 * equal to the stylesheet's.
 */
export const BAND = { plate: "#141820", glow: 0.62, rays: 0.16, underText: 0.15, needs: "#e69f00", dimWith: "#3a414c", dimShare: 0.3 };
const LIGHT_AT_TEXT = (1 - (1 - BAND.glow) * (1 - BAND.rays)) * BAND.underText;

/** The brightest the band gets under its text, in each light a character's card can wear: its own, needs-you, quiet. */
export const bandGrounds = (accent) =>
  [accent, BAND.needs, mixOklab(BAND.dimWith, accent, BAND.dimShare)].map((light) => mix(BAND.plate, light, LIGHT_AT_TEXT));

// An accent's epithet ink depends on the accent alone, so each is worked out once.
const inks = new Map();
const accentInk = (accent) => {
  if (!inks.has(accent)) inks.set(accent, readableOn(accent, bandGrounds(accent)));
  return inks.get(accent);
};

/**
 * How the Open terminal button is styled. "off" (disabled): quiet, nothing else.
 * "needs": the only filled button, on a needs_you card (quiet or not), no marker.
 * "accent": neutral with a left marker in the character's colour. "plain": neutral, no marker.
 */
function jumpStyle(s, accent) {
  const kind = !jumpable(s).enabled ? "off" : s.status === "needs_you" ? "needs" : accent ? "accent" : "plain";
  return { jumpKind: kind, jumpMark: kind === "accent" ? { color: accent, width: markerWidth(accent, BUTTON_BGS) } : null };
}

/** A session's background crew: its subagents, background shells and other background tasks still running, as the reader counts them. */
export function crewOf(s) {
  const n = (v) => (Number.isInteger(v) && v > 0 ? v : 0);
  return { agents: n(s.background?.agents), shells: n(s.background?.shells), tasks: n(s.background?.tasks) };
}
const crewSize = ({ agents = 0, shells = 0, tasks = 0 }) => agents + shells + tasks;

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
const crewWords = ({ agents, shells, tasks = 0 }, join) =>
  [agents && plural(agents, "agent"), shells && plural(shells, "shell"), tasks && plural(tasks, "task")]
    .filter(Boolean)
    .join(join);

/** "2 agents, 1 shell, 1 task"; null with none out. */
export const crewText = (crew) => crewWords(crew, ", ") || null;

// The ring: one solid arc per piece of background work, from 12 o'clock
// clockwise, agents first. An agent's arc is thick and a shell's thin, in the
// same colour, so the kind rests on width alone. Widths and the gap between
// arcs are set in screen pixels for each density's portrait and drawn in the
// portrait's 80-unit viewBox, so a gap is the same length on the page at
// either size. The thick arc's outer edge is the portrait's edge.
const ringFor = (facePx, agentPx, shellPx, gapPx) => {
  const unit = 80 / facePx;
  const agent = agentPx * unit;
  const r = 40 - agent / 2;
  return { cx: 40, cy: 40, r, agent, shell: shellPx * unit, gapDeg: ((gapPx * unit) / r) * (180 / Math.PI), gapPx };
};
export const RINGS = {
  comfortable: ringFor(80, 7, 3, 14),
  compact: ringFor(64, 5.5, 2.5, 11),
};
// Five at most: a glance counts about four without counting, and more arcs
// stop reading apart; "+N" says the rest, and the crew line the exact counts.
export const RING_MAX = 5;

const round2 = (v) => Number(v.toFixed(2));
const point = (g, deg) => {
  const rad = (deg * Math.PI) / 180;
  return `${round2(g.cx + g.r * Math.cos(rad))} ${round2(g.cy + g.r * Math.sin(rad))}`;
};
const arc = (g, from, to) =>
  `M ${point(g, from)} A ${round2(g.r)} ${round2(g.r)} 0 ${to - from > 180 ? 1 : 0} 1 ${point(g, to)}`;

/**
 * What the crew shows: a mark per piece of work, agents first, at most
 * RING_MAX, and how many more are out. Other tasks show as shells (thin); the
 * crew line names them. Past RING_MAX the thin kind keeps one mark, so it is
 * never hidden. The ring lays these around a portrait; a figure's plinth
 * lays them in a row.
 */
export function crewMarks(crew) {
  const thin = (crew.shells ?? 0) + (crew.tasks ?? 0);
  const shells = thin && Math.min(thin, Math.max(1, RING_MAX - crew.agents));
  const agents = Math.min(crew.agents, RING_MAX - shells);
  const kinds = [...Array(agents).fill("agent"), ...Array(shells).fill("shell")];
  return { kinds, more: crewSize(crew) - kinds.length };
}

/**
 * The ring's arcs for one density's geometry, each {kind, d, width}, and how
 * many more are out than drawn: `crewMarks` laid around the portrait.
 */
export function crewRing(crew, g = RINGS.comfortable, marks = crewMarks(crew)) {
  const { kinds, more } = marks;
  const step = 360 / Math.max(kinds.length, 1);
  // Every count keeps its gaps, a lone item too, so an arc never reads as a closed ring.
  const segments = kinds.map((kind, i) => {
    const from = -90 + i * step + g.gapDeg / 2;
    return { kind, d: arc(g, from, from + step - g.gapDeg), width: round2(g[kind]) };
  });
  return { segments, more };
}

/** The ring in each density. */
export const crewRings = (crew, marks = crewMarks(crew)) =>
  Object.fromEntries(Object.entries(RINGS).map(([density, g]) => [density, crewRing(crew, g, marks)]));

/** Whether the wall's ring key shows: while any card has background work out. */
export const showsRingKey = (cards) => cards.some((c) => c.rings.comfortable.segments.length > 0);

/**
 * The needs-you line as [lead, keep]: `keep` is the end a card holds in view
 * when the line is cut short, the tool a permission asks for. An MCP tool
 * keeps its own name past the server prefix ("mcp__server__tool" keeps
 * "tool"); the cut falls in the lead, so the line is cut in the middle.
 */
export function askParts(reason) {
  if (reason === "question") return ["Waiting for your answer", ""];
  if (reason === "approve plan") return ["Waiting for you to approve the plan", ""];
  if (!reason) return ["Waiting for you", ""];
  if (!reason.startsWith("approve ")) return [`Waiting for you to ${reason}`, ""];
  const tool = reason.slice("approve ".length);
  const cut = tool.lastIndexOf("__");
  const keep = cut > 0 && cut + 2 < tool.length ? tool.slice(cut + 2) : tool;
  return [`Waiting for you to approve ${tool.slice(0, tool.length - keep.length)}`, keep];
}

/** The needs-you line: what the session waits for. */
export const askText = (reason) => askParts(reason).join("");

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

/** A Remote Control session link (session.rs REMOTE_PREFIX), else null: nothing else becomes a link. */
export function remoteLink(url) {
  return typeof url === "string" && /^https:\/\/claude\.ai\/code\/[A-Za-z0-9_-]{1,128}$/.test(url) ? url : null;
}

/** The sessions with every needs-you one first, each group in the reader's order. */
export const needsFirst = (sessions) => [
  ...sessions.filter((s) => s.status === "needs_you"),
  ...sessions.filter((s) => s.status !== "needs_you"),
];

/** How many other repos the full card names before a "+N" chip takes the rest. */
export const ALSO_NAMED = 4;

/** Whether the live cards run on more than one account: only then is a card's account worth a chip. */
export function accountsDiffer(cards) {
  return new Set(cards.filter((c) => c.accountId && c.status !== "ended").map((c) => c.accountId)).size > 1;
}

// Claude Code's wrapper on a message one session sends another; the socket is
// named for the sender's Claude process id.
const CROSS_SESSION = /^\s*<cross-session-message\b([^>]*)(?:>([\s\S]*?))?(?:<\/cross-session-message>\s*)?$/;

/** A prompt that is another session's message: {pid, name, text}; null for any other prompt. */
export function crossMessage(text) {
  const m = typeof text === "string" ? CROSS_SESSION.exec(text) : null;
  if (!m) return null;
  const attr = (k) => new RegExp(`(?:^|\\s)${k}="([^"]*)"`).exec(m[1])?.[1] ?? null;
  const pid = Number(/\/(\d+)\.sock$/.exec(attr("from") ?? "")?.[1]);
  return { pid: pid > 0 ? pid : null, name: attr("from-name"), text: (m[2] ?? "").trim() };
}

/** Each live session's character name by its Claude process id, so a message names who sent it. */
export function senderNames(sessions, cast) {
  const names = new Map();
  for (const s of sessions) {
    const pid = s.claude?.pid;
    if (Number.isInteger(pid) && pid > 0 && s.status !== "ended") names.set(pid, identity(s, cast).name);
  }
  return names;
}

/** What a card shows of its prompt: another session's message says whose it is, never its tag. */
export function promptText(text, senders = new Map()) {
  const msg = crossMessage(text);
  if (!msg) return plainText(text);
  const who = (msg.pid !== null && senders.get(msg.pid)) || msg.name || "another session";
  const body = plainText(msg.text);
  return body ? `Message from ${who}: ${body}` : `Message from ${who}`;
}

/** One card on the wall; `request` is the snapshot's wrap-up, when one is shown; `senders`, senderNames'. */
export function card(s, cast, nowMs, request = null, senders = new Map()) {
  const who = identity(s, cast);
  const wrapup = wrapupLine(s, request, nowMs);
  const st = statusOf(s.status, isQuiet(s));
  const crew = crewOf(s);
  const also = [...new Set((s.touched ?? []).map((t) => t.repo))].filter((r) => r && r !== s.where?.repo);
  const jump = jumpable(s);
  const marks = crewMarks(crew);
  return {
    id: s.session_id,
    task: s.name || "No session name yet",
    tone: st.tone,
    pill: {
      label: PILL_REASON.has(s.status) && s.reason ? `${st.label} \u00b7 ${s.reason}` : st.label,
      age: statusParts(s, nowMs).at(-1),
      when: pillWhen(s, nowMs),
    },
    ask: s.status === "needs_you" ? askText(s.reason) : null,
    askParts: s.status === "needs_you" ? askParts(s.reason) : null,
    rings: crewRings(crew, marks),
    marks,
    // An agent's segment wears the character's colour; a medallion's, the wall's gold.
    ringColor: who.accent,
    crew: crewText(crew),
    // Only once Stop fired with work out (the hook's reason "background"), never mid-turn.
    promptFree: reasonText(s) === PROMPT_FREE && crewSize(crew) > 0,
    dim: DIM.has(s.status),
    place: s.where
      ? {
          repo: s.where.repo,
          worktree: s.where.worktree ?? null,
          branch: s.where.branch ?? null,
          folder: plainDir(s.where.dir),
          github: githubPage(s.where.github),
        }
      : null,
    also: also.slice(0, ALSO_NAMED).map((r) => `also in ${r}`),
    alsoRest: alsoChip(also.slice(ALSO_NAMED)),
    alsoPast: also.slice(ALSO_NAMED).map((r) => `also in ${r}`), // named only while a phone card shows its full text
    alsoChip: alsoChip(also),
    voiceTitle: who.voice ? `Voice: ${who.voice}` : null,
    name: who.name,
    session: s.name ?? null,
    face: who.face,
    face2x: who.face2x,
    full: who.full,
    accent: who.accent,
    accentInk: who.accent ? accentInk(who.accent) : null,
    epithet: who.epithet,
    figure: who.figure,
    ...jumpStyle(s, who.accent),
    status: s.status,
    quiet: isQuiet(s),
    badge: badgeSvg(s.status, isQuiet(s)),
    prompt: promptText(s.prompt?.text ?? null, senders),
    reply: plainText(s.reply?.text ?? null),
    error: s.status === "error" ? s.error ?? null : null,
    ledger: ledgerLine(s.ledger, s.ledger_partial === true),
    updated: s.status === "ended" ? null : updatedText(s, nowMs), // the pill's age says it
    jump,
    clear: s.status === "ended" || s.status === "silent",
    actions: sessionActions(s),
    wrapupRoute: sessionRoute(s),
    wrapup,
    remote: remoteLink(s.remote_url),
    // The account it runs on; the wall shows it only while cards differ in it (accountsDiffer).
    account: s.account?.label ?? null,
    accountId: s.account?.id ?? null,
    remoteLabel: `Open ${who.name}'s session in Claude`,
    // keryx's latest spoken reply, when it kept one (replay.js).
    clip: Number.isInteger(s.reply_at) ? s.reply_at : null,
    playLabel: `Play ${who.name}'s last reply`,
    stopLabel: `Stop ${who.name}'s reply`,
    menuLabel: `Session actions for ${who.name}`,
    // An off button says why in its name too, not only in its tooltip.
    jumpLabel: `Open terminal, ${who.name}${jump.why ? `, unavailable: ${jump.why}` : ""}`,
    label: [accessibleName(s, cast, nowMs), wrapup?.text].filter(Boolean).join(", "),
  };
}
