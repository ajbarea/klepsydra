// + New session: split button, engine menu, and sensible default (#440).
// Variant A: split button names the default engine with its logo; the caret
// opens a menu listing the other engines (never the default again), with logo,
// account, quota room from existing gauge readings, models, recommended badge,
// and "Set as default".

import { HARNESS_ORDER, HARNESS_LABELS, toRows, formatCountdown } from "../gauge.js";

export const DEFAULT_ENGINE_KEY = "klepsydra.default_engine";
export const LAST_ENGINE_KEY = "klepsydra.last_engine";

export const CHEV_ICON =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>';

export const STAR_ICON =
  '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="m12 2 3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>';

/**
 * Format a timestamp into clock time or weekday + time.
 */
export function formatResetTime(sec, nowMs = Date.now()) {
  if (!Number.isFinite(sec) || sec <= 0) return "";
  const d = new Date(sec * 1000);
  const now = new Date(nowMs);
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  const timeStr = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  if (sameDay) return timeStr;
  const dayStr = d.toLocaleDateString([], { weekday: "short" });
  return `${dayStr} ${timeStr}`;
}

/**
 * Decide the default engine:
 * 1. The user's choice (if installed and signed in),
 * 2. else the last engine used (if installed and signed in),
 * 3. else the first installed and signed-in engine.
 *
 * @param {Object} opts
 * @param {string|null} [opts.userChoice]
 * @param {string|null} [opts.lastEngineUsed]
 * @param {Array<Object>} opts.engines - List of engine entries
 * @returns {{ id: string, reason: string }}
 */
export function pickDefaultEngine({ userChoice, lastEngineUsed, engines }) {
  const isAvailable = (id) => {
    const e = engines.find((eng) => eng.id === id);
    return e && e.installed !== false && e.signedIn !== false;
  };

  if (userChoice && isAvailable(userChoice)) {
    return { id: userChoice, reason: "your chosen default" };
  }

  if (lastEngineUsed && isAvailable(lastEngineUsed)) {
    return { id: lastEngineUsed, reason: "the engine you used last" };
  }

  const firstAvailable = engines.find((e) => e.installed !== false && e.signedIn !== false);
  if (firstAvailable) {
    return { id: firstAvailable.id, reason: "the first installed and signed-in engine" };
  }

  return { id: engines[0]?.id || "claude", reason: "first available engine" };
}

/**
 * Find the last engine used from active/past sessions.
 * @param {Array<Object>} sessions
 * @param {string|null} [defaultLast=null]
 * @returns {string|null}
 */
export function extractLastEngineUsed(sessions, defaultLast = null) {
  if (!Array.isArray(sessions) || sessions.length === 0) return defaultLast;
  // Sort sessions newest first by status_at, active_at, or prompt.at
  const sorted = [...sessions].sort((a, b) => {
    const atA = a.status_at || a.active_at || a.prompt?.at || 0;
    const atB = b.status_at || b.active_at || b.prompt?.at || 0;
    return atB - atA;
  });

  for (const s of sorted) {
    const eng = s.engine ? s.engine.trim().toLowerCase() : (s.session_id ? "claude" : null);
    if (eng) return eng;
  }
  return defaultLast;
}

/**
 * Calculate quota room display for an engine/account.
 * @param {Object} account
 * @param {number} nowMs
 * @returns {{ bold: string, detail: string, spent: boolean }}
 */
export function computeAccountRoom(account, nowMs = Date.now()) {
  const ws = account?.windows || {};
  const week = ws.seven_day;
  const session = ws.five_hour;
  const aiCredits = ws.ai_credits;

  if (week && Number.isFinite(week.used_percentage) && week.used_percentage >= 100) {
    const at = formatResetTime(week.resets_at, nowMs);
    return {
      bold: "out",
      detail: at ? `until ${at}` : "week spent",
      spent: true,
    };
  }

  if (session && Number.isFinite(session.used_percentage)) {
    const remaining = Math.max(0, Math.round(100 - session.used_percentage));
    const at = formatResetTime(session.resets_at, nowMs);
    const detail = at ? `session · back to full ${at}` : "session";
    return {
      bold: `${remaining}%`,
      detail,
      spent: remaining <= 0,
    };
  }

  if (week && Number.isFinite(week.used_percentage)) {
    const remaining = Math.max(0, Math.round(100 - week.used_percentage));
    const at = formatResetTime(week.resets_at, nowMs);
    const detail = at ? `week · resets ${at}` : "week";
    return {
      bold: `${remaining}%`,
      detail,
      spent: remaining <= 0,
    };
  }

  if (aiCredits && Number.isFinite(aiCredits.used_percentage)) {
    const remaining = Math.max(0, Math.round(100 - aiCredits.used_percentage));
    return {
      bold: `${remaining}%`,
      detail: "credits",
      spent: remaining <= 0,
    };
  }

  return {
    bold: "–",
    detail: "no reading yet",
    spent: false,
  };
}

