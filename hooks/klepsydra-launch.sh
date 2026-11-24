#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR [agy MODEL | claude ACCOUNT [MODEL] | copilot [MODEL]]
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh models|engines
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump|end|interrupt|wrapup SOCKET PANE PID START
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"), or with `agy MODEL` Antigravity's CLI on MODEL (#323), locked
# (read-only, no shell) and once the helper rules are in agy's rules folder, refused while
# the model's quota group is spent; `claude ACCOUNT` starts claude on the config folder logged
# in to ACCOUNT (#440), `copilot` Copilot's CLI locked as `fleet delegate` runs it; `models`
# lists agy's models with their quota group; `engines` says which engines and Claude accounts
# can start here; `jump` brings PANE's window to the front of its session, once
# PANE still hosts Claude process PID (START = /proc/PID/stat field 22).
# `end` types /exit into that Claude Code, `wrapup` types /klepsydra-wrapup
# and `interrupt` presses Esc there, on klepsydra's own tmux server only. `new` and `jump` open a Windows Terminal tab (window "fleet", titled TAB_TITLE) only when no
# client shows the session and no tab opened in the last PENDING_FOR seconds is
# still starting. One line out: stdout on success, stderr on failure.
set -uo pipefail

SOCKET_NAME=${KLEPSYDRA_TMUX_SOCKET:-klepsydra} # default is FLEET_SOCKET in launch.rs
SESSION=fleet
TAB_TITLE="klepsydra sessions" # also FLEET_TAB in src-tauri/src/launch.rs
CONF=${KLEPSYDRA_TMUX_CONF:-$HOME/.claude/klepsydra-tmux.conf}
CLAUDE=${KLEPSYDRA_CLAUDE:-claude}
AGY=${KLEPSYDRA_AGY:-agy}
COPILOT=${KLEPSYDRA_COPILOT:-copilot}
# Claude Code keeps one login per config folder; the default one runs with
# CLAUDE_CONFIG_DIR unset (fleet/lib.sh FLEET_DEFAULT_CONFIG, FLEET_ACCOUNTS).
DEFAULT_CONFIG=${FLEET_DEFAULT_CONFIG:-$HOME/.claude}
ACCOUNT_RE='^[0-9A-Za-z][0-9A-Za-z-]{0,63}$'
# agy reads AGENTS.md or GEMINI.md, never CLAUDE.md (#323): the short working
# rules for a fleet helper reach it as an always-on rule. Not ~/.gemini/GEMINI.md,
# which the Antigravity IDE and Gemini CLI also write.
RULES_SRC=${KLEPSYDRA_RULES_SRC:-$HOME/.claude/klepsydra-engine-rules.md}
RULES_DST=${KLEPSYDRA_AGY_RULES:-$HOME/.gemini/config/rules/klepsydra-fleet.md}
RULES_MAX=24000 # agy's limit for one rules file, in bytes
# Every agy session the fleet starts is locked: no file writes, no shell, no
# MCP, no browser, in a terminal sandbox. The policy is one file the launcher
# and `fleet delegate` share; it goes in with --settings, which overrides AJ's own
# ~/.gemini/antigravity-cli/settings.json key by key (that file is never rewritten).
AGY_LOCK=${KLEPSYDRA_AGY_LOCK:-$HOME/.claude/klepsydra-agy-locked.json}
WINMNT=${KLEPSYDRA_WINDOWS_MOUNT:-/mnt} # the Windows drives under WSL
MODEL_RE='^[a-z0-9][a-z0-9.-]{0,63}$'
# What a folder may ship that an engine loads once the folder is trusted and that
# runs outside its tool lock (hooks, plugins, skills, MCP), each engine's own
# names (fleet/delegate.sh ENGINE_CONFIG strips all of them from a snapshot).
# Copilot's are GitHub's hooks reference and skills docs (11-19); it also reads
# hooks from .claude/settings.json and .claude/settings.local.json (no_copilot_hooks).
AGY_CONFIG=(.agents .agent _agents _agent)
COPILOT_CONFIG=(.github/hooks .github/copilot .github/skills .github/agents .github/extensions .github/mcp.json .mcp.json .vscode/mcp.json .copilot .claude/skills .agents/skills)
AGY_ASK=${KLEPSYDRA_AGY_ASK:-30} # seconds for one agy listing; a launch asks with less
WT=${KLEPSYDRA_WT:-wt.exe}
UNDO=()
# --- lock dir: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh and statusline/klepsydra-statusline.sh ---
# The folder for the locks and stamps every caller must share: one per host and
# boot in ~/.local/state/klepsydra (KLEPSYDRA_STATE), made with mode 0700 and
# used only while it and the folder above it are ours, not symlinks and the
# folder above it is writable by no one else. Sets LOCK_DIR, or empties it,
# says why in LOCK_WHY and fails; never waits, never prints. Not
# XDG_RUNTIME_DIR: a WSL boot sets it before logind makes it, and the overlay's
# shells may lack it, so callers would split between two locks (#517). Making
# this boot's folder removes this host's folders last changed before this boot
# began (btime), which only ended boots can be. Another host's are never
# touched, so a HOME two machines share (NFS) keeps each one's live folder.
# The host is the kernel's hostname, so renaming a host mid-boot moves its lock.
lock_why() { # PATH [w]: fails with LOCK_WHY set when PATH is no folder of ours (w: or not writable)
  local mode
  if [[ -L $1 ]]; then LOCK_WHY="$1 is a symlink"
  elif [[ ! -e $1 ]]; then LOCK_WHY="$1 is missing"
  elif [[ ! -d $1 ]]; then LOCK_WHY="$1 is not a folder"
  elif [[ ! -O $1 ]]; then LOCK_WHY="$1 belongs to another user"
  elif [[ -n ${2:-} && ! -w $1 ]]; then
    mode=$(stat -c %A -- "$1" 2>/dev/null)
    if [[ ${mode:2:1} == w ]]; then LOCK_WHY="$1 cannot be written (a read-only file system, or locked)"
    else LOCK_WHY="$1 is not writable (mode ${mode:-unknown})"; fi
  else return 0; fi
  return 1
}
# shellcheck disable=SC2034 # LOCK_WHY is for the caller
lock_dir() {
  local base=${KLEPSYDRA_STATE:-} given boot="" host="" run old name mode key val btime="" m err prune=1
  LOCK_DIR="" LOCK_WHY=""
  if [[ -z $base ]]; then
    if [[ -n ${HOME:-} ]]; then base=$HOME
    else local HOME; unset HOME; base=~; fi # bash reads the password file's home
    base=$base/.local/state/klepsydra
  fi
  given=$base
  while [[ $base == */ ]]; do base=${base%/}; done
  if [[ $base != /* ]]; then
    if [[ $given == /* ]]; then LOCK_WHY="the state folder cannot be /"
    else LOCK_WHY="the state folder '$given' is not an absolute path"; fi
    return 1
  fi
  # builtin reads: no process
  { read -r boot <"${KLEPSYDRA_BOOT_ID:-/proc/sys/kernel/random/boot_id}"; } 2>/dev/null
  [[ $boot =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || boot=unknown prune=0
  { read -r host <"${KLEPSYDRA_HOSTNAME:-/proc/sys/kernel/hostname}"; } 2>/dev/null
  [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || host=_ prune=0 # no hostname has a _, so no host's prune reaches it
  run=$base/run-$host-$boot
  if [[ ! -e $run && ! -L $run ]]; then
    if [[ ! -e $base && ! -L $base ]]; then
      err=$({ mkdir -p -- "${base%/*}" && mkdir -m 700 -- "$base"; } 2>&1) ||
        { LOCK_WHY="cannot make $base${err:+: ${err##*: }}"; return 1; }
    fi
    lock_why "$base" || return 1
    mode=$(stat -c %a -- "$base" 2>/dev/null) # once a boot: others could plant links
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
      LOCK_WHY="$base is writable by its group or others (mode ${mode:-unknown})"; return 1
    fi
    if err=$(mkdir -m 700 -- "$run" 2>&1); then
      if (( prune )); then
        while read -r key val; do [[ $key == btime ]] && { btime=$val; break; }; done 2>/dev/null </proc/stat
        for old in "$base/run-$host-"*; do
          name=${old##*/}; name=${name#"run-$host-"}
          [[ $btime =~ ^[0-9]+$ && $name =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
            $old != "$run" && -d $old && ! -L $old ]] || continue
          m=$(stat -c %Y -- "$old" 2>/dev/null) && [[ $m =~ ^[0-9]+$ ]] && (( m < btime )) && rm -rf -- "${old:?}" 2>/dev/null
        done
      fi
    elif [[ ! -e $run && ! -L $run ]]; then # not another caller's mkdir winning
      LOCK_WHY="cannot make $run${err:+: ${err##*: }}"; return 1
    fi
  fi
  lock_why "$base" && lock_why "$run" w || return 1
  LOCK_DIR=$run
}
# --- end lock dir ---
lock_dir
LOCK=${LOCK_DIR:+$LOCK_DIR/klepsydra-launch-$UID.lock}
PROC_ROOT=${KLEPSYDRA_PROC:-/proc} # tests point this at a fake /proc
# A tab opened but not yet attached: "EPOCH KEY", KEY its socket args and target.
PENDING=${LOCK_DIR:+$LOCK_DIR/klepsydra-tab-pending-$UID}
PENDING_FOR=30
# A socket path safe to hand wt.exe, which splits its arguments at ";".
SOCKET_RE='^/[A-Za-z0-9._/-]{1,255}$'
ATTACHED=1 # cleared by open_tab until the tab's client shows up
END_WAIT=${KLEPSYDRA_END_WAIT:-10} # seconds `end` waits for Claude to exit
[[ $END_WAIT =~ ^[1-9][0-9]{0,2}$ ]] || END_WAIT=10 # it reaches $(( )), which would run a crafted value
# Claude Code's input line as capture-pane shows it: U+276F and a no-break
# space at the left edge, a rule (U+2500) on the lines above and below.
PROMPT_MARK=$'\xe2\x9d\xaf\xc2\xa0'
RULE=$'\xe2\x94\x80'

fail() { printf '%s\n' "$*" >&2; exit 1; }
undo() { (( ${#UNDO[@]} )) && "${UNDO[@]}" >/dev/null 2>&1; } # what a failed launch created
need() { command -v "$1" >/dev/null 2>&1 || fail "$2"; }

has_client() { [[ -n $(tmux "${@:2}" list-clients -t "$1" -F x 2>/dev/null) ]]; } # target socket-args...

# Stop when lock_dir found no folder of ours to lock in, saying why.
no_lock_dir() { # [what the click did already] [what it then did not]
  [[ -n $LOCK_DIR ]] && return 0
  fail "${1:+$1, but }klepsydra has no lock folder (${LOCK_WHY:-reason unknown}), so ${2:-this click went no further}."
}

# Serialise launches: one tab per fleet even for back-to-back clicks.
take_lock() { # [what to say when another holds it for 10 s]
  no_lock_dir
  { exec {LOCKFD}>>"$LOCK"; } 2>/dev/null || fail "Could not open $LOCK."
  local wait=${KLEPSYDRA_LOCK_WAIT:-10}
  [[ $wait =~ ^[0-9]{1,3}(\.[0-9]{1,3})?$ ]] || wait=10
  flock -w "$wait" "$LOCKFD" || fail "${1:-Another launch is still running.}"
}

# Whether this is WSL (a Windows Terminal tab) rather than a native Linux desktop.
# Decided once: WSL_DISTRO_NAME, or "microsoft" in the kernel release.
IS_WSL=""
is_wsl() {
  if [[ -z $IS_WSL ]]; then
    local osrelease=""
    if [[ -n ${WSL_DISTRO_NAME:-} ]]; then IS_WSL=1
    elif proc_osrelease && [[ $osrelease == *[Mm]icrosoft* ]]; then IS_WSL=1
    else IS_WSL=0; fi
  fi
  [[ $IS_WSL == 1 ]]
}

# The terminal for a native Linux tab: KLEPSYDRA_TERMINAL when set (and then
# only it, so a typo is an error, not a silent other terminal), else the first
# of the usual emulators on PATH.
find_linux_terminal() {
  local term
  if [[ -n ${KLEPSYDRA_TERMINAL:-} ]]; then
    command -v "$KLEPSYDRA_TERMINAL" >/dev/null 2>&1 || return 1
    printf '%s' "$KLEPSYDRA_TERMINAL"
    return 0
  fi
  for term in xfce4-terminal gnome-terminal konsole kitty alacritty x-terminal-emulator xterm; do
    command -v "$term" >/dev/null 2>&1 && { printf '%s' "$term"; return 0; }
  done
  return 1
}

# Why find_linux_terminal found none: KLEPSYDRA_TERMINAL by name when it is set.
no_terminal() {
  if [[ -n ${KLEPSYDRA_TERMINAL:-} ]]; then
    printf 'KLEPSYDRA_TERMINAL is %s, which is not a command that can be run.' "$KLEPSYDRA_TERMINAL"
  else
    printf 'No terminal emulator found (e.g. xfce4-terminal, gnome-terminal, x-terminal-emulator, xterm).'
  fi
}

# Check a tab can be opened, before anything is created.
tab_preflight() {
  if is_wsl; then
    need "$WT" "wt.exe was not found, so no terminal tab could be opened."
    [[ ${WSL_DISTRO_NAME:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
      fail "WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
  else
    find_linux_terminal >/dev/null || fail "$(no_terminal)"
  fi
}

# Set for the fleet's own tab: its title is fixed, so Jump can find it.
TITLE_ARGS=()

# Whether the stamp is ours to use: only our own regular file counts, since a
# FIFO or a link left there would block its read under the lock. Anything else
# there is removed when it is ours.
stamp_usable() {
  [[ -f $PENDING && -O $PENDING && ! -L $PENDING ]] && return 0
  [[ -e $PENDING || -L $PENDING ]] && rm -f -- "$PENDING" 2>/dev/null
  return 1
}

# Whether a tab for `key` opened under PENDING_FOR seconds ago and has not
# attached yet: on a cold WSL a tab takes longer than open_tab waits.
tab_pending() { # key
  local at="" key="" now
  stamp_usable || return 1
  { IFS=' ' read -r at key <"$PENDING"; } 2>/dev/null
  printf -v now '%(%s)T' -1
  [[ $at =~ ^[0-9]+$ && $key == "$1" ]] && (( now >= at && now - at < PENDING_FOR ))
}

# Open a tab attached to `target`, unless one is still starting, then wait for
# its client so the next launch sees it; ATTACHED says whether it came. If
# wt.exe fails, run undo.
open_tab() { # target tmux-socket-args...
  local target=$1 key termpid="" term=""; shift
  key="$* $target"
  ATTACHED=0
  tab_pending "$key" && return 0
  if is_wsl; then
    # The lock fd is closed for wt.exe so a tab never outlives the lock; its
    # stdin is /dev/null, since WSL interop hands stdin to wt.exe, which drains it (#242).
    "$WT" -w fleet new-tab "${TITLE_ARGS[@]}" wsl.exe -d "$WSL_DISTRO_NAME" -e tmux "$@" attach -t "$target" \
      </dev/null >/dev/null 2>&1 {LOCKFD}>&- || {
      undo
      fail "Windows Terminal did not open a tab."
    }
  else
    # The terminal is started in the background (it stays up as the tab), so a
    # failed start shows only as its exit: the wait below reads it. Its lock fd is
    # closed so a tab never outlives the lock.
    local title="${TITLE_ARGS[1]:-$TAB_TITLE}"
    local -a termcmd
    term=$(find_linux_terminal) || { undo; fail "$(no_terminal)"; }
    case ${term##*/} in
      xfce4-terminal) termcmd=("$term" --disable-server -T "$title" -x) ;;
      gnome-terminal) termcmd=("$term" --tab --title="$title" --) ;;
      konsole) termcmd=("$term" --new-tab -p tabtitle="$title" -e) ;;
      kitty) termcmd=("$term" -T "$title") ;;
      *) termcmd=("$term" -T "$title" -e) ;; # alacritty, x-terminal-emulator, xterm
    esac
    "${termcmd[@]}" tmux "$@" attach -t "$target" </dev/null >/dev/null 2>&1 {LOCKFD}>&- &
    termpid=$!
  fi
  if [[ ! -e $PENDING && ! -L $PENDING ]] || stamp_usable; then
    { printf '%(%s)T %s\n' -1 "$key" >"$PENDING"; } 2>/dev/null
  fi
  local _
  for _ in $(seq 50); do
    if has_client "$target" "$@"; then
      ATTACHED=1
      rm -f -- "$PENDING"
      return 0
    fi
    # A terminal that exited non-zero never opened a tab; one that exited 0 handed
    # the tab to its server (gnome-terminal) and may still attach.
    if [[ -n $termpid ]] && ! kill -0 "$termpid" 2>/dev/null && ! wait "$termpid"; then
      rm -f -- "$PENDING"
      undo
      fail "$term did not open a tab."
    fi
    sleep 0.1
  done
}

# The fleet helper rules, as agy reads an always-on rule, written only when they
# changed; fails, starting nothing, when they cannot be put there or are over
# agy's size limit.
agy_rules() {
  local tmp old
  [[ -r $RULES_SRC ]] || fail "The fleet helper rules ($RULES_SRC) cannot be read, so agy would start without them."
  (( $(stat -c %s -- "$RULES_SRC") <= RULES_MAX )) || fail "The fleet helper rules ($RULES_SRC) are over agy's $RULES_MAX byte limit."
  mkdir -p -- "${RULES_DST%/*}" || fail "agy's rules folder (${RULES_DST%/*}) cannot be made."
  # The rule an earlier launcher made from the whole global rules file: gone, or every agy session keeps loading it.
  old=${RULES_DST%/*}/claude-global.md
  if [[ -f $old ]] && grep -q 'made from .* by klepsydra' "$old" 2>/dev/null; then rm -f -- "${old:?}"; fi
  tmp=$(mktemp "$RULES_DST.XXXXXX") || fail "agy's rules cannot be written beside $RULES_DST."
  { printf -- '---\ntrigger: always_on\ndescription: "Working rules for a fleet helper, made from %s by klepsydra; edit that file, not this one."\n---\n\n' "$RULES_SRC"
    cat -- "$RULES_SRC"; } >"$tmp" || { rm -f -- "${tmp:?}"; fail "agy's rules cannot be written."; }
  if cmp -s -- "$tmp" "$RULES_DST"; then rm -f -- "${tmp:?}"; else mv -f -- "$tmp" "$RULES_DST" || fail "agy's rules cannot be put in place."; fi
}

# The locked settings for an agy session: the lock policy itself, which names no
# trusted workspace, so agy asks before trusting a folder (a repo's own hooks, plugins
# and skills load only under trust, and run commands outside the deny rules; AJ answers
# for his own folders, which his agy settings already list). Prints the file's path.
# Fails, starting nothing, when the policy cannot be read.
agy_settings() {
  [[ -r $AGY_LOCK ]] || fail "agy's lock policy ($AGY_LOCK) cannot be read, so agy would start unlocked."
  printf '%s' "$AGY_LOCK"
}

# agy's quota as `agy -p /quota --output-format json` reports it (no turn, no
# quota spent), into QUOTA; empty when it does not answer.
agy_quota() {
  QUOTA=$(cd -- "$HOME" && timeout "$AGY_ASK" "$AGY" -p /quota --output-format json 2>/dev/null) || QUOTA=""
  jq -e '.command.data.groups | arrays' >/dev/null 2>&1 <<<"$QUOTA" || QUOTA=""
}

# The jq that gives each model its quota group: a group lists its members by base
# name ("Models within this group: Claude Sonnet 4.6, ..."), a model's label is
# that name and a variant ("Claude Sonnet 4.6 (Thinking)"); the group's key is
# its buckets' id less the window ("3p-5h" -> "3p"), as the statusLine hook files
# them. A model no group names gets none.
# shellcheck disable=SC2016 # jq variables, not shell ones
GROUP_JQ='
  def base: sub(" \\([^)]*\\)$"; "");
  ($q | if . == "" then [] else (fromjson | [.command.data.groups[]? | {
      key: ((.buckets[0].id // "") | sub("-[^-]*$"; "")),
      names: ((.description // "") | sub("^[^:]*: *"; "") | split(", ")),
      spent: ([.buckets[]? | select((.remaining_fraction // 1) <= 0) | .reset_time] | first)
    }]) end) as $groups
  | [inputs | split("\t") | {id: .[0], label: .[1]} as $m
     | ([$groups[] | select(.key != "" and (.names | index($m.label | base)))] | first) as $g
     | $m + (if $g then {group: $g.key} + (if $g.spent then {spent: $g.spent} else {} end) else {} end)]'

# agy's models, "ID<TAB>LABEL" lines, into LIST (`agy models` prints a fetching
# line first, and nothing else is an id).
agy_list() {
  LIST=$(timeout "$AGY_ASK" "$AGY" models 2>/dev/null) || fail "agy models did not answer."
  LIST=$(awk -F'\t' -v re="$MODEL_RE" 'NF == 2 && $1 ~ re && $2 != "" { print $1 "\t" $2 }' <<<"$LIST")
  [[ -n $LIST ]] || fail "agy listed no models."
}

# The models and their quota (asked at once, so the two waits overlap) as one
# JSON array, [{"id", "label", "group"?, "spent"?}...]; "spent" is the time a
# spent group comes back.
agy_models_json() {
  local qf
  need "$AGY" "agy (Antigravity CLI) was not found on PATH."
  need jq "jq is not installed in this distro."
  qf=$(mktemp) || fail "No temporary file for agy's quota."
  ( agy_quota; printf '%s' "$QUOTA" >"$qf" ) &
  local qpid=$!
  agy_list
  wait "$qpid"
  QUOTA=$(cat -- "$qf"); rm -f -- "${qf:?}"
  jq -Rnc --arg q "$QUOTA" "$GROUP_JQ" <<<"$LIST"
}

# agy's models as one line of JSON, since the launcher says one line.
models() { agy_models_json; }

# Which engines can start here, as one line of JSON: {"agy", "copilot": on PATH,
# "claude": the accounts with a login in a config folder}.
engines() {
  local dir id ids=() agy=false copilot=false
  need jq "jq is not installed in this distro."
  command -v "$AGY" >/dev/null 2>&1 && agy=true
  command -v "$COPILOT" >/dev/null 2>&1 && copilot=true
  while IFS= read -r dir; do
    id=$(account_of "$dir") && [[ $id =~ $ACCOUNT_RE ]] && ids+=("$id")
  done < <(account_dirs)
  printf '%s\n' "${ids[@]}" | jq -Rnc --argjson agy "$agy" --argjson copilot "$copilot" \
    '{claude: ([inputs | select(length > 0)] | unique), agy: $agy, copilot: $copilot}'
}

# The config folders a Claude login may live in, one per line: FLEET_ACCOUNTS
# when set (the fleet's own list), else the default folder and every ~/.claude-*.
account_dirs() {
  local d
  if [[ -n ${FLEET_ACCOUNTS:-} ]]; then
    # shellcheck disable=SC2086 # one folder per word, as fleet/lib.sh reads it
    printf '%s\n' $FLEET_ACCOUNTS
    return
  fi
  printf '%s\n' "$DEFAULT_CONFIG"
  for d in "$HOME"/.claude-*/; do [[ -d $d && ! -L ${d%/} ]] && printf '%s\n' "${d%/}"; done
}

# A config folder's global config file (fleet/lib.sh config_json).
config_json() { # DIR
  if [[ ${1%/} == "${DEFAULT_CONFIG%/}" ]]; then printf '%s' "${FLEET_DEFAULT_JSON:-$HOME/.claude.json}"; else printf '%s' "$1/.claude.json"; fi
}

# The account logged in at config folder DIR (fleet/lib.sh account_of). The
# login itself (.credentials.json) is only checked for, never read.
account_of() { # DIR
  [[ -e $1/.credentials.json ]] || return 1
  jq -er '.oauthAccount.accountUuid // empty' "$(config_json "$1")" 2>/dev/null
}

# The config folder logged in to ACCOUNT, by its login, never by its name.
folder_of() { # ACCOUNT
  local dir
  while IFS= read -r dir; do
    [[ $(account_of "$dir") == "$1" ]] && { printf '%s' "${dir%/}"; return 0; }
  done < <(account_dirs)
  return 1
}

# DIR and every folder above it up to its repo root, one per line: where an
# engine looks for workspace configuration.
up_to_root() { # real-dir
  local d=$1 top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || top=$1
  while :; do
    printf '%s\n' "$d"
    [[ $d != "$top" && $d != / ]] || break
    d=${d%/*}
    [[ -n $d ]] || d=/
  done
}

# Refuse a folder that ships an engine's workspace configuration, from DIR up to
# its repo root: once the folder is trusted (its trust dialog is the only gate),
# that configuration runs commands outside the lock.
no_engine_config() { # real-dir engine-name names...
  local real=$1 what=$2 d f; shift 2
  while IFS= read -r d; do
    for f in "$@"; do
      [[ ! -e $d/$f ]] || fail "$what is not started in $real: $d/$f ships $what workspace configuration (hooks, plugins, skills, MCP), which runs outside the lock once the folder is trusted."
    done
  done < <(up_to_root "$real")
}

# Copilot also runs the hooks of Claude Code's project settings: refuse a folder
# whose .claude/settings.json or settings.local.json sets them, or does not read
# as a JSON object (fail closed).
no_copilot_hooks() { # real-dir
  local d f
  while IFS= read -r d; do
    for f in "$d/.claude/settings.json" "$d/.claude/settings.local.json"; do
      [[ -e $f ]] || continue
      jq -e 'type == "object" and (has("hooks") | not)' "$f" >/dev/null 2>&1 ||
        fail "Copilot is not started in $1: $f sets hooks (or does not read as JSON), which Copilot runs outside the lock once the folder is trusted."
    done
  done < <(up_to_root "$1")
}

# A locked engine's workspace is the one folder its reads reach: never the home
# folder, a folder that holds it (/home, /), or a Windows drive (/mnt/c).
locked_workspace() { # dir engine-name: prints the real path
  local real home
  real=$(cd -- "$1" && pwd -P) home=$(cd -- "$HOME" && pwd -P)
  real=${real%/} # "/" becomes "", whose pattern /* holds every path
  case $home/ in "$real"/*) fail "$2 is not started in $1: its workspace would hold the whole home folder. Pick a project folder." ;; esac
  [[ $real != "$WINMNT" && $real != "$WINMNT"/* ]] || fail "$2 is not started in $1: the Windows side ($WINMNT) is no workspace, its user folders hold credentials. Pick a project folder in WSL."
  printf '%s' "${real:-/}"
}

# Refuse an agy model whose quota group is spent, by agy's own quota asked now,
# so a menu drawn before the group ran out starts nothing. When agy does not say
# (no answer, no group for the model) the launch goes ahead: agy reports a spent
# quota itself.
agy_spent() { # model
  local got back
  need jq "jq is not installed in this distro."
  # Short asks, so the launch stays inside the app's 45 s wait.
  got=$(AGY_ASK=10 agy_models_json 2>/dev/null) || return 0
  back=$(jq -r --arg m "$1" '.[] | select(.id == $m) | .spent // empty' <<<"$got" 2>/dev/null)
  [[ -z $back ]] || fail "Not started: Antigravity's quota for $1 is spent until $back."
}

new() { # dir [agy model | claude account [model] | copilot [model]]
  local dir=$1 tool=${2:-claude} arg=${3:-} cmodel=${4:-} cmd=$CLAUDE what="a session" keycheck=0 cfg_set=0 cfg_dir=""
  # shellcheck disable=SC2088 # a literal ~/ from the overlay
  case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
  esac
  [[ -d $dir ]] || fail "The folder $dir does not exist."
  need tmux "tmux is not installed in this distro."
  if [[ $tool == agy ]]; then
    local model=$arg real
    [[ $model =~ $MODEL_RE ]] || fail "That is not an agy model id: $model"
    real=$(locked_workspace "$dir" agy) || exit 1
    # agy reads workspace configuration from the folder and every folder above it up to the repo root,
    # from four folder names (a bare hooks.json elsewhere in the tree is loaded by nothing, tested).
    no_engine_config "$real" agy "${AGY_CONFIG[@]}"
    need "$AGY" "agy (Antigravity CLI) was not found on PATH."
    agy_spent "$model"
    agy_rules
    local settings
    settings=$(agy_settings) || exit 1
    printf -v cmd '%q --model %s --settings %q --sandbox' "$AGY" "$model" "$settings"
    what="a locked Antigravity session ($model)"
  elif [[ $tool == copilot ]]; then
    local model=${arg:-auto} real
    [[ $model =~ $MODEL_RE ]] || fail "That is not a Copilot model id: $model"
    real=$(locked_workspace "$dir" Copilot) || exit 1
    no_engine_config "$real" Copilot "${COPILOT_CONFIG[@]}"
    need jq "jq is not installed in this distro."
    no_copilot_hooks "$real"
    need "$COPILOT" "copilot (GitHub Copilot CLI) was not found on PATH."
    # fleet/engines.sh copilot:interactive: reads only, no writes, no shell, no built-in MCP.
    printf -v cmd '%q --model %s --allow-all-tools --available-tools view,grep,glob --deny-tool=write --deny-tool=shell --disable-builtin-mcps --disallow-temp-dir' "$COPILOT" "$model"
    what="a locked Copilot session ($model)"
  else
    need "${CLAUDE%% *}" "claude was not found on PATH."
    if [[ $tool == claude && -n $arg ]]; then
      [[ $arg =~ $ACCOUNT_RE ]] || fail "That is not a Claude account id: $arg"
      [[ -z $cmodel || $cmodel =~ $MODEL_RE ]] || fail "That is not a Claude model: $cmodel"
      need jq "jq is not installed in this distro."
      cfg_dir=$(folder_of "$arg") || fail "No Claude Code folder here is logged in to that account; sign in with claude /login under its CLAUDE_CONFIG_DIR."
      cfg_set=1
      if [[ ${cfg_dir%/} == "${DEFAULT_CONFIG%/}" ]]; then
        cmd="env -u CLAUDE_CONFIG_DIR $cmd"
      else
        printf -v cmd 'env CLAUDE_CONFIG_DIR=%q %s' "$cfg_dir" "$cmd"
      fi
      [[ -n $cmodel ]] && cmd="$cmd --model $cmodel"
    fi
    # Subscription only (#260): no API key, token or named profile from this
    # shell or the tmux server reaches an interactive session. The same list
    # as NO_KEY_ENV in fleet/lib.sh (test_headless.sh pins the two together).
    cmd="env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_PROFILE $cmd"
    keycheck=1
  fi
  # The voice is this session's alone: into its command, and out of a tmux
  # server this launch may start, whose environment every later pane copies.
  if [[ ${KERYX_VOICE:-} =~ ^[a-z0-9_+().-]+$ ]]; then
    cmd="env KERYX_VOICE=$(printf '%q' "$KERYX_VOICE") $cmd"
  else
    cmd="env -u KERYX_VOICE $cmd"
  fi
  unset KERYX_VOICE
  take_lock
  local -a t=(-L "$SOCKET_NAME") conf=()
  [[ -r $CONF ]] && conf=(-f "$CONF")
  local target="=$SESSION" exists=0 shown=0 win path
  tmux "${t[@]}" has-session -t "$target" 2>/dev/null && exists=1
  # Nor does a settings file the session would read set one (KEY_JQ, as in
  # fleet/lib.sh). A fleet launch (KLEPSYDRA_BACKGROUND=1) checked the folder
  # its command names already; any other session runs on the tmux server's
  # CLAUDE_CONFIG_DIR when the server is up (with any session, such as fleet
  # delegate's), else on this environment's.
  if (( keycheck )) && [[ ${KLEPSYDRA_BACKGROUND:-} != 1 ]]; then
    local key_jq f cfg=${CLAUDE_CONFIG_DIR:-}
    if (( cfg_set )); then
      cfg=$cfg_dir # the folder this launch names
    elif tmux "${t[@]}" list-sessions >/dev/null 2>&1; then
      cfg=$(tmux "${t[@]}" show-environment -g CLAUDE_CONFIG_DIR 2>/dev/null) && [[ $cfg == CLAUDE_CONFIG_DIR=* ]] && cfg=${cfg#*=} || cfg=""
    fi
    key_jq='(.apiKeyHelper // "" | tostring | length > 0) or ((.env // {}) | has("ANTHROPIC_API_KEY") or has("ANTHROPIC_AUTH_TOKEN") or has("ANTHROPIC_PROFILE"))'
    for f in "${cfg:-$HOME/.claude}/settings.json" "$dir/.claude/settings.json" "$dir/.claude/settings.local.json" "${KLEPSYDRA_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"; do
      [[ -f $f ]] && jq -e "$key_jq" "$f" >/dev/null 2>&1 &&
        fail "Not started: $f sets an API key or key helper, and an interactive session runs on your Claude subscription only. Remove it there (keys are for fleet headless jobs)."
    done
  fi
  (( exists )) && has_client "$target" "${t[@]}" && shown=1
  (( shown )) || tab_preflight
  # The tmux server must not inherit the lock fd, or it holds the lock for good.
  # A fleet launch (KLEPSYDRA_BACKGROUND=1) opens behind the window in view,
  # so AJ keeps typing where he was (#216); the wall's New session comes forward.
  local -a behind=()
  [[ ${KLEPSYDRA_BACKGROUND:-} == 1 ]] && behind=(-d)
  # Read once: a server this launch starts copies its environment into every pane.
  # KLEPSYDRA_CLAUDE too (read into CLAUDE above): fleet/launch.sh passes an agent's
  # whole command in it, and a server that kept it hands that command, session id
  # and all, to every later launch run from one of its panes.
  unset KLEPSYDRA_BACKGROUND KLEPSYDRA_CLAUDE
  if (( exists )); then
    win=$(tmux "${t[@]}" new-window "${behind[@]}" -P -F '#{window_id}' -t "$target:" -c "$dir" "$cmd" {LOCKFD}>&- 2>/dev/null) ||
      fail "tmux could not open a window."
    UNDO=(tmux "${t[@]}" kill-window -t "$win")
  else
    # Started from inside any systemd unit or scope (the tmux watchdog's recover,
    # the resume service, an agent's own scope), the server gets a scope of its
    # own: a oneshot unit's end kills what it leaves in its cgroup.
    local -a scope=()
    if [[ -n ${INVOCATION_ID:-} ]] && command -v "${KLEPSYDRA_SYSTEMD_RUN:-systemd-run}" >/dev/null 2>&1; then
      scope=("${KLEPSYDRA_SYSTEMD_RUN:-systemd-run}" --user --scope --quiet --collect --unit="klepsydra-tmux-$$" --)
    fi
    # A unit with no user manager to ask (a CI runner sets INVOCATION_ID too)
    # makes no scope: the server then starts as from a terminal.
    if ! { (( ${#scope[@]} )) && "${scope[@]}" tmux "${t[@]}" "${conf[@]}" new-session -d -s "$SESSION" -c "$dir" "$cmd" {LOCKFD}>&- 2>/dev/null; } &&
      ! tmux "${t[@]}" has-session -t "$target" 2>/dev/null; then
      tmux "${t[@]}" "${conf[@]}" new-session -d -s "$SESSION" -c "$dir" "$cmd" {LOCKFD}>&- 2>/dev/null ||
        fail "tmux could not start the fleet session."
    fi
    UNDO=(tmux "${t[@]}" kill-session -t "$target")
  fi
  if (( ! shown )); then
    # The tab attaches by the server's own path, whatever TMUX_TMPDIR it sees.
    path=$(tmux "${t[@]}" display-message -p -t "$target:" '#{socket_path}' 2>/dev/null)
    [[ $path =~ $SOCKET_RE ]] || { undo; fail "The tmux socket path cannot be passed to a tab: $path"; }
    TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
    open_tab "$target" -S "$path"
  fi
  if (( ATTACHED )); then
    printf 'Started %s in %s.\n' "$what" "$dir"
  else
    printf 'Started %s in %s. The terminal tab has not attached yet.\n' "$what" "$dir"
  fi
}

# --- proc stat: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh and hooks/klepsydra-browser.sh ---
# Fields of $PROC_ROOT/<pid>/stat after the command name, into the caller's
# `stat`: [0] is the state, [1] the parent pid, [19] the start time (field 22).
# The name sits in parentheses and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

# Whether `pid` runs with start time `start`: a zombie has exited, and a pid
# with another start time is a later process.
proc_is() { # pid start
  local -a stat=()
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  proc_stat "$1" && [[ ${stat[0]} != Z && ${stat[19]} == "$2" ]]
}

# The kernel's release string ("...microsoft-standard-WSL2" under WSL), into the
# caller's `osrelease`; fails when it cannot be read.
proc_osrelease() {
  osrelease=""
  { IFS= read -r osrelease <"$PROC_ROOT/sys/kernel/osrelease"; } 2>/dev/null
  [[ -n $osrelease ]]
}
# --- end proc stat ---

# Whether PID is alive with start time START and `ancestor` is PID or its ancestor.
owns_process() { # ancestor pid start
  local p=$2 _
  local -a stat=()
  proc_is "$p" "$3" || return 1
  for _ in $(seq 64); do
    [[ $p == "$1" ]] && return 0
    proc_stat "$p" || return 1
    p=${stat[1]}
    [[ $p =~ ^[1-9][0-9]*$ ]] || return 1
  done
  return 1
}

# Refuse unless PANE on SOCKET still hosts Claude process PID with START.
# Sets the caller's `t` (tmux's socket args) and `session` (PANE's session).
check_pane() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 pane_pid
  [[ $socket =~ $SOCKET_RE ]] || fail "Not a tmux socket path: $socket"
  [[ $pane =~ ^%[0-9]{1,9}$ ]] || fail "Not a tmux pane: $pane"
  [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || fail "Not a process id: $pid"
  [[ $start =~ ^[0-9]{1,20}$ ]] || fail "Not a process start time: $start"
  need tmux "tmux is not installed in this distro."
  t=(-S "$socket")
  # tmux 3.4 exits 0 with empty output for an unknown pane.
  session=$(tmux "${t[@]}" display-message -p -t "$pane" '#{session_name}' 2>/dev/null) ||
    fail "That session's tmux pane is gone."
  [[ -n $session ]] || fail "That session's tmux pane is gone."
  [[ $session =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The tmux session's name cannot be passed to a tab."
  pane_pid=$(tmux "${t[@]}" display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  [[ $pane_pid =~ ^[1-9][0-9]*$ ]] || fail "That session's tmux pane is gone."
  owns_process "$pane_pid" "$pid" "$start" ||
    fail "That session's tmux pane now belongs to another session."
}

# The top-level window of process `pid` that the window manager manages: the
# one with WM_STATE, which a minimized window keeps (xfwm4 unmaps it, so a
# visible-only search misses it, and an unmanaged leader window takes
# windowactivate with exit 0). Without xprop, or when no window of it reports
# WM_STATE (a window manager that sets none), the visible window alone.
managed_window() { # pid
  local wid
  if command -v xprop >/dev/null 2>&1; then
    while read -r wid; do
      [[ $wid =~ ^[0-9]+$ ]] || continue
      if xprop -id "$wid" WM_STATE 2>/dev/null | grep -Eq 'window state: (Normal|Iconic)'; then
        printf '%s' "$wid"
        return 0
      fi
    done < <(xdotool search --pid "$1" 2>/dev/null)
  fi
  wid=$(xdotool search --onlyvisible --pid "$1" 2>/dev/null | head -n1)
  [[ -n $wid ]] && printf '%s' "$wid"
}

# On a native Linux desktop, raise the terminal window that shows `session`,
# restoring it when minimized: the window of the first ancestor of its tmux
# client that owns one (the fleet's tab and a hand-started tmux alike). Best
# effort: Wayland and a missing xdotool leave the window where it is, as WSL does.
raise_window() { # session tmux-socket-args...
  is_wsl && return 0
  command -v xdotool >/dev/null 2>&1 || return 0
  local session=$1 cpid pid wid _; shift
  local -a stat=()
  while read -r cpid; do
    pid=$cpid
    for _ in $(seq 10); do
      [[ $pid =~ ^[1-9][0-9]*$ ]] || break
      wid=$(managed_window "$pid")
      if [[ -n $wid ]]; then xdotool windowactivate "$wid" >/dev/null 2>&1; return 0; fi
      proc_stat "$pid" || break
      pid=${stat[1]}
    done
  done < <(tmux "$@" list-clients -t "=$session" -F '#{client_pid}' 2>/dev/null)
  return 0
}

jump() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  check_pane "$@"
  { tmux "${t[@]}" select-window -t "$pane" && tmux "${t[@]}" select-pane -t "$pane"; } 2>/dev/null ||
    fail "tmux could not select the window."
  # An attached tab needs no lock; one missing is checked again under it.
  if has_client "=$session" "${t[@]}"; then
    raise_window "$session" "${t[@]}"
    printf "Selected the session's tmux window.\n"
    return 0
  fi
  no_lock_dir "Selected the session's tmux window" "no terminal tab opened for it"
  take_lock "Selected the session's tmux window, but another click is still opening a terminal tab. Try again."
  if ! has_client "=$session" "${t[@]}"; then
    tab_preflight
    # Only the fleet's own server gets the fixed title; another stays a plain tab.
    [[ ${socket##*/} == "$SOCKET_NAME" ]] && TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
    open_tab "=$session" "${t[@]}"
  fi
  printf "Selected the session's tmux window.\n"
}

# Typing into a session is for klepsydra's own server; a hand-started tmux is
# the user's.
fleet_pane() { # socket pane pid start
  check_pane "$@"
  [[ ${1##*/} == "$SOCKET_NAME" ]] ||
    fail "That session is not in klepsydra's tmux, so klepsydra will not type into it."
}

# What a refusal tells the user to do instead, per verb; each verb sets its own.
open_to="end it"
busy="That session is already being ended or interrupted."

# A pane in copy mode swallows keys as copy-mode commands, so leave it first.
leave_modes() {
  local _
  for _ in $(seq 5); do
    [[ $(tmux "${t[@]}" display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null) == 1 ]] || return 0
    tmux "${t[@]}" send-keys -t "$pane" -X cancel 2>/dev/null || return 0
  done
  fail "The session's pane is in a tmux mode that would not close. Open its terminal to $open_to."
}

# One End, Interrupt or Wrap up per pane: an End the app gave up on may still
# be running. The pane is checked again under the lock, as such an End may
# just have finished.
own_pane() { # socket pane pid start
  fleet_pane "$@"
  no_lock_dir
  local file=$LOCK_DIR/klepsydra-pane-$UID-${pane#%}.lock
  { exec {PANEFD}>>"$file"; } 2>/dev/null || fail "Could not open $file."
  flock -n "$PANEFD" || fail "$busy"
  # The fleet's typing lock too (fleet/lib.sh pane_locked, #325), so these keys
  # never land inside a message a fleet script is typing. Its folder is under
  # HOME, which every caller shares, as lock_dir's is.
  local typing=${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}/locks
  if [[ -d $typing ]]; then
    { exec {TYPEFD}>>"$typing/send-${pane#%}"; } 2>/dev/null || fail "Could not open $typing/send-${pane#%}."
    flock -w "${KLEPSYDRA_TYPING_WAIT:-5}" "$TYPEFD" || fail "A fleet script is typing into that session; try again in a moment."
  fi
  fleet_pane "$@"
}

keys() { tmux "${t[@]}" send-keys -t "$pane" "$@" 2>/dev/null || fail "tmux could not send keys to the session."; }

screen() { LC_ALL=C.UTF-8 tmux "${t[@]}" capture-pane -p -t "$pane" 2>/dev/null; }

# Whether PANE's input line reads exactly COMMAND, between its rules: not a
# line of the transcript, not the command menu's entry.
reads() { # command
  screen | awk -v mark="$PROMPT_MARK" -v rule="$RULE" -v want="$1" '
    { line[NR] = $0 }
    END {
      for (i = 2; i < NR; i++) {
        if (index(line[i - 1], rule) != 1 || index(line[i + 1], rule) != 1) continue
        if (index(line[i], mark want) == 1 && substr(line[i], length(mark want) + 1) ~ /^ *$/) found = 1
      }
      exit !found
    }'
}

# What tells a running turn, around the input box: "S" + the first line above
# it that starts in column 0 (Claude Code's spinner, "✢ Pollinating… (5m 2s ·
# ↓ 9.8k tokens)"; tips and notices under the spinner are indented, the
# transcript's last line is not), and "F" + each footer line below it, where
# "esc to interrupt" shows while a tool runs. Fails when no input box is on
# the screen. Lines the terminal wrapped are joined first, so a long tip's
# tail never reads as a column-0 line.
around_box() {
  LC_ALL=C.UTF-8 tmux "${t[@]}" capture-pane -p -J -t "$pane" 2>/dev/null | awk -v mark="$PROMPT_MARK" -v rule="$RULE" '
    { line[NR] = $0 }
    END {
      for (i = 2; i < NR; i++)
        if (index(line[i - 1], rule) == 1 && index(line[i + 1], rule) == 1 && index(line[i], mark) == 1) box = i - 1
      if (!box) exit 1
      for (j = box - 1; j >= 1; j--) if (line[j] ~ /^[^ \t]/) { print "S" line[j]; break }
      for (k = box + 3; k <= NR; k++) print "F" line[k]
    }'
}

# Whether the session is mid-turn: a spinner as the first column-0 line above
# its box, or the esc hint in its footer. The transcript above is never read,
# so one that quotes a spinner or the hint does not count.
mid_turn() {
  local around
  around=$(around_box) || fail "The session's input box is not on its screen, so klepsydra did not type into it. Open its terminal to $open_to."
  LC_ALL=C.UTF-8 grep -qE '^S. .+… \(|^F.*esc to (interrupt|cancel)' <<<"$around"
}

# Type COMMAND into the cleared input line and press Enter, only once the line
# reads exactly COMMAND, over 50 reads 0.1 s apart (at least 5 s on a busy
# machine); else clear it again and fail.
run_command() { # command
  local _
  keys -l "$1"
  for _ in $(seq 50); do reads "$1" && break; sleep 0.1; done
  if ! reads "$1"; then
    keys C-c
    fail "The session's prompt did not read $1, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
  fi
  keys Enter
}

end_session() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 session _
  local -a t=()
  own_pane "$@"
  leave_modes
  # Esc closes a dialog, declines a pending permission or stops a turn, so
  # Enter cannot answer one; Ctrl+C then clears a draft (Up brings it back).
  keys Escape
  sleep 1
  keys C-c
  sleep 0.5
  run_command /exit
  for _ in $(seq $((END_WAIT * 10))); do
    proc_is "$pid" "$start" || { printf 'Ended the session.\n'; return 0; }
    sleep 0.1
  done
  fail "Sent /exit, but the session is still running. Open its terminal to see why."
}

# Ask an idle session to wrap up. A session mid-turn is refused, since
# Ctrl+C would stop its turn; the Stop hook asks it when the turn ends.
wrapup() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  local open_to="ask it there: type /klepsydra-wrapup"
  local busy="klepsydra is already sending that session something; ask it by hand: type /klepsydra-wrapup in its terminal."
  own_pane "$@"
  leave_modes
  mid_turn && fail "The session is mid-turn; it is asked when the turn ends."
  # One Ctrl+C clears a draft (Up brings it back); on an idle prompt it does nothing else.
  keys C-c
  sleep 0.5
  run_command /klepsydra-wrapup
  printf 'Asked the session to wrap up.\n'
}

interrupt() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  local open_to="interrupt it"
  own_pane "$@"
  leave_modes
  keys Escape
  printf 'Sent Esc to the session.\n'
}

# The tray's Voices change (#273): keryx follows the mode the tray just saved,
# at once, through the installed `fleet voices` (no mode: it reads prefs.json,
# so two quick clicks never race on saving it).
voices() {
  local fleet=${FLEET_BIN:-$HOME/.local/bin}/fleet
  [[ -x $fleet ]] || fail "The fleet commands are not installed (make install-fleet)."
  "$fleet" voices || fail "fleet voices failed; see fleet log."
}

# Hand `target` (a folder or an https GitHub URL) to the desktop. On WSL that is
# Explorer (it exits 1 even when it opened the target); natively xdg-open, which
# must exist and, if it fails at once, fails the call. One still running after
# 2 s is a handler that stays up (a browser) and counts as opened.
open_on_desktop() { # target
  if is_wsl; then
    explorer.exe "$1" 2>/dev/null || true
    return 0
  fi
  need xdg-open "xdg-open was not found, so nothing could be opened."
  local pid _
  xdg-open "$1" </dev/null >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 20); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" || fail "xdg-open could not open it."; return 0; }
    sleep 0.1
  done
}

folder() { # dir
  local dir=$1
  # shellcheck disable=SC2088 # a literal ~/ from the overlay
  case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
  esac
  [[ -d $dir ]] || fail "The folder $dir does not exist."
  open_on_desktop "$dir"
}

github() { # url
  [[ $1 == https://github.com/* ]] || fail "That is not a GitHub URL."
  open_on_desktop "$1"
}

case ${1:-} in
  new)
    if (( $# == 4 )) && [[ $3 == agy ]]; then new "$2" agy "$4"
    elif (( $# == 4 || $# == 5 )) && [[ $3 == claude ]]; then new "$2" claude "$4" "${5:-}"
    elif (( $# == 3 || $# == 4 )) && [[ $3 == copilot ]]; then new "$2" copilot "${4:-}"
    else (( $# == 2 )) || fail "usage: klepsydra-launch.sh new DIR [agy MODEL | claude ACCOUNT [MODEL] | copilot [MODEL]]"; new "$2"; fi ;;
  models) (( $# == 1 )) || fail "usage: klepsydra-launch.sh models"; models ;;
  engines) (( $# == 1 )) || fail "usage: klepsydra-launch.sh engines"; engines ;;
  voices) (( $# == 1 )) || fail "usage: klepsydra-launch.sh voices"; voices ;;
  folder) (( $# == 2 )) || fail "usage: klepsydra-launch.sh folder DIR"; folder "$2" ;;
  github) (( $# == 2 )) || fail "usage: klepsydra-launch.sh github URL"; github "$2" ;;
  jump) (( $# == 5 )) || fail "usage: klepsydra-launch.sh jump SOCKET PANE PID START"; jump "$2" "$3" "$4" "$5" ;;
  end) (( $# == 5 )) || fail "usage: klepsydra-launch.sh end SOCKET PANE PID START"; end_session "$2" "$3" "$4" "$5" ;;
  wrapup) (( $# == 5 )) || fail "usage: klepsydra-launch.sh wrapup SOCKET PANE PID START"; wrapup "$2" "$3" "$4" "$5" ;;
  interrupt) (( $# == 5 )) || fail "usage: klepsydra-launch.sh interrupt SOCKET PANE PID START"; interrupt "$2" "$3" "$4" "$5" ;;
  *) fail "usage: klepsydra-launch.sh new DIR [agy MODEL | claude ACCOUNT [MODEL] | copilot [MODEL]] | models | engines | voices | jump|end|interrupt|wrapup SOCKET PANE PID START" ;;
esac
