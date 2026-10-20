# Fleet launch, tmux jump, clear and gone: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A **+ New session** button on the wall starts `claude` as a tmux window in one Windows Terminal tab; Jump selects a session's tmux window; Clear removes ended and silent cards; sessions killed without `SessionEnd` become ended ("gone").

**Architecture:** One new bash script (`hooks/klepsydra-launch.sh`) owns every tmux and `wt.exe` command. One new Rust file (`src-tauri/src/launch.rs`) is the only place the app starts a process: `wsl.exe -e bash … klepsydra-launch.sh`, from a click, one call at a time. The fleet hook records each session's tmux pane and host (boot id, distro) and marks dead sessions gone at `SessionStart`.

**Tech Stack:** bash + jq + tmux 3.4 (hooks), Rust/Tauri 2 (`src-tauri`, `src-tauri/fleet`), vanilla JS with `node --test`.

**Spec:** `docs/superpowers/specs/2026-10-20-fleet-launch-design.md`

All paths below are relative to the worktree root `/home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/fleet-launch` (branch `feat/fleet-launch`, issue #31). Run every command from there.

## Global Constraints

- Only `src-tauri/src/launch.rs` may start a process or contain the text `wsl`; it starts only `C:\Windows\System32\wsl.exe` (const `WSL_EXE`), with `CREATE_NO_WINDOW`.
- `wsl.exe` is always called with `-e` (exec, no shell), never `--`: measured 2026-10-20, `--` lets the Linux shell expand `$HOME`, `-e` passes `$HOME` and `~/x;y` through untouched.
- One launcher call at a time (`InFlight`); a click meanwhile gets `Err("A launch is already running.")`. Nothing polls.
- tmux socket name `klepsydra`, session `fleet`, Windows Terminal window name `fleet`.
- Clear deletes only `fleet/<uuid>.json` and `fleet/<uuid>.beat`, only regular files, only for a session the hub's latest snapshot shows `ended` or `silent`.
- Gone: `host.boot` differs from this boot, or (`host.distro` is this distro and `claude_alive` fails). A file with no `host`, or another distro on this boot, is left alone.
- Prefs: `launch_dir` (default `"~"`), `launch_distro` (default: none, WSL's default distro).
- No em-dashes in user-facing copy. Comments terse: what the code needs to be used, no history.
- Gates before every commit: `bash hooks/test_fleet.sh`, `bash hooks/test_launch.sh` (from Task 3), `node --test src/*.test.js`, `shellcheck hooks/*.sh statusline/*.sh scripts/*.sh`, and in `src-tauri`: `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`.

## Review Focus

1. **A launch while the `fleet` session exists but its tab was closed** must add a window and open exactly one tab that attaches (Task 3 test "closed tab").
2. **Two clicks in quick succession** must make two windows in one session, never two sessions or two tabs (Task 3 test "concurrent").
3. **A folder pref with spaces or shell characters** (`~/my repos;x`) must reach tmux as one literal folder (Task 5 test `new_args_pass_the_folder_as_one_argument`; Task 3 test "folder with a space").
4. **A reboot leaves files whose pid now belongs to another program**: `claude_alive` already checks start time and name; Task 2 test "same distro, pid reused" pins it.
5. **Clear on a card whose session comes back to life** between render and click: the server-side status check refuses (Task 7 test `clear_refuses_a_live_session`).

---

### Task 1: The hook records tmux and host

**Files:**
- Modify: `hooks/klepsydra-fleet.sh` (APPLY defaults near line 305; `main` near lines 415-440)
- Test: `hooks/test_fleet.sh` (append before the final summary block)

**Interfaces:**
- Produces: session-file fields `tmux: {socket: string, pane: string} | absent` and `host: {boot: string, distro: string|null} | absent`. Hook globals `host_boot`, `host_distro` (set by `host_facts`), read by Task 2.

- [ ] **Step 1: Write the failing tests** (append to `hooks/test_fleet.sh` before `printf '\n%d passed`):

```bash
echo "tmux and host"
boot_file="$work/boot_id"
printf '%s\n' 0b6e1c5a-1111-4222-8333-444455556666 >"$boot_file"
rm -f "$file"
fire session-start.json . TMUX=/tmp/tmux-1001/klepsydra,4242,0 TMUX_PANE=%3 \
  WSL_DISTRO_NAME=Ubuntu KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "tmux recorded" "$(field .tmux)" '{"socket":"/tmp/tmux-1001/klepsydra","pane":"%3"}'
check "host recorded" "$(field .host)" '{"boot":"0b6e1c5a-1111-4222-8333-444455556666","distro":"Ubuntu"}'
rm -f "$file"
fire session-start.json . TMUX= TMUX_PANE= WSL_DISTRO_NAME= KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "outside tmux: no tmux" "$(field .tmux)" "null"
check "no distro: null distro" "$(field .host.distro)" "null"
rm -f "$file"
fire session-start.json . 'TMUX=/tmp/x,1,0' 'TMUX_PANE=%3;rm -rf' KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "a malformed pane is not recorded" "$(field .tmux)" "null"
rm -f "$file"
fire session-start.json . 'TMUX=rel/sock,1,0' TMUX_PANE=%3 KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "a relative socket is not recorded" "$(field .tmux)" "null"
rm -f "$file"
fire session-start.json . KLEPSYDRA_BOOT_ID="$work/no-such-file" >/dev/null
check "no boot id: no host" "$(field .host)" "null"
```

- [ ] **Step 2: Run to see them fail**

Run: `bash hooks/test_fleet.sh 2>&1 | grep -E "FAIL|passed"`
Expected: the six new checks FAIL (fields are `null` or wrong), all older checks pass.

- [ ] **Step 3: Implement.** Add after `claude_alive()` in `hooks/klepsydra-fleet.sh`:

```bash
# Sets host_boot (this kernel boot) and host_distro (this WSL distro), each
# empty when unknown or malformed.
BOOT_ID=${KLEPSYDRA_BOOT_ID:-/proc/sys/kernel/random/boot_id}
host_facts() {
  host_boot="" host_distro=${WSL_DISTRO_NAME:-}
  { IFS= read -r host_boot <"$BOOT_ID"; } 2>/dev/null
  [[ $host_boot =~ ^[0-9a-f-]{36}$ ]] || host_boot=""
  [[ $host_distro =~ ^[A-Za-z0-9._-]{1,64}$ ]] || host_distro=""
}

# Sets tmux_socket and tmux_pane from the session's tmux, both empty outside
# tmux or when either is malformed.
tmux_facts() {
  tmux_socket=${TMUX%%,*} tmux_pane=${TMUX_PANE:-}
  if ! [[ ${TMUX:-} == *,* && $tmux_socket =~ ^/[A-Za-z0-9._/-]{1,255}$ && $tmux_pane =~ ^%[0-9]{1,9}$ ]]; then
    tmux_socket="" tmux_pane=""
  fi
}
```

Note `${TMUX%%,*}` with `TMUX` unset trips `set -u`; write it as `tmux_socket=${TMUX:-}; tmux_socket=${tmux_socket%%,*}`.

In APPLY's default object (the `($was // {v: 1, …})` literal) add `tmux: null, host: null,` after `claude: null,`. After the `| .claude = (…)` line add:

```jq
  | (if $tmux_pane != "" then .tmux = {socket: $tmux_socket, pane: $tmux_pane} else . end)
  | (if $boot != "" then .host = {boot: $boot, distro: ($distro | text)} else . end)
```

In `main`, before `[[ -n ${KLEPSYDRA_DIR:-} ]] || return 0`, add `host_facts; tmux_facts`, and add to the `jq -c` call: `--arg tmux_socket "$tmux_socket" --arg tmux_pane "$tmux_pane" --arg boot "$host_boot" --arg distro "$host_distro"`.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash hooks/test_fleet.sh 2>&1 | tail -1 && shellcheck hooks/*.sh`
Expected: `N passed, 0 failed`; shellcheck prints nothing.

- [ ] **Step 5: Commit**

```bash
git add hooks/klepsydra-fleet.sh hooks/test_fleet.sh
git commit -m "feat(fleet): record each session's tmux pane and host"
```

### Task 2: Gone at SessionStart

**Files:**
- Modify: `hooks/klepsydra-fleet.sh` (new `mark_gone`; call in `main` before `prune_hourly`)
- Test: `hooks/test_fleet.sh`

**Interfaces:**
- Consumes: `host_boot`, `host_distro`, `host_facts` (Task 1); existing `own_data_dir`, `claude_alive`, `write_atomic`, `UUID_RE`, `PROC_ROOT`.
- Produces: an affected file gets `state: "ended"`, `reason: "gone"`, `ended: {reason: "gone", at: now}`, `state_at: now`, `written_at: now`.

- [ ] **Step 1: Write the failing tests.** The fake `/proc` helper `mkproc` (defined near line 79 of `test_fleet.sh`) builds pid 500 as a live `claude` with start 8717628. Append:

```bash
echo "gone"
put() { # id state boot distro pid start
  jq -nc --arg id "$1" --arg st "$2" --arg b "$3" --arg d "$4" --argjson p "$5" --argjson s "$6" --argjson now "$now" \
    '{v:1, session_id:$id, state:$st, state_at:($now-100), written_at:($now-100),
      claude:{pid:$p, start:$s}, host:{boot:$b, distro:(if $d == "" then null else $d end)}}' \
    >"$dir/fleet/$1.json"
}
state_of() { jq -r '[.state, (.reason // "-")] | join("/")' "$dir/fleet/$1.json"; }
B=0b6e1c5a-1111-4222-8333-444455556666; OLD=99999999-1111-4222-8333-444455556666
A1=aaaaaaaa-0000-4000-8000-000000000001 # an earlier boot
A2=aaaaaaaa-0000-4000-8000-000000000002 # this boot and distro, pid dead
A3=aaaaaaaa-0000-4000-8000-000000000003 # this boot and distro, alive (pid 500)
A4=aaaaaaaa-0000-4000-8000-000000000004 # this boot, another distro, pid dead here
A5=aaaaaaaa-0000-4000-8000-000000000005 # this boot and distro, pid reused by another program
A6=aaaaaaaa-0000-4000-8000-000000000006 # already ended, an earlier boot
put $A1 working $OLD Ubuntu 500 8717628
put $A2 done $B Ubuntu 4999 1
put $A3 working $B Ubuntu 500 8717628
put $A4 working $B Debian 4999 1
put $A5 working $B Ubuntu 500 1
put $A6 ended $OLD Ubuntu 500 8717628
jq -c '.reason = "exited"' "$dir/fleet/$A6.json" >"$work/a6" && mv "$work/a6" "$dir/fleet/$A6.json"
rm -f "$file"
fire session-start.json . WSL_DISTRO_NAME=Ubuntu KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "an earlier boot is gone" "$(state_of $A1)" "ended/gone"
check "same distro, pid dead: gone" "$(state_of $A2)" "ended/gone"
check "same distro, alive: unchanged" "$(state_of $A3)" "working/-"
check "another distro: unchanged" "$(state_of $A4)" "working/-"
check "same distro, pid reused: gone" "$(state_of $A5)" "ended/gone"
check "already ended: unchanged" "$(state_of $A6)" "ended/exited"
check "gone stamps when" "$(jq -c '[.ended.at, .state_at]' "$dir/fleet/$A1.json")" "[$now,$now]"
rm -f "$dir"/fleet/aaaaaaaa-*.json
```

If `boot_file` holds `$B` from Task 1's test, keep it; otherwise write `$B` into it first.

- [ ] **Step 2: Run to see them fail**

Run: `bash hooks/test_fleet.sh 2>&1 | grep -E "FAIL|passed"`
Expected: "an earlier boot is gone", "same distro, pid dead: gone", "same distro, pid reused: gone", "gone stamps when" FAIL.

- [ ] **Step 3: Implement.** Add after `prune_here` in `hooks/klepsydra-fleet.sh`:

```bash
# Mark ended, reason "gone", every session in <dir>/fleet that has not ended
# and whose Claude Code process cannot be running: it started on another boot,
# or on this boot and distro under a pid that is no longer it. Sessions from
# another distro on this boot are left alone (their pids are not visible here).
mark_gone() { # dir now
  local dir=$1 now=$2 f state boot distro pid start new
  [[ -n $host_boot ]] && own_data_dir "$dir" || return 0
  [[ -d $dir/fleet && ! -L $dir/fleet ]] || return 0
  while IFS=$'\t' read -r f state boot distro pid start; do
    [[ ${f%.json} =~ $UUID_RE && $state != ended && -n $boot ]] || continue
    if [[ $boot == "$host_boot" ]]; then
      [[ -n $host_distro && $distro == "$host_distro" ]] || continue
      claude_alive "$pid" "$start" && continue
    fi
    new=$(jq -c --argjson now "$now" \
      '.state = "ended" | .reason = "gone" | .ended = {reason: "gone", at: $now} | .state_at = $now | .written_at = $now' \
      "$dir/fleet/$f" 2>/dev/null) || continue
    [[ -n $new ]] && write_atomic "$dir/fleet/$f" "$new"
  done < <(cd -- "$dir/fleet" 2>/dev/null && for f in *.json; do
      [[ -f $f && ! -L $f ]] || continue
      jq -r --arg f "$f" 'select(type == "object" and .v == 1)
        | [$f, (.state // "" | tostring), (.host.boot // "" | tostring), (.host.distro // "" | tostring),
           ((.claude.pid | numbers) // 0 | floor | tostring), ((.claude.start | numbers) // 0 | floor | tostring)]
        | @tsv' "$f" 2>/dev/null
    done)
}
```

In `main`, directly before the `prune_hourly` line, add:

```bash
  [[ $event == SessionStart ]] && mark_gone "$KLEPSYDRA_DIR" "$now"
```

(`host_facts` already ran in Task 1's change, before the lock.) Leave the current session's own file to the normal write that follows: it is alive by construction.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash hooks/test_fleet.sh 2>&1 | tail -1 && shellcheck hooks/*.sh`
Expected: `N passed, 0 failed`; no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add hooks/klepsydra-fleet.sh hooks/test_fleet.sh
git commit -m "feat(fleet): mark sessions whose Claude process is gone as ended"
```

### Task 3: The launch script and tmux conf

**Files:**
- Create: `hooks/klepsydra-launch.sh`, `hooks/klepsydra-tmux.conf`, `hooks/test_launch.sh`
- Modify: `.github/workflows/ci.yml` (after the `bash hooks/test_fleet.sh` step)

**Interfaces:**
- Produces: `klepsydra-launch.sh new DIR` and `klepsydra-launch.sh jump SOCKET PANE`. Exit 0 prints one line to stdout; exit 1 prints one line to stderr. Env overrides for tests: `KLEPSYDRA_TMUX_SOCKET`, `KLEPSYDRA_TMUX_CONF`, `KLEPSYDRA_CLAUDE`, `KLEPSYDRA_WT`.

- [ ] **Step 1: Write `hooks/klepsydra-tmux.conf`**

```
# tmux settings for klepsydra's fleet session (socket "klepsydra").
source-file -q ~/.tmux.conf
# The tab shows the active window's Claude title, so Jump can find it.
set -g set-titles on
set -g set-titles-string "#{pane_title}"
# A claude that fails to start leaves its window open to read.
set -g remain-on-exit failed
```

- [ ] **Step 2: Write the failing tests, `hooks/test_launch.sh`**

```bash
#!/usr/bin/env bash
# Tests for the launcher against a private tmux server and a stub wt.exe.
# Run: bash hooks/test_launch.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
launch="$here/klepsydra-launch.sh"
work=$(mktemp -d)
sock="kl-test-$$"
clients=()
cleanup() {
  for p in "${clients[@]}"; do kill "$p" 2>/dev/null; done
  tmux -L "$sock" kill-server 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

mkdir -p "$work/bin" "$work/home" "$work/repos/my repos"
cat >"$work/bin/wt.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WT_LOG"
EOF
chmod +x "$work/bin/wt.exe"
export WT_LOG="$work/wt.log" HOME="$work/home" XDG_RUNTIME_DIR="$work" WSL_DISTRO_NAME=Test
export KLEPSYDRA_TMUX_SOCKET="$sock" KLEPSYDRA_TMUX_CONF="$here/klepsydra-tmux.conf"
export KLEPSYDRA_CLAUDE="sleep 600" KLEPSYDRA_WT="$work/bin/wt.exe"
: >"$WT_LOG"

t() { tmux -L "$sock" "$@"; }
windows() { t list-windows -t =fleet 2>/dev/null | wc -l; }
tabs() { wc -l <"$WT_LOG"; }
attach() { # a real client on a pty, like the tab would be
  script -qfc "tmux -L $sock attach -t =fleet" /dev/null >/dev/null 2>&1 </dev/null &
  clients+=($!)
  for _ in $(seq 50); do [[ -n $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}
detach_all() {
  for p in "${clients[@]}"; do kill "$p" 2>/dev/null; done
  clients=()
  for _ in $(seq 50); do [[ -z $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}

echo "new"
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "first: exit 0" "$rc" "0"
check "first: says where" "$out" "Started a session in $work/repos."
check "first: one window" "$(windows)" "1"
check "first: one tab" "$(tabs)" "1"
check "first: the tab attaches with exec" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -L $sock attach -t =fleet"
check "first: conf loaded" "$(t show -gv set-titles)" "on"
attach
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "second: two windows" "$(windows)" "2"
check "second: no new tab" "$(tabs)" "1"
detach_all
check "closed tab: sessions survive" "$(windows)" "2"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "closed tab: a window" "$(windows)" "3"
check "closed tab: one tab to reattach" "$(tabs)" "2"
bash "$launch" new "~/../repos/my repos" >/dev/null 2>&1; rc=$?
check "folder with a space: exit 0" "$rc" "0"
check "folder with a space: cwd" "$(t display -p -t =fleet: '#{pane_current_path}')" "$work/repos/my repos"
out=$(bash "$launch" new "$work/nowhere" 2>&1); rc=$?
check "missing folder: exit 1" "$rc" "1"
check "missing folder: says so" "$out" "The folder $work/nowhere does not exist."
out=$(KLEPSYDRA_CLAUDE=no-such-claude bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no claude: exit 1" "$rc" "1"
check "no claude: says so" "$out" "claude was not found on PATH."

t kill-server 2>/dev/null; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "concurrent: one session" "$(t list-sessions | wc -l)" "1"
check "concurrent: two windows" "$(windows)" "2"

echo "jump"
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
socket=$(t display -p '#{socket_path}')
attach; : >"$WT_LOG"
out=$(bash "$launch" jump "$socket" "$first" 2>&1); rc=$?
check "jump: exit 0" "$rc" "0"
check "jump: says so" "$out" "Selected the session's tmux window."
check "jump: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump with a client: no tab" "$(tabs)" "0"
out=$(bash "$launch" jump "$socket" '%3;x' 2>&1); rc=$?
check "bad pane: exit 1" "$rc" "1"
out=$(bash "$launch" jump "rel/sock" "$first" 2>&1); rc=$?
check "relative socket: exit 1" "$rc" "1"
out=$(bash "$launch" jump "$socket" '%99999' 2>&1); rc=$?
check "unknown pane: exit 1" "$rc" "1"
check "unknown pane: says so" "$out" "That session's tmux pane is gone."
detach_all
bash "$launch" jump "$socket" "$first" >/dev/null 2>&1
check "jump without a client: one tab" "$(tabs)" "1"
check "jump's tab names the socket" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -S $socket attach -t =fleet"
out=$(bash "$launch" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 3: Run to see it fail**

Run: `bash hooks/test_launch.sh 2>&1 | tail -3`
Expected: failures throughout (the script does not exist yet), ends `0 passed` or close to it.

- [ ] **Step 4: Write `hooks/klepsydra-launch.sh`**

```bash
#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump SOCKET PANE
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"); `jump` brings PANE's window to the front of its session. Both
# open a Windows Terminal tab (window "fleet") only when no client shows the
# session. One line out: stdout on success, stderr on failure.
set -uo pipefail

SOCKET_NAME=${KLEPSYDRA_TMUX_SOCKET:-klepsydra}
SESSION=fleet
CONF=${KLEPSYDRA_TMUX_CONF:-$HOME/.claude/klepsydra-tmux.conf}
CLAUDE=${KLEPSYDRA_CLAUDE:-claude}
WT=${KLEPSYDRA_WT:-wt.exe}
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-launch-$UID.lock

fail() { printf '%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$2"; }

# Open a tab attached to session `target` unless a client already shows it.
show() { # target tmux-socket-args...
  local target=$1; shift
  [[ -n $(tmux "$@" list-clients -t "$target" -F x 2>/dev/null) ]] && return 0
  need "$WT" "wt.exe was not found, so no terminal tab could be opened."
  [[ -n ${WSL_DISTRO_NAME:-} ]] || fail "WSL_DISTRO_NAME is not set, so no tab could be opened."
  "$WT" -w fleet new-tab wsl.exe -d "$WSL_DISTRO_NAME" -e tmux "$@" attach -t "$target" >/dev/null 2>&1 ||
    fail "Windows Terminal did not open a tab."
}

new() { # dir
  local dir=$1 lock
  case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
  esac
  [[ -d $dir ]] || fail "The folder $dir does not exist."
  need tmux "tmux is not installed in this distro."
  need "${CLAUDE%% *}" "claude was not found on PATH."
  exec {lock}>>"$LOCK" || fail "Could not open $LOCK."
  flock -w 10 "$lock" || fail "Another launch is still running."
  local -a t=(-L "$SOCKET_NAME") conf=()
  [[ -r $CONF ]] && conf=(-f "$CONF")
  if tmux "${t[@]}" has-session -t "=$SESSION" 2>/dev/null; then
    tmux "${t[@]}" new-window -t "=$SESSION:" -c "$dir" "$CLAUDE" || fail "tmux could not open a window."
  else
    tmux "${t[@]}" "${conf[@]}" new-session -d -s "$SESSION" -c "$dir" "$CLAUDE" ||
      fail "tmux could not start the fleet session."
  fi
  show "=$SESSION" "${t[@]}"
  printf 'Started a session in %s.\n' "$dir"
}

jump() { # socket pane
  local socket=$1 pane=$2 session
  [[ $socket =~ ^/[A-Za-z0-9._/-]{1,255}$ ]] || fail "Not a tmux socket path: $socket"
  [[ $pane =~ ^%[0-9]{1,9}$ ]] || fail "Not a tmux pane: $pane"
  need tmux "tmux is not installed in this distro."
  local -a t=(-S "$socket")
  session=$(tmux "${t[@]}" display-message -p -t "$pane" '#{session_name}' 2>/dev/null) ||
    fail "That session's tmux pane is gone."
  [[ $session =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The tmux session's name cannot be passed to a tab."
  { tmux "${t[@]}" select-window -t "$pane" && tmux "${t[@]}" select-pane -t "$pane"; } 2>/dev/null ||
    fail "tmux could not select the window."
  show "=$session" "${t[@]}"
  printf "Selected the session's tmux window.\n"
}

case ${1:-} in
  new) (( $# == 2 )) || fail "usage: klepsydra-launch.sh new DIR"; new "$2" ;;
  jump) (( $# == 3 )) || fail "usage: klepsydra-launch.sh jump SOCKET PANE"; jump "$2" "$3" ;;
  *) fail "usage: klepsydra-launch.sh new DIR | jump SOCKET PANE" ;;
esac
```

`"~/../repos/my repos"` in the test resolves through `$HOME/../repos/my repos`; `#{pane_current_path}` reports the resolved path, which is what the check compares.

- [ ] **Step 5: Run tests and shellcheck**

Run: `chmod +x hooks/klepsydra-launch.sh && bash hooks/test_launch.sh 2>&1 | tail -1 && shellcheck hooks/*.sh`
Expected: `N passed, 0 failed`; no shellcheck output. If "first: conf loaded" fails because `~/.tmux.conf` is absent under the test `HOME`, check that `source-file -q` is present (it suppresses the missing-file error).

- [ ] **Step 6: Add the CI step** in `.github/workflows/ci.yml`, after the `bash hooks/test_fleet.sh` step, matching its indentation:

```yaml
      - name: Launcher tests
        run: |
          command -v tmux >/dev/null || sudo apt-get install -y tmux
          bash hooks/test_launch.sh
```

- [ ] **Step 7: Commit**

```bash
git add hooks/klepsydra-launch.sh hooks/klepsydra-tmux.conf hooks/test_launch.sh .github/workflows/ci.yml
git commit -m "feat(fleet): a launcher that opens claude as tmux windows in one tab"
```

### Task 4: The reader carries tmux and distro; the hub hands out its latest snapshot

**Files:**
- Modify: `src-tauri/fleet/src/session.rs` (new `Tmux`, `Host`; two `SessionFile` fields)
- Modify: `src-tauri/fleet/src/view.rs` (two `View` fields)
- Modify: `src-tauri/fleet/src/hub.rs` (`latest`)
- Create: `src-tauri/fleet/src/lookup.rs`; Modify: `src-tauri/fleet/src/lib.rs` (`pub mod lookup;`)

**Interfaces:**
- Produces: `session::Tmux { socket: String, pane: String }` (Serialize + Deserialize), `session::Host { boot: String, distro: Option<String> }`; `View.tmux: Option<Tmux>`, `View.distro: Option<String>` (serialized as `tmux` and `distro`); `Hub::latest(&self) -> Option<serde_json::Value>`; `lookup::session<'a>(snapshot: &'a Value, id: &str) -> Option<&'a Value>`.

- [ ] **Step 1: Write the failing tests.** In `view.rs`'s test module, next to the existing tests, add (adapt the fixture call to the module's existing `entry(...)` helper and its `SessionFile` construction):

```rust
#[test]
fn a_view_carries_its_tmux_pane_and_distro() {
    let mut e = entry("a", State::Working, NOW - 5, NOW - 5);
    e.file.tmux = Some(Tmux { socket: "/tmp/tmux-1001/klepsydra".into(), pane: "%3".into() });
    e.file.host = Some(Host { boot: "b".into(), distro: Some("Ubuntu".into()) });
    let v = view(&e, NOW).unwrap();
    assert_eq!(v.tmux.as_ref().map(|t| t.pane.as_str()), Some("%3"));
    assert_eq!(v.distro.as_deref(), Some("Ubuntu"));
}

#[test]
fn a_view_without_tmux_has_none() {
    let v = view(&entry("a", State::Working, NOW - 5, NOW - 5), NOW).unwrap();
    assert_eq!((v.tmux, v.distro), (None, None));
}
```

In `session.rs`'s tests add:

```rust
#[test]
fn tmux_and_host_parse_and_are_optional() {
    let with = r#"{"v":1,"session_id":"11111111-2222-4333-8444-555555555555","state":"working","state_at":1800000000,
        "tmux":{"socket":"/tmp/s","pane":"%3"},"host":{"boot":"b","distro":null}}"#;
    let f: SessionFile = serde_json::from_str(with).unwrap();
    assert_eq!(f.tmux.unwrap().pane, "%3");
    assert_eq!(f.host.unwrap().distro, None);
    let without = r#"{"v":1,"session_id":"11111111-2222-4333-8444-555555555555","state":"working","state_at":1800000000}"#;
    let f: SessionFile = serde_json::from_str(without).unwrap();
    assert_eq!((f.tmux, f.host), (None, None));
}
```

Create `src-tauri/fleet/src/lookup.rs` with its test:

```rust
//! A session in a published snapshot, by id.

use serde_json::Value;

/// The session `id` in `snapshot` (`{"sessions": [...]}`), if it is there.
pub fn session<'a>(snapshot: &'a Value, id: &str) -> Option<&'a Value> {
    snapshot
        .get("sessions")?
        .as_array()?
        .iter()
        .find(|s| s.get("session_id").and_then(Value::as_str) == Some(id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn finds_a_session_by_id_and_nothing_else() {
        let s = json!({"sessions": [{"session_id": "a", "status": "ended"}, {"session_id": "b"}]});
        assert_eq!(session(&s, "a").unwrap()["status"], "ended");
        assert!(session(&s, "c").is_none());
        assert!(session(&json!({}), "a").is_none());
    }
}
```

In `hub.rs`'s tests add:

```rust
#[test]
fn latest_is_the_last_published_snapshot() {
    let hub: Hub<Recorder> = Hub::default();
    assert_eq!(hub.latest(), None);
    hub.publish(json!({"sessions": []}));
    hub.publish(json!({"sessions": [1]}));
    assert_eq!(hub.latest(), Some(json!({"sessions": [1]})));
}
```

(Use whatever test sink type `hub.rs`'s tests already define in place of `Recorder`.)

- [ ] **Step 2: Run to see them fail**

Run: `cd src-tauri && cargo test -p klepsydra-fleet 2>&1 | tail -5; cd ..`
Expected: compile errors: no field `tmux`/`host`, no `latest`. (Check the crate name in `src-tauri/fleet/Cargo.toml`; use it for `-p`.)

- [ ] **Step 3: Implement.** In `session.rs`, after `Ended`:

```rust
/// The tmux pane a session runs in.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Tmux {
    pub socket: String,
    pub pane: String,
}

/// The kernel boot and WSL distro a session runs on.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Host {
    pub boot: String,
    #[serde(default)]
    pub distro: Option<String>,
}
```

and in `SessionFile` after `written_at`:

```rust
    #[serde(default)]
    pub tmux: Option<Tmux>,
    #[serde(default)]
    pub host: Option<Host>,
```

In `view.rs`, add to `View` after `quiet_since`:

```rust
    pub tmux: Option<Tmux>,
    pub distro: Option<String>,
```

and in `view()`'s `Some(View { … })` literal:

```rust
        tmux: f.tmux.clone(),
        distro: f.host.as_ref().and_then(|h| h.distro.clone()),
```

Import `Tmux` (and `Host` in tests) from `crate::session`. Fix every other `SessionFile { … }` or `View { … }` struct literal the compiler flags by adding `tmux: None, host: None` / `tmux: None, distro: None`.

In `hub.rs`, inside `impl<S: Sink> Hub<S>`:

```rust
    /// The last snapshot published, if any.
    pub fn latest(&self) -> Option<Value> {
        lock(&self.last).and_then(|l| l.clone())
    }
```

Add `pub mod lookup;` to `lib.rs`.

- [ ] **Step 4: Run all gates for Rust**

Run: `cd src-tauri && cargo fmt --all && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace 2>&1 | grep -E "test result|FAILED"; cd ..`
Expected: every `test result: ok`.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/fleet/src
git commit -m "feat(fleet): carry each session's tmux pane and distro to the wall"
```

### Task 5: `launch.rs`, the one process the app starts

**Files:**
- Create: `src-tauri/src/launch.rs`
- Modify: `src-tauri/src/main.rs` (`mod launch;`, `.manage(launch::InFlight::default())` in `with_state`, `launch::launch_session` in `generate_handler!`)
- Modify: `src/guards.test.js` (narrow the spawn and wsl guards)

**Interfaces:**
- Consumes: `crate::read_prefs(&AppHandle) -> Option<serde_json::Map<String, Value>>` (main.rs), `klepsydra_fleet::lookup::session`.
- Produces: `pub const WSL_EXE`, `pub struct InFlight`, `pub struct Target { socket, pane, distro }`, `pub fn target(snapshot: &Value, id: &str) -> Option<Target>`, `pub fn tmux_jump(app: &tauri::AppHandle, t: &Target) -> Result<String, String>`, `#[tauri::command] pub async fn launch_session(app) -> Result<String, String>`.

- [ ] **Step 1: Write the failing guard tests.** In `src/guards.test.js`, replace the bodies of `test("nothing starts a process", …)` and `test("nothing names wsl", …)` with:

```js
// The launcher is the one file allowed to start a process and name wsl.
const LAUNCHER = "src-tauri/src/launch.rs";

test("only the launcher starts a process", () => {
  assert.ok(RUST.includes(LAUNCHER), `${LAUNCHER} not found`);
  for (const f of [...RUST, ...FRONTEND, ...MANIFESTS, ...CONFIG].filter((f) => f !== LAUNCHER)) {
    assert.deepEqual(spawns(read(f)), [], f);
  }
});

test("the launcher starts only wsl.exe, from its fixed path, without a window", () => {
  const src = read(LAUNCHER);
  assert.deepEqual([...src.matchAll(/Command::new\(([^)]*)\)/g)].map((m) => m[1].trim()), ["WSL_EXE"]);
  assert.match(src, /pub const WSL_EXE: &str = r"C:\\Windows\\System32\\wsl\.exe";/);
  assert.match(src, /creation_flags\(CREATE_NO_WINDOW\)/);
  assert.doesNotMatch(src, /"--"/, "wsl.exe -- runs a shell; use -e");
});

test("nothing but the launcher names wsl", () => {
  for (const f of [...RUST, ...FRONTEND, ...CONFIG].filter((f) => f !== LAUNCHER)) {
    assert.equal(mentionsWsl(read(f)), false, f);
  }
  assert.equal(mentionsWsl('let x = "C:\\\\Windows\\\\System32\\\\wsl.exe";'), true);
});
```

- [ ] **Step 2: Run to see them fail**

Run: `node --test src/guards.test.js 2>&1 | grep -E "^not ok|^# (pass|fail)"`
Expected: "only the launcher starts a process" and "the launcher starts only wsl.exe…" fail (`launch.rs not found` / ENOENT).

- [ ] **Step 3: Write `src-tauri/src/launch.rs`** with its unit tests:

```rust
//! The one place klepsydra starts a process: wsl.exe, from a click, one call
//! at a time, running ~/.claude/klepsydra-launch.sh to start a session or
//! bring a session's tmux window forward.

use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;
use tauri::Manager;

/// The only program klepsydra starts.
pub const WSL_EXE: &str = r"C:\Windows\System32\wsl.exe";
/// The launcher, relative to the WSL home (`--cd ~`).
const SCRIPT: &str = ".claude/klepsydra-launch.sh";
/// Longest wait for wsl.exe to finish.
#[cfg(windows)]
const TIMEOUT: Duration = Duration::from_secs(20);

/// Set while a call runs; a click meanwhile is refused.
#[derive(Default)]
pub struct InFlight(pub Mutex<bool>);

/// A session's tmux pane and the distro it runs in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub socket: String,
    pub pane: String,
    pub distro: String,
}

fn distro_ok(d: &str) -> bool {
    (1..=64).contains(&d.len()) && d.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

fn dir_ok(d: &str) -> bool {
    (d == "~" || d.starts_with("~/") || d.starts_with('/'))
        && d.len() <= 1024
        && !d.chars().any(char::is_control)
}

fn socket_ok(s: &str) -> bool {
    s.starts_with('/')
        && s.len() <= 256
        && s.chars().all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c))
}

fn pane_ok(p: &str) -> bool {
    (2..=10).contains(&p.len())
        && p.starts_with('%')
        && p[1..].chars().all(|c| c.is_ascii_digit())
}

/// wsl.exe's arguments to start a session in `dir`.
pub fn new_args(dir: &str, distro: Option<&str>) -> Result<Vec<String>, String> {
    if !dir_ok(dir) {
        return Err(format!("launch_dir must start with ~ or /: {dir}"));
    }
    let mut a: Vec<String> = Vec::new();
    if let Some(d) = distro {
        if !distro_ok(d) {
            return Err(format!("launch_distro is not a distro name: {d}"));
        }
        a.extend(["-d".into(), d.into()]);
    }
    a.extend(["--cd", "~", "-e", "bash", "-l", SCRIPT, "new", dir].map(String::from));
    Ok(a)
}

/// wsl.exe's arguments to bring `t`'s tmux window forward.
pub fn jump_args(t: &Target) -> Result<Vec<String>, String> {
    if !(distro_ok(&t.distro) && socket_ok(&t.socket) && pane_ok(&t.pane)) {
        return Err("This session's tmux pane cannot be named safely.".into());
    }
    Ok([
        "-d", &t.distro, "--cd", "~", "-e", "bash", SCRIPT, "jump", &t.socket, &t.pane,
    ]
    .map(String::from)
    .to_vec())
}

/// Session `id`'s tmux pane and distro from a published snapshot.
pub fn target(snapshot: &Value, id: &str) -> Option<Target> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let tmux = s.get("tmux")?;
    Some(Target {
        socket: tmux.get("socket")?.as_str()?.into(),
        pane: tmux.get("pane")?.as_str()?.into(),
        distro: s.get("distro")?.as_str()?.into(),
    })
}

/// Run `f` unless another call is running.
pub fn gated<T>(flight: &InFlight, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    {
        let mut busy = flight.0.lock().map_err(|_| "The launcher's lock was poisoned.")?;
        if *busy {
            return Err("A launch is already running.".into());
        }
        *busy = true;
    }
    let r = f();
    if let Ok(mut busy) = flight.0.lock() {
        *busy = false;
    }
    r
}

/// wsl.exe writes its own messages as UTF-16LE and the Linux side's as UTF-8.
fn decode(b: &[u8]) -> String {
    let utf16 = b.len() >= 2 && b.len() % 2 == 0 && b.iter().skip(1).step_by(2).all(|&x| x == 0);
    if utf16 {
        let units: Vec<u16> = b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(b).into_owned()
    }
}

/// The last non-blank line, at most 200 characters.
fn last_line(text: &str) -> String {
    let line = text.lines().map(str::trim).filter(|l| !l.is_empty()).last().unwrap_or("");
    line.chars().take(200).collect()
}

#[cfg(windows)]
fn run(args: &[String]) -> Result<String, String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::time::Instant;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut child = Command::new(WSL_EXE)
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start {WSL_EXE}: {e}"))?;
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                return Err("WSL did not answer within 20 seconds.".into());
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let (stdout, stderr) = (last_line(&decode(&out.stdout)), last_line(&decode(&out.stderr)));
    if out.status.success() {
        Ok(stdout)
    } else if stderr.is_empty() {
        Err(if stdout.is_empty() { format!("wsl.exe exited with {}.", out.status) } else { stdout })
    } else {
        Err(stderr)
    }
}

#[cfg(not(windows))]
fn run(_args: &[String]) -> Result<String, String> {
    Err("Starting a session works on Windows only.".into())
}

/// Bring `t`'s tmux window to the front of its session.
pub fn tmux_jump(app: &tauri::AppHandle, t: &Target) -> Result<String, String> {
    let args = jump_args(t)?;
    gated(&app.state::<InFlight>(), || run(&args))
}

/// Start `claude` in the `launch_dir` pref as a window of the fleet session.
#[tauri::command]
pub async fn launch_session(app: tauri::AppHandle) -> Result<String, String> {
    let prefs = crate::read_prefs(&app).unwrap_or_default();
    let dir = prefs.get("launch_dir").and_then(Value::as_str).unwrap_or("~").to_owned();
    let distro = prefs.get("launch_distro").and_then(Value::as_str).map(str::to_owned);
    let args = new_args(&dir, distro.as_deref())?;
    tauri::async_runtime::spawn_blocking(move || gated(&app.state::<InFlight>(), || run(&args)))
        .await
        .map_err(|e| format!("Could not run the launch: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn new_args_pass_the_folder_as_one_argument() {
        let a = new_args("~/my repos;x", None).unwrap();
        assert_eq!(a, ["--cd", "~", "-e", "bash", "-l", SCRIPT, "new", "~/my repos;x"]);
        let a = new_args("/home/aj", Some("Ubuntu")).unwrap();
        assert_eq!(&a[..2], ["-d", "Ubuntu"]);
    }

    #[test]
    fn new_args_refuse_a_relative_folder_or_a_bad_distro() {
        assert!(new_args("repos", None).is_err());
        assert!(new_args("~/a\nb", None).is_err());
        assert!(new_args("~", Some("Ub untu")).is_err());
        assert!(new_args("~", Some("")).is_err());
    }

    #[test]
    fn jump_args_refuse_anything_but_a_plain_pane_and_socket() {
        let ok = Target { socket: "/tmp/tmux-1001/klepsydra".into(), pane: "%3".into(), distro: "Ubuntu".into() };
        assert_eq!(jump_args(&ok).unwrap()[6..], [SCRIPT, "jump", "/tmp/tmux-1001/klepsydra", "%3"]);
        for bad in [
            Target { pane: "%3;x".into(), ..ok.clone() },
            Target { pane: "3".into(), ..ok.clone() },
            Target { socket: "rel".into(), ..ok.clone() },
            Target { socket: "/tmp/a b".into(), ..ok.clone() },
            Target { distro: "a;b".into(), ..ok.clone() },
        ] {
            assert!(jump_args(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn target_needs_both_tmux_and_distro() {
        let s = json!({"sessions": [
            {"session_id": "a", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu"},
            {"session_id": "b", "tmux": {"socket": "/s", "pane": "%1"}, "distro": null},
            {"session_id": "c", "tmux": null, "distro": "Ubuntu"}]});
        assert_eq!(target(&s, "a").unwrap().pane, "%1");
        assert!(target(&s, "b").is_none());
        assert!(target(&s, "c").is_none());
    }

    #[test]
    fn a_call_while_one_runs_is_refused_and_the_gate_reopens() {
        let flight = InFlight::default();
        let inner = gated(&flight, || Ok(gated(&flight, || Ok(()))));
        assert_eq!(inner.unwrap(), Err("A launch is already running.".into()));
        assert!(gated(&flight, || Ok(())).is_ok());
        let _ = gated::<()>(&flight, || Err("x".into()));
        assert!(gated(&flight, || Ok(())).is_ok(), "an error reopens the gate");
    }

    #[test]
    fn decode_reads_both_encodings_and_last_line_trims() {
        assert_eq!(decode(b"ok\n"), "ok\n");
        let utf16: Vec<u8> = "Error: no distro\r\n".encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(last_line(&decode(&utf16)), "Error: no distro");
        assert_eq!(last_line("a\n\n  b  \n\n"), "b");
        assert_eq!(last_line(&"x".repeat(300)).len(), 200);
    }
}
```

`launch.rs` contains no `"--"` literal (the guard checks it), and its only `Command::new` is `Command::new(WSL_EXE)`.

- [ ] **Step 4: Wire it into `main.rs`.** Add `mod launch;` beside `mod jump;`. In `with_state`, add `.manage(launch::InFlight::default())`. In `generate_handler!`, add `launch::launch_session`. If `read_prefs` is declared `fn read_prefs`, child modules can already call `crate::read_prefs`.

- [ ] **Step 5: Run all gates**

Run: `node --test src/*.test.js 2>&1 | grep -E "^# (pass|fail)" && (cd src-tauri && cargo fmt --all && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace 2>&1 | grep -E "test result|FAILED")`
Expected: `# fail 0`; every `test result: ok`. The managed-state guard test in `main.rs` (`every_managed_state_has_a_type_of_its_own`) passes because `InFlight` is its own struct; if it lists types explicitly, add `InFlight` to its list.

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/launch.rs src-tauri/src/main.rs src/guards.test.js
git commit -m "feat: launch.rs, the one place klepsydra starts wsl.exe"
```

### Task 6: Jump goes through tmux first

**Files:**
- Modify: `src-tauri/src/jump.rs` (`jump_to_terminal` signature and body; new `jump_settled`)
- Modify: `src/fleet/wall.js` (pass `id` to `jump_to_terminal`)

**Interfaces:**
- Consumes: `crate::fleet::Fleet` (`Hub::latest`), `crate::launch::{target, tmux_jump}`.
- Produces: `jump_to_terminal(app, id: String, name: String) -> Result<String, String>`.

- [ ] **Step 1: Write the failing JS test.** In `src/guards.test.js` (or `src/fleet-style.test.js`, whichever already reads `src/fleet/wall.js` as text), add:

```js
test("the wall's Jump passes the session id along with its name", () => {
  const src = read("src/fleet/wall.js");
  assert.match(src, /invoke\("jump_to_terminal", \{ id: button\.dataset\.id, name: button\.dataset\.name \}\)/);
});
```

- [ ] **Step 2: Run to see it fail**

Run: `node --test src/*.test.js 2>&1 | grep -E "^not ok"`
Expected: the new test fails.

- [ ] **Step 3: Implement.** In `jump.rs`, replace `jump_to_terminal` with:

```rust
/// The outcome in a sentence for the card: Ok when the tab was selected,
/// Err when nothing was done. A session in tmux has its window selected first,
/// so its tab shows that session's title.
#[tauri::command]
pub async fn jump_to_terminal(app: tauri::AppHandle, id: String, name: String) -> Result<String, String> {
    use tauri::Manager;
    let target = app
        .state::<crate::fleet::Fleet>()
        .latest()
        .and_then(|v| crate::launch::target(&v, &id));
    tauri::async_runtime::spawn_blocking(move || match target {
        Some(t) if crate::launch::tmux_jump(&app, &t).is_ok() => jump_settled(&name),
        _ => jump(&name),
    })
    .await
    .map_err(|e| format!("Could not run the jump: {e}"))?
}

/// Jump by title, retrying for up to 1.5 s while the tab takes the title of
/// the tmux window just selected.
fn jump_settled(name: &str) -> Result<String, String> {
    let mut last = jump(name);
    for _ in 0..6 {
        if last.is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
        last = jump(name);
    }
    last
}
```

`jump.rs` must not contain the text `wsl` (guard). In `src/fleet/wall.js`'s `paint`, after `jump.dataset.name = c.session ?? "";` add `jump.dataset.id = c.id;`, and change the invoke to:

```js
    note.textContent = await window.__TAURI__.core.invoke("jump_to_terminal", { id: button.dataset.id, name: button.dataset.name });
```

- [ ] **Step 4: Run all gates** (same command as Task 5 Step 5).
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/jump.rs src/fleet/wall.js src/guards.test.js
git commit -m "feat(fleet): Jump selects a session's tmux window before its tab"
```

### Task 7: Clear

**Files:**
- Create: `src-tauri/fleet/src/clear.rs`; Modify: `src-tauri/fleet/src/lib.rs` (`pub mod clear;`)
- Modify: `src-tauri/src/fleet.rs` (`clear_session` command), `src-tauri/src/main.rs` (`fleet::clear_session` in `generate_handler!`)
- Modify: `src/fleet/model.js` (`clear` on a card), `src/wall.html` (button), `src/fleet/wall.js` (handler)
- Test: `src/fleet-model.test.js`

**Interfaces:**
- Consumes: `session::is_session_id`, `lookup::session`, `Hub::latest`, `crate::klepsydra_dir(&AppHandle) -> Option<PathBuf>`.
- Produces: `clear::clearable(status: &str) -> bool`, `clear::remove_session(fleet: &Path, id: &str) -> Result<(), String>`; card field `clear: boolean`; Tauri command `clear_session(id)`.

- [ ] **Step 1: Write the failing Rust tests** in a new `src-tauri/fleet/src/clear.rs`:

```rust
//! Clear: remove an ended or silent session's two files from the wall.

use std::io::ErrorKind;
use std::path::Path;

use crate::session::is_session_id;

/// Whether a card with this status may be cleared.
pub fn clearable(status: &str) -> bool {
    matches!(status, "ended" | "silent")
}

/// Delete `<id>.json` and `<id>.beat` in `fleet`, each only if it is a regular
/// file; anything else there leaves both in place.
pub fn remove_session(fleet: &Path, id: &str) -> Result<(), String> {
    if !is_session_id(id) {
        return Err("Not a session id.".into());
    }
    match std::fs::symlink_metadata(fleet) {
        Ok(m) if m.is_dir() => {}
        _ => return Err("The fleet folder is missing or not a plain folder.".into()),
    }
    let mut doomed = Vec::new();
    for ext in ["json", "beat"] {
        let p = fleet.join(format!("{id}.{ext}"));
        match std::fs::symlink_metadata(&p) {
            Ok(m) if m.is_file() => doomed.push(p),
            Ok(_) => return Err(format!("{id}.{ext} is not a plain file, so nothing was removed.")),
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    for p in doomed {
        std::fs::remove_file(&p).map_err(|e| format!("Could not remove {}: {e}", p.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "11111111-2222-4333-8444-555555555555";

    fn fleet() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn only_ended_and_silent_are_clearable() {
        for s in ["ended", "silent"] {
            assert!(clearable(s));
        }
        for s in ["working", "needs_you", "done", "new", "error", ""] {
            assert!(!clearable(s), "{s}");
        }
    }

    #[test]
    fn removes_both_files_and_nothing_else() {
        let d = fleet();
        for f in [format!("{ID}.json"), format!("{ID}.beat"), "other.json".into()] {
            std::fs::write(d.path().join(f), "x").unwrap();
        }
        remove_session(d.path(), ID).unwrap();
        let left: Vec<_> = std::fs::read_dir(d.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(left, ["other.json"]);
    }

    #[test]
    fn a_missing_beat_is_fine() {
        let d = fleet();
        std::fs::write(d.path().join(format!("{ID}.json")), "x").unwrap();
        remove_session(d.path(), ID).unwrap();
    }

    #[test]
    fn refuses_a_bad_id_and_a_path() {
        let d = fleet();
        assert!(remove_session(d.path(), "../x").is_err());
        assert!(remove_session(d.path(), &format!("{ID}/..")).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_never_followed_or_removed() {
        let d = fleet();
        let outside = fleet();
        let target = outside.path().join("keep");
        std::fs::write(&target, "x").unwrap();
        std::fs::write(d.path().join(format!("{ID}.json")), "x").unwrap();
        std::os::unix::fs::symlink(&target, d.path().join(format!("{ID}.beat"))).unwrap();
        assert!(remove_session(d.path(), ID).is_err());
        assert!(target.exists());
        assert!(d.path().join(format!("{ID}.json")).exists(), "nothing removed");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_fleet_folder_is_refused() {
        let real = fleet();
        let d = fleet();
        let link = d.path().join("fleet");
        std::os::unix::fs::symlink(real.path(), &link).unwrap();
        std::fs::write(real.path().join(format!("{ID}.json")), "x").unwrap();
        assert!(remove_session(&link, ID).is_err());
        assert!(real.path().join(format!("{ID}.json")).exists());
    }
}
```

If `tempfile` is not already a dev-dependency of the fleet crate, use the scratch-dir helper the crate's other tests use (`scan.rs` and `watch.rs` tests make temp dirs; reuse theirs) and do not add a dependency.

Add `pub mod clear;` to `lib.rs`.

In `src/fleet-model.test.js`, using its existing `session(...)` builder:

```js
test("only an ended or silent card offers Clear", () => {
  for (const status of ["ended", "silent"]) assert.equal(card(session({ status }), cast, now).clear, true, status);
  for (const status of ["working", "needs_you", "done", "new", "error"]) {
    assert.equal(card(session({ status }), cast, now).clear, false, status);
  }
});
```

(Match the file's existing names for `cast` and the clock.)

- [ ] **Step 2: Run to see them fail**

Run: `node --test src/fleet-model.test.js 2>&1 | grep -E "^not ok"; (cd src-tauri && cargo test --workspace 2>&1 | grep -E "test result|error\[")`
Expected: the JS test fails (`clear` undefined); the Rust tests pass once `clear.rs` compiles (it is self-contained), which is fine: the command wiring below is what Step 3 adds.

- [ ] **Step 3: Implement the command and the card.** In `src-tauri/src/fleet.rs`:

```rust
/// Remove an ended or silent session's card. A session still running brings
/// its file back at its next hook event.
#[tauri::command]
pub fn clear_session(app: AppHandle, id: String) -> Result<(), String> {
    use klepsydra_fleet::clear::{clearable, remove_session};
    let latest = app.state::<Fleet>().latest();
    let status = latest
        .as_ref()
        .and_then(|v| klepsydra_fleet::lookup::session(v, &id))
        .and_then(|s| s.get("status")?.as_str().map(str::to_owned));
    match status {
        Some(s) if clearable(&s) => {}
        Some(_) => return Err("Only an ended or silent card can be cleared.".into()),
        None => return Err("That session is no longer on the wall.".into()),
    }
    let dir = crate::klepsydra_dir(&app).ok_or("klepsydra has no data folder.")?;
    remove_session(&dir.join("fleet"), &id)
}
```

Add `fleet::clear_session` to `generate_handler!`. In `src/fleet/model.js` `card()`, add after `jump: jumpable(s),`:

```js
    clear: s.status === "ended" || s.status === "silent",
```

In `src/wall.html`, inside `.actions` after the jump button:

```html
        <button type="button" class="clear" hidden
          title="Removes this card. A session that is still running brings it back at its next event, without its start time or the repos it touched.">Clear</button>
```

In `src/fleet/wall.js` `paint`, after the jump block's `jump.setAttribute(...)` line:

```js
  const clear = el.querySelector(".clear");
  clear.hidden = !c.clear;
  clear.dataset.id = c.id;
```

and extend the wall click handler: at its top,

```js
  const clearButton = e.target.closest(".clear");
  if (clearButton && !clearButton.disabled && inTauri) {
    const note = clearButton.parentElement.querySelector(".note");
    clearButton.disabled = true;
    try {
      await window.__TAURI__.core.invoke("clear_session", { id: clearButton.dataset.id });
    } catch (err) {
      note.textContent = String(err);
      clearButton.disabled = false;
    }
    return;
  }
```

In `src/fleet/wall.css`, add `.clear` to the selector that styles `.jump` so both buttons look alike.

- [ ] **Step 4: Rust test for the command's refusal.** The status check needs a live `AppHandle`, so pin it through the pure parts: add to `clear.rs` tests

```rust
    #[test]
    fn clear_refuses_a_live_session() {
        let snap = serde_json::json!({"sessions": [{"session_id": ID, "status": "working"}]});
        let s = crate::lookup::session(&snap, ID).unwrap()["status"].as_str().unwrap();
        assert!(!clearable(s));
    }
```

- [ ] **Step 5: Run all gates** (Task 5 Step 5 command).
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src-tauri src/fleet src/wall.html src/fleet-model.test.js
git commit -m "feat(fleet): Clear an ended or silent card from the wall"
```

### Task 8: The New session button

**Files:**
- Modify: `src/wall.html`, `src/fleet/wall.js`, `src/fleet/wall.css`
- Test: `src/guards.test.js`

**Interfaces:**
- Consumes: Tauri command `launch_session` (Task 5).

- [ ] **Step 1: Write the failing test** in `src/guards.test.js`:

```js
test("the wall has a New session button that calls the launcher", () => {
  assert.match(read("src/wall.html"), /<button type="button" id="new-session">\+ New session<\/button>/);
  assert.match(read("src/wall.html"), /<span id="new-note" role="status"><\/span>/);
  assert.match(read("src/fleet/wall.js"), /invoke\("launch_session"\)/);
});
```

- [ ] **Step 2: Run to see it fail**

Run: `node --test src/guards.test.js 2>&1 | grep -E "^not ok"`
Expected: the new test fails.

- [ ] **Step 3: Implement.** In `src/wall.html`, directly after `<body>`:

```html
  <div class="bar">
    <button type="button" id="new-session">+ New session</button>
    <span id="new-note" role="status"></span>
  </div>
```

In `src/fleet/wall.js`, after the `const tpl = …` line:

```js
const newButton = document.getElementById("new-session");
const newNote = document.getElementById("new-note");
newButton.hidden = !inTauri;
newButton.addEventListener("click", async () => {
  if (newButton.disabled) return;
  newButton.disabled = true;
  newNote.textContent = "Starting\u2026";
  try {
    newNote.textContent = await window.__TAURI__.core.invoke("launch_session");
  } catch (err) {
    newNote.textContent = String(err);
  } finally {
    newButton.disabled = false;
  }
});
```

In `src/fleet/wall.css`, add `.bar { display: flex; align-items: center; gap: var(--gap, 12px); margin-bottom: var(--gap, 12px); }` (use the gap token the file already defines) and add `#new-session` to the `.jump` button selector.

- [ ] **Step 4: Run all gates** (Task 5 Step 5 command).
Expected: all pass, including `fleet-style.test.js`'s contrast checks.

- [ ] **Step 5: Commit**

```bash
git add src/wall.html src/fleet/wall.js src/fleet/wall.css src/guards.test.js
git commit -m "feat(fleet): a New session button on the wall"
```

### Task 9: Docs

**Files:**
- Modify: `README.md` (Install line ~120; "The fleet strip" section ~299; a prefs note), `IMPL.md`, `ROADMAP.md`, `docs/superpowers/specs/2026-10-18-fleet-visualizer-design.md` (Addendum)

- [ ] **Step 1: README install.** Replace the two lines at ~120-121 with:

```
cp statusline/klepsydra-statusline.sh hooks/klepsydra-fleet.sh hooks/klepsydra-launch.sh hooks/klepsydra-tmux.conf ~/.claude/
chmod +x ~/.claude/klepsydra-statusline.sh ~/.claude/klepsydra-fleet.sh ~/.claude/klepsydra-launch.sh
```

- [ ] **Step 2: README fleet section.** Add a subsection "Starting sessions" stating: **+ New session** starts `claude` in `launch_dir` (prefs.json, default `~`) as a window of tmux session `fleet` on socket `klepsydra`; the first opens a Windows Terminal window named `fleet` with one tab; later ones add tmux windows to it; closing the tab leaves the sessions running and the next **+** or Jump reattaches; `launch_distro` picks the distro; tmux loads `~/.tmux.conf` first. Add rows to the status table: "ended · gone: the session's Claude process is gone (a reboot or `wsl --shutdown`)". Document Clear in one sentence with the come-back caveat. Add to the README's live-check list: "+ three times: one tab, three windows; Jump hops between them; close the tab, + reattaches."

- [ ] **Step 3: Addendum to the 2026-10-18 spec**, appended under its Addendum heading:

```
- Launching (#31, ruled 2026-10-20): the no-spawn and no-wsl constraints now exempt exactly `src-tauri/src/launch.rs`, which starts only `wsl.exe` from a click, one call at a time. Clear is the overlay's first write to `fleet/`. See `2026-10-20-fleet-launch-design.md`.
```

- [ ] **Step 4: IMPL.md** rewritten for this slice (30-50 lines, ✅/📋 per item); **ROADMAP.md** Completed log gets one dated line on merge.

- [ ] **Step 5: Commit**

```bash
git add README.md IMPL.md ROADMAP.md docs/superpowers/specs/2026-10-18-fleet-visualizer-design.md
git commit -m "docs: starting sessions from the wall, Clear and gone"
```

### Task 10: Deploy and live check on Windows

- [ ] **Step 1:** Copy the hooks: `cp hooks/klepsydra-fleet.sh hooks/klepsydra-launch.sh hooks/klepsydra-tmux.conf ~/.claude/ && chmod +x ~/.claude/klepsydra-fleet.sh ~/.claude/klepsydra-launch.sh` (back up `~/.claude/klepsydra-fleet.sh` to `.bak-launch` first).
- [ ] **Step 2:** Set AJ's pref: `jq '.launch_dir = "~/ajsoftworks"'` on `/mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra/prefs.json` (write via temp file, backup `.bak-launch`).
- [ ] **Step 3:** Build and install per `project_klepsydra` memory: `bash scripts/build-windows.sh </dev/null`, stop the running exe, run the installer with `/S`, start it, screenshot the live window rect.
- [ ] **Step 4:** Drive it: open the wall, invoke **+ New session** three times through UI Automation (button name "+ New session"). Check `tmux -L klepsydra list-windows -t =fleet` shows 3 windows, `tasklist.exe` shows one more `wsl.exe` for the tab only, and the wall shows three cards. Send `/rename` to two of them via `tmux -L klepsydra send-keys`, then Jump between them and confirm with `tmux -L klepsydra display -p '#{pane_id}'` and a screenshot that the tab title changed.
- [ ] **Step 5:** Close the tab (kill its client: `tmux -L klepsydra detach-client -s fleet`), press **+**, confirm one new tab attaches with 4 windows.
- [ ] **Step 6:** Clear an ended card (exit one session with `/exit` via send-keys), confirm the card disappears and its two files are gone.
- [ ] **Step 7:** Gone: write a fake non-ended session file with `host.boot` of another boot, start a session, confirm the card reads "ended · gone".

## Wall redesign (approved 2026-10-20)

**Spec:** `docs/superpowers/specs/2026-10-20-fleet-wall-redesign.md`, with its mockup PNG. Execution order: Tasks 1-8, then 11, 12, then 9 (docs cover both), then 10. The mockup's HTML and CSS are at `.superpowers/sdd/2026-10-20-fleet-launch/mockup-wall.html` (git-ignored; its image paths are local). Port its CSS, not its markup-building script.

### Task 11: The card model for the redesign

**Files:**
- Modify: `src/fleet/model.js`
- Test: `src/fleet-model.test.js`, `src/fleet-style.test.js`

**Interfaces:**
- Produces, on each `card()`: `task: string`, `tone: "needs"|"error"|"working"|"done"|"quiet"`, `pill: {label: string, age: string}`, `ask: string|null`, `arc: number` (0..1), `dim: boolean`, `place: {repo, worktree, branch}|null`, `also: string[]`, `voiceTitle: string|null`, `jump: {enabled, why}` (unchanged), `clear` (Task 7). Removes `statusLine` and `where` from the card. New exports `WORKING_FULL_S = 600`, `WAITING_FULL_S = 1800`, `askText(reason)`, `arcFraction(s, nowMs)`, `tally(sessions)`.

- [ ] **Step 1: Write the failing tests** in `src/fleet-model.test.js` (use the file's `session`, `CAST`, `NOW`, `ago`):

```js
import { askText, arcFraction, tally, WORKING_FULL_S, WAITING_FULL_S } from "./fleet/model.js";

test("the arc fills over the reader's own thresholds", () => {
  const view = readFileSync(new URL("../src-tauri/fleet/src/view.rs", import.meta.url), "utf8");
  const rs = (name) => Number(view.match(new RegExp(`pub const ${name}: i64 = (\\d+);`))[1]);
  assert.equal(WORKING_FULL_S, rs("QUIET_AFTER"));
  assert.equal(WAITING_FULL_S, rs("WAITING_DOUBT_AFTER"));
});

test("arc: working by 600 s, needs you by 1800 s, quiet working full, others empty", () => {
  assert.equal(arcFraction(session({ status: "working", status_at: ago(300) }), NOW), 0.5);
  assert.equal(arcFraction(session({ status: "working", status_at: ago(900) }), NOW), 1);
  assert.equal(arcFraction(session({ status: "working", status_at: ago(900), quiet_since: ago(700) }), NOW), 1);
  assert.equal(arcFraction(session({ status: "needs_you", status_at: ago(900) }), NOW), 0.5);
  for (const status of ["done", "error", "new", "silent", "ended"]) {
    assert.equal(arcFraction(session({ status, status_at: ago(900) }), NOW), 0, status);
  }
  assert.equal(arcFraction(session({ status: "working", status_at: undefined }), NOW), 0);
});

test("the ask line says what a session waits for", () => {
  assert.equal(askText("approve Bash"), "Waiting for you to approve Bash");
  assert.equal(askText("approve plan"), "Waiting for you to approve the plan");
  assert.equal(askText("question"), "Waiting for your answer");
  assert.equal(askText(null), "Waiting for you");
});

test("a card carries pill, ask, tone, dim, place and its voice as a tooltip", () => {
  const c = card(session(), CAST, NOW);
  assert.deepEqual(c.pill, { label: "needs you", age: "2m" });
  assert.equal(c.ask, "Waiting for you to approve Bash");
  assert.equal(c.tone, "needs");
  assert.equal(c.dim, false);
  assert.equal(c.task, "Plan the fleet visualizer");
  assert.deepEqual(c.place, { repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer" });
  assert.deepEqual(c.also, ["also in ideas"]);
  assert.equal(c.voiceTitle, "Voice: Michael");
  const quiet = card(session({ status: "silent", status_at: ago(360), name: null }), CAST, NOW);
  assert.deepEqual(quiet.pill, { label: "silent", age: "no word for 6m" });
  assert.equal(quiet.dim, true);
  assert.equal(quiet.ask, null);
  assert.equal(quiet.task, "No session name yet");
  const idle = card(session({ status: "working", status_at: ago(900), quiet_since: ago(720) }), CAST, NOW);
  assert.deepEqual(idle.pill, { label: "working?", age: "no activity for 12m" });
});

test("the tally counts what the bar shows", () => {
  const t = tally([
    session({ status: "needs_you" }), session({ status: "working" }), session({ status: "working" }),
    session({ status: "done" }), session({ status: "error" }), session({ status: "new" }),
    session({ status: "silent" }), session({ status: "ended" }),
  ]);
  assert.deepEqual(t, { needs: 1, working: 2, done: 1, error: 1, idle: 3 });
});
```

`also` lists touched repos as "also in <repo>" (one entry per repo, the file's order); an empty `touched` gives `[]`. In `src/fleet-style.test.js`, change the columns test to the new layout:

```js
test("the wall fits four columns at 1920 px and reflows below", () => {
  const wallCss = read("./fleet/wall.css");
  const px = (name) => parseFloat(token(wallCss, name));
  const tokens = { min: px("--card-min"), gap: px("--card-gap"), pad: px("--wall-pad") };
  const SCROLLBAR = 17;
  assert.equal(columnsAt(1920 - SCROLLBAR, tokens), 4);
  assert.equal(columnsAt(1280 - SCROLLBAR, tokens), 2);
  assert.equal(columnsAt(800 - SCROLLBAR, tokens), 1);
});
```

(Task 12 sets `--card-min: 420px; --card-gap: 16px; --wall-pad: 28px`; this test fails until then, which is expected and stays failing only until Task 12. Commit Task 11 with that one test marked `test.todo` and flip it in Task 12.)

- [ ] **Step 2: Run to see them fail**: `node --test src/fleet-model.test.js 2>&1 | grep -E "^not ok"`.

- [ ] **Step 3: Implement** in `src/fleet/model.js`:

```js
// The arc fills over the reader's thresholds (view.rs QUIET_AFTER, WAITING_DOUBT_AFTER).
export const WORKING_FULL_S = 600;
export const WAITING_FULL_S = 1800;

/** How full a card's arc is, 0..1: the time in the current state against its threshold. */
export function arcFraction(s, nowMs) {
  if (s.status === "working" && isQuiet(s)) return 1;
  const full = { working: WORKING_FULL_S, needs_you: WAITING_FULL_S }[s.status];
  const age = ageMs(s.status_at, nowMs);
  if (!full || !Number.isFinite(age)) return 0;
  return Math.min(1, Math.max(0, age / 1000 / full));
}

/** The needs-you line: what the session waits for. */
export function askText(reason) {
  if (reason === "question") return "Waiting for your answer";
  if (reason === "approve plan") return "Waiting for you to approve the plan";
  return reason ? `Waiting for you to ${reason}` : "Waiting for you";
}

const DIM = new Set(["new", "silent", "ended"]);

/** Counts for the summary bar. */
export function tally(sessions) {
  const t = { needs: 0, working: 0, done: 0, error: 0, idle: 0 };
  for (const s of sessions) {
    if (s.status === "needs_you") t.needs++;
    else if (s.status === "working") t.working++;
    else if (s.status === "done") t.done++;
    else if (s.status === "error") t.error++;
    else t.idle++;
  }
  return t;
}
```

`pill.age` is the last part of `statusParts(s, nowMs)` when the status is silent or quiet (the "no word for" / "no activity for" text), else the short age; `pill.label` is `statusOf(s.status, isQuiet(s)).label`. In `card()`, add `task: s.name || "No session name yet"`, `tone: statusOf(s.status, isQuiet(s)).tone`, `pill`, `ask: s.status === "needs_you" ? askText(s.reason) : null`, `arc: arcFraction(s, nowMs)`, `dim: DIM.has(s.status)`, `place: s.where ? { repo: s.where.repo, worktree: s.where.worktree ?? null, branch: s.where.branch ?? null } : null`, `also`, `voiceTitle: who.voice ? \`Voice: ${who.voice}\` : null`; drop `statusLine`, `where` and `voice` from the card object. Keep `statusLine`, `whereText` exported only if something else still imports them; otherwise delete them and their tests (DRY).

- [ ] **Step 4: Run** `node --test src/*.test.js` → all pass except the `test.todo`.
- [ ] **Step 5: Commit** `git commit -m "feat(fleet): the card model for the redesigned wall"`.

### Task 12: The redesigned wall

**Files:**
- Modify: `src/wall.html`, `src/fleet/wall.js`, `src/fleet/wall.css`
- Test: `src/fleet-style.test.js`, `src/guards.test.js`

**Interfaces:**
- Consumes: Task 11's card fields and `tally`; Task 7's `.clear` button; Task 8's bar.

- [ ] **Step 1: Write the failing tests** in `src/fleet-style.test.js`: flip the four-column test from `test.todo` to `test`, and add:

```js
test("the wall's text meets 4.5:1 on live and quiet cards", () => {
  const css = read("./fleet/wall.css");
  for (const bg of ["--card-bg", "--card-quiet"]) {
    for (const fg of ["--text", "--text-dim", "--text-error"]) {
      const r = contrast(token(css, fg), token(css, bg));
      assert.ok(r >= 4.5, `${fg} on ${bg}: ${r.toFixed(2)}`);
    }
  }
  assert.ok(contrast(token(css, "--tone-working"), token(css, "--card-bg")) >= 3, "working arc and edge");
});

test("the arc and the dimming respect reduced motion and keep the face visible", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(css, /\.card\.dim \.face \{[^}]*filter:/);
});
```

and in `src/guards.test.js`, extend Task 8's bar test: `assert.match(read("src/wall.html"), /<div class="tally"/);` and `assert.match(read("src/wall.html"), />Open terminal</);`.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Markup.** In `src/wall.html`: the bar gets `<div class="tally" aria-label="Session counts"></div>` before the New session button. The card template becomes (keep `tabindex="-1"` and the live region):

```html
    <article class="card" tabindex="-1">
      <header>
        <span class="portrait">
          <svg class="arc" viewBox="0 0 80 80" aria-hidden="true">
            <circle class="track" cx="40" cy="40" r="37"/><circle class="fill" cx="40" cy="40" r="37" pathLength="1"/>
          </svg>
          <img class="face" alt="" />
        </span>
        <div class="who"><h2 class="name"></h2><p class="task"></p></div>
        <p class="pill"><span class="mark"></span><span class="label"></span> <span class="age"></span></p>
      </header>
      <p class="where"><span class="repo"></span><span class="branch" hidden></span></p>
      <ul class="also"></ul>
      <p class="ask" hidden><span class="mark"></span><span class="text"></span></p>
      <p class="error" hidden></p>
      <div class="said">
        <p class="prompt"></p>
        <p class="reply"></p>
      </div>
      <p class="updated" hidden></p>
      <footer class="actions">
        <span class="note" role="status"></span>
        <button type="button" class="clear" hidden title="Removes this card. A session that is still running brings it back at its next event, without its start time or the repos it touched.">Clear</button>
        <button type="button" class="jump">Open terminal</button>
      </footer>
    </article>
```

The branch chip's git icon is inline SVG set once in `paint` from a constant (copy the mockup's `branchIcon`). The arc uses `pathLength="1"`, so `stroke-dasharray: ${arc} 1` draws the fraction; when `arc` is 0, hide `.fill`.

- [ ] **Step 4: Paint.** In `src/fleet/wall.js` `paint(el, c)`: set `el.className = \`card ${c.dim ? "dim" : ""} tone-${c.tone}\``; the portrait's `title` to `c.voiceTitle ?? ""`; `.task` text; pill badge (`c.badge`), `.label` = `c.pill.label`, `.age` = `c.pill.age`; ask line shown when `c.ask`, its mark = `c.badge`; `.repo` text = `c.place ? [c.place.repo, c.place.worktree].filter(Boolean).join(" / ") : ""`; branch chip shown when `c.place?.branch`; `.also` items from `c.also`; prompt/reply text with `title` set to the full text; a disabled Open terminal button carries `c.jump.why` in its `title` (no note). Results of Open terminal and Clear go to `.note` and clear after 8 s (`setTimeout`, cancelled when a new result arrives). In `render()`, fill `.tally` from `tally(sessions)`: one `<span class="t-needs">` etc. per non-zero count except needs, working, done, idle always shown (error only when > 0), each `<b>N</b> label` built with `textContent`, labels "needs you", "working", "done", "error", "idle or ended".

- [ ] **Step 5: Style.** Rewrite `src/fleet/wall.css` from the mockup's `<style>`: tokens per the spec's table plus `--card-min: 420px; --card-gap: 16px; --wall-pad: 28px; --wall-face: 80px; --text-error` (keep its value if it passes the 4.5:1 test, else lighten to the first value that does); `--badge-ring: var(--card-bg)` inside `.card`; selectors renamed to the template above (`.card.dim` for the mockup's `.card.quiet`, `.tone-needs` etc. setting `--tone`). Add `@media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }`. Keep `.visually-hidden`, `#empty`, focus outlines (`.card:focus`, `button:focus-visible`).

- [ ] **Step 6: Run all gates** (Task 5 Step 5 command) → pass.

- [ ] **Step 7: Render and compare.** Serve `src/` with `python3 -m http.server -d src 8765` in the background, and open `wall.html` at 1920x1080 with Playwright (Chromium at `~/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome`). Outside Tauri the feed is empty, so inject the eight sample sessions from the mockup via `page.evaluate` into the same `receive` path (export nothing new; add a `?demo` query that `feed.js` honours only when `!inTauri`, reading `fleet/demo.json`, and add `src/fleet/demo.json` with the mockup's eight sessions in reader-snapshot shape). Screenshot to `.superpowers/sdd/2026-10-20-fleet-launch/wall-built.png` and compare against `docs/superpowers/specs/2026-10-20-fleet-wall-mockup.png`. Fix any difference in layout, hierarchy or colour before committing. Kill the server.

- [ ] **Step 8: Commit** `git commit -m "feat(fleet): redesign the wall: water-clock arc, status first, quiet cards step back"`.

## A stable jump (approved by AJ 2026-10-20: "a fully stable system")

Execution order now: Tasks 1-8, 11, 12, **13**, then 9, then 10. Spec: the launch design's "Addendum 2026-10-20: a stable jump".

### Task 13: Jump verifies the pane's process and finds the fleet tab by its own title

**Files:**
- Modify: `hooks/klepsydra-launch.sh` (`jump` takes `PID START`; `show`/`open_tab` pass `--title` and `--suppressApplicationTitle`), `hooks/klepsydra-tmux.conf`, `hooks/test_launch.sh`
- Modify: `src-tauri/fleet/src/session.rs` and `view.rs` (the session file's `claude: {pid, start}` reaches the View as `claude`)
- Modify: `src-tauri/src/launch.rs` (`Target` gains `pid: u32, start: u64`; `jump_args` passes them; `target()` reads `claude.pid`/`claude.start`), `src-tauri/src/jump.rs` (the tmux path matches the fixed title `FLEET_TAB = "klepsydra fleet"`, single attempt, then `settle`)
- Test: the files above plus `src/guards.test.js` if a guard needs updating

**Interfaces:**
- Script: `klepsydra-launch.sh jump SOCKET PANE PID START`. PID and START are digits; START is field 22 of `/proc/PID/stat`, clock ticks since boot, which is what the hook records as `claude.start`.
- View JSON: `claude: {pid: number, start: number} | null`.
- Rust: `pub struct Target { socket, pane, distro, pid: u32, start: u64 }`. `pub const FLEET_TAB: &str = "klepsydra fleet";` lives in `launch.rs` and is used by the script call and jump.rs. The script takes the title from one constant too, `TAB_TITLE="klepsydra fleet"`, and a guard test asserts the two are equal.

- [ ] **Step 1: Failing tests.**
  - `hooks/test_launch.sh`:
    - (a) `jump` with the pane's real Claude: use the test's `sleep 600` process; its pid comes from `#{pane_pid}` and its start from `/proc/<pid>/stat` field 22. It succeeds, because the pane process is its own ancestor (the walk includes the pid itself).
    - (b) The right pane, but the PID of another pane's process: refused with "That session's tmux pane now belongs to another session." and no window change.
    - (c) A dead PID: refused with the same message.
    - (d) The right PID with a wrong START (pid reused): refused.
    - (e) Malformed PID or START (`12a`, empty): refused with "Not a process id: …".
    - (f) The tab command now contains `--title klepsydra fleet --suppressApplicationTitle` before `wsl.exe` (update the expected `wt.log` lines).
    - (g) `show -gv automatic-rename-format` is `#{pane_title}` on the fleet server.
  - Rust: `jump_args` includes pid and start and refuses `pid == 0`; `target()` needs `claude` too; the View test reads `claude`; `SessionFile` parses `claude: null` and a missing `claude`.
  - jump.rs: a pure helper `fleet_tab_titles_match(title) -> bool`, or reuse `tabs::pick_tab(FLEET_TAB, …)`, with a unit test that only the exact title matches.

- [ ] **Step 2: Run them; see them fail.**

- [ ] **Step 3: Implement.** In the script's `jump`:
  - Validate PID `^[1-9][0-9]{0,9}$` and START `^[0-9]{1,20}$`.
  - Read `pane_pid` with `display-message -p -t "$pane" '#{pane_pid}'`; empty means "That session's tmux pane is gone."
  - Check `/proc/$pid/stat` exists, and that its field 22 equals START. Parse after the last `)`, because the comm field can contain spaces and parens; the hook's `proc_stat` shows how.
  - Walk parents from PID through `/proc/<p>/stat` field 4, at most 64 steps, until `pane_pid` is reached; not reached means refuse.
  - Do all of this before `select-window`.

  Everywhere the script opens a tab, add `--title "$TAB_TITLE" --suppressApplicationTitle` right after `new-tab`. In `klepsydra-tmux.conf`, drop the two `set-titles` lines and add `set -g automatic-rename on` and `set -g automatic-rename-format "#{pane_title}"`, keeping `source-file -q ~/.tmux.conf` first and `remain-on-exit failed`. In jump.rs, when `tmux_jump` succeeds, run one `jump(FLEET_TAB)` attempt and `settle(true, …)`; drop `jump_settled`'s retry loop, since the title no longer changes.

- [ ] **Step 4: Gates.** The whole audit list in `.claude/skill-context.md` (Phase 3 and 4), plus `KLEPSYDRA_STAGE=klepsydra-build-launch bash scripts/build-windows.sh --check </dev/null`. Two `test_launch.sh` runs.

- [ ] **Step 5: Commit** `feat(fleet): Jump checks the pane's process and finds the fleet tab by its own title`.
