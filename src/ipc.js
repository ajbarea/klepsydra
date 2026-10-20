// The app's push channels: `command` is handed a Channel and sends each
// message on it, starting with the latest.
export function follow(command, onMessage) {
  const { Channel, invoke } = window.__TAURI__.core;
  const channel = new Channel();
  channel.onmessage = onMessage;
  return invoke(command, { onMessage: channel });
}
