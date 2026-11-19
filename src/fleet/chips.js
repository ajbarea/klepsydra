// The gauge strip's chips (#421, variant A): one per account and engine,
// built from toRows' rows so the readings and the route have one source.
// Pure: no DOM, no Tauri, so the floating strip, the wall header and the
// tests all share it.
import { ROUTE_ORDER, formatAgeShort, formatCountdownShort, windowLabel } from "../gauge.js";

// Past this age a chip dims and names its age instead of looking live.
export const STALE_AFTER_MS = 3 * 60 * 60 * 1000;

// The windows that limit a whole account. Any other window is one model
// group's pool (agy's Claude & GPT, an API key's credit): it shows as a pip
// and never decides the chip, unless the account has nothing else.
const ACCOUNT_WINDOWS = new Set(["five_hour", "seven_day", "spend_limit"]);

// Which engine each route lane runs on, so chips follow the fleet's
// free-first order (gauge.js ROUTE_ORDER, #411) without a second list.
export const LANE_HARNESS = {
  agy_gemini: "agy",
  agy_claude_gpt: "agy",
  copilot: "copilot",
  api_credit: "api",
  claude_subscription: "claude",
};
export const CHIP_ORDER = [...new Set(ROUTE_ORDER.map((lane) => LANE_HARNESS[lane]))];

const HARNESS_ICON = { claude: "claude", agy: "agy", copilot: "copilot", api: "anthropic" };
const HARNESS_NAME = { claude: "Claude", agy: "Antigravity", copilot: "Copilot", api: "API" };

/**
 * An account's mark: its engine's logo, or for a Claude account that belongs
 * to an organisation, a short monogram of the organisation's name ("RIT"),
 * so two Claude accounts never wear the same mark. A real logo for such an
 * account is a local file (Settings, #421), never committed.
 */
export function markOf(harness, label) {
  const text = String(label ?? "").trim();
  if (harness === "claude" && text && !/^personal$/i.test(text)) {
    const mono = text.split(/[\s\-_·/.]+/).find(Boolean)?.slice(0, 4).toUpperCase();
    if (mono) return { mono };
  }
  return { icon: HARNESS_ICON[harness] ?? "anthropic" };
}

/** The name a chip is read by: "Claude · Personal", "Google AI Pro". */
export function chipName(harness, label) {
  const text = String(label ?? "").trim();
  if (harness === "claude") return text ? `Claude · ${text}` : "Claude";
  return text || HARNESS_NAME[harness] || harness;
}

/**
 * A reset time on the clock: "3:32 PM" today, else with its day,
 * "Wed 10:15 AM". Null without a time.
 */
export function clockAt(sec, nowMs = Date.now()) {
  if (!Number.isFinite(sec)) return null;
  const at = new Date(sec * 1000);
  const time = at.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  if (at.toDateString() === new Date(nowMs).toDateString()) return time;
  return `${at.toLocaleDateString("en-US", { weekday: "short" })} ${time}`;
}

const spent = (row) => row.state === "live" && row.pct >= 100;

/**
 * What a chip leads with. A spent week hides the session (it cannot be used
 * until the week resets) and reads "out"; otherwise the account window with
 * the least room. Ties keep window order (session first).
 */
export function leadOf(rows) {
  const week = rows.find((r) => r.window === "seven_day" && spent(r));
  if (week) {
    return { lead: week, out: true, hidden: rows.filter((r) => r.window === "five_hour") };
  }
  const own = rows.filter((r) => ACCOUNT_WINDOWS.has(r.window));
  const pool = own.length ? own : rows;
  const lead = pool.reduce((a, b) => ((b.pct ?? 0) > (a.pct ?? 0) ? b : a));
  return { lead, out: spent(lead), hidden: [] };
}

/** A window's time in a stacked cell: the countdown, or what its reset says. */
export function cellWhen(row, nowMs = Date.now()) {
  if (row.state !== "live") return row.short;
  return spent(row) ? `until ${clockAt(row.resetsAt, nowMs)}` : (formatCountdownShort(row.resetsAt, nowMs) ?? row.short);
}

/** One window as the hover reads it: "This week 45% · resets Mon 1:00 PM". */
function windowLine(row, nowMs) {
  const name = windowLabel(row.window);
  if (row.state !== "live") return `${name}: ${row.short}`;
  const at = clockAt(row.resetsAt, nowMs);
  const pct = `${Math.floor(row.pct)}%`;
  const when = spent(row) ? `out until ${at}` : `resets ${at} (in ${formatCountdownShort(row.resetsAt, nowMs)})`;
  return `${name} ${pct} · ${when}`;
}

