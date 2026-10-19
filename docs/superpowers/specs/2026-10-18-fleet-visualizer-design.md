# Fleet visualizer: design

Date: 2026-10-18. Status: approved by AJ 2026-10-18; spike results added the same day.

## Goal

AJ runs about eight Claude Code sessions at once, each in its own WSL2 terminal
and worktree, on unrelated work. The visualizer shows all of them on one
screen: how many are running, which repo each is working in, which ones need
him and why, and what he last asked each one and what it last said.

It is for one developer first. A product version is a later decision (heuresis
verdict `later`, 2026-10-18).

It succeeds when one glance at the screen answers four questions: how many
sessions are up, where each one is working, who needs AJ and for what, and what
each was doing. While nothing changes, it must cost close to nothing.

## Constraints

- It never shows a confident wrong status. Every status carries its age.
- Nothing on the Windows side starts a process, and nothing crosses into WSL
  to ask for state. State arrives as files, as the usage gauge's readings do
  now. Jump to terminal uses Windows UI Automation, an in-process API.
- It adds one window at most beyond the gauge, and that window exists only
  after the first click.
- AJ keeps his workflow: ordinary Windows Terminal tabs, one `claude` each.
  Nothing has to be launched through klepsydra.
- keryx owns all audio. The visualizer makes no sound.

## Rejected ideas and their guards

Each idea below was considered and dropped. Each guard is written and passing
before any feature code exists.

