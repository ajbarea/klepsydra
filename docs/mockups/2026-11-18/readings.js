// The readings every mockup shows: klepsydra's newest reading per account,
// taken Wed 18 Nov 2026 at 1:23 PM EST from
// the app data folder (accounts/<id>/*.json).
// Percentages are the readings' used_percentage, rounded; reset times are
// their resets_at in local time; "in" is resets_at minus 1:23 PM.
// klepsydra rewrites a session's file in place, so the files on disk move on;
// SOURCE freezes what each one held when it was read (accounts/<id>/<session>.json).
window.SOURCE = {
  personal: { account: "6f5fe38b", session: "d1561ead", written_at: 1795026200, five_hour: [9, 1795036800], seven_day: [45, 1795456800] },
  rit: { account: "96130a18", session: "b02de147", written_at: 1795026210, five_hour: [2, 1795044000], seven_day: [0, 1795629600] },
  agy: { account: "agy-primary", session: "0e65e748", written_at: 1795023195, five_hour: [7.2, 1795032916], seven_day: [4.06, 1795619716], claude_gpt: [100, 1795033968] },
};
// Copilot has no reading yet (#323); its chip is a labelled placeholder.
// Order is the route order (gauge.js ROUTE_ORDER): agy, Copilot, API credit
// (no reading on this PC), Claude subscription.

(() => {
  const theme = new URLSearchParams(location.search).get("theme");
  document.documentElement.dataset.theme =
    theme || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
})();

window.SNAP = {
  takenAt: "Wed 18 Nov, 1:23 PM EST",
  accounts: [
    {
      id: "agy",
      icon: "agy",
      name: "Google AI Pro",
      engine: "agy",
      ageMin: 50, // its reading was written at 12:33 PM
      windows: [
        { key: "five_hour", label: "Gemini session", short: "5h", pct: 7, in: "1h 52m", at: "3:15 PM" },
        { key: "seven_day", label: "Gemini week", short: "wk", pct: 4, in: "6d 20h", at: "Wed Nov 25, 10:15 AM" },
        {
          key: "claude_gpt", label: "Claude & GPT", short: "c/g", pct: 100, in: "2h 9m", at: "3:32 PM", group: true,
          note: "Antigravity removes these models on Nov 18 (antigravity.google/docs/models)",
        },
      ],
      route: { window: "five_hour", says: "Gemini" },
    },
    { id: "copilot", icon: "copilot", name: "Copilot", engine: "copilot", placeholder: true },
    {
      id: "personal",
      icon: "claude",
      name: "Claude · Personal",
      engine: "claude",
      ageMin: 0,
      faces: ["hephaestus"], // Heph runs on Personal (fleet accounts, 11-18)
      windows: [
        { key: "five_hour", label: "Session", short: "5h", pct: 9, in: "2h 57m", at: "4:20 PM" },
        { key: "seven_day", label: "Week", short: "wk", pct: 45, in: "4d 23h", at: "Mon Nov 23, 1:00 PM" },
      ],
    },
    {
      id: "rit",
      mono: "RIT", // the repo's fallback; AJ's local icon file shows the real logo
      name: "Claude · RIT",
      engine: "claude",
      ageMin: 0,
      faces: ["worker"],
      windows: [
        { key: "five_hour", label: "Session", short: "5h", pct: 2, in: "4h 57m", at: "6:20 PM" },
        { key: "seven_day", label: "Week", short: "wk", pct: 0, in: "6d 23h", at: "Wed Nov 25, 1:00 PM" },
      ],
    },
  ],

  // Past readings, for the state examples only (each says where it is from).
  states: {
    // AJ's phone screenshot, 11-18 3:48 AM: RIT week 100%, session 0% (#421 comment).
    ritOut: {
      id: "rit-out", mono: "RIT", name: "Claude · RIT", engine: "claude", ageMin: 0,
      windows: [
        { key: "five_hour", label: "Session", short: "5h", pct: 0, in: "", at: "" },
        { key: "seven_day", label: "Week", short: "wk", pct: 100, in: "9h 12m", at: "1:00 PM" },
      ],
    },
    // AJ's 11-17 comfortable screenshot: "Google AI Pro · week 95% · updated
    // 10 hr ago" was as red as a live reading (#421 evidence).
    agyStale: {
      id: "agy-stale", icon: "agy", name: "Google AI Pro", engine: "agy", ageMin: 10 * 60,
      windows: [
        { key: "five_hour", label: "Gemini session", short: "5h", pct: 0, in: "", at: "" },
        { key: "seven_day", label: "Gemini week", short: "wk", pct: 95, in: "3d 12h", at: "" },
      ],
    },
  },
};

