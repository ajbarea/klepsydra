// Settings registry for klepsydra (#384).
// Rows are data, not markup: PR 1 lists the 13 settings that exist on main today.
// Later PRs (e.g. #421, #438) add rows by adding an entry here.

export const SECTIONS = [
  { id: "appearance", title: "Appearance" },
  { id: "gauges", title: "Gauges" },
  { id: "characters", title: "Characters" },
  { id: "voices", title: "Voices and sounds" },
  { id: "engines", title: "Engines" },
  { id: "files", title: "Fleet files" },
  { id: "system", title: "System" },
];

export const ROWS = [
  {
    id: "split_terminal",
    section: "appearance",
    label: "Split with terminal",
    description: "The wall on the left half of this screen, the fleet terminal on the right.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_split_mode"),
    write: (invoke, on) => invoke("set_split_mode", { on: Boolean(on) }),
  },
  {
    id: "card_density",
    section: "appearance",
    label: "Card density",
    description: "Wall session card spacing and size.",
    control: {
      type: "seg",
      options: [
        { value: "auto", label: "Auto" },
        { value: "comfortable", label: "Comfortable" },
        { value: "compact", label: "Compact" },
      ],
    },
    read: (invoke) => invoke("get_wall_density"),
    write: (invoke, density) => invoke("set_wall_density", { density: String(density) }),
  },
  {
    id: "compact",
    section: "gauges",
    label: "Compact layout",
    description: "A single compact strip designed to fit inside the taskbar, or full cards.",
    control: { type: "toggle" },
    read: async (invoke) => {
      const mode = await invoke("get_layout");
      return mode === "compact";
    },
    write: (invoke, compact) => invoke("set_layout_mode", { compact: Boolean(compact) }),
  },
  {
    id: "reset_position",
    section: "gauges",
    label: "Reset strip position",
    description: "Return the floating gauge strip to its default screen position.",
    control: { type: "button", label: "Reset position" },
    read: null,
    write: (invoke) => invoke("reset_gauge_position"),
  },
  {
    id: "set_home",
    section: "gauges",
    label: "Set home here",
    description: "Remember the floating strip's current position as its home.",
    control: { type: "button", label: "Set home here" },
    read: null,
    write: (invoke) => invoke("set_gauge_home"),
  },
  {
    id: "character_theme",
    section: "characters",
    label: "Character set",
    description: "Card faces, names, and session accent colors.",
    control: {
      type: "select",
      options: [
        { value: "kourai", label: "Kourai" },
        { value: "professions", label: "Professions" },
        { value: "dicebear", label: "DiceBear" },
      ],
    },
    read: (invoke) => invoke("get_theme"),
    write: (invoke, theme) => invoke("set_theme", { theme: String(theme) }),
  },
  {
    id: "voices_mode",
    section: "voices",
    label: "Voices",
    description: "Who speaks through Keryx when a session finishes a turn.",
    control: {
      type: "seg",
      options: [
        { value: "off", label: "Off" },
        { value: "heph", label: "Orchestrator only" },
        { value: "everyone", label: "Everyone" },
      ],
    },
    read: (invoke) => invoke("get_voices_mode"),
    write: (invoke, mode) => invoke("set_voices_mode", { mode: String(mode) }),
  },
  {
    id: "ping",
    section: "voices",
    label: "Ping",
    description: "Two short audio notes when a session needs you. Useful when voices are off.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_ping"),
    write: (invoke, on) => invoke("set_ping", { on: Boolean(on) }),
  },
  {
    id: "new_session_default",
    section: "engines",
    label: "New session starts",
    description: "The default engine behind the primary + New session button.",
    control: {
      type: "select",
      options: [
        { value: "", label: "Last used" },
        { value: "claude:default", label: "Claude" },
        { value: "agy", label: "Antigravity" },
        { value: "copilot", label: "Copilot" },
      ],
    },
    read: async (invoke) => {
      const prefs = await invoke("new_session_prefs");
      return prefs?.default || "";
    },
    write: (invoke, id) => invoke("set_new_session_default", { id: id ? String(id) : null }),
  },
  {
    id: "queue_file",
    section: "files",
    label: "Queue file",
    description: "Task backlog markdown file watched for new tasks.",
    control: { type: "path", buttonLabel: "Choose…" },
    read: async (invoke) => {
      const files = await invoke("get_fleet_files");
      return files?.queue || "";
    },
    write: (invoke) => invoke("choose_queue_file"),
  },
  {
    id: "needs_file",
    section: "files",
    label: "Needs you file",
    description: "File listing sessions awaiting human decisions.",
    control: { type: "path", buttonLabel: "Choose…" },
    read: async (invoke) => {
      const files = await invoke("get_fleet_files");
      return files?.needs || "";
    },
    write: (invoke) => invoke("choose_needs_file"),
  },
  {
    id: "autostart",
    section: "system",
    label: "Start with Windows",
    description: "Open klepsydra automatically on user login.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_autostart"),
    write: (invoke, enabled) => invoke("set_autostart", { enabled: Boolean(enabled) }),
  },
  {
    id: "phone_wall",
    section: "system",
    label: "Phone wall",
    description: "Serve the wall over Tailscale for phone viewing.",
    control: { type: "toggle" },
    read: (invoke) => invoke("get_phone_wall"),
    write: (invoke, on) => invoke("set_phone_wall", { on: Boolean(on) }),
  },
];

/**
 * Filter registry rows by matching query against label and description.
 * Empty query returns all rows. Case-insensitive.
 */
export function filterRows(rows, query) {
  if (!query || typeof query !== "string") return rows;
  const q = query.trim().toLowerCase();
  if (!q) return rows;
  return rows.filter((r) => {
    const text = `${r.label || ""} ${r.description || ""}`.toLowerCase();
    return text.includes(q);
  });
}
