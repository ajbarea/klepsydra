#!/usr/bin/env bash
# klepsydra's wrap-up, in two roles.
#
# As a Stop hook (no arguments, the event on stdin; registered without
# "async" so Claude Code reads its output): while the wall's wrap-up request
# is live and this session has not been asked, it hands Claude the wrap-up
# instructions once, as additionalContext, so the turn continues with a
# checkpoint. Otherwise, and on any error, it prints nothing and exits 0.
#
# As `klepsydra-wrapup.sh ready SESSION` or `klepsydra-wrapup.sh blocked
# SESSION REASON`, run by Claude at the end of that turn: it records the
# session's answer for the wall.

set -uo pipefail

# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
# The overlay's app-local-data dir, named for the bundle identifier in
# src-tauri/tauri.conf.json. Not the install dir: the uninstaller's "delete app
# data" reaches only this one, and a per-machine install cannot be written to.
# Under WSL the overlay is a Windows app, so the hook writes across to it. On
# Linux, Tauri honours XDG_DATA_HOME only when it is absolute, and so must we,
# or the readings land under whatever directory Claude Code is running in.
if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  osrelease=""
  { read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null  # builtin: no process per run
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    if [[ -n "${USER:-}" ]]; then
      KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
    fi
  else
    data_home="${HOME:-}/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    [[ "$data_home" == /* ]] && KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi
# --- end klepsydra dir ---

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
SKILL=${KLEPSYDRA_WRAPUP_SKILL:-${HOME:-}/.claude/skills/klepsydra-wrapup/SKILL.md}
WRAP=${KLEPSYDRA_DIR:-}/wrapup
REASON_CHARS=300

fail() { printf '%s\n' "$*" >&2; exit 1; }
now() { printf '%(%s)T' -1; }

write_atomic() { # file text
  local tmp="$1.$$.tmp"
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# A regular file, not a FIFO (a read would hang the Stop) and not a symlink.
plain() { [[ -f $1 && ! -L $1 ]]; }

# Sets request_id when the wall's request has not expired and lists SESSION.
live_request() { # session
  local id until listed
  [[ -n ${KLEPSYDRA_DIR:-} ]] && plain "$WRAP/request.json" || return 1
  IFS=$'\t' read -r id until listed < <(jq -r --arg s "$1" \
    '[(.id | strings), (.until | numbers | floor | tostring), ((.ids // []) | index($s) != null | tostring)] | @tsv' \
    "$WRAP/request.json" 2>/dev/null) || return 1
  [[ $id =~ ^[0-9]{1,20}$ && $until =~ ^[0-9]{1,12}$ && $listed == true ]] || return 1
  (( until >= $(now) )) || return 1
  request_id=$id
}

# The skill's body without its frontmatter, the session's id put in.
instructions() { # session
  local body
  plain "$SKILL" || return 1
  body=$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$SKILL" 2>/dev/null) || return 1
  [[ -n ${body//[[:space:]]/} ]] || return 1
  # shellcheck disable=SC2016 # the skill's literal placeholder, not an expansion
  printf '%s' "${body//'${CLAUDE_SESSION_ID}'/$1}"
}

stop_hook() {
  local sid body
  sid=$(jq -r '.session_id | strings' 2>/dev/null) || return 0
  [[ $sid =~ $UUID_RE ]] || return 0
  live_request "$sid" || return 0
  if [[ -e $WRAP/$sid.json || -L $WRAP/$sid.json ]]; then
    plain "$WRAP/$sid.json" || return 0
    jq -e --arg r "$request_id" '.request == $r' "$WRAP/$sid.json" >/dev/null 2>&1 && return 0
  fi
  body=$(instructions "$sid") || return 0
  write_atomic "$WRAP/$sid.json" "$(jq -cn --arg r "$request_id" --argjson at "$(now)" \
    '{request: $r, state: "asked", at: $at}')" || return 0
  jq -cn --arg c "$body" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
}

report() { # state session [reason]
  local state=$1 sid=$2 reason=${3:-}
  [[ $sid =~ $UUID_RE ]] || fail "Not a session id: $sid"
  if [[ $state == blocked ]]; then
    reason=${reason//[[:cntrl:]]/ }
    [[ -n ${reason//[[:space:]]/} ]] || fail "Say what would be lost: klepsydra-wrapup.sh blocked SESSION REASON"
    reason=${reason:0:REASON_CHARS}
  fi
  command -v jq >/dev/null 2>&1 || fail "jq is not installed."
  live_request "$sid" || fail "No wrap-up is waiting for this session's answer; nothing was recorded."
  write_atomic "$WRAP/$sid.json" "$(jq -cn --arg r "$request_id" --arg s "$state" --arg why "$reason" \
    --argjson at "$(now)" '{request: $r, state: $s, at: $at} + (if $why == "" then {} else {reason: $why} end)')" ||
    fail "Could not write $WRAP/$sid.json."
  printf 'Told klepsydra: %s.\n' "$state"
}

case ${1:-} in
  "") stop_hook; exit 0 ;;
  ready) (( $# == 2 )) || fail "usage: klepsydra-wrapup.sh ready SESSION"; report ready "$2" ;;
  blocked) (( $# == 3 )) || fail "usage: klepsydra-wrapup.sh blocked SESSION REASON"; report blocked "$2" "$3" ;;
  *) fail "usage: klepsydra-wrapup.sh [ready SESSION | blocked SESSION REASON]" ;;
esac