| Idea | Why it was dropped | Guard |
| --- | --- | --- |
| Poll `claude agents --json` for state | Measured 2026-10-18 over three runs: 0.38 to 0.57 s wall, 82 to 86% of a core and about 170 MB peak RSS per call. Polling every few seconds would make the visualizer the heaviest process on the box. | A test fails if any fleet source (Rust or JS) contains a process spawn (`Command::new`, `std::process`, shell plugins). No exemptions. |
| Windows app calls `wsl.exe` for state | Every interop call opens new host channels, the cause of the 0x8007274c tab failures (microsoft/WSL #41901). | The same no-spawn test, plus a grep test for `wsl` in the fleet sources. |
| Identity per repo | A session that starts in one repo and works in others would change face mid-life. | A test replays a session that moves across three repos and asserts its identity is unchanged while its "where" follows. |
| Photo faces (randomuser.me, 100k-faces, thispersondoesnotexist) | randomuser.me's photos defer to UI Faces' terms; 100k-faces serves Generated Photos images, whose terms bar storing them as standalone files; thispersondoesnotexist cannot reproduce a face from a seed and publishes no terms. | CI fails if any file under `src/fleet/faces/` lacks an entry in `faces/LICENSES.json` naming its source and license. |
| Last reply read from the transcript | The hooks docs say the transcript is written asynchronously and may not hold the current turn. | The Stop handler reads only `last_assistant_message`; a fixture test with a transcript that lags proves it. |
| "Needs approval" from `Notification` `permission_prompt` | It fires about 6 s after the prompt appears, and only while the user is away from the terminal. | `PermissionRequest` sets the state; a fixture test asserts it does. |
| An empty session counted as needing AJ | `claude agents --json` reported a session with no first prompt as `blocked`. | A session with no prompt yet shows "not started"; fixture test. |
| A status that outlives its evidence ("working" forever, "ready for review" forever, always unread) | The most common complaint across Claude Code agent view (#101806, #101614), VS Code (#300191) and Cursor in the 2026-10-18 review sweep. | Every rendered status includes its age. A test feeds a session whose heartbeat stopped and asserts it shows "silent" with the age, never "working". |
| Dashboard memory growth | Cursor staff confirmed the Agents window grows to 5 to 8 GB in long sessions (forum thread 158856). | A scripted measurement of klepsydra's working set at 5 minutes and at 8 hours, recorded in the release checklist; the release is blocked if it grew more than 10%. |
| A second window for the strip | Microsoft's WebView2 performance guidance says to avoid redundant WebView2 instances, since each adds processes and memory. | The strip renders inside the gauge window; a config test asserts `tauri.conf.json` declares no extra always-on-top window. |
| Blinking attention cues (ParallelPilot blinks its yellow cue) | Conflicts with calm design and `prefers-reduced-motion`. | A style test fails on any infinite animation in fleet CSS; the one attention pulse is disabled under reduced motion. |
| The visualizer speaking | keryx already speaks in each terminal's voice; two speakers overlap. | A test fails if the fleet frontend uses audio or speech APIs. |
| A face that hints at status (expressions, health) | A face that changes with state would compete with the badge as a second, less exact status signal. | The portrait is chosen from identity only; a test asserts the same image for every state. |

## Architecture

Five units, each testable alone.

1. **Fleet hook** (`hooks/klepsydra-fleet.sh`, bash and jq, WSL side). Claude
   Code runs it on session events. It writes one JSON file per session.
2. **Heartbeat** (existing `statusline/klepsydra-statusline.sh`). On each
   render it writes the session's `session_name` (the custom name or the
   AI-generated title, which is also the terminal tab's title) to a per-session
   beat file, at most once per 10 s unless the name changed.
   `statusLine.refreshInterval: 30` makes it render at least every 30 s, idle
   or not.
3. **Fleet reader** (Rust, `src-tauri/src/fleet.rs`, Windows side). It watches
   the fleet directory, parses the files, and hands the webview a list of
   sessions.
4. **Face strip** (JS and CSS in the gauge window). A row of portraits beside
   the gauge, with a badge on each session that needs AJ.
5. **Card wall** (a second webview window, created on first click). One card
   per session.

Data flows one way: hook to file, file to reader, reader to webview.

### Fleet hook

Registered in `~/.claude/settings.json` with `async: true` on these events:

| Event | Effect |
| --- | --- |
| `SessionStart` | Creates the file: session id, display name, start time, launch directory, Claude Code pid and its start time. State `new`, shown as "not started". Prunes dead files (see Lifecycle). |
| `UserPromptSubmit` | State `working`. Stores the prompt (first 300 characters) and its time, except for a background subagent's report, whose text starts with `<task-notification>`: that sets `working` but keeps the last prompt. |
| `PermissionRequest` | State `needs_you`, reason `approve <tool_name>`. The hook prints nothing, so it never decides the permission. |
| `PreToolUse` on `AskUserQuestion` and `ExitPlanMode` | State `needs_you`, reason `question` or `approve plan`. |
| `Notification` `elicitation_dialog` | State `needs_you`, reason `question` (an MCP server's request for input). |
| `PostToolUse` | Clears `needs_you` back to `working`. For `Edit`, `Write` and `NotebookEdit` it also updates "where" from `tool_input.file_path`. |
| `Stop` | Stores `last_assistant_message` (first 300 characters) and its time. State `done`. |
| `StopFailure` | Stores the error text. State `error`. |
| `SessionEnd` | State `ended`, with the end reason. |

The hook writes only when a field changed, so a run of tool calls in one repo
costs reads, not writes. Each write goes to a temp file in the same directory,
then `mv` replaces the session file, as the statusline script already does.

It never records tool input beyond the tool name and an edited file's path.

**Where.** On every event the hook resolves the repo, worktree and branch from
the event's `cwd`, or from the edited file's path on `PostToolUse` for edits.
It reads `.git` directly, as keryx's `source_name` does, so it never runs
`git`. A worktree resolves to its main checkout's name, plus the worktree's own
name. The branch comes from the `HEAD` file. "Where now" is the repo of the
last edit, or of `cwd` when nothing was edited yet. "Touched" keeps the last
six other repos with their last times.

**Identity.** The hook finds the nearest `claude` ancestor process and its
start time from `/proc`, the key keryx uses for a terminal (`pid:starttime` in
`~/.cache/keryx/voices.json` under `holders`). It copies that holder's voice id
into the session file whenever it changes. keryx keeps a terminal's voice for
the terminal's life and picks the repo's usual voice first, so identity stays
with the session while "where" moves. Without keryx, or before keryx assigns a
voice, the voice is null.

### Session file

`<KLEPSYDRA_DIR>/fleet/<session_id>.json`:

```json
{
  "v": 1,
  "session_id": "cb9fa591-1514-44d1-a31c-eba4a7cb41ed",
  "name": "ajsoftworks-e9",
  "started_at": 1792351300,
  "launch_dir": "/home/ajbar/ajsoftworks",
  "claude": { "pid": 2231, "start": 8717628 },
  "voice": "am_michael",
  "state": "needs_you",
  "reason": "approve Bash",
  "state_at": 1792353060,
  "where": { "repo": "klepsydra", "worktree": "fleet", "branch": "feat/fleet-visualizer", "at": 1792353050 },
  "touched": [ { "repo": "ideas", "at": 1792352500 } ],
  "prompt": { "text": "i just want to be able to VIZ them...", "at": 1792353000 },
  "reply": { "text": "That works with no model calls...", "at": 1792352990 },
  "ended": null
}
```

The beat file `<session_id>.beat` holds one line: the session name, a tab, and
the 10 s bucket it was written in. Its modification time is the heartbeat; the
reader takes the name from it for the card title and for Jump to terminal.

### Fleet reader

The reader watches `fleet/` with the `notify` crate and ignores `.tmp` files.
A 5 s re-read runs as a safety net, matching the gauge's `POLL_MS`. On this
machine a Windows file watcher fired for every write made from WSL into the
same directory tree, 3 to 38 ms after the create (measured 2026-10-18). The
`notify` docs' warning about WSL concerns WSL programs watching Windows paths,
which is not this case.

The reader computes what no file can know by itself: a session whose beat file
is more than 90 s old (three missed 30 s heartbeats) and whose last event is
older still shows as `silent`, with "no word for <age>". It rejects files with
an unknown `v` and reports them once in the log.

### Face strip

The strip sits to the right of the gauge bar in the existing window, which
widens to fit it. Each session gets a portrait scaled from the gauge's
`--scale` token (28 px at 100%). A badge sits on the portrait's corner.

Order: `needs_you` (longest wait first), `error`, `working`, `done` (newest
first), `new`, `silent`, `ended`. A session that starts needing AJ moves to the
front.

Clicking a portrait opens the card wall scrolled to that session's card.
The strip's hit area joins the grip in the existing pointer watcher, which
makes the click-through window interactive only over those areas.

### Card wall

A normal window: resizable, not always on top, remembering its position with
the window-state plugin. It is created from an async command on first click,
and after that hidden and shown, never destroyed. At 1920 px wide it fits three
columns of cards; it reflows below that.

Each card shows:

- portrait, name, and voice name in small type
- where now: `repo · worktree · branch`, then chips for touched repos
- status line: badge, label, reason and age, e.g. `needs you · approve Bash · 2m`
- `>` the last prompt, `<` the last reply, two lines each, full text on hover
- the action **Jump to terminal**: UI Automation finds the Windows Terminal
  tab whose title contains the session name, selects it, and brings its window
  to the front. If Windows refuses the foreground change, the window's taskbar
  button flashes instead. With no match, or more than one, the action says so
  and does nothing else. A session with no name yet shows the action disabled,
  with the reason.

### Identity: faces and names

`src/fleet/cast.json` maps keryx voices to the ten kourai-khryseai characters
(Hephaestus, Metis, Techne, Dokimasia, Kallos, Mneme, Aidos, Aletheia, Cupid,
Puck). Each character gets one voice from keryx's rotation pool, matched by
gender, and seeded from kourai's voice casting plan where it names a Kokoro
voice (Hephaestus `am_michael`, Puck `am_puck`). The card shows the
character's name.

A voice without a character gets a DiceBear Lorelei face (CC0 1.0) seeded by
the voice id, and the capitalised voice name (`am_fenrir` is "Fenrir"). A
session with no voice gets one of 24 pre-rendered Lorelei faces chosen by a
hash of its session id, and its Claude Code display name.

All faces are files in the repo, generated once by a script: the ten portraits
are cut from kourai's `assets/avatars/vn/*_neutral.png` to 96 px and 192 px
WebP, and the Lorelei faces are rendered with `@dicebear/core@9.4.2` and
`@dicebear/lorelei@9.4.2` (exact versions) for every Kokoro voice plus the 24
fallbacks. The frontend loads no library and fetches nothing at run time.

## Visual and interaction design

- **Badges carry shape, symbol, text and colour together** (WCAG 1.4.1). From
  the Okabe-Ito palette: needs you, orange `#E69F00` diamond with `!`; error,
  vermillion `#D55E00` square with `×`; working, blue `#0072B2` circle with
  `…`; done, bluish green `#009E73` circle with `✓`; not started, silent and
  ended, grey outline circles with `○`, `?` and `–`. Each badge meets 3:1
  contrast against the strip's backdrop (WCAG 1.4.11), checked in a test.
- **One pulse when a session starts needing AJ**, then a static badge. No
  pulse under `prefers-reduced-motion`.
- **Ages everywhere.** `2m`, `1h`, `3d`. A card's "updated" line appears when
  its newest field is older than 5 minutes.
- **Accessible names.** Each portrait is a button named, for example,
  "Hephaestus, needs you, approve Bash, 2 minutes". The wall has a polite live
  region that announces state changes.
- **No status in the face.** The portrait never changes with state.

These follow ParallelPilot (Long et al., arXiv 2609.33113, N=16). Agreement
with "I noticed when agents finished or needed me" rose from 3.63 to 6.19 out
of 7, and its live dashboard rated 6.88 for usefulness. The same study found
no significant gain in perceived control (p=.414) or intervention success
(p=.603), which is why the card's main action leads back to the terminal.

## Lifecycle and errors

- An `ended` card stays 10 minutes, then leaves the strip and wall.
- At `SessionStart` the hook deletes fleet files whose Claude process is gone
  (pid missing, or start time changed) and whose last event is over 24 hours
  old. It deletes only `fleet/<uuid>.json` and `fleet/<uuid>.beat` inside an
  absolute `KLEPSYDRA_DIR`, and refuses to run if the directory is unset,
  relative or not named `dev.ajsoftworks.klepsydra`. A test covers each refusal.
- A malformed file is skipped and logged once; the rest of the fleet renders.
- If the fleet directory does not exist, the strip is empty and the gauge
  renders as before.
- If the hook fails, Claude Code is unaffected: the hook is async and always
  exits 0.

## Spike results (2026-10-18)

The three unknowns were settled before planning. The design above already
reflects each answer.

- **S1, jump to terminal.** Claude Code sets the terminal tab title to the
  session's custom name or its AI-generated title (`terminalTitleFromRename`,
  settings reference), and the statusline input carries that same value as
  `session_name` (statusline docs). UI Automation listed AJ's Windows Terminal
  windows and their tab titles ("FedAgents", "Klepsydra") with
  `CASCADIA_HOSTING_WINDOW_CLASS` and `TabItem`. Not yet verified: that
  klepsydra may take the foreground after AJ's click; the live check covers it,
  and the taskbar flash is the fallback.
- **S2, question and automated prompts.** `PreToolUse` matches
  `AskUserQuestion` and `ExitPlanMode` (hooks docs). `UserPromptSubmit` also
  fires for scheduled tasks, `/loop` iterations, background subagent reports
  and cross-session messages, with no field that marks them (hooks docs). In
  this session's transcript, 8 of 32 user messages were subagent reports, each
  starting with `<task-notification>`; that prefix is the one rule. Pasted text
  arrives inside `<pasted_content>` and must not match it.
- **S3, background sessions.** A probe background session (`claude --bg`, its
  own `--settings`, Haiku) fired `SessionStart` (`startup`),
  `UserPromptSubmit`, `Stop` with `last_assistant_message` "ok", and on
  `claude stop`, `SessionEnd` with reason `other`. Its statusline with
  `refreshInterval: 2` rendered while idle (4 beats, then 9 ten seconds later)
  and stopped after the stop (15 then 15). The `silent` rule therefore holds
  for background sessions too.

## Testing

- **Guards first**: the tests in the rejected-ideas table.
- **Hook**: `hooks/test_fleet.sh` replays fixture events (one JSON file per
  event type, captured from real sessions) and asserts the session file; repo
  resolution gets fixtures for a plain repo, a linked worktree, a submodule and
  a directory outside any repo, checked against keryx's `source_name` on the
  same paths. shellcheck covers `hooks/*.sh` in CI.
- **Reader**: Rust unit tests for parsing, versioning, ordering and the
  `silent` rule with injected clocks.
- **Frontend**: `node --test` for ordering, ages, badge text and accessible
  names; the existing style test extends to fleet CSS.
- **Live check on Windows**: eight real sessions, one per state, confirmed in
  the running strip and wall against their session files, as the gauge was
  verified in `ROADMAP.md` (2026-09-16).

## Out of scope

Controlling sessions from the wall, coordination between agents, agents other
than Claude Code, per-session quota (the gauge shows the account), per-session
CPU and RAM, and product packaging.

## Sources

- `# research(2026-10)` Claude Code hooks, statusline and terminal title: https://code.claude.com/docs/en/hooks, https://code.claude.com/docs/en/statusline, https://code.claude.com/docs/en/settings-reference#terminaltitlefromrename
- `# research(2026-10)` agent view and `claude agents --json`: https://code.claude.com/docs/en/agent-view
- `# research(2026-10)` Tauri 2 config and window builder: https://v2.tauri.app/reference/config/, https://docs.rs/tauri/latest/tauri/webview/struct.WebviewWindowBuilder.html
- `# research(2026-10)` WebView2 process model and performance: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model, https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/performance
- `# research(2026-10)` notify crate: https://docs.rs/notify/latest/notify/
- `# research(2026-10)` ParallelPilot: https://arxiv.org/abs/2609.33113
- `# research(2026-10)` DiceBear licenses: https://www.dicebear.com/licenses/
- `# research(2026-10)` randomuser.me photo terms: https://randomuser.me/copyright
- `# research(2026-10)` Generated Photos API terms: https://generated.photos/api
- `# research(2026-10)` WCAG 2.2: https://www.w3.org/WAI/WCAG22/understanding/
- Dashboard review sweep, 2026-10-18: Cursor forum 157226 and 158856, VS Code #300191 and #317380, Claude Code #101806, #101614 and #102671.

## Addendum 2026-10-19: rulings made during implementation

The text above is unchanged. Each line below changed or sharpened it, with the reason.

- Idle self-heal: a `Notification` of type `idle_prompt` sets a `working` or `needs_you` session to `done` once its state is 30 s old. Stop does not run after an interrupt, so a session could stay "working" forever. The install block's Notification matcher is `elicitation_dialog|elicitation_url_dialog|idle_prompt`, since the heal never fires otherwise.
- `written_at` is the activity stamp. The hook refreshes it at most once per 60 s, and it drives pruning and carries clock skew between the hook and the reader. The "working?" rule uses the file's own modification time, on the reader's clock.
- Session files add `needs`, `where.by`, `ended`, `written_at` and `error`. The asker rule and the skew correction need them.
- `quiet_since` and "working?": a working session with no activity for over 10 minutes keeps the working colour, shows a `?` badge and reads "working? · no activity for <age>". A confident "working" would be wrong for an interrupted session.
- Time bounds: the reader puts the writer's clock right first (skew from `written_at` against the file time), then skips a file with any corrected time outside 2020-01-01 to 2100-01-01 as malformed. A wildly wrong but consistent clock must not produce a 1970 age or a hidden session.
- Pruning runs at most once an hour. It deletes only names from its own `fleet/<uuid>.json` glob, never a path read from file content, and refuses a data dir that is not an absolute `dev.ajsoftworks.klepsydra` path. A deletion outside `fleet/` was reproduced in review. It also removes `.tmp` litter older than a day.
- Jump matches the one tab whose title, after a leading status glyph and with padding trimmed, equals the session's name. The spec said "contains", which could select a wrong tab (`klepsydra` against `klepsydra-e2`).
- Jump refuses with a message when Windows Terminal hides its tabs (full screen or focus mode), and never falls back to a window-title guess.
- Jump creates CUIAutomation8 first (CUIAutomation when that is missing) and sets the UI Automation connection timeout to 1000 ms and the transaction timeout to 3000 ms through IUIAutomation2, so a hung terminal cannot hang the click.
- Bad files are logged once to `fleet.log` in the app data dir (truncated at 64 KiB), since release builds have no console.
- A need is cleared only by the tool that raised it, on the same thread, finishing or failing (`PostToolUse` or `PostToolUseFailure`). Clearing on any PostToolUse would drop the badge while a parallel or subagent tool finishes; without the failure event, an approved command that exits non-zero would keep "needs you" for the rest of the turn.
- NotebookEdit's path comes from `tool_input.notebook_path`. The spec named `file_path`, which that tool does not carry.
- A prompt starting `<task-notification>` is a background subagent's report: it sets `working` and keeps the last prompt. Pasted text arrives inside `<pasted_content>` and does not match.
- A session is silent only when both its beat and its session file are over 90 s old. Judging by the beat alone could leave a dying session at "working".
- A session waiting on AJ is never silent: Claude Code hides the status line while a permission prompt or dialog is open, so no beat arrives (measured on 2.1.301: none for 30 s at a Bash prompt, none for 37 s at an AskUserQuestion). It keeps `needs_you` and its age. With no beat and no event for 30 minutes it reads "needs you? · no word for <age>", keeps the needs-you order, and shows a `?` badge on the diamond.
- Cast: Puck is `am_puck`, Mneme `bf_isabella`, Dokimasia `af_aoede`, Cupid `af_heart`, and the rest follow kourai's `tts_backend.py`, because kourai's voices are outside keryx's pool. A blend voice gets a hash fallback face and a joined name.
- Badge contrast is measured against a panel-coloured ring around each badge, since `#0072B2` is 2.1:1 on a white desktop without it. Every portrait carries its badge, and only needs-you pulses.
- Strip state and the resize-band maths live in `src-tauri/src/fleet.rs` and `geometry.rs`, so `main.rs` gains only wiring.
- The strip shows a status's age in the tooltip and the accessible name, since a 28 px portrait has no room for text; the wall shows it visibly. The silent rule swaps the badge, and a needs-you badge turns to `?` after 30 minutes without a word, so a strip badge is never stale-wrong.
- The wall's window label is `wall`, it is not always on top, and it does not pulse; the strip owns the one pulse.
- Order: the needs-you group comes first, longest wait first inside it. A session that starts needing AJ joins that group.
- A card's name comes from the beat's session name, then the file's `session_title`, then the launch folder. The default display name reaches no hook.