/**
 * Group Antigravity models into Gemini and Claude & GPT groups with quota details.
 *
 * @param {Array<Object>} models - Model list from `agy_models`
 * @param {Object|null} agyUsage - Usage reading object for agy
 * @param {number} nowMs
 * @returns {Array<Object>} Array of model groups
 */
export function groupAgyModels(models, agyUsage, nowMs = Date.now()) {
  if (!Array.isArray(models) || models.length === 0) return [];

  const ws = agyUsage?.windows || {};
  const session = ws.five_hour;
  const week = ws.seven_day;
  const claudeGpt = ws.claude_gpt;

  // Gemini quota summary
  let geminiRoomStr = "Gemini";
  if (session && Number.isFinite(session.used_percentage)) {
    const sRem = Math.max(0, Math.round(100 - session.used_percentage));
    if (week && Number.isFinite(week.used_percentage)) {
      const wRem = Math.max(0, Math.round(100 - week.used_percentage));
      geminiRoomStr = `Gemini · ${sRem}% of the session, ${wRem}% of the week`;
    } else {
      geminiRoomStr = `Gemini · ${sRem}% of the session`;
    }
  }

  const geminiModels = [];
  const otherModels = [];

  for (const m of models) {
    const isGemini = m.id.toLowerCase().startsWith("gemini");
    if (isGemini) {
      geminiModels.push({
        id: m.id,
        label: m.label,
        disabled: false,
        why: "",
      });
    } else {
      otherModels.push(m);
    }
  }

  const groups = [];

  if (geminiModels.length > 0) {
    groups.push({
      key: "gemini",
      label: geminiRoomStr,
      models: geminiModels,
    });
  }

  // Claude & GPT models: only shown if the plan has such a group (#440)
  if (otherModels.length > 0 && claudeGpt) {
    const isSpent = claudeGpt.used_percentage >= 100;
    const at = formatResetTime(claudeGpt.resets_at, nowMs);
    let label = "Claude & GPT";
    if (isSpent) {
      label = `Claude & GPT · spent${at ? `, back ${at}` : ""} · leaving agy today`;
    } else {
      const rem = Math.max(0, Math.round(100 - claudeGpt.used_percentage));
      label = `Claude & GPT · ${rem}% remaining`;
    }

    groups.push({
      key: "claude_gpt",
      label,
      models: otherModels.map((m) => ({
        id: m.id,
        label: m.label,
        disabled: isSpent,
        why: isSpent ? "spent" : "",
      })),
    });
  }

  return groups;
}

/**
 * Build the full list of available engines with their accounts, room, models,
 * recommended status, and install/sign-in status.
 *
 * @param {Object} opts
 * @param {Array<Object>|Object|null} opts.usage - Snapshot usage readings
 * @param {Array<Object>} [opts.agyModels=[]]
 * @param {Object} [opts.installedStatus={}] - Map of harness -> { installed, signedIn }
 * @param {number} [opts.nowMs=Date.now()]
 * @returns {Array<Object>}
 */
