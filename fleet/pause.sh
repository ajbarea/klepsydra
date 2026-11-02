#!/usr/bin/env bash
# pause.sh pause NAME WHY... | unpause NAME (`fleet pause`, `fleet unpause`):
# set an agent aside without losing it (#246). Pause moves its panes.tsv row to
# paused.tsv (name, note, then the row itself), so `fleet recover` and the
# doctor leave it alone; only an agent whose session no longer runs can be
# paused. Unpause puts the row back, and the next `fleet recover` launches it
# fresh from its brief. Both run under the registry lock.
set -u
FLEET_TARGET=fleet::pause
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
PAUSED=${FLEET_PAUSED:-$FLEET_STATE/paused.tsv}
cmd=${1:-} name=${2:-}
shift 2 2>/dev/null
why="$*"
case $cmd in
  pause) [[ -n $name && -n ${why//[[:space:]]/} ]] || { err "usage: fleet pause NAME WHY..."; exit 2; } ;;
  unpause) [[ -n $name && $# -eq 0 ]] || { err "usage: fleet unpause NAME"; exit 2; } ;;
  *) err "usage: pause.sh pause NAME WHY... | unpause NAME"; exit 2 ;;
esac
[[ $name != *[[:space:]]* ]] || { err "fleet $cmd: a name has no spaces"; exit 2; }

# A refusal: logged with its reason, and said on stderr.
refuse() { flog WARN "fleet $cmd refused" name="$name" reason="$*"; err "fleet $cmd: $*"; }

# Writes FILE from awk's output on stdin, whole (temp file, then rename).
put() { # FILE
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  if cat >"$tmp" && mv -f -- "$tmp" "$1"; then return 0; fi
  rm -f -- "${tmp:?}"
  return 1
}

# shellcheck disable=SC2329 # run through with_registry
pause_now() {
  local rows row p sid
  rows=$(awk -F'\t' -v n="$name" '$2 == n' "$REGISTRY" 2>/dev/null)
  [[ -n $rows ]] || { refuse "no agent named $name in panes.tsv"; return 1; }
  (( $(grep -c . <<<"$rows") == 1 )) || { refuse "more than one row is named $name"; return 1; }
  row=$rows p=$(cut -f1 <<<"$row") sid=$(cut -f4 <<<"$row")
  if [[ $(row_state "$p" "$sid") == running ]]; then
    refuse "$name still runs in $p; end its session first"
    return 1
  fi
  awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$PAUSED" 2>/dev/null &&
    { refuse "$name is already in paused.tsv"; return 1; }
  printf '%s\tPAUSED %s: %s\t%s\n' "$name" "$(date '+%m-%d %H:%M')" "${why//[$'\t\n']/ }" "$row" >>"$PAUSED" || return 1
  if ! awk -F'\t' -v n="$name" '$2 != n' "$REGISTRY" | put "$REGISTRY"; then
    # Never in both files: take the line just added back out.
    awk -F'\t' -v n="$name" '$1 != n' "$PAUSED" | put "$PAUSED"
    refuse "could not rewrite panes.tsv; nothing changed"
    return 1
  fi
  flog INFO "agent paused" name="$name" pane="$p" session="$sid" why="$why"
  echo "paused: $name ($p): fleet unpause $name brings it back"
}

# shellcheck disable=SC2329 # run through with_registry
unpause_now() {
  local line row
  line=$(awk -F'\t' -v n="$name" '$1 == n' "$PAUSED" 2>/dev/null | head -1)
  [[ -n $line ]] || { refuse "no agent named $name in paused.tsv"; return 1; }
  row=$(cut -f3- <<<"$line")
  if [[ $(cut -f2 <<<"$row") != "$name" ]]; then
    refuse "$name was paused by hand, with no saved row; relaunch it from its brief (launch.sh)"
    return 1
  fi
  awk -F'\t' -v n="$name" '$2 == n { f = 1 } END { exit !f }' "$REGISTRY" 2>/dev/null &&
    { refuse "panes.tsv already has a row named $name"; return 1; }
  printf '%s\n' "$row" >>"$REGISTRY" || return 1
  awk -F'\t' -v n="$name" '$1 != n' "$PAUSED" | put "$PAUSED" || return 1
  flog INFO "agent unpaused" name="$name" pane="$(cut -f1 <<<"$row")"
  echo "unpaused: $name: fleet recover launches it fresh from its brief"
}

with_registry "${cmd}_now"
