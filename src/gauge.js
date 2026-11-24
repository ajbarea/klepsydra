// Pure rendering logic, kept free of Tauri and DOM so it can be unit tested.
// The desktop gauge and the phone wall both draw from it (gaugeview.js).

/** What a gauge with no reading says. */
export const WAITING = "waiting for Claude Code";

// Past this age a reading says how old it is.
export const SHOW_AGE_AFTER_MS = 15 * 60 * 1000;
// An account unused this long is gone. Short of that it stays, because the
// account you are not on is the one you may want to switch to.
export const DROP_AFTER_MS = 30 * 24 * 60 * 60 * 1000;

// Two sessions can timestamp the same window a moment apart; within this many
// seconds they are the same window, not a newer one.
export const WINDOW_MATCH_SECONDS = 90;
// Keep this mirror of fleet/lib.sh's default FLEET_ROOM_PCT in sync.
export const FLEET_ROOM_PCT = 90;

/**
 * A reading's number: a JSON number only, as the phone server sends it
 * (usage.rs), else NaN. "57" in a file is no reading.
 */
const num = (x) => (typeof x === "number" && Number.isFinite(x) ? x : Number.NaN);

// Fixed display order, so rows never reshuffle between polls.
export const WINDOW_ORDER = [
  "five_hour",
  "seven_day",
  "spend_limit",
  "gemini",
  "claude_gpt",
  "ai_credits",
  "personal",
  "ldqis",
];

export const HARNESS_ORDER = ["claude", "agy", "copilot", "api"];

export const HARNESS_LABELS = {
  claude: "Claude Code",
  agy: "Antigravity",
  copilot: "Copilot",
  api: "API Keys",
};

export const ROUTE_ORDER = ["agy_gemini", "agy_claude_gpt", "copilot", "api_credit", "claude_subscription"];

/**
 * The lane the fleet should try next. A model group is a lane of its own:
 * one spent group must not disqualify another group on the same account.
 */
export function routeLane(row) {
  const harness = row?.harness;
  const window = row?.window;
  if (harness === "agy" && ["five_hour", "seven_day", "gemini"].includes(window)) return "agy_gemini";
  if (harness === "agy" && window === "claude_gpt") return "agy_claude_gpt";
  if (harness === "copilot") return "copilot";
  if (harness === "api" || ["ai_credits", "personal", "ldqis", "claude_gpt"].includes(window)) return "api_credit";
  return "claude_subscription";
}

/** The windows that must all have room for one lane to run, as one key per account and model. */
export const routeGroup = (row) => {
  const lane = routeLane(row);
  // API credit and Copilot windows are separate model pools; Claude and AGY
  // Gemini windows are coupled limits for one account.
  const model = ["api_credit", "copilot"].includes(lane) ? row.window : lane;
  return `${row.account}\u0000${model}`;
};

const hasRoom = (row) => {
  if (!Number.isFinite(row.pct)) return false;
  const remaining = Math.floor(100 - row.pct);
  if (row.window === "five_hour") return remaining > 100 - FLEET_ROOM_PCT;
  if (row.window === "seven_day") return remaining > 5;
  return remaining > 0;
};

const WINDOW_LABELS = {
  five_hour: "Current session",
  seven_day: "This week",
  spend_limit: "Spend limit",
  gemini: "Gemini models",
  claude_gpt: "Claude & GPT",
  ai_credits: "AI Credits",
  personal: "Personal API",
  ldqis: "LDQIS API",
};
// Shorter forms, used once an account name is already carrying context.
const WINDOW_SHORT = {
  five_hour: "session",
  seven_day: "week",
  spend_limit: "spend",
  gemini: "gemini",
  claude_gpt: "claude/gpt",
  ai_credits: "credits",
  personal: "personal",
  ldqis: "ldqis",
};

export function harnessOf(entry) {
  if (entry?.harness) return entry.harness;
  const acct = String(entry?.account ?? "");
  if (acct.startsWith("agy") || entry?.engine === "agy") return "agy";
  if (acct.startsWith("copilot") || entry?.engine === "copilot") return "copilot";
  if (acct.startsWith("api")) return "api";
  return "claude";
}


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

/** When a window's number was read (s): its own stamp, else its reading's. */
export function readAtOf(payload, win) {
  return num(win?.observed_at ?? payload?.observed_at ?? payload?.written_at);
}

/**
 * Decide what to draw from a parsed usage.json (or null when it is missing
 * or unreadable). Never throws; an unusable payload degrades to "waiting".
 */
