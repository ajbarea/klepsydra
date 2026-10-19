// Where fleet messages come from: the app's fleet_subscribe channel, or in a
// browser a dev-fleet.json snapshot (serve src/ and add ?focus=<id> to focus).
// `onMessage` gets `{sessions}` snapshots and `{focus: id}` requests.
export const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);

export function subscribe(onMessage) {
  if (inTauri) {
    const { Channel, invoke } = window.__TAURI__.core;
    const channel = new Channel();
    channel.onmessage = onMessage;
    invoke("fleet_subscribe", { onMessage: channel }).catch(() => {});
    return;
  }
  fetch("./dev-fleet.json", { cache: "no-store" })
    .then((res) => (res.ok ? res.json() : null))
    .then((snapshot) => {
      if (!snapshot) return;
      onMessage(snapshot);
      const focus = new URLSearchParams(location.search).get("focus");
      if (focus) onMessage({ focus });
    })
    .catch(() => {});
}
