#!/usr/bin/env bash
# accounts-sync.sh [--check] [DIR...]: make each second Claude Code config
# folder (default: every folder in FLEET_ACCOUNTS but the first) behave like
# ~/.claude while keeping its own login. Claude Code keeps one login per
# folder (.credentials.json, and the account in its .claude.json), so both
# folders stay logged in at once; this script never reads or writes a login.
#   settings.json      a copy of ~/.claude's: hooks, statusLine, env and OTel,
#                      plugins and their config, autoMemoryDirectory. A link
#                      would be read as project settings when run from $HOME.
#   plugins/*.json     copies of the installed and known lists, which point at
#                      ~/.claude's plugin cache, so both run the same plugins;
#                      plugins/data links to ~/.claude's (plugin state shared)
#   .claude.json       only the keys in SHARED_KEYS (MCP servers, each
#                      folder's trust and tools, onboarding done), so a fleet
#                      launch never stops at a first-run screen
#   links              CLAUDE.md, agents, commands, rules, output-styles,
#                      keybindings.json, techne.toml, hooks, projects (one
#                      session history, so a session resumes on either
#                      account) and each skill folder but claude.ai's synced ones
# --check prints what differs and fails if anything does; nothing is written.
set -u
FLEET_TARGET=fleet::accounts
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
check=0
[[ ${1:-} == --check ]] && { check=1; shift; }
SRC=${FLEET_CLAUDE_SRC:-$FLEET_DEFAULT_CONFIG}
SRC_JSON=$(config_json "$SRC")
LINKS=(CLAUDE.md agents commands rules output-styles keybindings.json techne.toml hooks projects)
# What of .claude.json both folders share: SHARED_KEYS, and of each projects entry its trust and tool grants.
# shellcheck disable=SC2016 # a jq program
SHARED='with_entries(select(.key as $x | $k | index($x)))
  | if (.projects | type) == "object" then .projects |= map_values(with_entries(select(.key | IN("hasTrustDialogAccepted", "allowedTools", "hasClaudeMdExternalIncludesApproved")))) else . end'
