// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus),
// or with ?demo a sample fleet, its times moved up to now (serve the repo root
// and open /src/wall.html?demo: the sample sits outside the bundled src/);
// ?demo=8 shows its first eight sessions.
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
      if (Array.isArray(rest.sessions)) rest.sessions = rest.sessions.slice(0, demoCount(location.search));
      const current = typeof at === "number" ? shifted(rest, Math.floor(Date.now() / 1000) - at) : snapshot;
      onMessage(current);
      replaySpeaking(current, onMessage);
      const focus = new URLSearchParams(location.search).get("focus");
      if (focus) onMessage({ focus });
    })
    .catch(() => {});
}
