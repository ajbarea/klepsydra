// Pure rendering logic, kept free of Tauri and DOM so it can be unit tested.

// Past this age a reading says how old it is.
export const SHOW_AGE_AFTER_MS = 15 * 60 * 1000;
// An account unused this long is gone. Short of that it stays, because the
// account you are not on is the one you may want to switch to.
export const DROP_AFTER_MS = 30 * 24 * 60 * 60 * 1000;

// Two sessions can timestamp the same window a moment apart; within this many
// seconds they are the same window, not a newer one.
export const WINDOW_MATCH_SECONDS = 90;

// Fixed display order, so rows never reshuffle between polls.
export const WINDOW_ORDER = ["five_hour", "seven_day", "spend_limit"];

const WINDOW_LABELS = {
  five_hour: "Current session",
  seven_day: "This week",
  spend_limit: "Spend limit",
};
// Shorter forms, used once an account name is already carrying context.
const WINDOW_SHORT = {
  five_hour: "session",
  seven_day: "week",
  spend_limit: "spend",
};

export function windowLabel(key) {
  return WINDOW_LABELS[key] ?? key;
}

/**
 * Which pair of stops a percentage falls between, and how far along it is.
 * Clamped, so a spend_limit reading above 100 pins to the high stop.
 */
export function rampPosition(pct, midAt) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const m = Math.max(1, Math.min(99, Number(midAt) || 60));
  return p <= m
    ? { from: "low", to: "mid", t: p / m }
    : { from: "mid", to: "high", t: (p - m) / (100 - m) };
}

/**
 * Colour for a given used-percentage.
 *
 * "blend" interpolates in OKLab, which the browser computes -- sRGB
 * interpolation between blue and yellow passes through a muddy olive.
 * "bands" holds each stop flat and switches at the boundaries, which reads
 * more like a game health bar.
 */
export function rampColor(pct, stops, mode = "blend") {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  if (mode === "bands") {
    const highAt = Number(stops.highAt) || 85;
    if (p >= highAt) return stops.high;
    if (p >= (Number(stops.midAt) || 60)) return stops.mid;
    return stops.low;
  }
  const { from, to, t } = rampPosition(p, stops.midAt);
  return `color-mix(in oklab, ${stops[to]} ${Math.round(t * 100)}%, ${stops[from]})`;
}

/**
 * The time left before a reset as {d, h, m}, with minutes dropped a day or
 * more out ("83 hr 19 min" is not readable). `{}` under a minute; null once
 * the window has reset, or when there is no reset time.
 */
function countdownParts(resetsAtSec, nowMs) {
  if (!Number.isFinite(resetsAtSec)) return null;
  const ms = resetsAtSec * 1000 - nowMs;
  if (ms <= 0) return null;
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return {};
  const h = Math.floor(mins / 60);
  if (h >= 24) return { d: Math.floor(h / 24), h: h % 24 };
  return { h, m: mins % 60 };
}

/** "Resets in 4 hr 58 min", or null as for countdownParts. */
export function formatCountdown(resetsAtSec, nowMs = Date.now()) {
  const p = countdownParts(resetsAtSec, nowMs);
  if (p === null) return null;
  const parts = [
    p.d && `${p.d} day${p.d === 1 ? "" : "s"}`,
    p.h && `${p.h} hr`,
    p.m && `${p.m} min`,
  ].filter(Boolean);
  return `Resets in ${parts.length ? parts.join(" ") : "under a minute"}`;
}

/** "4h 58m", the compact layout's countdown, or null as for countdownParts. */
export function formatCountdownShort(resetsAtSec, nowMs = Date.now()) {
  const p = countdownParts(resetsAtSec, nowMs);
  if (p === null) return null;
  const parts = [p.d && `${p.d}d`, p.h && `${p.h}h`, p.m && `${p.m}m`].filter(Boolean);
  return parts.length ? parts.join(" ") : "<1m";
}

/** An age in its largest whole unit, as [count, unit], or null under a minute. */
function ageUnit(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  if (mins < 1) return null;
  if (mins < 60) return [mins, "min"];
  const h = Math.floor(mins / 60);
  if (h < 24) return [h, "hr"];
  return [Math.floor(h / 24), "day"];
}

