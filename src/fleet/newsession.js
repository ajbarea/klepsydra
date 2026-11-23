// + New session (#440, Variant A): what the split button starts and what its
// menu lists, from the gauge's own rows (toRows over read_usage), the
// launcher's engine list and agy's models. Pure: wall.js draws it.

import { HARNESS_ORDER } from "../gauge.js";

/** Claude Code's model aliases (`claude --model`), latest of each. */
export const CLAUDE_MODELS = [
  { id: "opus", label: "Opus" },
  { id: "sonnet", label: "Sonnet" },
  { id: "fable", label: "Fable" },
];

/**
 * agy's quota groups (the launcher's `models`, from agy's /quota) and the
 * windows the statusLine hook files each under: gemini-5h and gemini-weekly
 * as five_hour and seven_day, 3p-5h as claude_gpt.
 */
export const AGY_GROUPS = {
  gemini: { label: "Gemini", windows: ["five_hour", "seven_day"] },
  "3p": { label: "Claude & GPT", windows: ["claude_gpt"] },
};

const WINDOW_WORDS = { five_hour: "session", seven_day: "week", claude_gpt: "session", spend_limit: "spend", ai_credits: "credits" };

/** The one step that makes a missing engine usable, shown in its row. */
export const FIX_STEPS = {
  claude: { signin: "claude, then /login" },
  agy: { install: "curl -fsSL https://antigravity.google/cli/install.sh | bash", signin: "agy, then sign in with Google" },
  copilot: { install: "npm install -g @github/copilot", signin: "copilot login" },
};

/** A short name for an account from its label: "RIT-CS-DQL" gives "RIT". */
export function accountBadge(label) {
  const first = String(label ?? "").split(/[^A-Za-z0-9]+/).find(Boolean) ?? "";
  return first.slice(0, 10);
}

/** "3:15 PM" today, else "Mon 1:00 PM"; "" without a time. */
export function clockAt(sec, nowMs = Date.now()) {
  if (!Number.isFinite(sec) || sec <= 0) return "";
  const d = new Date(sec * 1000);
  const now = new Date(nowMs);
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return d.toDateString() === now.toDateString() ? time : `${d.toLocaleDateString([], { weekday: "short" })} ${time}`;
}

/** Room left in a row, a whole percent. */
const roomOf = (row) => Math.max(0, Math.floor(100 - row.pct));

/** The live rows of a window list: an ended window (state reset) binds nothing. */
const live = (rows) => rows.filter((r) => r.state === "live" && Number.isFinite(r.pct));

/**
 * What a set of rows leaves: the window with the least room binds (the week
 * when it is lower than the session), spent when any is at 100%.
 * `{ pct, word, back, spent }` or null with no live row.
 */
export function limitingRoom(rows, nowMs = Date.now()) {
  const ls = live(rows);
  if (ls.length === 0) return null;
  const spentRows = ls.filter((r) => r.pct >= 100);
  if (spentRows.length) {
    const at = Math.max(...spentRows.map((r) => r.resetsAt).filter(Number.isFinite));
    return { pct: 0, word: WINDOW_WORDS[spentRows[0].window] ?? spentRows[0].window, back: clockAt(at, nowMs), spent: true };
  }
  const bind = ls.reduce((a, b) => (roomOf(b) < roomOf(a) || (roomOf(b) === roomOf(a) && b.resetsAt > a.resetsAt) ? b : a));
  return { pct: roomOf(bind), word: WINDOW_WORDS[bind.window] ?? bind.window, back: clockAt(bind.resetsAt, nowMs), spent: false };
}

/** A room as the menu's row says it: { bold, detail }. */
export function roomWords(room) {
  if (!room) return { bold: "–", detail: "no reading yet" };
  if (room.spent) return { bold: "out", detail: room.back ? `until ${room.back}` : `${room.word} spent` };
  const when = room.word === "session" ? "back to full" : "resets";
  return { bold: `${room.pct}%`, detail: room.back ? `${room.word} · ${when} ${room.back}` : room.word };
}