SHARED_KEYS='["mcpServers","projects","githubRepoPaths","hasCompletedOnboarding","lastOnboardingVersion","lastReleaseNotesSeen","installMethod","autoUpdates","autoUpdatesProtectedForNative","shiftEnterKeyBindingInstalled","remoteDialogSeen","hasUsedRemoteControl","effortCalloutV2Dismissed","hasSeenAutoModeEntryWarning"]'
if (( $# )); then
  dsts=("$@")
else
  read -ra dsts <<<"$FLEET_ACCOUNTS"
  dsts=("${dsts[@]:1}")
fi
drift=0

differs() { drift=1; printf 'differs: %s\n' "$1"; }
SRC_REAL=$(readlink -f -- "$SRC")

# Whether DST/NAME's folder resolves into the first folder (a link the second
# folder holds into ~/.claude): writing there would change the first account's
# own files, so nothing is written and the sync fails.
inside_src() { # NAME
  local dir
  dir=$(readlink -f -- "$DST/$(dirname -- "$1")") || return 1
  if [[ $dir == "$SRC_REAL" || $dir == "$SRC_REAL"/* ]]; then
    err "$DST/$1 resolves into $SRC; not written"
    drift=1
    return 0
  fi
  return 1
}

# Make DST/NAME a link to TARGET (when TARGET exists); a file or folder in the
# way is moved aside to DST/.sync-bak/, never deleted (inside skills/ it would
# load as a second skill).
link() { # TARGET NAME
  local target=$1 name=$2
  [[ -e $target ]] || return 0
  [[ $(readlink -- "$DST/$name") == "$target" ]] && return 0
  if (( check )); then differs "$DST/$name is not a link to $target"; return 0; fi
  inside_src "$name" && return 0
  if [[ -e $DST/$name || -L $DST/$name ]]; then
    mkdir -p -- "$DST/.sync-bak"
    mv -- "$DST/$name" "$DST/.sync-bak/${name//\//_}.$(date +%Y%m%d%H%M%S)"
  fi
  ln -s -- "$target" "$DST/$name"
}

# Make DST/NAME a copy of SRC-FILE's content.
copy() { # SRC-FILE NAME
  [[ -r $1 ]] || return 0
  cmp -s -- "$1" "$DST/$2" && return 0
  if (( check )); then differs "$DST/$2 is not a copy of $1"; return 0; fi
  mkdir -p -- "$(dirname -- "$DST/$2")"
  inside_src "$2" && return 0
  cp -- "$1" "$DST/$2.tmp.$$" && mv -f -- "$DST/$2.tmp.$$" "$DST/$2"
}

[[ -d $SRC ]] || { err "no Claude Code config at $SRC"; exit 2; }
for DST in "${dsts[@]}"; do
  d=$(readlink -f -- "$DST")
  if [[ $d == "$SRC_REAL" || $d == "$SRC_REAL"/* || $SRC_REAL == "$d"/* ]]; then
    err "the second folder is, holds or sits in the first: $DST"
    exit 2
  fi
  (( check )) || mkdir -p -- "$DST/plugins" "$DST/skills"
  copy "$SRC/settings.json" settings.json
  copy "$SRC/plugins/installed_plugins.json" plugins/installed_plugins.json
  copy "$SRC/plugins/known_marketplaces.json" plugins/known_marketplaces.json
  link "$SRC/plugins/data" plugins/data
  for n in "${LINKS[@]}"; do link "$SRC/$n" "$n"; done
  for d in "$SRC"/skills/*/; do
    [[ -d $d && ${d%/} != */synced ]] || continue # skills synced from claude.ai differ per account
    d=${d%/}
    link "$d" "skills/${d##*/}"
  done

  # The shared keys of .claude.json, which also holds the account; the rest of
  # it is left as it is. Of each folder's entry in projects only its trust and
  # tool grants are shared (the rest is per session), merged into the second
  # folder's own. A second .claude.json that does not parse is one Claude Code
  # is rewriting: it is left alone and the sync fails.
  if [[ -r $SRC_JSON ]]; then
    want=$(jq -cS --argjson k "$SHARED_KEYS" "$SHARED" "$SRC_JSON" 2>/dev/null)
    # shellcheck disable=SC2016 # jq's own variables
    MERGE='(. * $w) + ($w | del(.projects))'
    if [[ -e $DST/.claude.json ]] && ! jq -e 'type == "object"' "$DST/.claude.json" >/dev/null 2>&1; then
      err "$DST/.claude.json does not parse; left as it is"
      drift=1
    elif [[ -n $want ]]; then
      # Drift is a merge that would change the file: keys only the second
      # folder holds (its own trust, its own Remote Control flags) are kept.
      if [[ -e $DST/.claude.json ]]; then
        have=$(jq -cS . "$DST/.claude.json") merged=$(jq -cS --argjson w "$want" "$MERGE" "$DST/.claude.json")
      else
        have="" merged=$want
      fi
      if [[ $merged == "$have" ]]; then
        :
      elif (( check )); then
        differs "$DST/.claude.json's shared keys"
      else
        tmp=$(mktemp "$DST/.claude.json.XXXXXX")
        # shellcheck disable=SC2016 # jq's own variable
        if [[ -e $DST/.claude.json ]]; then merge=("$MERGE" "$DST/.claude.json"); else merge=(-n '$w'); fi
        if jq --argjson w "$want" "${merge[@]}" >"$tmp" && [[ -s $tmp ]] && chmod 600 "$tmp"; then
          mv -f -- "$tmp" "$DST/.claude.json"
        else
          rm -f -- "${tmp:?}"
          err "could not write $DST/.claude.json"
          drift=1
        fi
      fi
    fi
  fi
  (( check )) || flog INFO "second config folder synced" folder="$DST" from="$SRC"
done

if (( check )); then
  (( drift )) && flog WARN "a second config folder differs from the first" folders="${dsts[*]}"
  exit "$drift"
fi
if (( drift )); then
  flog ERROR "second config folder sync failed" folders="${dsts[*]}"
  exit 1
fi
echo "synced ${dsts[*]} from $SRC"