/** The chip's hover lines: its name, every window, the reading's age and the route. */
function detailLines(chip, nowMs) {
  const age = Number.isFinite(chip.ageMs) ? formatAgeShort(chip.ageMs) : null;
  const lines = [chip.name, ...chip.windows.map((r) => {
    const hidden = chip.hidden.includes(r);
    return hidden ? `${windowLabel(r.window)}: hidden until the week resets` : windowLine(r, nowMs);
  })];
  lines.push(age === null ? "read at an unknown time" : age === "now" ? "read just now" : `read ${age} ago`);
  if (chip.route) lines.push(`Route: the fleet's next pick (${windowLabel(chip.route.window)})`);
  return lines;
}

/**
 * One chip per account, in route order (agy, Copilot, API credit, Claude),
 * then by name so chips never trade places between readings. `rows` is
 * toRows' output; `placeholders` adds a labelled chip for each engine in it
 * that has no reading yet (Copilot until #323).
 */
export function toChips(rows, nowMs = Date.now(), placeholders = ["copilot"]) {
  const byAccount = new Map();
  for (const row of Array.isArray(rows) ? rows : []) {
    if (!byAccount.has(row.account)) byAccount.set(row.account, []);
    byAccount.get(row.account).push(row);
  }

  const chips = [];
  for (const [account, windows] of byAccount) {
    const first = windows[0];
    const harness = first.harness ?? "claude";
    const { lead, out, hidden } = leadOf(windows);
    const ageMs = nowMs - first.observedAt * 1000;
    const chip = {
      key: account,
      account,
      harness,
      name: chipName(harness, first.accountLabel),
      mark: markOf(harness, first.accountLabel),
      windows,
      lead,
      out,
      hidden,
      // The pips: the lead first, then the other windows still shown.
      pips: [lead, ...windows.filter((r) => r !== lead && !hidden.includes(r))],
      value: out ? "out" : `${Math.floor(lead.pct ?? 0)}%`,
      when: cellWhen(lead, nowMs),
      route: windows.find((r) => r.isBestRoute) ?? null,
      ageMs,
      stale: Number.isFinite(ageMs) ? ageMs > STALE_AFTER_MS : true,
      observedAt: first.observedAt,
      placeholder: false,
    };
    chip.age = chip.stale && Number.isFinite(ageMs) ? `${formatAgeShort(ageMs)} old` : null;
    chip.detail = detailLines(chip, nowMs);
    chip.spoken = chip.detail.join(". ");
    chips.push(chip);
  }

  for (const harness of placeholders) {
    if (chips.some((c) => c.harness === harness)) continue;
    const name = chipName(harness, null);
    chips.push({
      key: `${harness}:placeholder`, account: null, harness, name, mark: markOf(harness, null),
      windows: [], pips: [], hidden: [], lead: null, out: false, value: "–", when: "no reading yet",
      route: null, ageMs: Number.NaN, stale: false, age: null, observedAt: Number.NaN, placeholder: true,
      detail: [name, "No reading yet"], spoken: `${name}: no reading yet`,
    });
  }

  const rank = (h) => {
    const i = CHIP_ORDER.indexOf(h);
    return i < 0 ? CHIP_ORDER.length : i;
  };
  return chips.sort(
    (a, b) => rank(a.harness) - rank(b.harness) || a.name.localeCompare(b.name) || String(a.key).localeCompare(String(b.key)),
  );
}

/**
 * The chip the tray icon and the window title mirror: the account read most
 * recently, the one in use now (as toRows' first row was before chips).
 */
export function primaryChip(chips) {
  const live = chips.filter((c) => !c.placeholder && Number.isFinite(c.observedAt));
  return live.reduce((a, b) => (b.observedAt > a.observedAt ? b : a), live[0] ?? null);
}

/**
 * Which chip a session's portrait docks beside: its account's, else the
 * first chip of its engine (agy and Copilot sessions name no account), else
 * none, and it sits after the last chip.
 */
export function dockKey(session, chips) {
  const id = session?.account?.id;
  if (id) {
    const own = chips.find((c) => c.account === id);
    if (own) return own.key;
  }
  const engine = String(session?.engine ?? "").trim().toLowerCase();
  if (engine && engine !== "claude") {
    const same = chips.find((c) => c.harness === engine);
    if (same) return same.key;
  }
  return null;
}
