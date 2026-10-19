// What the fleet strip and wall show for each session, kept free of the DOM
// so it can be unit tested. Sessions arrive from the reader already ordered.

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
// A working session with no hook activity for a while: an interrupt runs no Stop hook.
const QUIET_WORKING = { ...STATUS.working, label: "working?", symbol: "?" };
export const statusOf = (status, quiet = false) =>
  quiet && status === "working" ? QUIET_WORKING : (STATUS[status] ?? UNKNOWN);
const isQuiet = (s) => s.status === "working" && s.quiet_since != null;

// A card says when it last changed once that is older than this.
export const SHOW_UPDATED_AFTER_MS = 5 * 60 * 1000;

const FACES = "fleet/faces";
const ageMs = (atSec, nowMs) => nowMs - Number(atSec) * 1000;

/** "2m", "1h", "3d"; "<1m" under a minute. A time ahead of the clock is now. */
export function shortAge(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  if (mins < 1) return "<1m";
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  if (h < 24) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

/** The same age in words, for accessible names: "2 minutes". */
export function longAge(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  const unit = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
  if (mins < 1) return "under a minute";
  if (mins < 60) return unit(mins, "minute");
  const h = Math.floor(mins / 60);
  if (h < 24) return unit(h, "hour");
  return unit(Math.floor(h / 24), "day");
}

/** Label, reason and age. A silent session says how long since any word; a quiet one, since any activity. */
export function statusParts(s, nowMs, age = shortAge) {
  const a = age(ageMs(s.status_at, nowMs));
  if (s.status === "silent") return [statusOf(s.status).label, `no word for ${a}`];
  if (isQuiet(s)) return [statusOf(s.status, true).label, `no activity for ${age(ageMs(s.quiet_since, nowMs))}`];
  return [statusOf(s.status).label, s.reason, a].filter(Boolean);
}

/** "needs you \u00b7 approve Bash \u00b7 2m" */
export const statusLine = (s, nowMs) => statusParts(s, nowMs).join(" \u00b7 ");

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

/** FNV-1a over UTF-16 code units: a stable hash for picking a fallback face. */
export function hash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

const basename = (path) => (typeof path === "string" ? path.replace(/\/+$/, "").split("/").pop() : "");

/**
 * Who a session is, from its identity alone, never its state: the kourai
 * character cast for its keryx voice; else a Lorelei face for the voice; else
 * a fallback face picked by a hash of the voice (a blend) or of the session.
 */
export function identity(s, cast) {
  const voice = typeof s.voice === "string" && s.voice ? s.voice : null;
  const character = voice ? cast.characters[voice] : null;
  if (character) {
    const base = `${FACES}/kourai/${character.face}`;
    return { name: character.name, voice: voiceName(voice), face: `${base}-96.webp`, face2x: `${base}-192.webp` };
  }
  if (voice && cast.lorelei.includes(voice)) {
    const face = `${FACES}/lorelei/${voice}.svg`;
    return { name: voiceName(voice), voice: null, face, face2x: face };
  }
  const n = hash(voice ?? s.session_id) % cast.fallbacks;
  const face = `${FACES}/fallback/${String(n).padStart(2, "0")}.svg`;
  const name = voice ? voiceName(voice) : s.name || basename(s.launch_dir) || s.session_id.slice(0, 8);
  return { name, voice: null, face, face2x: face };
}

/** "Hephaestus, needs you, approve Bash, 2 minutes" */
export const accessibleName = (s, cast, nowMs) =>
  [identity(s, cast).name, ...statusParts(s, nowMs, longAge)].join(", ");

/** Each session's status by id, to compare the next snapshot against. */
export const statuses = (sessions) => new Map(sessions.map((s) => [s.session_id, s.status]));

/** Sessions that started needing AJ since `before`; none on the first look. */
export function startedNeeding(before, sessions) {
  if (!before) return new Set();
  return new Set(
    sessions
      .filter((s) => s.status === "needs_you" && before.get(s.session_id) !== "needs_you")
      .map((s) => s.session_id),
  );
}

/** What the wall's live region says about changes since `before`; nothing on the first look. */
export function announcements(before, sessions, cast) {
  if (!before) return [];
  return sessions
    .filter((s) => before.get(s.session_id) !== s.status)
    .map((s) => [identity(s, cast).name, statusOf(s.status).label, s.status === "silent" ? null : s.reason]
      .filter(Boolean)
      .join(", "));
}

/** "klepsydra \u00b7 fleet \u00b7 feat/fleet-visualizer" */
export const whereText = (w) => (w ? [w.repo, w.worktree, w.branch].filter(Boolean).join(" \u00b7 ") : "");

/** "updated 7m ago" once the newest field is over five minutes old. */
export function updatedText(s, nowMs) {
  const age = ageMs(s.updated_at, nowMs);
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
      label: accessibleName(s, cast, nowMs),
      face: who.face,
      face2x: who.face2x,
      pulse: pulse.has(s.session_id),
    };
  });
}

/** Whether the card can jump to the session's terminal, and why not. */
function jumpable(s) {
  if (s.status === "ended") return { enabled: false, why: "session ended" };
  if (!s.name) return { enabled: false, why: "no session name yet" };
  return { enabled: true, why: null };
}

/** One card on the wall. */
export function card(s, cast, nowMs) {
  const who = identity(s, cast);
  return {
    id: s.session_id,
    name: who.name,
    voice: who.voice,
    session: s.name ?? null,
    face: who.face,
    face2x: who.face2x,
    status: s.status,
    quiet: isQuiet(s),
    statusLine: statusLine(s, nowMs),
    where: whereText(s.where),
    touched: (s.touched ?? []).map((t) => `${t.repo} \u00b7 ${shortAge(ageMs(t.at, nowMs))}`),
    prompt: s.prompt?.text ?? null,
    reply: s.reply?.text ?? null,
    error: s.status === "error" ? s.error ?? null : null,
    updated: updatedText(s, nowMs),
    jump: jumpable(s),
    label: accessibleName(s, cast, nowMs),
  };
}

/** Columns that `repeat(auto-fill, minmax(min, 1fr))` makes in a viewport `width` wide. */
export function columnsAt(width, { min, gap, pad }) {
  return Math.max(1, Math.floor((width - 2 * pad + gap) / (min + gap)));
}
