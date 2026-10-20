// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus),
// or with ?demo a sample fleet, its times moved up to now.
// `onMessage` gets `{sessions}` snapshots and `{focus: id}` requests.
import { follow } from "../ipc.js";

export const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

/** The browser's snapshot file; none inside the app. */
export function devSnapshotUrl(app, search) {
  if (app) return null;
  return new URLSearchParams(search).has("demo") ? "./fleet/demo.json" : "./dev-fleet.json";
}

// The sample's times are as of its `at`; shift them so its ages read as written.
const TIMES = new Set(["status_at", "updated_at", "quiet_since", "at"]);
function shifted(value, by) {
  if (Array.isArray(value)) return value.map((v) => shifted(v, by));
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value).map(([k, v]) => [k, TIMES.has(k) && typeof v === "number" ? v + by : shifted(v, by)]),
  );
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
      onMessage(typeof at === "number" ? shifted(rest, Math.floor(Date.now() / 1000) - at) : snapshot);
      const focus = new URLSearchParams(location.search).get("focus");
      if (focus) onMessage({ focus });
    })
    .catch(() => {});
}
