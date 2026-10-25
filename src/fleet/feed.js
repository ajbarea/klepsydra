// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus),
// or with ?demo a sample fleet, its times moved up to now (serve the repo root
// and open /src/wall.html?demo: the sample sits outside the bundled src/);
// ?demo=8 shows its first eight sessions, ?demo&empty none and ?demo&ended the
// ended ones, and ?demo&wrapup adds a sample wrap-up request and answers.
// `onMessage` gets `{sessions, speaking}` snapshots and `{focus: id}` requests.
// In a browser a snapshot's speaking line replays, a sentence at a time.
import { follow } from "../ipc.js";
import { RATE } from "./speaking.js";

export const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

/**
 * Where this page's fleet comes from: "app" inside klepsydra; "served" from
 * the phone wall server, the one place the wall loads at a root path (the
 * server sends its /wall.html there; a dev server's root is the gauge or a
 * listing); "demo" with ?demo; else "dev", a dev snapshot beside the page.
 */
export function feedKind(app, search, pathname) {
  if (app) return "app";
  if (new URLSearchParams(search).has("demo")) return "demo";
  return pathname === "/" ? "served" : "dev";
}

/** True on the phone: the page came from the phone wall server. */
export const served = feedKind(inTauri, globalThis.location?.search ?? "", globalThis.location?.pathname ?? "") === "served";

/** The first wait before a closed stream is opened again, and the longest. */
export const RETRY_MS = [1000, 30000];

// EventSource.CLOSED: the browser gave the stream up and will not reconnect it.
const CLOSED = 2;

/**
 * Follow the phone wall server's event stream: each event a snapshot. The
 * browser reconnects a stream that drops, but gives one up for good on any
 * answer but a 200 event stream (a 503 at the stream cap, Serve's 502 while
 * klepsydra restarts); that one is opened again after a wait that starts at
 * 1 s and doubles to 30 s, back to 1 s once a stream opens. `onLink` hears
 * whether the stream is up, so the page can say when what it shows may be old.
 */
export function followServed(onMessage, onLink = () => {}, Source = globalThis.EventSource, later = (fn, ms) => setTimeout(fn, ms)) {
  let wait = RETRY_MS[0];
  const open = () => {
    const source = new Source("/events");
    source.onopen = () => {
      wait = RETRY_MS[0];
      onLink(true);
    };
    source.onerror = () => {
      onLink(false);
      if (source.readyState !== CLOSED) return;
      source.onerror = null;
      source.close();
      later(open, wait);
      wait = Math.min(wait * 2, RETRY_MS[1]);
    };
    source.onmessage = (e) => {
      let snapshot;
      try {
        snapshot = JSON.parse(e.data);
      } catch {
        return;
      }
      if (Array.isArray(snapshot?.sessions)) {
        onLink(true);
        onMessage(snapshot);
      }
    };
    return source;
  };
  return open();
}

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
const TIMES = new Set(["status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at", "until", "settled_at", "turn_at"]);
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

/** A dev or demo snapshot as the wall gets it: filtered by ?demo=N, ?empty or ?ended, its times moved up to `nowS` when it has an `at`. */
export function demoSnapshot(snapshot, search, nowS) {
  const { at, ...rest } = snapshot;
  if (Array.isArray(rest.sessions)) rest.sessions = demoSessions(rest.sessions, search);
  return typeof at === "number" ? shifted(rest, nowS - at) : rest;
}

export function subscribe(onMessage, onLink) {
  if (inTauri) {
    follow("fleet_subscribe", onMessage).catch(() => {});
    return;
  }
  if (served) {
    followServed(onMessage, onLink);
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
      const current = withWrapup(demoSnapshot(fleet, location.search, now), wrap && moved(wrap));
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