/** agy's models in their quota groups, Gemini first, each group's room from its windows' rows. */
export function agyGroups(models, agyRows, nowMs = Date.now()) {
  const keys = [...Object.keys(AGY_GROUPS), ""];
  const groups = [];
  for (const key of keys) {
    const ms = models.filter((m) => (AGY_GROUPS[key] ? m.group === key : !AGY_GROUPS[m.group]));
    if (ms.length === 0) continue;
    const def = AGY_GROUPS[key];
    const rows = def ? agyRows.filter((r) => def.windows.includes(r.window)) : [];
    const room = def ? limitingRoom(rows, nowMs) : null;
    let label = def?.label ?? "Other models";
    if (room?.spent) label += ` · spent${room.back ? `, back ${room.back}` : ""}`;
    else if (def) {
      const parts = live(rows).map((r) => `${roomOf(r)}% of the ${WINDOW_WORDS[r.window] ?? r.window}`);
      if (parts.length) label += ` · ${parts.join(", ")}`;
    }
    groups.push({
      key: key || "other",
      label,
      spent: Boolean(room?.spent),
      models: ms.map((m) => ({ id: m.id, label: m.label, disabled: Boolean(room?.spent), why: room?.spent ? "spent" : "" })),
    });
  }
  return groups;
}

/**
 * Every engine + New session can start, one entry per Claude account.
 *
 * `rows`: toRows over read_usage. `engines`: the launcher's list
 * ({ claude: [account ids], agy, copilot }) or null before it answers;
 * `enginesError` why it did not.
 * `agy`: { state: "ok" | "missing" | "signedout" | "error" | "waiting",
 * models, error }.
 */
export function buildEntries({ rows = [], engines = null, enginesError = null, agy = { state: "waiting", models: [] }, nowMs = Date.now() } = {}) {
  const byHarness = (h) => rows.filter((r) => r.harness === h);
  const entries = [];

  // Claude: an account per reading, and any login with no reading yet.
  const claudeRows = byHarness("claude");
  const accounts = new Map();
  for (const r of claudeRows) if (!accounts.has(r.account)) accounts.set(r.account, r.accountLabel ?? "Claude");
  for (const id of engines?.claude ?? []) if (!accounts.has(id)) accounts.set(id, "Claude");
  const multi = accounts.size > 1;
  // By label, then id: the gauge lists the account used last first, which would move the default.
  const sorted = [...accounts].sort(([a, la], [b, lb]) => la.localeCompare(lb) || a.localeCompare(b));
  for (const [account, label] of sorted) {
    const mine = claudeRows.filter((r) => r.account === account);
    const badge = multi ? accountBadge(label) : "";
    const signedIn = engines === null || engines.claude.includes(account);
    entries.push({
      id: `claude:${account}`,
      engine: "claude",
      account,
      shortName: "Claude",
      name: badge ? `Claude on ${badge}` : "Claude",
      badge,
      accountLabel: `${label} account`,
      room: limitingRoom(mine, nowMs),
      recommended: mine.some((r) => r.isBestRoute),
      installed: true,
      signedIn,
      models: CLAUDE_MODELS.map((m) => ({ ...m, disabled: false, why: "" })),
      groups: null,
    });
  }
  if (accounts.size === 0) {
    entries.push({
      id: "claude", engine: "claude", account: null, shortName: "Claude", name: "Claude", badge: "",
      accountLabel: "Claude Code's own account", room: null, recommended: false, installed: true, signedIn: true,
      models: CLAUDE_MODELS.map((m) => ({ ...m, disabled: false, why: "" })), groups: null,
    });
  }

  // Antigravity: one Google account; its models in quota groups.
  const agyRows = byHarness("agy");
  const groups = agy.state === "ok" ? agyGroups(agy.models ?? [], agyRows, nowMs) : [];
  const gemini = agyRows.filter((r) => AGY_GROUPS.gemini.windows.includes(r.window));
  entries.push({
    id: "agy",
    engine: "agy",
    account: null,
    shortName: "Antigravity",
    name: "Antigravity",
    badge: "",
    accountLabel: agyRows[0]?.accountLabel ?? "Google AI Pro",
    room: limitingRoom(gemini.length ? gemini : agyRows, nowMs),
    recommended: agyRows.some((r) => r.isBestRoute),
    installed: engines ? engines.agy : agy.state !== "missing",
    signedIn: agy.state !== "signedout",
    failed: agy.state === "error" ? agy.error || "Antigravity did not list its models." : null,
    waiting: agy.state === "waiting",
    models: groups.flatMap((g) => g.models),
    groups,
  });

  // Copilot: one GitHub account, one pool of AI credits.
  const copilotRows = byHarness("copilot");
  entries.push({
    id: "copilot",
    engine: "copilot",
    account: null,
    shortName: "Copilot",
    name: "Copilot",
    badge: "",
    accountLabel: "GitHub · one pool of AI credits",
    room: limitingRoom(copilotRows, nowMs),
    recommended: copilotRows.some((r) => r.isBestRoute),
    // Unknown until the launcher's list answers: never "not installed" on a failed ask.
    installed: engines ? engines.copilot : true,
    signedIn: true,
    failed: engines ? null : enginesError,
    waiting: !engines && !enginesError,
    models: [],
    groups: null,
  });

  for (const e of entries) {
    e.usable = e.installed && e.signedIn && !e.failed && !e.waiting;
    e.fix = !e.installed ? "install" : !e.signedIn ? "signin" : e.failed ? "retry" : null;
    e.spent = Boolean(e.room?.spent); // listed with when it returns; Start is off and the launch refuses it
    e.recommended &&= e.usable; // the route the gauge picks, only where a session can start
  }
  return entries;
}

