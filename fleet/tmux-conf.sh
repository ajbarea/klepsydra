#!/usr/bin/env bash
# tmux-conf.sh HOOK_DIR: have the running fleet tmux server read the installed
# klepsydra-tmux.conf (HOOK_DIR, ~/.claude) now (#290): a server reads its conf
# only when it starts, so a new pane-died hook would wait for the next restart.
# A pane already dead there is handled as the hook would. With no server
# running, nothing. Exit 1 when the server would not read the conf.
set -u
FLEET_TARGET=fleet::tmux-conf
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
dir=${1:?usage: tmux-conf.sh HOOK_DIR}
conf=$dir/klepsydra-tmux.conf
[[ -f $conf ]] || exit 0
t has-session 2>/dev/null || exit 0
# The panes dead before the hook is set: one that dies after it gets tmux's own run.
mapfile -t dead_panes < <(t list-panes -a -F '#{pane_dead} #{pane_id}' 2>/dev/null | awk '$1 == 1 && $2 ~ /^%[0-9]+$/ { print $2 }')
if ! t source-file "$conf" 2>/dev/null; then
  flog ERROR "the running fleet tmux server could not read the installed tmux conf" conf="$conf" socket="$FLEET_SOCK"
  exit 1
fi
flog INFO "the running fleet tmux server read the installed tmux conf" conf="$conf" socket="$FLEET_SOCK"
sock_path=$(t display-message -p '#{socket_path}' 2>/dev/null)
for p in "${dead_panes[@]}"; do
  bash "$dir/klepsydra-pane-died.sh" "$sock_path" "$p" </dev/null >/dev/null 2>&1
  flog WARN "a pane already dead on the running server was handled by the pane-died hook" pane="$p"
done
exit 0
