// Pure rendering logic, kept free of Tauri and DOM so it can be unit tested.

// Past this age a reading says how old it is.
export const STALE_AFTER_MS = 15 * 60 * 1000;
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
 * "Resets in 4 hr 58 min". Returns null once the window has already reset,
 * which the caller treats as "no live data" rather than "0% used".
 */
export function formatCountdown(resetsAtSec, nowMs = Date.now()) {
  if (!Number.isFinite(resetsAtSec)) return null;
  const ms = resetsAtSec * 1000 - nowMs;
  if (ms <= 0) return null;
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return "Resets in under a minute";
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  // A weekly window is tens of hours out; "83 hr 19 min" is not readable.
  if (h >= 24) {
    const d = Math.floor(h / 24);
    const rh = h % 24;
    const days = `${d} day${d === 1 ? "" : "s"}`;
    return rh === 0 ? `Resets in ${days}` : `Resets in ${days} ${rh} hr`;
  }
  if (h === 0) return `Resets in ${m} min`;
  if (m === 0) return `Resets in ${h} hr`;
  return `Resets in ${h} hr ${m} min`;
}

/** "3 hr ago": the largest whole unit, so a glance reads it. */
export function formatAge(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const h = Math.floor(mins / 60);
  if (h < 24) return `${h} hr ago`;
  const d = Math.floor(h / 24);
  return `${d} day${d === 1 ? "" : "s"} ago`;
}

/**
 * Decide what to draw from a parsed usage.json (or null when it is missing
 * or unreadable). Never throws; an unusable payload degrades to "waiting".
 */
export function evaluate(payload, key, nowMs = Date.now()) {
  const waiting = { state: "waiting", label: windowLabel(key), pct: null, sub: "waiting for Claude Code" };
  if (!payload || typeof payload !== "object") return waiting;

  const win = payload.windows?.[key];
  if (!win || !Number.isFinite(Number(win.used_percentage))) return waiting;

  const resetsAt = Number(win.resets_at);
  const countdown = formatCountdown(resetsAt, nowMs);
  // The window that number described has ended, and the next one has not
  // started; usage elsewhere since then would not have reached this machine.
  if (countdown === null) {
    const sub = Number.isFinite(resetsAt) ? `Reset ${formatAge(nowMs - resetsAt * 1000)}` : "window reset";
    return { state: "reset", label: windowLabel(key), pct: 0, sub };
  }

  const observedAtMs = Number(win.observed_at ?? payload.written_at) * 1000;
  const age = Number.isFinite(observedAtMs) ? nowMs - observedAtMs : Infinity;
  const sub = age > STALE_AFTER_MS && Number.isFinite(age)
    ? `${countdown} \u00b7 updated ${formatAge(age)}`
    : countdown;

  return {
    state: "live",
    label: windowLabel(key),
    pct: Number(win.used_percentage),
    sub,
  };
}

export function formatPct(pct) {
  if (pct === null) return "--";
  return `${Math.floor(pct)}% used`;
}

/**
 * Reconcile one window across every session of an account.
 *
 * Each session's file holds its own last API response, published when it
 * changed, so the one written last is current. Highest-wins is not safe: a
 * mid-window reset or a plan change lowers usage under the same `resets_at`.
 * Readings from one second fall back to the newer window, then the higher one.
 * The winner carries `observed_at`, its session's `written_at`.
 */
export function pickWindow(sessions, key) {
  const all = sessions.flatMap((s) => {
    const w = s?.windows?.[key];
    const ok = w && Number.isFinite(Number(w.used_percentage)) && Number.isFinite(Number(w.resets_at));
    return ok ? [{ ...w, observed_at: Number(s.written_at) || 0 }] : [];
  });
  if (all.length === 0) return null;

  const latest = Math.max(...all.map((w) => w.observed_at));
  const cands = all.filter((w) => w.observed_at === latest);
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
  for (const [id, sessions] of byAccount) {
    const writtenAt = Math.max(...sessions.map((s) => Number(s.written_at) || 0));
    // The windows the account reports now. An ended window outside them is
    // one it no longer has, or one filed under it by mistake.
    const current = new Set(
      sessions
        .filter((s) => (Number(s.written_at) || 0) === writtenAt)
        .flatMap((s) => Object.keys(s.windows)),
    );
    const windows = {};
    for (const key of WINDOW_ORDER) {
      const win = pickWindow(sessions, key);
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
