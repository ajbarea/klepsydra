// The gauge strip's chips (#421, variant A): one per account and engine,
// built from toRows' rows so the readings and the route have one source.
// Pure: no DOM, no Tauri, so the floating strip, the wall header and the
// tests all share it.
import { ROUTE_ORDER, formatAgeShort, formatCountdownShort, routeGroup, routeLane, windowLabel } from "../gauge.js";

// Past this age a chip dims and names its age instead of looking live.
export const STALE_AFTER_MS = 3 * 60 * 60 * 1000;
// From this age a reading's age is written out where there is room: the
// stacked layout and the hover. The linear row names it only once stale.
export const AGE_TEXT_AFTER_MS = 30 * 60 * 1000;

/** "50m old", "2h old" from AGE_TEXT_AFTER_MS on, else null (also for an unknown age). */
export function ageText(ms) {
  return Number.isFinite(ms) && ms >= AGE_TEXT_AFTER_MS ? `${formatAgeShort(ms)} old` : null;
}

// A window's place in the fleet's free-first order (gauge.js ROUTE_ORDER, #411).
const laneRank = (row) => ROUTE_ORDER.indexOf(routeLane(row));
// An unknown reset time sorts last: such a window may not be back soon.
const resetOf = (row) => (Number.isFinite(row.resetsAt) ? row.resetsAt : Number.POSITIVE_INFINITY);
const tightest = (rows) => rows.reduce((a, b) => ((b.pct ?? 0) > (a.pct ?? 0) ? b : a));

/**
 * An account's windows in routing's groups (gauge.js routeGroup): the
 * windows that must all have room for one lane to run, such as a Claude
 * account's session and week, agy's Gemini session and week, or one API
 * pool. A group with a spent window (routing's isCapped) is closed until the
 * spent window that resets last comes back (`back`).
 */
function groupsOf(rows) {
  const byGroup = new Map();
  for (const r of rows) {
    const key = routeGroup(r);
    if (!byGroup.has(key)) byGroup.set(key, []);
    byGroup.get(key).push(r);
  }
  return [...byGroup.values()].map((group) => {
    const capped = group.filter((r) => r.isCapped);
    const back = capped.length ? capped.reduce((a, b) => (resetOf(b) > resetOf(a) ? b : a)) : null;
    return { rows: group, back, lead: back ?? tightest(group), rank: laneRank(group[0]) };
  });
}

const HARNESS_ICON = { claude: "claude", agy: "agy", copilot: "copilot", api: "anthropic" };
const HARNESS_NAME = { claude: "Claude", agy: "Antigravity", copilot: "Copilot", api: "API" };

// A Claude account's label that names no organisation: its own logo fits.
const PLAIN_CLAUDE = /^(personal|claude)$/i;

/**
 * An account's mark: its engine's logo, or for a Claude account that belongs
 * to an organisation, a short monogram of the organisation's name ("RIT"),
 * so it does not wear the same logo as the personal account. Two
 * organisations whose names start with the same word share a monogram; the
 * chip's name tells them apart. A real logo for such an account is a local
 * file (Settings, #421), never committed.
 */
export function markOf(harness, label) {
  const text = String(label ?? "").trim();
  if (harness === "claude" && text && !PLAIN_CLAUDE.test(text)) {
    const mono = text.split(/[\s\-_·/.]+/).find(Boolean)?.slice(0, 4).toUpperCase();
    if (mono) return { mono };
  }
  return { icon: HARNESS_ICON[harness] ?? "anthropic" };
}

/** The name a chip is read by: "Claude · Personal", "Google AI Pro". */
export function chipName(harness, label) {
  const text = String(label ?? "").trim();
  if (harness === "claude") return text && !/^claude$/i.test(text) ? `Claude · ${text}` : "Claude";
  return text || HARNESS_NAME[harness] || harness;
}

/**
 * A reset time on the clock: "3:32 PM" today, else with its day,
 * "Wed 10:15 AM". Null without a time.
 */
// Built once: a formatter per call costs ~30x the format itself, and the
// strip formats every window's reset on every redraw.
const TIME = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" });
const WEEKDAY = new Intl.DateTimeFormat("en-US", { weekday: "short" });
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

export function clockAt(sec, nowMs = Date.now()) {
  if (typeof sec !== "number") return null; // new Date(null * 1000) is 1970, not "no time"
  const at = new Date(sec * 1000);
  // Intl throws on a time past Date's range (a reset in microseconds, 1e13 s).
  if (!Number.isFinite(at.getTime())) return null;
  const time = TIME.format(at);
  if (sameDay(at, new Date(nowMs))) return time;
  return `${WEEKDAY.format(at)} ${time}`;
}

/** "until 3:32 PM", or "until it resets" when the reading names no reset time. */
const untilReset = (row, nowMs) => {
  const at = clockAt(row.resetsAt, nowMs);
  return at ? `until ${at}` : "until it resets";
};

