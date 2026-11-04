#!/usr/bin/env bash
# send.sh PANE TEXT...: send a message to the Claude Code session in fleet pane
# PANE (Heph to a worker, a worker to Heph) so it is submitted, not left in the
# input box (#320). Raw `tmux send-keys TEXT Enter` types the text as a burst
# that Claude Code reads as a paste, and the Enter right after it can be lost.
# Here the text goes in as a bracketed paste, is checked in the box, then Enter
# is pressed until the box empties (three times at most). A running turn is no
# bar: Claude Code queues a message sent during one. Text already in the box
# (AJ typing) is never touched. TEXT "-" reads the message from stdin.
# Prints sent, not-pasted (the box held text, or the paste never showed),
# mixed (pasted beside text typed meanwhile: left unsent) or held (still in
# the box after three Enters); exits 0 only for sent, 2 for bad arguments.
set -u
FLEET_TARGET=fleet::send
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
(( $# >= 2 )) || { err "usage: fleet send PANE TEXT... (TEXT - reads stdin)"; exit 2; }
p=$1
shift
[[ $p =~ ^%[0-9]+$ ]] || { err "a pane is %N: $p"; exit 2; }
# tmux 3.4 answers for a gone pane with an empty field and exit 0: the id decides.
[[ $(t display-message -p -t "$p" '#{pane_id}' 2>/dev/null) == "$p" ]] || { err "no pane $p on the fleet's tmux server ($FLEET_SOCK)"; exit 2; }
if [[ $1 == - && $# -eq 1 ]]; then text=$(cat); else text="$*"; fi
[[ -n ${text//[[:space:]]/} ]] || { err "nothing to send"; exit 2; }
# Not inbox/: the resume service types every file there into its pane.
mkdir -p -- "$FLEET_STATE/send"
f=$(mktemp "$FLEET_STATE/send/msg-XXXXXX") || { err "cannot write in $FLEET_STATE/send"; exit 1; }
printf '%s' "$text" >"$f"
got=$(inbox_deliver "$p" "$f" any)
rm -f -- "${f:?}"
if [[ $got == sent ]]; then
  flog INFO "message sent" pane="$p" chars="${#text}" result="$got"
else
  flog WARN "message not sent" pane="$p" chars="${#text}" result="$got" text="${text:0:120}"
fi
echo "$got"
[[ $got == sent ]]
