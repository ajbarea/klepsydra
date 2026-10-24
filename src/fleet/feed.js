// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus),
// or with ?demo a sample fleet, its times moved up to now (serve the repo root
// and open /src/wall.html?demo: the sample sits outside the bundled src/);
// ?demo=8 shows its first eight sessions, ?demo&empty none and ?demo&ended the
// ended ones.
// `onMessage` gets `{sessions, speaking}` snapshots and `{focus: id}` requests.
// In a browser a snapshot's speaking line replays, a sentence at a time.
import { follow } from "../ipc.js";
import { RATE } from "./speaking.js";

export const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

/** The browser's snapshot file; none inside the app. */
export function devSnapshotUrl(app, search) {
  if (app) return null;
  return new URLSearchParams(search).has("demo") ? "../scripts/fixtures/fleet-demo.json" : "./dev-fleet.json";
}

/** The browser's ledger sample, only with ?demo and never inside the app. */
export function demoLedgerUrl(app, search) {
  return !app && new URLSearchParams(search).has("demo") ? "../scripts/fixtures/ledger-demo.json" : null;
}

// The sample's times are as of its `at`; shift them so its ages read as written.
const TIMES = new Set(["status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at"]);
function shifted(value, by) {
  if (Array.isArray(value)) return value.map((v) => shifted(v, by));
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value).map(([k, v]) => [k, TIMES.has(k) && typeof v === "number" ? v + by : shifted(v, by)]),
  );
}

// The gap between replayed sentences: under the wall's hold, so they read as one line.
const REPLAY_GAP_MS = 400;

/** Play the snapshot's line again each time it ends, as keryx's next sentence would. */
function replaySpeaking(snapshot, onMessage) {
  const line = snapshot?.speaking;
  if (!Array.isArray(line?.envelope) || line.envelope.length === 0) return;
  const every = (line.envelope.length / RATE) * 1000 + REPLAY_GAP_MS;
  setInterval(() => onMessage({ ...snapshot, speaking: { ...line, started_at: Date.now() / 1000 } }), every);
}

/** How many demo sessions ?demo=N asks for; all of them for a bare ?demo or anything not a positive count. */
export function demoCount(search) {
  const n = Number(new URLSearchParams(search).get("demo"));
  return Number.isInteger(n) && n > 0 ? n : Infinity;
}

/** The demo's sessions: none with ?demo&empty, the ended ones with ?demo&ended, else the first ?demo=N. */
export function demoSessions(sessions, search) {
  const q = new URLSearchParams(search);
  if (q.has("empty")) return [];
  if (q.has("ended")) return sessions.filter((s) => s.status === "ended");
  return sessions.slice(0, demoCount(search));
}

export function subscribe(onMessage) {
  if (inTauri) {
    follow("fleet_subscribe", onMessage).catch(() => {});
    return;
  }
  fetch(devSnapshotUrl(inTauri, location.search), { cache: "no-store" })
    .then((res) => (res.ok ? res.json() : null))
    .then((snapshot) => {
      if (!snapshot) return;
      const { at, ...rest } = snapshot;
      if (Array.isArray(rest.sessions)) rest.sessions = demoSessions(rest.sessions, location.search);
      const current = typeof at === "number" ? shifted(rest, Math.floor(Date.now() / 1000) - at) : snapshot;
      onMessage(current);
      replaySpeaking(current, onMessage);
      const focus = new URLSearchParams(location.search).get("focus");
      if (focus) onMessage({ focus });
    })
    .catch(() => {});
}

const EMPTY_TODAY = { day: { sessions: {}, attribution: {} }, receiver: null, guardrails: [], guardrails_total: 0 };

/**
 * Today's ledger for the drawer, filtered to `session` when given: the app's
 * ledger_today command, or in a browser the ?demo sample (its times moved up
 * to now, its guardrails filtered as the command filters them), else an empty day.
 */
export async function todayLedger(session = null) {
  if (inTauri) return window.__TAURI__.core.invoke("ledger_today", { session });
  const url = demoLedgerUrl(inTauri, location.search);
  if (!url) return EMPTY_TODAY;
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) return EMPTY_TODAY;
  const { at, ...rest } = await res.json();
  const view = typeof at === "number" ? shifted(rest, Math.floor(Date.now() / 1000) - at) : rest;
  const guardrails = view.guardrails.filter((g) => session === null || g.session_id === session);
  return { ...view, guardrails, guardrails_total: guardrails.length };
}
