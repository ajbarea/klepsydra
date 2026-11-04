#!/usr/bin/env bash
# klepsydra-pane-died.sh SOCKET PANE: tmux's pane-died hook on the fleet's
# server (klepsydra-tmux.conf, #290). tmux 3.4 crashes when a focus event
# reaches a pane whose process has ended (fixed in 3.5a), and remain-on-exit
# failed keeps such a pane, so it is started again at once: its last screen is
# saved to a file and shown again, with the reason, until Enter closes it. The
# pane option @klepsydra_dead holds the viewer's pid and the reason: the hook
# closes a killed viewer, and only that one (a program started there since is
# a new death). Saved screens older than a week are removed. Logged to the
# fleet log when the fleet is installed.
set -u
sock=${1:?usage: klepsydra-pane-died.sh SOCKET PANE} pane=${2:?usage: klepsydra-pane-died.sh SOCKET PANE}
lib=${KLEPSYDRA_FLEET_LIB:-$(dirname "$(readlink -f "${FLEET_BIN:-$HOME/.local/bin}/fleet" 2>/dev/null || echo /nonexistent/fleet)")/lib.sh}
if [[ -f $lib ]]; then
  FLEET_TARGET=fleet::pane-died
  # shellcheck source=fleet/lib.sh
  . "$lib"
else
  flog() { printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
fi
# After lib.sh, whose own t() is the fleet's socket.
t() { tmux -S "$sock" "$@"; }

# Tab-separated (tmux prints other control characters as octal), "-" for an empty field.
IFS=$'\t' read -r dead ppid st sig cmd < <(t display-message -p -t "$pane" $'#{pane_dead}\t#{pane_pid}\t#{?pane_dead_status,#{pane_dead_status},-}\t#{?pane_dead_signal,#{pane_dead_signal},-}\t#{pane_start_command}' 2>/dev/null)
[[ ${st:-} == - ]] && st=""
[[ ${sig:-} == - ]] && sig=""
[[ ${dead:-} == 1 ]] || exit 0
# The viewer this hook started ended without Enter (killed): closed, never
# shown again. A mark left by an older viewer (the pane started again by hand) goes.
mark=$(t show -pqv -t "$pane" @klepsydra_dead 2>/dev/null)
if [[ -n $mark ]]; then
  if [[ ${mark%% *} == "${ppid:-}" ]]; then
    t kill-pane -t "$pane" 2>/dev/null
    flog INFO "a dead pane's viewer ended; closed it" pane="$pane"
    exit 0
  fi
  t set -pu -t "$pane" @klepsydra_dead 2>/dev/null
fi
if [[ -n ${sig:-} ]]; then why="its process ended on signal $sig"; else why="its process exited with status ${st:-unknown}"; fi
dir=${KLEPSYDRA_DEAD_DIR:-${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}/dead-panes}
saved=$dir/$(date +%Y%m%d-%H%M%S)-${pane#%}.txt
if mkdir -p -- "$dir" && { printf 'Pane %s: %s at %s.\nCommand: %s\n\n' "$pane" "$why" "$(date '+%F %T')" "${cmd:-}"; t capture-pane -p -J -S -500 -t "$pane"; } >"$saved" 2>/dev/null; then
  show="cat $(printf '%q' "$saved")"
else
  saved="" show=":"
fi
find "${dir:?}" -maxdepth 1 -name '*.txt' -mtime +7 -delete 2>/dev/null
note="[klepsydra] This pane's process ${why#its process }.${saved:+ Its last screen is saved in $saved.} Press Enter to close."
if t respawn-pane -t "$pane" "$show; printf '\\n%s\\n' $(printf '%q' "$note"); read -r _"; then
  t set -p -t "$pane" @klepsydra_dead "$(t display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) $why"
  flog WARN "pane died; started again on its saved screen so tmux 3.4 cannot crash on it" pane="$pane" reason="$why" saved="$saved"
else
  # Never left exited: a focus event on it would take the server down. Only a
  # pane still dead: one started again meanwhile is someone's, and stays.
  if [[ $(t display-message -p -t "$pane" '#{pane_dead}' 2>/dev/null) == 1 ]]; then
    t kill-pane -t "$pane" 2>/dev/null
    flog ERROR "pane died and could not be started again; closed it" pane="$pane" reason="$why" saved="$saved"
  else
    flog WARN "pane died, and someone else started it again first; left it" pane="$pane" reason="$why" saved="$saved"
  fi
fi