/**
 * What a chip leads with, by routing's groups. While a group is open the
 * chip shows it: the route's group when it is on this chip, else the first
 * open group in route order, the one with most room first, led by its
 * tightest window. A spent pool or week closes only its own group. With
 * every group closed the chip reads "out" until the group back first.
 * `hidden`: the windows a closed group cannot use until it is back.
 */
export function leadOf(rows) {
  if (!rows.length) return { lead: null, out: false, hidden: [] };
  const groups = groupsOf(rows);
  const hidden = [...hiddenRows(rows)];
  const open = groups.filter((g) => !g.back).sort((a, b) => a.rank - b.rank || (a.lead.pct ?? 0) - (b.lead.pct ?? 0));
  if (open.length) {
    const route = open.find((g) => g.rows.some((r) => r.isBestRoute));
    return { lead: (route ?? open[0]).lead, out: false, hidden };
  }
  const first = groups.reduce((a, b) => (resetOf(b.back) < resetOf(a.back) ? b : a));
  return { lead: first.back, out: true, hidden };
}

/** A window's time in a stacked cell: the countdown, or what its reset says. */
export function cellWhen(row, nowMs = Date.now()) {
  if (row.state !== "live") return row.short;
  return row.isCapped ? untilReset(row, nowMs) : (formatCountdownShort(row.resetsAt, nowMs) ?? row.short);
}

/** How old a window's own number is (ms); NaN when its reading names no time. */
export const rowAge = (row, nowMs) => nowMs - (row.readAt ?? row.observedAt) * 1000;

/**
 * The rows a closed group hides (#421): its windows with room that reset
 * before the group is back, since they cannot be used until then, such as a
 * session under a spent week. Keyed to the window the group waits on.
 * Shared by the chips and the phone's limit rows, so both hide the same ones.
 */
function hiddenBy(rows) {
  const out = new Map();
  for (const g of groupsOf(rows)) {
    if (!g.back) continue;
    for (const r of g.rows) if (!r.isCapped && resetOf(r) < resetOf(g.back)) out.set(r, g.back);
  }
  return out;
}

/** The rows a closed group hides, as a Set (see hiddenBy). */
export function hiddenRows(rows) {
  return new Set(hiddenBy(rows).keys());
}

/**
 * One window as the hover reads it: "This week 45% · resets Mon 1:00 PM",
 * with its own age when it is older than the chip's lead ("· read 2d ago").
 */
function windowLine(row, chip, nowMs) {
  const name = windowLabel(row.window);
  if (row.state !== "live") return `${name}: ${row.short}`;
  const pct = `${Math.floor(row.pct)}%`;
  const at = clockAt(row.resetsAt, nowMs);
  const when = row.isCapped
    ? `out ${untilReset(row, nowMs)}`
    : at
      ? `resets ${at} (in ${formatCountdownShort(row.resetsAt, nowMs)})`
      : "resets at a time the reading does not give";
  const age = rowAge(row, nowMs);
  const own = row !== chip.lead && ageText(age) && !(age <= chip.ageMs) ? ` · read ${formatAgeShort(age)} ago` : "";
  return `${name} ${pct} · ${when}${own}`;
}

// What a hidden window waits for, as the hover says it.
const WAITS_ON = { seven_day: "the week", five_hour: "the session" };

/** The chip's hover lines: its name, every window, the lead reading's age and the route. */
function detailLines(chip, nowMs) {
  const age = Number.isFinite(chip.ageMs) ? formatAgeShort(chip.ageMs) : null;
  const waits = hiddenBy(chip.windows);
  const lines = [chip.name, ...chip.windows.map((r) => {
    const on = waits.get(r);
    return on ? `${windowLabel(r.window)}: hidden until ${WAITS_ON[on.window] ?? windowLabel(on.window)} resets` : windowLine(r, chip, nowMs);
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
    // The chip's number is its lead's, so its age is the lead's own reading.
    const ageMs = rowAge(lead, nowMs);
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
    // The linear row names the age once stale; stacked from AGE_TEXT_AFTER_MS.
    const named = Number.isFinite(ageMs) ? ageText(ageMs) : "age unknown";
    chip.age = chip.stale ? named : null;
    chip.ageText = named;
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
      route: null, ageMs: Number.NaN, stale: false, age: null, ageText: null, observedAt: Number.NaN, placeholder: true,
      detail: [name, "No reading yet"], spoken: `${name}: no reading yet`,
    });
  }

  // Route order by the chip's first lane; a placeholder ranks by its engine's.
  const rank = (c) => Math.min(...(c.windows.length ? c.windows : [{ harness: c.harness }]).map(laneRank));
  return chips.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name) || String(a.key).localeCompare(String(b.key)));
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