const ORDER = (e) => HARNESS_ORDER.indexOf(e.engine);

/**
 * The default: the user's choice, else the engine last started from the
 * wall, else the first usable one in the gauge's engine order. A saved id
 * that names nothing usable now is passed over.
 */
export function pickDefault(entries, { userDefault = null, lastUsed = null } = {}) {
  const usable = (id) => entries.find((e) => e.id === id && e.usable);
  const chosen = usable(userDefault);
  if (chosen) return { entry: chosen, reason: "your choice" };
  const last = usable(lastUsed);
  if (last) return { entry: last, reason: "the engine you used last" };
  const first = [...entries].sort((a, b) => ORDER(a) - ORDER(b)).find((e) => e.usable);
  if (first) return { entry: first, reason: "the first engine set up here" };
  return { entry: entries[0], reason: "the only engine klepsydra knows" };
}

/** The menu: every entry but the default, the free-first Recommended one first, then the gauge's engine order. */
export function menuEntries(entries, defaultId) {
  return entries
    .filter((e) => e.id !== defaultId)
    .sort((a, b) => Number(b.recommended) - Number(a.recommended) || ORDER(a) - ORDER(b));
}

/** launch_session's arguments for an entry and its picked model; null is plain `claude`. */
export function launchArgs(entry, model = null) {
  if (entry.engine === "claude") {
    if (!entry.account) return null;
    return model ? { engine: "claude", account: entry.account, model } : { engine: "claude", account: entry.account };
  }
  if (entry.engine === "agy") return { engine: "agy", model };
  return model ? { engine: "copilot", model } : { engine: "copilot" };
}

/** The first model an entry would start on: agy's first usable, Gemini first; Claude and Copilot their own default. */
export function firstModel(entry) {
  if (entry.engine !== "agy") return null;
  return entry.models.find((m) => !m.disabled)?.id ?? null;
}

/** The split button's tooltip: the engine and its room. */
export function buttonTitle(entry) {
  const w = roomWords(entry.room);
  if (!entry.room) return `Start a ${entry.name} session`;
  return entry.room.spent ? `${entry.name}: out ${w.detail}` : `${entry.name}: ${entry.room.pct}% of the ${entry.room.word} left`;
}
