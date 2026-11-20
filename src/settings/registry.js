// The settings page's rows (#384). Rows are data, not markup: a later PR adds
// a setting by adding a row here.
//
// A row either talks to the app itself (`read`, `write`, both through
// `invoke`) or is bound to a control the wall already has (`bind`: the
// toolbar's Split, the gear's density and Characters pickers, + New
// session's default). A bound row has no commands of its own: the wall hands
// the page the same function its own control calls (settings.js `apply`), so
// the two can never drift.
//
// What a row shows comes from what its command returned, through `view`
// (default: the value as it is): { value, label?, disabled?, note?,
// options? }. A read that fails hides the row; the app refuses the commands
// of a setting this system lacks (Ping and Split off Windows).

export const SECTIONS = [
  { id: "appearance", title: "Appearance" },
  { id: "gauges", title: "Gauges" },
  { id: "characters", title: "Characters" },
  { id: "voices", title: "Voices and sounds" },
  { id: "engines", title: "Engines" },
  { id: "files", title: "Fleet files" },
  { id: "system", title: "System" },
];

/** The mode ids and labels of src-tauri/fleet/src/voices.rs VOICES, in its order. */
export const VOICE_MODES = [
  { value: "heph", label: "Heph only" },
  { value: "everyone", label: "Everyone" },
  { value: "off", label: "Off" },
];

export const ROWS = [
  {
    id: "split_terminal",
    section: "appearance",
    label: "Split with terminal",
    description: "The wall on the left half of this screen, the fleet terminal on the right.",
    control: { type: "toggle" },
    bind: "split",
  },
  {
    id: "card_density",
    section: "appearance",
    label: "Card density",
    description: "How much room each session card takes on the wall.",
    control: {
      type: "seg",
      options: [
        { value: "auto", label: "Auto" },
        { value: "comfortable", label: "Comfortable" },
        { value: "compact", label: "Compact" },
      ],
    },
    bind: "density",
  },
  {
    id: "compact",
    section: "gauges",
    label: "Compact layout",
    description: "The gauge as one slim strip that fits the taskbar, or as full cards.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_layout"),
    write: (invoke, compact) => invoke("set_layout_mode", { compact: Boolean(compact) }),
  },
  {
    id: "reset_position",
    section: "gauges",
    label: "Reset strip position",
    description: "Put the gauge strip back in its default place on the screen.",
    control: { type: "button", label: "Reset position" },
    write: (invoke) => invoke("reset_gauge_position"),
  },
  {
    id: "set_home",
    section: "gauges",
    label: "Set home here",
    description: "Remember where the gauge strip is now as its home.",
    control: { type: "button", label: "Set home here" },
    write: (invoke) => invoke("set_gauge_home"),
  },
  {
    id: "character_theme",
    section: "characters",
    label: "Character set",
    description: "Card faces, names, and each session's accent colour.",
    control: { type: "select" },
    bind: "theme",
  },
  {
    id: "voices_mode",
    section: "voices",
    label: "Voices",
    description: "Who speaks through keryx when a session finishes a turn.",
    control: { type: "seg", options: VOICE_MODES },
    read: (invoke) => invoke("get_voices_mode"),
    write: (invoke, mode) => invoke("set_voices_mode", { mode: String(mode) }),
    // keryx's live state: no mode selected when none matches it, and why.
    view: (shown) => ({ value: shown?.tick ?? null, note: shown?.says ?? "" }),
  },
  {
    id: "ping",
    section: "voices",
    label: "Ping",
    description: "Two short notes when a session needs you. Useful while voices are off.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_ping"),
    write: (invoke, on) => invoke("set_ping", { on: Boolean(on) }),
  },
  {
    id: "new_session_default",
    section: "engines",
    label: "New session starts",
    description: "The engine behind the + New session button.",
    control: { type: "select" },
    bind: "newSession",
  },
  {
    id: "queue_file",
    section: "files",
    label: "Queue file",
    description: "The markdown file the Queue panel shows.",
    control: { type: "path", buttonLabel: "Choose…" },
    read: (invoke) => invoke("get_fleet_files"),
    write: (invoke) => invoke("choose_queue_file"),
    view: (files) => ({ value: files?.queue ?? "" }),
  },
  {
    id: "needs_file",
    section: "files",
    label: "Needs you file",
    description: "The markdown file the Needs you panel shows.",
    control: { type: "path", buttonLabel: "Choose…" },
    read: (invoke) => invoke("get_fleet_files"),
    write: (invoke) => invoke("choose_needs_file"),
    view: (files) => ({ value: files?.needs ?? "" }),
  },
  {
    id: "autostart",
    section: "system",
    label: "Start at login",
    description: "Open klepsydra when you sign in.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_autostart"),
    write: (invoke, enabled) => invoke("set_autostart", { enabled: Boolean(enabled) }),
    // The app names the row for its system and says when it is held as it is.
    view: (a) => ({
      value: Boolean(a?.on),
      label: a?.label,
      disabled: Boolean(a?.held),
      note: a?.held ? "Held as it is: KLEPSYDRA_NO_AUTOSTART is set." : "",
    }),
  },
  {
    id: "phone_wall",
    section: "system",
    label: "Phone wall",
    description: "Serve the wall on this PC for Tailscale Serve, to read on a phone.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_phone_wall"),
    write: (invoke, on) => invoke("set_phone_wall", { on: Boolean(on) }),
  },
];

/**
 * The rows whose label (as shown now, from `labels` by row id) or
 * description holds `query`, ignoring case; all of them for an empty query.
 */
export function filterRows(rows, query, labels = new Map()) {
  const q = typeof query === "string" ? query.trim().toLowerCase() : "";
  if (!q) return rows;
  return rows.filter((r) => `${labels.get(r.id) ?? r.label} ${r.description}`.toLowerCase().includes(q));
}
