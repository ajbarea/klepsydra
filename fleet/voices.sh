#!/usr/bin/env bash
# voices.sh [MODE] | --check (`fleet voices`): make keryx follow the tray's Voices mode
# now, for running sessions too (#273). MODE (heph, everyone or off) is saved
# to klepsydra's prefs.json first; with none, the saved mode applies.
#   off       keryx off (keryx's own switch: its daemon stops, the GPU is freed)
#   heph      keryx on; only the orchestrator's session speaks (keryx
#             speak_only reads orchestrator.session, which the fleet keeps current)
#   everyone  keryx on; every session speaks
# keryx is changed only where it differs; each run logs the values it decided
# on. The resume service runs it every pass, the tray on every change.
# --check only says whether keryx matches the saved mode (exit 1 when not).
set -u
FLEET_TARGET=fleet::voices
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
PREFS=$KLEPSYDRA_DIR/prefs.json
KERYX_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/keryx/config.json
ORCH_SESSION=$FLEET_STATE/orchestrator.session

# The keryx command: on PATH, else the newest one in the plugin cache (a
# systemd unit's PATH has no plugin folders).
keryx_bin() {
  local b
  # FLEET_KERYX (tests): that file, or nothing when it is not one.
  if [[ -n ${FLEET_KERYX+x} ]]; then [[ -x ${FLEET_KERYX} && -f ${FLEET_KERYX} ]] && printf '%s' "$FLEET_KERYX"; return; fi
  if b=$(command -v keryx 2>/dev/null); then printf '%s' "$b"; return; fi
  b=$(find "$HOME"/.claude*/plugins/cache/*/keryx/*/bin/keryx -maxdepth 0 -type f 2>/dev/null | sort -V | tail -1)
  [[ -n $b ]] && printf '%s' "$b"
}

# The saved mode: prefs.json's "voices" when it is one of the three, else heph
# (launch.sh's reading before #273; the tray's default).
saved_mode() {
  jq -ser 'if length == 1 then .[0].voices else empty end | select(. == "heph" or . == "everyone" or . == "off")' "$PREFS" 2>/dev/null || echo heph
}

check=0 mode=${1:-}
[[ $mode == --check ]] && { check=1 mode=""; }
if [[ -n $mode ]]; then
  [[ $mode == heph || $mode == everyone || $mode == off ]] || { err "usage: fleet voices [heph|everyone|off]"; exit 2; }
  tmp=$(mktemp "$PREFS.XXXXXX") || { err "cannot write beside $PREFS"; exit 1; }
  if { jq -e 'type == "object"' "$PREFS" >/dev/null 2>&1 && jq --arg m "$mode" '.voices = $m' "$PREFS" || jq -n --arg m "$mode" '{voices: $m}'; } >"$tmp"; then
    mv -f -- "$tmp" "$PREFS"
  else
    rm -f -- "${tmp:?}"
    err "could not save the mode to $PREFS"
    exit 1
  fi
else
  mode=$(saved_mode)
fi

# What keryx should hold for MODE, and what it holds now (its own file; a key
# it lacks is its default: enabled, every session).
want_on=true want_only='[]'
case $mode in
  off) want_on=false ;;
  heph) want_only=$(jq -cn --arg f "$ORCH_SESSION" '[$f]') ;;
esac
have_on=$(jq -r 'if .enabled == false then "false" else "true" end' "$KERYX_CONFIG" 2>/dev/null || echo true)
have_only=$(jq -c '.speak_only // [] | if type == "string" then [.] else . end' "$KERYX_CONFIG" 2>/dev/null || echo '[]')

if (( check )); then
  # Off holds whatever speak_only was: keryx off silences every session anyway.
  if [[ $have_on == "$want_on" && ( $want_on == false || $have_only == "$want_only" ) ]]; then
    echo "keryx matches $mode"
    exit 0
  fi
  echo "keryx differs from $mode: enabled $have_on, speak_only $have_only"
  exit 1
fi

bin=$(keryx_bin)
if [[ -z $bin ]]; then
  flog WARN "voices: keryx is not installed; nothing to change" mode="$mode"
  echo "keryx is not installed"
  exit 0
fi
changed=""
# Off leaves speak_only as it is: keryx off silences every session anyway.
if [[ $want_on == true && $have_only != "$want_only" ]]; then
  if [[ $want_only == '[]' ]]; then out=$("$bin" speak-only --everyone 2>&1); else out=$("$bin" speak-only "$ORCH_SESSION" 2>&1); fi || {
    flog ERROR "voices: keryx refused speak-only (older than 0.12.0?)" mode="$mode" keryx="$bin" said="${out:0:200}"
    err "keryx could not set speak-only: $out"
    exit 1
  }
  changed+="speak_only "
fi
if [[ $have_on != "$want_on" ]]; then
  if [[ $want_on == true ]]; then "$bin" on >/dev/null 2>&1; else "$bin" off >/dev/null 2>&1; fi || {
    flog ERROR "voices: keryx on/off failed" mode="$mode" keryx="$bin"
    exit 1
  }
  changed+="enabled "
fi
if [[ -n $changed ]]; then
  flog INFO "voices: keryx set to the tray's mode" mode="$mode" changed="${changed% }" enabled="$want_on" speak_only="$want_only" was_enabled="$have_on" was_speak_only="$have_only"
  echo "voices: $mode (changed: ${changed% })"
else
  echo "voices: $mode (keryx already matches)"
fi