export function evaluate(payload, key, nowMs = Date.now()) {
  const waiting = { state: "waiting", label: windowLabel(key), pct: null, sub: WAITING, short: "waiting" };
  if (!payload || typeof payload !== "object") return waiting;

  const win = payload.windows?.[key];
  if (!win || !Number.isFinite(num(win.used_percentage))) return waiting;

  const resetsAt = num(win.resets_at);
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

  const age = nowMs - readAtOf(payload, win) * 1000;
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
    pct: num(win.used_percentage),
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

/**
 * The ring's dash for `pct`, on a circle whose path is 100 long. A round cap
 * adds half the stroke at each end, `cap` along the path in all, so the dash
 * leaves it out and the drawn arc is `pct`. Under `cap` it is a dot; a full
 * window closes the ring.
 */
export function ringDash(pct, cap) {
  const p = Math.max(0, Math.min(100, pct ?? 0));
  if (p === 0 || p === 100) return p;
  return Math.max(MIN_DASH, p - cap);
}
// A zero-length dash may draw no cap at all, so the dot keeps a hair of length.
const MIN_DASH = 0.01;

/** The round caps' length along the 100-long path of a ring of radius `r` drawn `stroke` wide. */
export function ringCap(stroke, r) {
  return (stroke / (2 * Math.PI * r)) * 100;
}

/**
 * The ring's stroke for `pct`: the dash less its caps, moved half a cap
 * forward so the drawn arc starts at 12 o'clock. Hidden at zero, where the
 * caps alone would draw a dot.
 */
export function ringStyle(pct, cap) {
  const p = Math.max(0, Math.min(100, pct ?? 0));
  return { dasharray: `${ringDash(pct, cap)} 100`, dashoffset: `${-cap / 2}`, visible: p > 0 };
}

/**
 * A row's words: the compact layout's short forms or the full layout's,
 * and one sentence for a screen reader, which reads the full forms.
 */
export function entryText(row, compact) {
  const sub = compact ? row.short : row.sub;
  return {
    label: row.label,
    pct: compact ? formatPctShort(row.pct) : formatPct(row.pct),
    sub,
    spoken: `${row.label}: ${formatPct(row.pct)}. ${row.sub}`,
  };
}

/**
 * The phone wall's rows from a snapshot's `usage` readings, as toRows draws
 * the gauge's; null when the snapshot carries none (an older server, or a
 * server with no readings to read), so no gauge shows.
 */
export function usageRows(snapshot, nowMs = Date.now()) {
  const usage = snapshot?.usage;
  return Array.isArray(usage) ? toRows(usage, nowMs) : null;
}

/** Whether a file came from a hook that publishes only new API responses. */
const isObserved = (s) => Number.isFinite(num(s?.observed_at));

/**
 * When a session's reading arrived, or for an older hook's file, when it was
 * last written. NaN when the file carries neither.
 */
function stampOf(s) {
  const raw = isObserved(s) ? s.observed_at : s?.written_at;
  return num(raw);
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
    const ok = w && Number.isFinite(num(w.used_percentage)) && Number.isFinite(num(w.resets_at));
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
    const newest = sessions.filter((s) => stampOf(s) === writtenAt);
    const current = new Set(newest.flatMap((s) => Object.keys(s.windows)));
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
      // The newest reading names the account: an organisation renamed shows
      // its new name, and dropping older readings never changes it.
      label: (newest.find((s) => s.label) ?? sessions.find((s) => s.label))?.label ?? "Claude",
      harness: harnessOf(newest[0] ?? sessions[0]),
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
    const h = p.harness ?? "claude";
    for (const key of WINDOW_ORDER) {
      if (!p.windows[key]) continue;
      const r = evaluate(p, key, nowMs);
      if (r.state === "waiting") continue;
      rows.push({
        ...r,
        key: `${p.account}:${key}`,
        account: p.account,
        harness: h,
        window: key,
        accountLabel: p.label,
        harnessLabel: HARNESS_LABELS[h] ?? h,
        // When the account's newest reading arrived (s).
        observedAt: Number(p.written_at),
        // When this window's own number was read (s): older than observedAt
        // when a live window survives from an earlier reading.
        readAt: readAtOf(p, p.windows[key]),
        // The reconciled window's reset, unix seconds: + New session says when room comes back.
        resetsAt: num(p.windows[key].resets_at),
        isCapped: r.pct >= 100 || r.state === "waiting",
        label: multi ? `${p.label} \u00b7 ${WINDOW_SHORT[key] ?? key}` : r.label,
      });
    }
  }

  // Route recommendation follows the same free-first order as the fleet.
  // Windows that constrain the same account/model group must all have room;
  // otherwise a low row can recommend a route that cannot actually run.
  const groups = new Map();
  for (const row of rows) {
    row.isBestRoute = false;
    const key = routeGroup(row);
    if (!groups.has(key)) groups.set(key, { lane: routeLane(row), rows: [] });
    groups.get(key).rows.push(row);
  }

  const bestByLane = new Map();
  for (const group of groups.values()) {
    const required = group.lane === "agy_gemini" && !group.rows.some((row) => row.window === "gemini")
      ? ["five_hour", "seven_day"]
      : [];
    const keys = new Set(group.rows.map((row) => row.window));
    if (required.some((key) => !keys.has(key)) || !group.rows.every(hasRoom)) continue;
    const best = group.rows.reduce((a, b) => (b.pct > a.pct ? b : a));
    const current = bestByLane.get(group.lane);
    if (!current || best.pct < current.pct) bestByLane.set(group.lane, best);
  }

  for (const lane of ROUTE_ORDER) {
    const best = bestByLane.get(lane);
    if (best) {
      best.isBestRoute = true;
      break;
    }
  }

  return rows;
}

/**
 * Group evaluated usage rows by harness for dashboard grouping (#393).
 * Returns array of { harness, label, isCapped, isBestRoute, rows }.
 */
export function harnessGroups(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return [];
  const groups = new Map();
  for (const row of rows) {
    const h = row.harness ?? "claude";
    if (!groups.has(h)) {
      groups.set(h, {
        harness: h,
        label: HARNESS_LABELS[h] ?? h,
        isCapped: true,
        isBestRoute: false,
        rows: [],
      });
    }
    const g = groups.get(h);
    g.rows.push(row);
    if (!row.isCapped) g.isCapped = false;
    if (row.isBestRoute) g.isBestRoute = true;
  }
  return HARNESS_ORDER.filter((h) => groups.has(h)).map((h) => groups.get(h));
}
