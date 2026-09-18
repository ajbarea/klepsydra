// Pure rendering logic, kept free of Tauri and DOM so it can be unit tested.

export const STALE_AFTER_MS = 15 * 60 * 1000;
// An account nobody has used in this long is gone, not stale. Dropping it stops
// a signed-out account leaving a dead row on screen forever.
export const DROP_AFTER_MS = 12 * 60 * 60 * 1000;

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

/**
 * Decide what to draw from a parsed usage.json (or null when it is missing
 * or unreadable). Never throws; an unusable payload degrades to "waiting".
 */
export function evaluate(payload, key, nowMs = Date.now()) {
  const waiting = { state: "waiting", label: windowLabel(key), pct: null, sub: "waiting for Claude Code" };
  if (!payload || typeof payload !== "object") return waiting;

  const win = payload.windows?.[key];
  if (!win || !Number.isFinite(Number(win.used_percentage))) return waiting;

  const countdown = formatCountdown(Number(win.resets_at), nowMs);
  // The window's own reset time has passed, so the number on disk describes a
  // window that no longer exists.
  if (countdown === null) {
    return { state: "stale", label: windowLabel(key), pct: null, sub: "window reset" };
  }

  const writtenAtMs = Number(payload.written_at) * 1000;
  const stale = !Number.isFinite(writtenAtMs) || nowMs - writtenAtMs > STALE_AFTER_MS;

  return {
    state: stale ? "stale" : "live",
    label: windowLabel(key),
    pct: Number(win.used_percentage),
    sub: countdown,
  };
}

export function formatPct(pct) {
  if (pct === null) return "--";
  return `${Math.floor(pct)}% used`;
}

/**
 * Reconcile one window across every session of an account.
 *
 * Each session reports whatever its own last API response said, so an idle
 * terminal keeps publishing a stale, lower number indefinitely. Two rules
 * settle it: a later `resets_at` means a newer window and wins outright, and
 * within one window usage only ever grows, so the highest reading is current.
 */
export function pickWindow(sessions, key) {
  const cands = sessions
    .map((s) => s?.windows?.[key])
    .filter(
      (w) =>
        w &&
        Number.isFinite(Number(w.used_percentage)) &&
        Number.isFinite(Number(w.resets_at)),
    );
  if (cands.length === 0) return null;

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
    const windows = {};
    for (const key of WINDOW_ORDER) {
      const win = pickWindow(sessions, key);
      if (win) windows[key] = win;
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
    if (!Number.isFinite(at) || nowMs - at > DROP_AFTER_MS) return false;
    // After a login switch the previous account stops publishing, but its
    // window keeps burning down and still counts against you -- so keep it
    // until every one of its windows has actually reset.
    if (nowMs - at <= STALE_AFTER_MS) return true;
    return WINDOW_ORDER.some(
      (k) => p.windows[k] && formatCountdown(Number(p.windows[k].resets_at), nowMs) !== null,
    );
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
