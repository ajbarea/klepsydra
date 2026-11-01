#!/usr/bin/env bash
# doctor.sh (`fleet doctor`): check the fleet's health and print one line per
# check, "ok", "warn" or "FAIL" with what was found; exits non-zero on any FAIL.
# Checks: the resume service is active and its last pass is recent; every
# registered pane and the orchestrator's has Remote Control on (the link its
# live session's fleet file holds, which is what the phone wall's Open in
# Claude uses); the phone wall answers on 127.0.0.1:8318 and through
# Tailscale Serve with a fresh fleet.json (a usage reading observed in the last
# 2 minutes); a pane watcher is running; each config folder in FLEET_ACCOUNTS
# is logged in and the second ones match the first; the copies in ~/.claude
# (hooks, status line, launcher, cast) match the checkout. Briefs whose shared rules
# are out of date, and a second folder not logged in, are warnings.
# With `--json FILE` (the fleet-doctor timer) it also writes the checks to FILE
# for the wall, and logs a check only when its status changed since FILE's run.
set -u
FLEET_TARGET=fleet::doctor
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
SYSTEMCTL=${FLEET_SYSTEMCTL:-systemctl}
# The phone wall listens on Windows' loopback, which WSL reaches only through Windows' own curl.
CURL=${FLEET_CURL:-curl.exe}
TAILSCALE=${FLEET_TAILSCALE:-tailscale.exe}
PS=${FLEET_PS:-ps}
PHONE=${FLEET_PHONE:-http://127.0.0.1:8318}
BEAT_MAX_S=${FLEET_BEAT_MAX_S:-600}
FRESH_MAX_S=120
now=$(date +%s)
failed=0
json=""
if [[ ${1:-} == --json ]]; then
  json=${2:?--json takes a file}
fi
# Each check's status at the last --json run.
declare -A was=()
if [[ -n $json && -f $json ]]; then
  while IFS=$'\t' read -r c s; do [[ -n $c ]] && was[$c]=$s; done < <(jq -r '.checks[]? | [.check, .status] | @tsv' "$json" 2>/dev/null)
fi
results=()


report() { # ok|warn|FAIL CHECK DETAIL
  local check detail
  check=$(tilde "$2") detail=$(tilde "$3")
  printf '%-4s %s: %s\n' "$1" "$check" "$detail"
  results+=("$1"$'\t'"${check//[$'\t\n']/ }"$'\t'"${detail//[$'\t\n']/ }")
  [[ $1 == FAIL ]] && failed=1
  [[ -n $json && ${was[${check//[$'\t\n']/ }]-} == "$1" ]] && return
  case $1 in
    FAIL) flog ERROR "doctor: $check" detail="$detail" ;;
    warn) flog WARN "doctor: $check" detail="$detail" ;;
    # An ok detail can be a Remote Control link, which opens a session: not logged.
    ok) [[ -n ${was[${check//[$'\t\n']/ }]-} ]] && flog INFO "doctor: $check recovered" ;;
  esac
}

if $SYSTEMCTL --user is-active --quiet fleet-resume-at-reset.service 2>/dev/null; then
  report ok "resume service" "active"
else
  report FAIL "resume service" "not active: systemctl --user start fleet-resume-at-reset"
fi
beat=$(stat -c %Y -- "$FLEET_STATE/resume.beat" 2>/dev/null || echo 0)
if (( now - beat <= BEAT_MAX_S )); then
  report ok "resume loop" "last pass $((now - beat)) s ago"
else
  report FAIL "resume loop" "$( ((beat)) && echo "last pass $((now - beat)) s ago" || echo "no pass recorded")"
fi

# The newest live session file of tmux pane PANE.
session_of() {
  local f best="" best_at=-1 at
  for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f ]] || continue
    at=$(jq -r --arg p "$1" 'select(.tmux.pane == $p and .ended == null) | (.started_at // 0)' "$f" 2>/dev/null)
    [[ -n $at ]] && (( ${at%.*} > best_at )) && best=$f best_at=${at%.*}
  done
  printf '%s' "$best"
}
orch=$(orchestrator)
panes=$(awk -F'\t' 'NF >= 3 { print $1 }' "$REGISTRY" 2>/dev/null)
for p in $orch $panes; do
  who=$(reg_field "$p" 2)
  [[ $p == "$orch" ]] && who=orchestrator
  if ! fleet_panes | grep -qx "$p"; then
    if [[ $p == "$orch" ]]; then
      report FAIL "remote control $p ($who)" "the orchestrator's pane is gone"
    else
      report warn "remote control $p ($who)" "the pane is gone: a finished agent's row in panes.tsv"
    fi
    continue
  fi
  f=$(session_of "$p")
  if [[ -z $f ]]; then
    report FAIL "remote control $p ($who)" "no live session file for the pane"
  elif url=$(jq -er '.remote_url // empty' "$f" 2>/dev/null); then
    report ok "remote control $p ($who)" "$url"
  else
    report FAIL "remote control $p ($who)" "off: the resume service turns it on at its next idle prompt"
  fi
done

# fleet.json at BASE: whether it answers and its newest usage reading's age.
phone() { # CHECK BASE
  local body newest
  if ! body=$($CURL -fsS --max-time 5 "$2/fleet.json" 2>/dev/null); then
    report FAIL "$1" "no answer from $2/fleet.json"
    return
  fi
  newest=$(jq -r '[.usage[]?.observed_at // empty] | max // empty' <<<"$body" 2>/dev/null)
  if [[ -z $newest ]]; then
    report FAIL "$1" "answers, but fleet.json holds no usage reading"
  elif (( now - ${newest%.*} <= FRESH_MAX_S )); then
    report ok "$1" "fleet.json observed $((now - ${newest%.*})) s ago"
  else
    report FAIL "$1" "fleet.json is stale: observed $((now - ${newest%.*})) s ago"
  fi
}
phone "phone wall" "$PHONE"
dns=$($TAILSCALE status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
serve=$($TAILSCALE serve status 2>/dev/null)
if [[ -z $dns ]]; then
  report FAIL "phone wall over Tailscale" "Tailscale is not running or not logged in"
elif [[ -z $serve || $serve == *"No serve config"* ]]; then
  report FAIL "phone wall over Tailscale" "Tailscale Serve is not set up (README: Phone wall)"
else
  phone "phone wall over Tailscale" "https://$dns"
fi

# Two accounts: each config folder logged in, the second ones in step with the first.
for dir in $FLEET_ACCOUNTS; do
  if id=$(account_of "$dir"); then
    report ok "account $dir" "logged in: $(account_label "$id")"
  elif [[ $dir == "$FLEET_DEFAULT_CONFIG" ]]; then
    report FAIL "account $dir" "not logged in: claude auth login"
  else
    report warn "account $dir" "not logged in, so the fleet runs on one account: CLAUDE_CONFIG_DIR=$dir claude auth login"
  fi
  if [[ $dir != "$FLEET_DEFAULT_CONFIG" && -d $dir ]]; then
    if drift=$(bash "$here/accounts-sync.sh" --check "$dir" 2>/dev/null); then
      report ok "settings $dir" "in step with $FLEET_DEFAULT_CONFIG"
    else
      report FAIL "settings $dir" "$(grep -c . <<<"$drift") differences: fleet accounts sync"
    fi
  fi
done

# Each role's preferred account (#175): a live pane left on another while its own has room.
now=$(date +%s) away=""
for p in $orch $panes; do
  fleet_panes | grep -qx -- "$p" || continue
  if [[ $p == "$orch" ]]; then
    pref=${FLEET_HEPH_ACCOUNTS%% *} c=$(heph_config) who=orchestrator
  else
    pref=${FLEET_ACCOUNTS%% *} c=$(pane_config "$p") who=$(reg_field "$p" 2)
  fi
  pref_id=$(account_of "$pref") || continue
  [[ $c != "$pref" && $(account_of "$c") != "$pref_id" ]] && back_room "$pref_id" "$now" && away+="$p ($who, prefers $(account_label "$pref_id")) "
done
if [[ -n $away ]]; then
  report warn "preferred accounts" "on another account while their own has room: ${away% } (each moves back at its next finished turn)"
else
  report ok "preferred accounts" "every pane on its role's preferred account, or that one is short of room"
fi

# CI reds routed to an agent (#180) wait in its inbox for an idle prompt; an hour is too long.
stale_inbox=$(find "$FLEET_STATE/inbox" -mindepth 2 -maxdepth 2 -name '*.txt' -type f -mmin +60 -printf '%P ' 2>/dev/null)
if [[ -n $stale_inbox ]]; then
  report warn "CI inbox" "undelivered over an hour (the agent never sat idle): ${stale_inbox% }"
else
  report ok "CI inbox" "nothing waiting over an hour"
fi

# Processes running watch-panes.sh itself (bash, then the script), not a shell that names it.
watchers=$($PS -eo args= 2>/dev/null | awk '$1 ~ /(^|\/)bash$/ && $2 ~ /(^|\/)watch-panes\.sh$/ { $1 = $2 = ""; sub(/^ +/, ""); printf "%s;", $0 }')
if [[ -n $watchers ]]; then
  report ok "pane watcher" "watching ${watchers%;}"
else
  report FAIL "pane watcher" "none running: the orchestrator is not woken when an agent finishes"
fi
# Registered agents whose session no longer runs: after a hard shutdown, all of them.
gone=$(while IFS=$'\t' read -r _ name _ sid _; do
  [[ $sid =~ ^[0-9a-f-]{36}$ ]] && ! session_alive "$sid" && printf '%s ' "$name"
done < <(cat "$REGISTRY" 2>/dev/null))
if [[ -n $gone ]]; then
  report FAIL "agents" "sessions gone: ${gone% }: fleet recover"
else
  report ok "agents" "every registered session runs"
fi
mapfile -t briefs < <(awk -F'\t' 'NF >= 3 { print $3 }' "$REGISTRY" 2>/dev/null)
if (( ! ${#briefs[@]} )); then
  report ok "briefs" "no registered agents"
elif stale=$(bash "$here/brief.sh" --check "${briefs[@]}" 2>/dev/null); then
  report ok "briefs" "every registered brief has the shared rules"
else
  report warn "briefs" "$(tr '\n' ' ' <<<"$stale")(fleet brief --check)"
fi
# A hook or cast copy older than the checkout gives every session old behaviour (#244).
root=${here%/fleet} differ="" missing=""
for c in "${HOOK_COPIES[@]}"; do
  if [[ ! -f $root/${c%% *} ]]; then missing+="${c%% *} "; continue; fi
  cmp -s -- "$root/${c%% *}" "$FLEET_HOOK_DIR/${c#* }" || differ+="${c#* } "
done
if [[ -n $missing ]]; then
  report FAIL "installed copies" "missing from $root: ${missing% }"
elif [[ -n $differ ]]; then
  report FAIL "installed copies" "make install-fleet: differ from $root: ${differ% }"
else
  report ok "installed copies" "the hooks, status line, launcher and cast match $root"
fi
if [[ -n $json ]]; then
  tmp=$json.tmp.$$
  if printf '%s\n' "${results[@]}" | jq -R -s --argjson at "$now" --argjson failed "$failed" \
    '{v: 1, observed_at: $at, failed: $failed, checks: [split("\n")[] | select(length > 0) | split("\t") | {status: .[0], check: .[1], detail: .[2]}]}' >"$tmp"; then
    mv -f -- "$tmp" "$json"
  else
    rm -f -- "${tmp:?}"
    flog ERROR "doctor: could not write its report" path="$json"
  fi
else
  flog INFO "doctor ran" failed="$failed"
fi
exit "$failed"
