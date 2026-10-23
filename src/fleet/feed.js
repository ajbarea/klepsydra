// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus),
// or with ?demo a sample fleet, its times moved up to now (serve the repo root
// and open /src/wall.html?demo: the sample sits outside the bundled src/);
// ?demo=8 shows its first eight sessions, and ?demo&wrapup adds a sample
// wrap-up request and answers.
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

/** The browser's wrap-up sample, only with ?demo&wrapup and never inside the app. */
export function demoWrapupUrl(app, search) {
  const q = new URLSearchParams(search);
  return !app && q.has("demo") && q.has("wrapup") ? "../scripts/fixtures/wrapup-demo.json" : null;
}

/** `snapshot` with the wrap-up sample's request and each session's answer. */
export function withWrapup(snapshot, sample) {
  if (!sample?.request || !Array.isArray(snapshot?.sessions)) return snapshot;
  const answers = sample.answers ?? {};
  return {
    ...snapshot,
    wrapup: sample.request,
    sessions: snapshot.sessions.map((s) => (answers[s.session_id] ? { ...s, wrapup: answers[s.session_id] } : s)),
  };
}

const sample = (url) =>
  url ? fetch(url, { cache: "no-store" }).then((res) => (res.ok ? res.json() : null)).catch(() => null) : Promise.resolve(null);

// The sample's times are as of its `at`; shift them so its ages read as written.
const TIMES = new Set(["status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at", "until"]);
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

export function subscribe(onMessage) {
  if (inTauri) {
    follow("fleet_subscribe", onMessage).catch(() => {});
    return;
  }
  Promise.all([
    fetch(devSnapshotUrl(inTauri, location.search), { cache: "no-store" }).then((res) => (res.ok ? res.json() : null)),
    sample(demoWrapupUrl(inTauri, location.search)),
  ])
    .then(([fleet, wrap]) => {
      if (!fleet) return;
      const now = Math.floor(Date.now() / 1000);
      const moved = (x) => {
        const { at, ...rest } = x;
        return typeof at === "number" ? shifted(rest, now - at) : x;
      };
      const snapshot = moved(fleet);
      if (Array.isArray(snapshot.sessions)) snapshot.sessions = snapshot.sessions.slice(0, demoCount(location.search));
      const current = withWrapup(snapshot, wrap && moved(wrap));
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