/** "3 hr ago": the largest whole unit, so a glance reads it. */
export function formatAge(ms) {
  const a = ageUnit(ms);
  if (a === null) return "just now";
  const [n, unit] = a;
  return `${n} ${unit}${unit === "day" && n !== 1 ? "s" : ""} ago`;
}

/** "3h": formatAge for the compact layout, "now" under a minute. */
export function formatAgeShort(ms) {
  const a = ageUnit(ms);
  return a === null ? "now" : `${a[0]}${a[1][0]}`;
}

/**
 * Decide what to draw from a parsed usage.json (or null when it is missing
 * or unreadable). Never throws; an unusable payload degrades to "waiting".
 */
export function evaluate(payload, key, nowMs = Date.now()) {
  const waiting = { state: "waiting", label: windowLabel(key), pct: null, sub: "waiting for Claude Code", short: "waiting" };
  if (!payload || typeof payload !== "object") return waiting;

  const win = payload.windows?.[key];
  if (!win || !Number.isFinite(Number(win.used_percentage))) return waiting;

  const resetsAt = Number(win.resets_at);
  const countdown = formatCountdown(resetsAt, nowMs);
  // The window that number described has ended, and the next one has not
  // started; usage elsewhere since then would not have reached this machine.
  if (countdown === null) {
    const since = nowMs - resetsAt * 1000;
    const sub = Number.isFinite(resetsAt) ? `Reset ${formatAge(since)}` : "window reset";
    const recent = !Number.isFinite(resetsAt) || formatAgeShort(since) === "now";
    const short = recent ? "just reset" : `reset ${formatAgeShort(since)} ago`;
    return { state: "reset", label: windowLabel(key), pct: 0, sub, short };
  }

  const age = nowMs - Number(win.observed_at ?? payload.observed_at ?? payload.written_at) * 1000;
  let sub = countdown;
  let short = formatCountdownShort(resetsAt, nowMs);
  if (!Number.isFinite(age)) {
    sub += " \u00b7 age unknown";
    short += " \u00b7 age unknown";
  } else if (age > SHOW_AGE_AFTER_MS) {
    sub += ` \u00b7 updated ${formatAge(age)}`;
    short += ` \u00b7 ${formatAgeShort(age)} old`;
  }

  return {
    state: "live",
    label: windowLabel(key),
    pct: Number(win.used_percentage),
    sub,
    short,
  };
}

export function formatPct(pct) {
  if (pct === null) return "--";
  return `${Math.floor(pct)}% used`;
}

/** "73%": formatPct for the compact layout, where the ring says "used". */
export function formatPctShort(pct) {
  if (pct === null) return "--";
  return `${Math.floor(pct)}%`;
}

/** Whether a file came from a hook that publishes only new API responses. */
const isObserved = (s) => s?.observed_at != null && Number.isFinite(Number(s.observed_at));

/**
 * When a session's reading arrived, or for an older hook's file, when it was
 * last written. NaN when the file carries neither.
 */
function stampOf(s) {
  const raw = isObserved(s) ? s.observed_at : s?.written_at;
  return raw == null ? Number.NaN : Number(raw);
}

/**
 * Which of an account's sessions to reconcile, and whether their times can be
 * trusted. Before `observed_at`, the hook restamped every session on every
 * re-render, so its times say only when a terminal last redrew. Older files
 * that observed readings have overtaken are ignored: a real response carries
 * every window, so they hold nothing newer. One newer than every observed
 * reading means an old hook is still writing, so no time is trusted.
 */
function reconcilable(sessions) {
  const observed = sessions.filter(isObserved);
  if (observed.length === 0) return { sessions, byTime: false };
  const newest = Math.max(...observed.map(stampOf));
  const oldHookWriting = sessions.some((s) => !isObserved(s) && stampOf(s) > newest);
  return oldHookWriting ? { sessions, byTime: false } : { sessions: observed, byTime: true };
}