export function buildEngineEntries({
  usage = null,
  agyModels = [],
  installedStatus = {},
  nowMs = Date.now(),
} = {}) {
  const rows = toRows(usage, nowMs);
  const byHarness = new Map();
  for (const r of rows) {
    const h = r.harness || "claude";
    if (!byHarness.has(h)) byHarness.set(h, []);
    byHarness.get(h).push(r);
  }

  const usageList = (Array.isArray(usage) ? usage : Object.values(usage ?? {})).filter(
    (p) => p && typeof p === "object",
  );

  const entries = [];

  // 1. Claude entries (can be multiple accounts e.g. RIT, Personal)
  const claudeAccounts = usageList.filter(
    (p) => !p.account?.startsWith?.("agy") && !p.account?.startsWith?.("copilot") && p.harness !== "agy" && p.harness !== "copilot",
  );

  const claudeStatus = installedStatus.claude ?? { installed: true, signedIn: true };

  if (claudeAccounts.length > 0) {
    for (const acct of claudeAccounts) {
      const isRit = String(acct.label || "").toUpperCase().includes("RIT") || String(acct.account || "").includes("96130a18");
      const mono = isRit ? "RIT" : (acct.mono || null);
      const name = acct.label ? (acct.label === "Claude" ? "Claude" : `Claude on ${acct.label}`) : "Claude";
      const room = computeAccountRoom(acct, nowMs);
      const isRecommended = (byHarness.get("claude") ?? []).some((r) => r.account === acct.account && r.isBestRoute);

      entries.push({
        id: `claude:${acct.account || acct.label}`,
        engineId: "claude",
        harness: "claude",
        shortName: "Claude",
        name,
        mono,
        accountLabel: acct.label ? `${acct.label} account` : "Personal account",
        icon: "claude",
        room,
        isRecommended,
        installed: claudeStatus.installed !== false,
        signedIn: claudeStatus.signedIn !== false,
        models: [],
      });
    }
  } else {
    // Single Claude fallback
    entries.push({
      id: "claude",
      engineId: "claude",
      harness: "claude",
      shortName: "Claude",
      name: "Claude",
      mono: null,
      accountLabel: "Default account",
      icon: "claude",
      room: { bold: "–", detail: "no reading yet", spent: false },
      isRecommended: (byHarness.get("claude") ?? []).some((r) => r.isBestRoute),
      installed: claudeStatus.installed !== false,
      signedIn: claudeStatus.signedIn !== false,
      models: [],
    });
  }

  // 2. Antigravity entry
  const agyAccount = usageList.find((p) => p.account?.startsWith?.("agy") || p.harness === "agy");
  const agyStatus = installedStatus.agy ?? {
    installed: agyModels.length > 0,
    signedIn: agyModels.length > 0,
  };
  const agyRoom = computeAccountRoom(agyAccount, nowMs);
  const agyGroups = groupAgyModels(agyModels, agyAccount, nowMs);
  const agyRecommended = (byHarness.get("agy") ?? []).some((r) => r.isBestRoute);

  entries.push({
    id: "agy",
    engineId: "agy",
    harness: "agy",
    shortName: "Antigravity",
    name: "Antigravity",
    mono: null,
    accountLabel: agyAccount?.label || "Google AI Pro",
    icon: "agy",
    room: agyRoom,
    isRecommended: agyRecommended,
    installed: agyStatus.installed !== false,
    signedIn: agyStatus.signedIn !== false,
    modelGroups: agyGroups,
    models: agyModels,
  });

  // 3. Copilot entry
  const copilotAccount = usageList.find((p) => p.account?.startsWith?.("copilot") || p.harness === "copilot");
  const copilotStatus = installedStatus.copilot ?? {
    installed: false,
    signedIn: false,
  };
  const copilotRoom = computeAccountRoom(copilotAccount, nowMs);
  const copilotRecommended = (byHarness.get("copilot") ?? []).some((r) => r.isBestRoute);

  entries.push({
    id: "copilot",
    engineId: "copilot",
    harness: "copilot",
    shortName: "Copilot",
    name: "Copilot",
    mono: null,
    accountLabel: copilotAccount?.label || "GitHub · one pool of AI credits",
    icon: "copilot",
    room: copilotRoom,
    isRecommended: copilotRecommended,
    installed: copilotStatus.installed !== false,
    signedIn: copilotStatus.signedIn !== false,
    models: [],
  });

  return entries;
}

/**
 * Filter and prepare the engine menu list:
 * - Default engine is omitted ("never the default again")
 * - Missing engines are disabled with "Sign in" or "Not installed"
 *
 * @param {Array<Object>} entries
 * @param {string} defaultEngineId
 * @returns {Array<Object>}
 */
export function buildMenuList(entries, defaultEngineId) {
  return entries
    .filter((e) => e.id !== defaultEngineId && e.engineId !== defaultEngineId)
    .map((e) => {
      const isMissing = !e.installed || !e.signedIn;
      const missingReason = !e.installed ? "Not installed on this PC" : (!e.signedIn ? "Installed, not signed in" : null);
      const missingAction = !e.installed ? "How to install" : (!e.signedIn ? "Sign in" : null);

      return {
        ...e,
        disabled: isMissing,
        missingReason,
        missingAction,
      };
    });
}
