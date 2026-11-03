#!/usr/bin/env bash
# voices.sh [MODE | --if-changed | --check] (`fleet voices`): make keryx follow
# the tray's Voices mode, for running sessions too (#273). MODE (heph,
# everyone or off) is saved to klepsydra's prefs.json first; with none, the
# saved mode applies.
#   off       keryx off (keryx's own switch: its daemon stops, the GPU is freed)
#   heph      keryx on; only the orchestrator's session speaks (keryx
#             speak_only reads orchestrator.session, which the fleet keeps current)
#   everyone  keryx on; every session speaks
# A plain run (the tray's, AJ's) always applies the mode. --if-changed (the
# resume service, every pass) applies it only when it differs from the mode
# last applied, so a deliberate `keryx off` between changes is left alone.
# --check says whether the saved mode has been applied (exit 1 when not).
# keryx is changed only where it differs; each change logs the values decided on.
set -u
FLEET_TARGET=fleet::voices
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
PREFS=$KLEPSYDRA_DIR/prefs.json
KERYX_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/keryx/config.json
ORCH_SESSION=$(realpath -m -- "$FLEET_STATE/orchestrator.session")
APPLIED=$FLEET_STATE/voices.applied
KERYX_WAIT_S=${KERYX_WAIT_S:-120} # a new keryx's first run syncs its environment

# The keryx command: the newest version in either account's plugin cache (a
# unit's PATH can pin an old one), else keryx on PATH. FLEET_KERYX (tests):
# that file, or none when it is not one.
keryx_bin() {
  local b
  if [[ -n ${FLEET_KERYX+x} ]]; then [[ -x ${FLEET_KERYX} && -f ${FLEET_KERYX} ]] && printf '%s' "$FLEET_KERYX"; return; fi
  b=$(find "$HOME"/.claude*/plugins/cache/*/keryx/*/bin/keryx -maxdepth 0 -type f 2>/dev/null |
    awk -F/ '{ print $(NF-2) "\t" $0 }' | sort -V -k1,1 | tail -1 | cut -f2-)
  [[ -z $b ]] && b=$(command -v keryx 2>/dev/null)
  [[ -n $b ]] && printf '%s' "$b"
}
# Whether keryx BIN has speak_only (0.12.0 and later): read from its source
# beside it, never by running it.
has_speak_only() { # BIN
  local src
  src=$(dirname -- "$(readlink -f -- "$1")")/../src/keryx/__main__.py
  [[ -f $src ]] && grep -q '"speak-only"' -- "$src"
}

# The saved mode: prefs.json's "voices" when it is one of the three, else heph
# (the tray's default).
saved_mode() {
  jq -ser 'if length == 1 then .[0].voices else empty end | select(. == "heph" or . == "everyone" or . == "off")' "$PREFS" 2>/dev/null || echo heph
}

run=apply mode=${1:-}
case $mode in
  --check) run=check mode="" ;;
  --if-changed) run=if-changed mode="" ;;
esac
if [[ -n $mode ]]; then
  [[ $mode == heph || $mode == everyone || $mode == off ]] || { err "usage: fleet voices [heph|everyone|off|--if-changed|--check]"; exit 2; }
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
applied=$(cat "$APPLIED" 2>/dev/null)

if [[ $run == check ]]; then
  if [[ $applied == "$mode" ]]; then
    echo "applied $mode"
    exit 0
  fi
  why="fleet voices applies it"
  if b=$(keryx_bin) && [[ -n $b ]] && [[ $mode == heph ]] && ! has_speak_only "$b"; then
    why="keryx at $b has no speak_only: update the keryx plugin to 0.12.0 or later on both accounts"
  fi
  echo "$mode not applied (last applied: ${applied:-none}): $why"
  exit 1
fi
[[ $run == if-changed && $applied == "$mode" ]] && exit 0
# The service does not retry a keryx without speak_only until another is
# installed, nor any other failure for 15 min, so a fault is logged once.
FAILED=$FLEET_STATE/voices.failed
if [[ $run == if-changed ]] && read -r f_mode f_bin f_at f_kind <"$FAILED" 2>/dev/null && [[ $f_mode == "$mode" && $f_bin == "$(keryx_bin)" ]] &&
  { [[ $f_kind == old ]] || (( $(date +%s) - ${f_at:-0} < 900 )); }; then
  exit 0
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
need_only=0
[[ $want_on == true && $have_only != "$want_only" ]] && need_only=1
if [[ $have_on == "$want_on" ]] && (( !need_only )); then
  printf '%s\n' "$mode" >"$APPLIED"
  echo "voices: $mode (keryx already matches)"
  exit 0
fi

bin=$(keryx_bin)
if [[ -z $bin ]]; then
  flog WARN "voices: keryx is not installed; nothing to change" mode="$mode"
  echo "keryx is not installed"
  exit 0
fi
changed="" failed=""
# On first, so a refused speak-only never leaves the orchestrator silent.
if [[ $have_on != "$want_on" ]]; then
  if [[ $want_on == true ]]; then verb=on; else verb=off; fi
  if timeout "$KERYX_WAIT_S" "$bin" "$verb" >/dev/null 2>&1; then changed+="enabled "; else failed+="$verb "; fi
fi
if (( need_only )); then
  if ! has_speak_only "$bin"; then
    failed+="speak_only(keryx<0.12.0) "
  elif [[ $want_only == '[]' ]]; then
    if timeout "$KERYX_WAIT_S" "$bin" speak-only --everyone >/dev/null 2>&1; then changed+="speak_only "; else failed+="speak_only "; fi
  else
    if timeout "$KERYX_WAIT_S" "$bin" speak-only "$ORCH_SESSION" >/dev/null 2>&1; then changed+="speak_only "; else failed+="speak_only "; fi
  fi
fi
if [[ -n $failed ]]; then
  # Not recorded as applied; the service tries again later (see FAILED).
  kind=other
  [[ $failed == "speak_only(keryx<0.12.0) " ]] && kind=old
  printf '%s %s %s %s\n' "$mode" "$bin" "$(date +%s)" "$kind" >"$FAILED"
  flog ERROR "voices: keryx could not be set to the tray's mode" mode="$mode" failed="${failed% }" changed="${changed% }" keryx="$bin" timeout_s="$KERYX_WAIT_S"
  echo "voices: $mode not fully applied (failed: ${failed% })"
  exit 1
fi
printf '%s\n' "$mode" >"$APPLIED"
rm -f -- "${FAILED:?}"
flog INFO "voices: keryx set to the tray's mode" mode="$mode" changed="${changed% }" enabled="$want_on" speak_only="$want_only" was_enabled="$have_on" was_speak_only="$have_only"
echo "voices: $mode (changed: ${changed% })"
