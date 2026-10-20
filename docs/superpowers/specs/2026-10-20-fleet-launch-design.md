<!-- budget: 1500 words -->
# Fleet launch, tmux jump, clear and gone: design

Date: 2026-10-20. Status: approved by AJ 2026-10-20 ("I trust your web-research-backed recommendations").

## Goal

AJ opens a new Windows Terminal tab, and so a new `wsl.exe`, for every Claude
session. He wants one terminal instead: klepsydra opens it, and every further
session is a tmux window inside it. The wall then hops between those windows.

Three smaller changes ship with it:

- **Clear**: a button on an ended or silent card removes it now.
- **Gone**: a session whose Claude process died without a `SessionEnd`, as on
  a reboot, becomes ended instead of staying silent for a day.
- **claude-prefs**: `~/claude-prefs` is in `additionalDirectories` in both
  settings files (done 2026-10-20, outside this repo).

It succeeds when AJ presses **+** on the wall and gets a new `claude` in
`~/ajsoftworks` inside the one `fleet` terminal, and Jump on any card brings
that session's tmux window to the front.

## What a tab costs, measured

`tasklist.exe` and `ps` on 2026-10-20 with one terminal tab open:

| Process | Side | Memory |
| --- | --- | --- |
| `vmmemWSL` (the one VM, shared by every tab) | Windows | 9914 MB |
| `wsl.exe` x2, `OpenConsole.exe`, `wslhost.exe` x4 | Windows | 83 MB |
| `Relay`, `SessionLeader`, `init` per tab | Linux | about 4 MB |
| `claude` | Linux | 439 MB |