/**
 * Reconcile one window across an account's sessions.
 *
 * `byTime`: the newest reading is current. Highest-wins is not safe there: a
 * mid-window reset or a plan change lowers usage under the same `resets_at`.
 * Otherwise, and for ties, the newest window wins, then the highest reading.
 * The winner carries `observed_at`, its session's time.
 */
export function pickWindow(sessions, key, byTime) {
  const all = sessions.flatMap((s) => {
    const w = s?.windows?.[key];
    const ok = w && Number.isFinite(Number(w.used_percentage)) && Number.isFinite(Number(w.resets_at));
    return ok ? [{ ...w, observed_at: stampOf(s) }] : [];
  });
  if (all.length === 0) return null;

  const latest = Math.max(...all.map((w) => w.observed_at).filter(Number.isFinite));
  const cands = byTime ? all.filter((w) => w.observed_at === latest) : all;
  const newest = Math.max(...cands.map((w) => Number(w.resets_at)));
  const current = cands.filter(
    (w) => newest - Number(w.resets_at) <= WINDOW_MATCH_SECONDS,
  );
  return current.reduce((a, b) =>
    Number(b.used_percentage) > Number(a.used_percentage) ? b : a,
  );
}

/**
 * Flatten every published session into the rows to draw, one per live window.
 *
 * `payload` is the list the backend hands over, one entry per session. With a
 * single account the rows read like the desktop app ("Current session"); with
 * more than one, each row is prefixed by its account so two unrelated numbers
 * are never mistaken for each other.
 */
export function toRows(payload, nowMs = Date.now()) {
  const list = (Array.isArray(payload) ? payload : Object.values(payload ?? {})).filter(
    (p) => p && typeof p === "object" && p.windows && typeof p.windows === "object",
  );

  const byAccount = new Map();
  for (const entry of list) {
    const id = String(entry.account ?? "?");
    if (!byAccount.has(id)) byAccount.set(id, []);
    byAccount.get(id).push(entry);
  }

  const accounts = [];
  for (const [id, all] of byAccount) {
    const { sessions, byTime } = reconcilable(all);
    const stamps = sessions.map(stampOf).filter(Number.isFinite);
    const writtenAt = stamps.length > 0 ? Math.max(...stamps) : Number.NaN;
    // The windows the account reports now. An ended window outside them is
    // one it no longer has, or one filed under it by mistake. A live one is
    // kept until it ends, since hiding a real window costs more.
    const current = new Set(
      sessions
        .filter((s) => stampOf(s) === writtenAt)
        .flatMap((s) => Object.keys(s.windows)),
    );
    const windows = {};
    for (const key of WINDOW_ORDER) {
      const win = pickWindow(sessions, key, byTime);
      if (!win) continue;
      if (!current.has(key) && formatCountdown(Number(win.resets_at), nowMs) === null) continue;
      windows[key] = win;
    }
    if (Object.keys(windows).length === 0) continue;
    accounts.push({
      account: id,
      label: sessions.find((s) => s.label)?.label ?? "Claude",
      written_at: writtenAt,
      windows,
    });
  }

  const fresh = accounts.filter((p) => {
    const at = Number(p.written_at) * 1000;
    return Number.isFinite(at) && nowMs - at <= DROP_AFTER_MS;
  });

  // Most recently used account first. Only one account can be signed in at a
  // time, so this is the one you are on now; the one you switched away from
  // sits below it while its windows burn down. Label then id break ties, so
  // rows never jump around.
  fresh.sort(
    (a, b) =>
      Number(b.written_at) - Number(a.written_at) ||
      String(a.label).localeCompare(String(b.label)) ||
      String(a.account).localeCompare(String(b.account)),
  );

  const multi = fresh.length > 1;
  const rows = [];
  for (const p of fresh) {
    for (const key of WINDOW_ORDER) {
      if (!p.windows[key]) continue;
      const r = evaluate(p, key, nowMs);
      if (r.state === "waiting") continue;
      rows.push({
        ...r,
        key: `${p.account}:${key}`,
        label: multi ? `${p.label} \u00b7 ${WINDOW_SHORT[key] ?? key}` : r.label,
      });
    }
  }
  return rows;
}