// Status from the gauge's band thresholds (style.css: --ramp-mid-at 60, --ramp-high-at 85).
window.band = (pct) => (pct >= 85 ? "high" : pct >= 60 ? "mid" : "low");

// What a chip leads with (#421): a weekly window at 100% hides the session and
// reads "out until <reset>"; a spent model group (agy claude/gpt) stays a pip
// and never decides the chip; otherwise the window with the least room.
window.lead = (acct) => {
  const ws = acct.windows || [];
  const week = ws.find((w) => w.key === "seven_day");
  if (week && week.pct >= 100) return { out: true, w: week, rest: [] };
  const pool = ws.filter((w) => !w.group);
  const w = pool.reduce((a, b) => (b.pct > a.pct ? b : a), pool[0]);
  return { out: false, w, rest: ws.filter((x) => x !== w) };
};

window.ageText = (min) => (min >= 120 ? `${Math.round(min / 60)}h old` : min >= 30 ? `${min}m old` : "");
window.staleAt = 180; // minutes: past this a reading dims and its chip shows its age; younger ages show only in stacked and hover

window.iconHTML = (acct) =>
  acct.mono ? `<span class="mono" aria-hidden="true">${acct.mono}</span>` : `<span class="ico">${window.ICON[acct.icon]}</span>`;

window.FACE = (who) =>
  who === "worker"
    ? `<span class="face-dot" title="1 agent" aria-hidden="true"></span>`
    : `<img class="face" src="../../../src/fleet/faces/kourai/${who}-96.webp" alt="" title="${who[0].toUpperCase() + who.slice(1)}">`;

// System snapshot, Wed 18 Nov 4:00 PM EST (#421, AJ 11-18): /proc/meminfo
// (MemTotal 10186852 kB, MemAvailable 3981872 kB), the fleet slice's cgroup
// (memory.current 5496434688, memory.max 8820621312), /proc/stat over 1 s
// (276 of 612 jiffies busy), nvidia-smi (RTX 3060 Ti, 12 %, 6179 of 8192 MiB).
// GB here are GiB, as Windows Task Manager shows them. No FPS (AJ 11-18).
window.SYS = {
  takenAt: "Wed 18 Nov, 4:00 PM EST",
  ram: { used: 5.9, total: 9.7, pct: 61, label: "WSL memory" },
  fleet: { used: 5.1, cap: 8.2, capMb: 8412, pct: 62, label: "fleet slice" }, // capMb: 8820621312 B / 2^20
  cpu: { pct: 45, cores: 6 },
  gpu: { name: "RTX 3060 Ti", pct: 12 },
  vram: { used: 6.0, total: 8.0, pct: 75 },
};

// Each session's process tree from its pid (/proc/<pid>/stat RSS and CPU
// ticks over 1 s, 4:00 PM). Names are the fleet's pane names. cpu is % of one
// core, as top shows it (the System chip's CPU is of all 6 cores). mb sums RSS,
// which counts shared pages once per process; a build should use PSS (smaps_rollup).
window.TREES = [
  { name: "Athena", role: "orchestrator", task: "Heph to Athena orchestrator handover", face: "athena", mb: 715, cpu: 3, procs: 32 },
  { name: "docsync-1118", task: "klepsydra docsync", mb: 909, cpu: 12, procs: 9 },
  { name: "design-pass", task: "klepsydra gauge strip mockups", mb: 603, cpu: 5, procs: 15 },
  { name: "phylax-378", task: "Phylax fail-closed hooks (techne #378)", mb: 567, cpu: 4, procs: 13 },
  { name: "linux-458", task: "klepsydra PR 458 Debian launch parity", mb: 498, cpu: 4, procs: 9 },
  { name: "fleet-done-445", task: "Fleet done report for klepsydra #445 and #446", mb: 470, cpu: 1, procs: 15 },
];
