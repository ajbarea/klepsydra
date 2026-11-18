// Settings page mockups (#384). Every setting from the tray menu and the
// gear popover gets one home here (#384 inventory, 11-17), plus the new
// ones from #421, #438, #440, #444, #448 and the sisters editor (11-18).
// Values shown are today's: tray screenshot 11-17 (Compact on, Ping off,
// Start with Windows on, Phone wall on); gauge opacity is style.css's 82%,
// shown at its nearest 5% step.

(() => {
  const I = (n, cls = "ico") => `<span class="${cls}">${window.ICON[n]}</span>`;
  const toggle = (on, label) =>
    `<button class="tog" role="switch" aria-checked="${on}" aria-label="${label}"><i></i></button>`;
  const seg = (opts, on, label) =>
    `<span class="seg" role="radiogroup" aria-label="${label}">${opts.map((o) => `<button role="radio" aria-checked="${o === on}">${o}</button>`).join("")}</span>`;
  const select = (v, label) => `<button class="sel" aria-haspopup="listbox" aria-label="${label}">${v}${I("chev")}</button>`;
  const btn = (t, cls = "") => `<button class="${cls}">${t}</button>`;

  const row = (label, desc, control, extra = "") =>
    `<div class="row ${extra}"><div class="rl"><span class="lab">${label}</span>${desc ? `<span class="desc">${desc}</span>` : ""}</div><div class="rc">${control}</div></div>`;

  const slider = (v) =>
    `<span class="slider"><input type="range" min="0" max="100" step="5" value="${v}" aria-label="Gauge background opacity"><output>${v}%</output></span>`;

  const faces = ["hephaestus", "athena", "hermes", "chronos"];
  const facePick = `<span class="faces-pick" role="radiogroup" aria-label="Default orchestrator">${faces
    .map((f, i) => `<button role="radio" aria-checked="${i === 0}" title="${f[0].toUpperCase() + f.slice(1)}"><img src="../../../src/fleet/faces/kourai/${f}-96.webp" alt=""><span>${f[0].toUpperCase() + f.slice(1)}</span></button>`)
    .join("")}<button class="more" aria-label="All characters">+12</button></span>`;

  const accountIcons = [
    ["claude", "", "Claude · Personal", "Claude mark (built in)"],
    ["", "RIT", "Claude · RIT", "RIT logo from <code>icons/rit.png</code> in the settings folder; repo fallback is “RIT”"],
    ["agy", "", "Google AI Pro", "Antigravity mark (built in)"],
    ["copilot", "", "Copilot", "Copilot mark (built in)"],
  ];
  const acctRows = accountIcons
    .map(([i, m, n, d]) => `<div class="acct">${i ? I(i) : `<span class="mono">${m}</span>`}<span class="an">${n}</span><span class="ad">${d}</span>${btn("Choose icon…", "small")}</div>`)
    .join("");

  // Engines (#384, AJ 11-18): one switch per harness; all three binaries are on this PC.
  const engineRow = (icon, mono, name, desc, on) =>
    row(`${icon ? I(icon) : `<span class="mono">${mono}</span>`} ${name}`, desc, toggle(on, `${name} on`), "eng-row");
  const order = ["agy · Gemini", "Copilot", "API credit", "Claude subscription"];
  const orderList = `<ol class="order" aria-label="Route order">${order.map((o) => `<li><span class="handle" aria-hidden="true">${window.ICON.grip}</span>${o}</li>`).join("")}</ol>`;

  // ~/.claude/techne.toml, read 11-18 1:20 PM (not modified). Comments stay in the file.
  const SISTERS = [
    ["phalanx-fl", "active", "solo"], ["sphragis", "active", "solo"], ["velocity-fl", "backburner", "solo"],
    ["kourai-khryseai", "backburner", "solo"], ["ajbarea.github.io", "active", "solo"], ["techne", "active", "solo"],
    ["ldqis", "active", "team"], ["periplus", "active", "solo"], ["ariadne", "active", "solo"],
    ["papers", "active", "solo"], ["pharos", "active", "solo"], ["klepsydra", "active", "solo"],
    ["csci739-qfl-privacy", "active", "solo"], ["askesis", "active", "solo"], ["keryx", "active", "solo"],
    ["talks", "active", "solo"],
  ];
  const active = SISTERS.filter((s) => s[1] === "active").length;
  const sisters = `
<div class="sis">
  <div class="sis-head">
    <span>${SISTERS.length} projects · ${active} active · ${SISTERS.length - active} on the backburner</span>
    <span class="ok">${I("check")}every project has a clone in ~/ajsoftworks</span>
  </div>
  <div class="sis-table" role="table" aria-label="Sisters">
    <div class="sis-row th" role="row"><span role="columnheader">Project</span><span role="columnheader">Status</span><span role="columnheader">Kind</span><span></span></div>
    ${SISTERS.map(([n, st, k]) => `<div class="sis-row${st === "backburner" ? " bb" : ""}" role="row"><span class="sn" role="cell">${n}</span><span role="cell">${seg(["active", "backburner"], st, `${n} status`)}</span><span role="cell">${seg(["solo", "team"], k, `${n} kind`)}</span><span role="cell"><button class="icon-btn" aria-label="Remove ${n}">${I("trash")}</button></span></div>`).join("")}
  </div>
  <div class="sis-add">${select("Add a project…", "Add a project from the repos the fleet has opened")}<span class="desc">Lists the repos the fleet has opened sessions in that are not here yet.</span></div>
  <p class="desc file">${I("folder")}Saved to <code>~/.claude/techne.toml</code>, keeping its comments and order. <code>/techne:sisters</code> reads it on its next run.</p>
</div>`;

  const SECTIONS = [
    {
      id: "appearance", icon: "palette", title: "Appearance",
      rows: [
        row("Show gauge strip", "Hidden, it stops sampling too. The tray menu or Ctrl+Alt+G (proposed) brings it back; the wall and the phone keep their own usage view.", toggle(true, "Show gauge strip")),
        row("Card density", "How much each session card shows on the wall.", seg(["Auto", "Comfortable", "Compact"], "Compact", "Card density")),
        row("Gauge layout", "Linear fits a taskbar; double suits a screen corner; stacked shows every window.", seg(["Linear", "Double", "Stacked"], "Linear", "Gauge layout")),
        row("Gauge background opacity", "Below 60% (50% in the light theme) the text gets a dark halo so it reads over the wallpaper.", slider(80)),
        row("Text-only gauge", "Logo, value and reset only: no rings or bars (#438).", toggle(false, "Text-only gauge")),
        row("Light or dark", "The wall and the gauge follow Windows unless you pick one.", select("Match Windows", "Light or dark")),
      ],
    },
    {
      id: "characters", icon: "person", title: "Characters",
      rows: [
        row("Character set", "The faces and colours sessions wear.", select("Kourai", "Character set")),
        row("Default orchestrator", "The face and voice of the session that runs the fleet.", facePick, "tall"),
      ],
    },
    {
      id: "voices", icon: "speaker", title: "Voices and sounds",
      rows: [
        row("Voices", "Who speaks when a session finishes a turn.", seg(["Off", "Orchestrator only", "Everyone"], "Everyone", "Voices")),
        row("Ping", "Two short notes when a session needs you. For when voices are off.", toggle(false, "Ping")),
      ],
    },
    {
      id: "engines", icon: "plug", title: "Engines",
      lead: "Off hides an engine from + New session and the gauge, and routing skips it. Sessions already running keep going. At least one stays on.",
      rows: [
        engineRow("claude", "", "Claude", "Installed · 2 accounts (Personal, RIT)", true),
        engineRow("agy", "", "Antigravity", "Installed · Google AI Pro", true),
        engineRow("copilot", "", "Copilot", "Installed · GitHub", true),
        `<div class="row eng-missing" aria-label="State example"><div class="rl"><span class="lab">${I("copilot")} Copilot <span class="ex">state example</span></span><span class="desc">On a PC without it: <code>copilot</code> not found. Install it with <code>npm install -g @github/copilot</code>, then reopen Settings.</span></div><div class="rc"><span class="unavail">Unavailable</span></div></div>`,
        row("New session starts", "The engine behind the main button.", select("Last used (Claude on RIT)", "New session default")),
        row("Route order", "Free first: the gauge marks the first engine here with room. Engines that are off are skipped.", orderList, "tall"),
        row("Antigravity Remote Control", "Connect each new agy session to Remote Control when it starts.", toggle(false, "Antigravity Remote Control")),
      ],
    },
    {
      id: "accounts", icon: "person", title: "Accounts",
      rows: [
        row("Account icons", "Each account's mark on the gauge and the wall. A local file stays on this PC.", `<div class="accts">${acctRows}</div>`, "tall stack"),
      ],
    },
    {
      id: "sisters", icon: "branch", title: "Sisters",
      lead: "The projects <code>/techne:sisters</code> audits for drift.",
      rows: [`<div class="row stack full">${sisters}</div>`],
    },
    {
      id: "files", icon: "file", title: "Fleet files",
      rows: [
        row("Queue file", "<code>fleet-briefing/queue.md</code>", btn("Choose…", "small")),
        row("Needs you file", "<code>fleet-briefing/needs-you.md</code>", btn("Choose…", "small")),
      ],
    },
    {
      id: "system", icon: "monitor", title: "System",
      rows: [
        row("Start with Windows", "Open the gauge when you sign in to Windows.", toggle(true, "Start with Windows")),
        row("Phone wall", "Serve the wall to your phone over Tailscale.", toggle(true, "Phone wall")),
        row("System chip on the gauge", "WSL memory, CPU, and GPU load with VRAM, sampled once a second while shown.", toggle(false, "System chip on the gauge")),
        row("System chip shows", "A tap on the chip switches too.", seg(["Percent", "GB"], "Percent", "System chip shows")),
        row("Agent RAM and CPU on cards", "Each card shows its session's process tree: memory and CPU.", toggle(false, "Agent RAM and CPU on cards")),
        row("Gauge position", "Put the gauge back where it started, or make where it is now its home.", `${btn("Reset position", "small")} ${btn("Set home here", "small")}`),
      ],
    },
  ];

  window.SETTINGS = { SECTIONS, I };
})();