A tab starts no new VM or Ubuntu. A tmux window saves the per-tab Windows
helpers and their interop channels, the source of the `0x8007274c` tab
failures (microsoft/WSL #41901). Claude costs the same either way.

## Changed constraints

The 2026-10-18 spec says nothing on the Windows side starts a process or names
`wsl`. AJ's request needs both, so the rule becomes:

- Exactly one source file, `src-tauri/src/launch.rs`, starts a process. It
  starts only `C:\Windows\System32\wsl.exe`, from a fixed path, with
  `CREATE_NO_WINDOW`.
- It runs only from a click (**+** or Jump), one call at a time. A click while one runs is refused. Nothing polls.
- Every other file keeps both guards. `src/guards.test.js` asserts the
  exemption list is exactly `launch.rs`.
- The overlay deletes files for the first time (Clear), only
  `fleet/<uuid>.json` and `fleet/<uuid>.beat`.

Sessions started by hand keep working, and Jump still matches their tab titles.

## Parts

### `hooks/klepsydra-launch.sh` (new, installed to `~/.claude/`)

It holds every tmux and `wt.exe` command, so Rust builds one fixed command
line and the tmux logic is tested in bash.

`new DIR`:

1. Take a `flock` on `$XDG_RUNTIME_DIR/klepsydra-launch.lock`.
2. If tmux socket `klepsydra` has no session `fleet`, create it detached:
   `tmux -L klepsydra -f ~/.claude/klepsydra-tmux.conf new-session -d -s fleet -c DIR claude`.
   Otherwise `tmux -L klepsydra new-window -t =fleet: -c DIR claude`.
3. If no client is attached to `fleet`, open one tab:
   `wt.exe -w fleet new-tab wsl.exe -d $WSL_DISTRO_NAME -- tmux -L klepsydra attach -t =fleet`.

Creating the session detached, before any tab exists, means two quick clicks
make two windows, never two sessions. A closed tab leaves the sessions running
detached, and the next **+** or Jump reattaches.

`jump SOCKET PANE`: checks `PANE` is `%<digits>` and `SOCKET` is an absolute
path, runs `select-window -t PANE` and `select-pane -t PANE`, then reattaches
as in step 3 if no client is attached. It exits non-zero when tmux has no such
pane.

A missing `claude`, `tmux` or `wt.exe` exits non-zero with one line naming
it, which the wall shows.

### `hooks/klepsydra-tmux.conf` (new, installed to `~/.claude/`)

```
source-file -q ~/.tmux.conf
set -g set-titles on
set -g set-titles-string "#{pane_title}"
set -g remain-on-exit failed
```

AJ's own settings load first (passthrough, extended keys, mouse). The
`set-titles` lines pass the active window's Claude title to the tab, so
title-matching Jump still works. The 2026-10-19 live check ran sessions this
way. A window whose `claude` exits non-zero stays open, so a start-up error
can be read.

### `hooks/klepsydra-fleet.sh` (changed)

- Records `tmux: {socket, pane}` from `$TMUX` (its first field) and
  `$TMUX_PANE`, when both are set and well formed.
- Records `host: {boot, distro}` from `/proc/sys/kernel/random/boot_id` and
  `$WSL_DISTRO_NAME`.
- At every `SessionStart`, under the fleet lock, marks a session that has not
  ended as ended with reason `gone` when:
  - its `host.boot` differs from this boot (a reboot or `wsl --shutdown`), or
  - its `host.distro` is this distro and `claude_alive` fails for its pid.

  A file from another distro on the same boot is left alone, since that
  distro's pids are not visible here. A file with no `host` is left to the
  24-hour prune.

A gone card shows "ended · gone" and leaves 10 minutes later, like any ended
card.

### `src-tauri/src/launch.rs` (new)

- `launch_session()`: `wsl.exe [-d DISTRO] --cd ~ -- bash -l .claude/klepsydra-launch.sh new DIR`.
- `tmux_jump(socket, pane, distro)`: `wsl.exe -d DISTRO --cd ~ -- bash .claude/klepsydra-launch.sh jump SOCKET PANE`.
- The command line comes from a pure function with unit tests. Arguments are
  validated before use and passed as separate argv entries, never through a
  shell string on the Windows side.
- One `Mutex<bool>` in managed state holds the one-call-at-a-time rule.

Prefs: `launch_dir` (default `~`; AJ's is `~/ajsoftworks`) and
`launch_distro` (default: WSL's default distro).

### Jump (changed)

When a card has `tmux` and `host.distro`, Jump first calls `tmux_jump`, then
runs today's title match. It retries the match for up to 1.5 s while Windows
Terminal picks up the new title. If `tmux_jump` fails, Jump falls back to the
title match alone. A card without `tmux` works as today.

### Clear (new)

A Clear button on ended and silent cards calls `clear_session(id)`. The
command:

- checks `id` against the UUID pattern;
- refuses unless the hub's latest snapshot shows the session ended or silent;
- deletes `<id>.json` and `<id>.beat` only when `symlink_metadata` says each
  is a regular file inside the overlay's own `fleet` folder.

A silent session that is still alive gets its file back at its next hook event
(verified in `APPLY`: a missing file is rebuilt). It loses its start time and
touched list. The button's tooltip says so.

### Wall

- A bar above the cards holds a **+ New session** button and a note. While a
  launch runs, the button is disabled; the note shows the script's line.
- The face strip and tray are left alone. #30 is reworking the strip.

## Rejected ideas and their guards

| Idea | Why it was dropped | Guard |
| --- | --- | --- |
| A tab per session (the 2026-10-19 live-check layout) | Starts a `wsl.exe` and opens interop channels per session (measured above). | `new` never calls `wt.exe` while a client is attached: bash test. |
| Agent view (`claude --bg`) or a tmux dashboard (recon, ccmonitor, ccmgr) | Agent view runs sessions out of sight; the dashboards duplicate the wall. | None needed. |
| A resident WSL daemon that takes launch requests | Always running for a once-a-minute action. | The guards test still forbids a spawn in every file but `launch.rs`. |
| `destroy-unattached on` | Closing the tab would kill every session in it. | Bash test: a session survives losing its client. |
| `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` for claude-prefs | `~/claude-prefs/CLAUDE.md` is identical to the global one and would load twice. | Not applicable; settings only. |
| Marking gone by pid alone | Another distro's live session would be marked gone. | Bash test: a file with another distro on this boot keeps its state. |

## Testing

- Bash (`hooks/test_launch.sh`, new): `new` against a private tmux socket and
  a stub `wt.exe` on `PATH`. Covers the first click (session, then one tab),
  a second click (window, no tab), two concurrent clicks (two windows, one
  session), and a closed tab (window, then one tab). `jump` gets bad pane and
  socket strings refused, an unknown pane exits non-zero, and a known pane is
  selected.
- Bash (`test_fleet.sh`): the `tmux` and `host` fields, and gone marking for
  the other-boot, same-distro dead, same-distro alive and other-distro cases.
- Rust: command-line builder, argument validation, the in-flight refusal,
  Clear's refusals (bad id, live status, symlink, path outside the folder).
- JS: the **+** button's states, Clear on ended and silent cards only, and the
  narrowed guards (exemption list is exactly `launch.rs`, which names only the
  fixed `wsl.exe` path).
- Live on Windows: **+** three times gives one tab and three windows; Jump
  hops between them; after closing the tab, **+** reattaches; after
  `wsl --shutdown`, old cards read "ended · gone".

## Out of scope

- #22 (interrupt and exit from a card). The recorded `tmux.pane` makes it a
  `send-keys` to a known pane, so the wrong-tab risk in #22 goes away. It stays
  its own issue.
- Choosing a folder or account per launch.

## Sources

- Windows Terminal command-line arguments (`-w`, `new-tab`): learn.microsoft.com/windows/terminal/command-line-arguments
- tmux(1): `TMUX_PANE`, pane ids, `new-window`, `set-titles`, `remain-on-exit`
- Claude Code memory docs, additional directories: code.claude.com/docs/en/memory
- anthropics/claude-code #38033 (settings `additionalDirectories` do not load CLAUDE.md)
- Agent view: claude.com/blog/agent-view-in-claude-code
- recon, ccmonitor, ccmgr: tmux-based session dashboards (prior art)
