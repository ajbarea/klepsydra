#!/usr/bin/env bash
# doctor.sh (`fleet doctor`): check the fleet's health and print one line per
# check, "ok", "warn" or "FAIL" with what was found; exits non-zero on any FAIL.
# Checks: the resume service is active and its last pass is recent; every
# registered pane and the orchestrator's has Remote Control on (the link its
# live session's fleet file holds, which is what the phone wall's Open in
# Claude uses); the phone wall answers on 127.0.0.1:8318 and through
# Tailscale Serve; its usage readings are fresh (observed in the last 2
# minutes) while some pane is mid-turn, the only time a session refreshes them;
# a pane watcher is running, unless every live agent waits out a usage limit;
# paused agents (paused.tsv) are listed; each config folder in FLEET_ACCOUNTS
# is logged in and the second ones match the first; the copies in ~/.claude
# (hooks, status line, launcher, cast) match the checkout. Briefs whose shared rules
# are out of date, and a second folder not logged in, are warnings.
# With `--json FILE` (the fleet-doctor timer) it also writes the checks to FILE
# for the wall, and logs a check only when its status changed since FILE's run.
# `--prune` instead removes finished agents' rows from panes.tsv (#220), with a
# backup beside it, and runs no checks.
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


report() { # ok|warn|FAIL CHECK DETAIL [KEY=VALUE...]: the values are logged with it
  local check detail
  check=$(tilde "$2") detail=$(tilde "$3")
  local -a vals=("${@:4}")
  printf '%-4s %s: %s\n' "$1" "$check" "$detail"
  results+=("$1"$'\t'"${check//[$'\t\n']/ }"$'\t'"${detail//[$'\t\n']/ }")
  [[ $1 == FAIL ]] && failed=1
  [[ -n $json && ${was[${check//[$'\t\n']/ }]-} == "$1" ]] && return
  case $1 in
    FAIL) flog ERROR "doctor: $check" detail="$detail" "${vals[@]}" ;;
    warn) flog WARN "doctor: $check" detail="$detail" "${vals[@]}" ;;
    # An ok detail can be a Remote Control link, which opens a session: not logged.
    ok) [[ -n ${was[${check//[$'\t\n']/ }]-} ]] && flog INFO "doctor: $check recovered" "${vals[@]}" ;;
  esac
}

# Rows whose agent finished, as "PANE/SID<TAB>NAME" lines. A pane id alone is
# not a key: a restarted tmux server hands out %N again.
finished_rows() {
  local p name sid
  while IFS=$'\t' read -r p name _ sid _; do
    [[ -n $p && -n $name ]] && [[ $(row_state "$p" "$sid") == finished ]] && printf '%s/%s\t%s\n' "$p" "$sid" "$name"
  done < <(cat "$REGISTRY" 2>/dev/null)
}
# Drop the rows finished_rows named from panes.tsv, keeping a backup.
# shellcheck disable=SC2329 # run through with_registry
prune_now() { # PANE/SID...
  local tmp bak
  bak=$REGISTRY.bak-$(date +%Y%m%d-%H%M%S)
  cp -p -- "$REGISTRY" "$bak" || return 1
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  awk -F'\t' -v drop="$*" 'BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) gone[d[i]] = 1 } !(($1 "/" $4) in gone)' "$REGISTRY" >"$tmp" &&
    mv -f -- "$tmp" "$REGISTRY" && printf '%s' "$bak"
}
if [[ ${1:-} == --prune ]]; then
  mapfile -t rows < <(finished_rows)
  if (( ! ${#rows[@]} )); then
    echo "nothing to prune: no finished agent's row in panes.tsv"
    exit 0
  fi
  if ! bak=$(with_registry prune_now "${rows[@]%%$'\t'*}"); then
    flog ERROR "doctor: prune failed" registry="$REGISTRY"
    echo "could not prune $REGISTRY" >&2
    exit 1
  fi
  for r in "${rows[@]}"; do
    key=${r%%$'\t'*}
    echo "pruned: ${r#*$'\t'} (${key%%/*})"
    flog INFO "doctor: pruned a finished agent's row" pane="${key%%/*}" session="${key#*/}" name="${r#*$'\t'}"
  done
  echo "backup: $(home "$bak")"
  exit 0
fi

if $SYSTEMCTL --user is-active --quiet fleet-resume-at-reset.service 2>/dev/null; then
  report ok "resume service" "active"
else
  report FAIL "resume service" "not active: systemctl --user start fleet-resume-at-reset"
fi
beat=$(stat -c %Y -- "$FLEET_STATE/resume.beat" 2>/dev/null || echo 0)
saw=$(head -1 "$FLEET_STATE/resume.beat" 2>/dev/null | sed 's/ at=.*//')
if (( now - beat <= BEAT_MAX_S )); then
  report ok "resume loop" "last pass $((now - beat)) s ago${saw:+: $saw}"
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

# Limits as the panes show them (#263): one still showing OVERDUE_S past the
# reset it names was missed by the resume service; a reset time beside a limit
# wording LIMIT_RE does not know means Claude Code renamed its message again.
overdue="" unknown="" resets=""
for p in $orch $panes; do
  fleet_panes | grep -qx -- "$p" || continue
  s=$(screen "$p")
  busy "$s" && continue
  if l=$(limit_line "$s"); then
    lnow=${FLEET_NOW:-$now} # tests set the clock
    # A dated reset is exact. A time-only one can be up to 24 h ahead, so it is
    # placed only for the 5-hour window, whose reset is at most 5 h ahead: today's
    # is tomorrow's when over 19 h past, yesterday's when over 5.5 h ahead.
    # Any other time-only reset cannot tell a missed reset from a later one.
    if grep -qE 'resets [A-Z][a-z]{2} [0-9]' <<<"$l"; then
      r=$(reset_epoch "$l" "$lnow") || continue
    elif grep -qE "hit your (5-hour|session) limit" <<<"$l"; then
      r=$(reset_epoch "$l" "$lnow" 68400) || continue
      if (( r - lnow > 19800 )); then
        r=$(reset_epoch "$l" "$(date -d "$(date -d "@$lnow" +%F) 12:00 yesterday" +%s)" 86400) || continue
      fi
    else
      continue
    fi
    if (( lnow - r > ${FLEET_OVERDUE_S:-600} )); then
      overdue+="$p " resets+="$p:$(date -d "@$r" '+%H:%M') "
    fi
  else
    # Only what came after the last prompt sent: an answered limit is past.
    # A stop's shape only ("hit ... limit", "limit reached"): Claude Code's
    # near-limit notices and the /fast dialog's limit also print a reset.
    split_screen "$s"
    { near 6 | awk '/^❯ / && !/^❯ \// { b = ""; next } { b = b $0 "\n" } END { printf "%s", b }'; printf '%s\n' "$BELOW"; } |
      grep -iE '(hit|reached)[^·]*limit|limit (hit|reached)' |
      grep -viE 'fast limit|used [0-9]+% of|approaching|now using' | grep -qE 'resets [A-Za-z0-9]' && unknown+="$p "
  fi
done
if [[ -n $overdue ]]; then
  report FAIL "limits" "still at a limit past its reset: ${overdue% } (the resume service missed it)" panes="${overdue% }" resets="${resets% }" overdue_s="${FLEET_OVERDUE_S:-600}"
elif [[ -n $unknown ]]; then
  report warn "limits" "a reset time shows beside a limit message the fleet does not recognise: ${unknown% } (LIMIT_RE in fleet/lib.sh)" panes="${unknown% }"
else
  report ok "limits" "no pane waits past its reset"
fi
for p in $orch $panes; do
  who=$(reg_field "$p" 2)
  [[ $p == "$orch" ]] && who=orchestrator
  if ! fleet_panes | grep -qx "$p"; then
    # A worker's gone pane gets its one verdict from the agents check (#220).
    [[ $p == "$orch" ]] && report FAIL "remote control $p ($who)" "the orchestrator's pane is gone"
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

# Whether the wall at BASE answers (#246): the pass or fail. A Windows program
# run from WSL now and then fails once at start, so a miss is tried again.
phone_body=""
phone() { # CHECK BASE
  local body
  if ! body=$($CURL -fsS --max-time 5 "$2/fleet.json" 2>/dev/null); then
    sleep "${FLEET_RETRY_S:-2}"
    if ! body=$($CURL -fsS --max-time 5 "$2/fleet.json" 2>/dev/null); then
      report FAIL "$1" "no answer from $2/fleet.json (tried twice)" url="$2/fleet.json"
      return
    fi
    # A miss the FAIL above does not cover: logged each time, to show how often.
    flog WARN "doctor: $1 answered only on the second try" url="$2/fleet.json" curl="$CURL"
  fi
  [[ -n $phone_body ]] || phone_body=$body
  report ok "$1" "answers at $2"
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

# The usage readings' age (#246). Only a session's status line refreshes them,
# so they age while no turn runs (every agent limited, Heph between turns) and
# nothing is broken: stale is a warning only while some pane is mid-turn.
# Missing readings are unknown, never fresh.
if [[ -n $phone_body ]]; then
  newest=$(jq -r '[.usage[]?.observed_at // empty] | max // empty' <<<"$phone_body" 2>/dev/null)
  by=$(jq -r '[.usage[]? | select(.observed_at != null)] | max_by(.observed_at) | .label // .account // "" ' <<<"$phone_body" 2>/dev/null)
  mid=""
  for p in $orch $panes; do
    fleet_panes | grep -qx -- "$p" && busy "$(screen "$p")" && mid+="$p "
  done
  mid=${mid% }
  if [[ -z $newest ]]; then
    report warn "usage readings" "fleet.json holds none: their age is unknown" now="$now" mid_turn="$mid"
  else
    age=$((now - ${newest%.*}))
    vals=(observed_at="${newest%.*}" now="$now" max_s="$FRESH_MAX_S" account="$by" mid_turn="$mid")
    if (( age < -FRESH_MAX_S )); then
      report warn "usage readings" "observed $((-age)) s in the future: a clock is off" "${vals[@]}"
    elif (( age <= FRESH_MAX_S )); then
      report ok "usage readings" "observed $age s ago ($by)" "${vals[@]}"
    elif [[ -n $mid ]]; then
      report warn "usage readings" "stale: observed $age s ago while $mid runs a turn" "${vals[@]}"
    else
      report ok "usage readings" "observed $age s ago; no pane runs a turn, so none refreshes them" "${vals[@]}"
    fi
  fi
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
# None running is expected while every live agent waits out a usage limit
# (#246): a watcher would wake at once on each limited pane.
if [[ -n $watchers ]]; then
  report ok "pane watcher" "watching ${watchers%;}"
else
  limited="" resets="" free=""
  for p in $panes; do
    fleet_panes | grep -qx -- "$p" || continue
    s=$(screen "$p")
    if ! busy "$s" && l=$(limit_line "$s"); then
      limited+="$p "
      r=$(grep -oE 'resets [^(]*[ap]m' <<<"$l" | tail -1)
      [[ -n $r && $resets != *"$r"* ]] && resets+="${r#resets }, "
    else
      free+="$p "
    fi
  done
  limited=${limited% } resets=${resets%, } free=${free% }
  if [[ -n $limited && -z $free ]]; then
    report warn "pane watcher" "none running while every agent waits out a usage limit (resets ${resets:-at an unknown time}): start one after the reset" limited="$limited" resets="$resets"
  else
    report FAIL "pane watcher" "none running: the orchestrator is not woken when an agent finishes" limited="$limited" not_limited="$free"
  fi
fi
# Registered agents, one verdict per row (#220): a session gone without an end
# (after a hard shutdown, all of them) is a FAIL for `fleet recover`; one that
# finished cleanly is a warn until its row is pruned.
gone="" done_=""
while IFS=$'\t' read -r p name _ sid _; do
  [[ -n $p && -n $name ]] || continue
  case $(row_state "$p" "$sid") in
    finished) done_+="$name " ;;
    gone) gone+="$name " ;;
  esac
done < <(cat "$REGISTRY" 2>/dev/null)
if [[ -n $gone ]]; then
  report FAIL "agents" "sessions gone: ${gone% }: fleet recover"
elif [[ -n $done_ ]]; then
  report warn "agents" "finished, still in panes.tsv: ${done_% }: fleet doctor --prune"
else
  report ok "agents" "every registered session runs"
fi
[[ -n $gone && -n $done_ ]] && report warn "finished agents" "still in panes.tsv: ${done_% }: fleet doctor --prune"
# Agents set aside (paused.tsv, `fleet pause`): listed, never a failure (#246).
paused=$(awk -F'\t' '$1 != "" && $1 !~ /^#/ { printf "%s, ", $1 }' "${FLEET_PAUSED:-$FLEET_STATE/paused.tsv}" 2>/dev/null)
[[ -n $paused ]] && report ok "paused agents" "${paused%, }: fleet unpause NAME brings one back" paused="${paused%, }"
mapfile -t briefs < <(awk -F'\t' 'NF >= 3 { print $3 }' "$REGISTRY" 2>/dev/null)
if (( ! ${#briefs[@]} )); then
  report ok "briefs" "no registered agents"
elif stale=$(bash "$here/brief.sh" --check "${briefs[@]}" 2>/dev/null); then
  report ok "briefs" "every registered brief has the shared rules"
else
  report warn "briefs" "$(tr '\n' ' ' <<<"$stale")(fleet brief --check)"
fi

# Voices (#273): the tray's mode has been applied to keryx (the resume service
# applies a change within a pass; a mode left unapplied says why).
if v=$(bash "$here/voices.sh" --check 2>/dev/null); then
  report ok "voices" "$v"
else
  report warn "voices" "${v:-could not compare}"
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
