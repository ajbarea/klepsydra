#!/usr/bin/env bash
# Engine adapters for `fleet delegate`: one function set per non-Claude engine
# behind one interface, so no other fleet script branches on the engine. Sourced
# (after lib.sh), never run. Docs: docs/engines.md.
#
# Interface, each taking the ENGINE first:
#   eng_has          the binary is on PATH
#   eng_model KIND   the model a kind of task runs on (a small table)
#   eng_order KIND   the engines `auto` tries, in order
#   eng_can MODE     print|interactive: whether the engine has that lane
#   eng_argv MODE MODEL KIND SETTINGS PROMPT   fill ENG_ARGV (the locked command)
#   eng_settings KIND DIR OUT                  write the engine's locked settings
#   eng_classify RC STDOUT STDERR   ok|limit|auth|empty|error for a finished print run
#   eng_state SCREEN [PROMPT]       busy|idle|limit|auth|trust|unknown for an interactive pane
#   eng_answer SCREEN [PROMPT]      the reply under the echo of PROMPT (the last echo without one);
#                                   no echo of PROMPT on screen gives nothing, never another turn's
#   eng_trust_key           the key that answers a trust dialog
#   eng_models              the sorted list of available model identifiers (one per line)
#   eng_usage [NOW]         formatted usage line(s) for the engine
# The lock is the point: every lane starts with write tools, the shell, MCP and
# the browser off, and a failure to build the lock starts nothing.

# shellcheck disable=SC2034 # read by doctor.sh and delegate.sh
ENGINES=(agy copilot)
ENG_LOCK=${FLEET_AGY_LOCK:-$FLEET_HOOK_DIR/klepsydra-agy-locked.json}

# What a finished run's text says when the engine is out of quota or logged out.
# The wording is each vendor's and can change: a miss reads as a plain error, so
# nothing falls back; docs/engines.md says which phrases were seen live.
ENG_LIMIT_RE='quota|rate.?limit|resource.?exhausted|too many requests|usage limit|limit (reached|exceeded|hit)|out of (credits|requests)|ai credits|premium request|try again (later|in )|\b429\b'
ENG_AUTH_RE='not (logged|signed) in|log ?in required|(please|must) (log ?in|sign in|authenticate)|unauthori[sz]ed|authentication (failed|required)|invalid (token|credentials)|copilot login|\b401\b'

# A headless run auto-denied a tool: the engine had no chance to answer.
ENG_DENIED_RE='auto-denied|headless mode cannot prompt'

eng_bin() {
  case $1 in
    agy) printf '%s' "${FLEET_AGY:-agy}" ;;
    copilot) printf '%s' "${FLEET_COPILOT:-copilot}" ;;
    *) return 1 ;;
  esac
}
eng_has() { command -v "$(eng_bin "$1")" >/dev/null 2>&1; }

# One model per engine until a kind earns another; --model overrides.
eng_model() { # ENGINE KIND
  case $1 in
    agy) printf 'gemini-3.8-flash-high' ;;
    copilot) printf 'auto' ;;
  esac
}

# Available model IDs for ENGINE, one per line, sorted.
eng_models() { # ENGINE: the model ids ENGINE offers now, sorted, one a line
  eng_models_raw "$1" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
  (( PIPESTATUS[0] == 0 ))
}

# Each engine's own list: agy asks its server (`agy models`, about a second);
# Copilot's is the list its CLI cached at its last start (data.db, read-only),
# so no login token is read here. FLEET_<ENGINE>_MODELS (one id a line) stands in, for tests.
eng_models_raw() { # ENGINE
  local fake
  case $1 in
    agy) fake=${FLEET_AGY_MODELS-} ;;
    copilot) fake=${FLEET_COPILOT_MODELS-} ;;
    *) return 1 ;;
  esac
  if [[ -n $fake ]]; then printf '%s\n' "$fake"; return; fi
  eng_has "$1" || return 1
  case $1 in
    agy)
      # Whole, or not at all: a listing cut short by an error would read as models gone.
      local out
      out=$(timeout "${FLEET_MODELS_TIMEOUT:-10}" "$(eng_bin agy)" models 2>/dev/null) || return 1
      awk -F'\t' 'NF >= 2 && $1 ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { print $1 }' <<<"$out"
      ;;
    copilot)
      local db=${COPILOT_HOME:-$HOME/.copilot}/data.db # Copilot's own variable for its folder
      [[ -r $db ]] || return 1
      timeout "${FLEET_MODELS_TIMEOUT:-10}" python3 -I -c 'import json, sqlite3, sys, urllib.parse
c = sqlite3.connect("file:" + urllib.parse.quote(sys.argv[1]) + "?mode=ro", uri=True)
r = c.execute("SELECT value FROM app_state WHERE key = ?", ("copilot-available-models",)).fetchone()
for m in json.loads(r[0]) if r else []:
    if isinstance(m, dict) and m.get("id") not in (None, "auto"):
        print(m["id"])' "$db" 2>/dev/null
      ;;
  esac
}

# agy for research and drafts (Gemini's strengths), Copilot for a second-opinion
# PR review and CI triage.
eng_order() { # KIND
  case $1 in
    research | draft) echo "agy copilot" ;;
    review | ci) echo "copilot agy" ;;
  esac
}

eng_can() { # ENGINE MODE
  case $1:$2 in
    agy:print | agy:interactive | copilot:print | copilot:interactive) return 0 ;;
    *) return 1 ;;
  esac
}

# agy's locked settings: the shared policy, DIR as the one trusted workspace
# (no trust prompt); the policy denies URL reads, which a research task alone gets back.
eng_settings() { # KIND DIR OUT
  [[ -r $ENG_LOCK ]] || return 1
  jq --arg d "$2" --arg kind "$1" \
    '. + {trustedWorkspaces: [$d]} | if $kind == "research" then .permissions.deny -= ["read_url(*)"] else . end' \
    "$ENG_LOCK" >"$3.tmp" && mv -f -- "$3.tmp" "$3"
}

# The locked command for MODE, in ENG_ARGV. PROMPT is the prompt text (print mode).
# shellcheck disable=SC2034 # ENG_ARGV is read by the caller
eng_argv() { # ENGINE MODE MODEL KIND SETTINGS PROMPT
  local bin
  bin=$(eng_bin "$1") || return 1
  case $1:$2 in
    agy:print) ENG_ARGV=("$bin" -p "$6" --model "$3" --settings "$5" --sandbox) ;;
    agy:interactive) ENG_ARGV=("$bin" --model "$3" --settings "$5" --sandbox) ;;
    copilot:print)
      # Deny beats allow, even with every tool allowed: --allow-all-tools only
      # lets a headless run start, the tool list and the denies do the locking.
      ENG_ARGV=("$bin" -p "$6" -s --model "$3" --allow-all-tools --available-tools "view,grep,glob"
        --deny-tool=write --deny-tool=shell --disable-builtin-mcps --disallow-temp-dir --no-ask-user)
      ;;
    copilot:interactive)
      ENG_ARGV=("$bin" --model "$3" --allow-all-tools --available-tools "view,grep,glob"
        --deny-tool=write --deny-tool=shell --disable-builtin-mcps --disallow-temp-dir)
      ;;
    *) return 1 ;;
  esac
}

eng_classify() { # RC STDOUT STDERR: a failure is read with its stderr; an exit 0 only when its stdout is a line or two
  local rc=$1 out=$2 err=$3 both=""
  if [[ $rc != 0 ]]; then both=$out$'\n'$err
  elif (( ${#out} < 200 )); then both=$out; fi
  # A headless engine that auto-denied a tool it could not prompt for: not the
  # engine's fault, so the caller may try the next one. agy exits 0 with nothing
  # on stdout then (#358), so an empty answer counts as much as a failure.
  if [[ $rc != 0 || -z ${out//[[:space:]]/} ]] && grep -Eqi -- "$ENG_DENIED_RE" <<<"$err"; then
    echo denied; return
  fi
  if [[ -n $both ]]; then
    if grep -Eqi -- "$ENG_LIMIT_RE" <<<"$both"; then echo limit; return; fi
    if grep -Eqi -- "$ENG_AUTH_RE" <<<"$both"; then echo auth; return; fi
  fi
  [[ $rc == 0 ]] || { echo error; return; }
  [[ -n ${out//[[:space:]]/} ]] && echo ok || echo empty
}

# An interactive pane's state from its screen. agy: the input box sits between
# two rules and the footer under it reads "esc to cancel" while a turn runs and
# "? for shortcuts" when idle; with a status line (agy 1.5.12+, klepsydra's
# "... · ctx N% · ..."), that line is the footer instead, and a turn runs while
# a spinner line (Braille) or a "● [hh:mm:ss] ... running" task line shows
# (agy_spinning). Copilot: the footer reads "Working ctrl+c
# interrupt" while a turn runs and "open sidebar ... Manual Approval" when idle,
# and a folder not yet trusted shows a dialog (state trust; eng_trust_key answers).
eng_state() { # ENGINE SCREEN (plain text, no escapes) [PROMPT: the text last sent]
  local engine=$1 screen=$2 foot recent
  recent=$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -12)
  foot=$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -1)
  # Only the dialog's own footer, last on screen: the answered dialog stays in scrollback.
  if [[ $engine == copilot && $(grep -v '^[[:space:]]*$' <<<"$screen" | tail -2) == *"enter to select"* ]]; then echo trust; return; fi
  local footer=unknown
  if [[ $engine == agy && $foot == *"esc to cancel"* ]]; then footer=busy
  elif [[ $engine == agy && $foot == *"? for shortcuts"* ]]; then footer=idle
  elif [[ $engine == agy && $foot == *" · ctx "[0-9]*"% · "* ]]; then
    if agy_spinning "$recent"; then footer=busy; else footer=idle; fi
  elif [[ $engine == copilot && $foot == *"ctrl+c interrupt"* ]]; then footer=busy
  elif [[ $engine == copilot && ( $foot == *"open sidebar"* || $foot == *"Manual Approval"* ) ]]; then footer=idle; fi
  # A running turn is busy whatever the screen says. A quota or login message is the
  # engine's whole reply: short, and what the box last answered. A long answer that
  # merely mentions a rate limit (CI triage, API research) is an answer.
  if [[ $footer == busy ]]; then echo busy; return; fi
  local reply
  if [[ $footer == idle ]]; then reply=$(eng_answer "$engine" "$screen" "${3:-}"); else reply=$recent; fi
  if (( ${#reply} < 400 )); then
    if grep -Eqi -- "$ENG_LIMIT_RE" <<<"$reply"; then echo limit; return; fi
    if grep -Eqi -- "$ENG_AUTH_RE" <<<"$reply"; then echo auth; return; fi
  fi
  echo "$footer"
}

# Whether agy's recent lines show a turn at work: a spinner line (its first
# character Braille, U+2800 to U+28FF) or a background task still running.
agy_spinning() { # LINES
  local LC_ALL=C line lead
  while IFS= read -r line; do
    lead=${line#"${line%%[![:space:]]*}"}
    case ${lead:0:2} in $'\xe2\xa0' | $'\xe2\xa1' | $'\xe2\xa2' | $'\xe2\xa3') return 0 ;; esac
    [[ $lead =~ ^$'\xe2\x97\x8f'\ \[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\ .*\ running$ ]] && return 0
  done <<<"$1"
  return 1
}

# The key that answers a "trust this folder" dialog (Copilot's first option is Yes).
eng_trust_key() { echo Enter; } # ENGINE

# The last turn: what follows the last non-empty "> prompt" echo, up to the next
# rule (the input box's), without tool-call, token-count and tip lines. agy draws
# a rule before every prompt too, so a rule ends only the text after the last echo.
# index() and no multibyte brackets: mawk reads a UTF-8 range or `+` byte by byte.
# awk helpers shared by both extractors: the echo of what was sent can wrap onto more lines,
# indented like an answer, so after an echo the lines that continue the sent text are skipped.
ECHO_AWK='
  function norm(x) { gsub(/[ \t]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
  function matches(rest) { rest = norm(rest); return rest != "" && (p == "" || index(rest, p) == 1 || index(full, rest) == 1) }
  function begin_echo(rest) { rest = norm(rest); skip = 0
    if (full != "" && index(full, rest) == 1) { remain = norm(substr(full, length(rest) + 1)); skip = (remain != "") } }
  function continues(line,   t) { if (!skip) return 0; t = norm(line); if (t == "") return 1
    if (index(remain, t) == 1) { remain = norm(substr(remain, length(t) + 1)); if (remain == "") skip = 0; return 1 }
    skip = 0; return 0 }'

eng_answer() { # ENGINE SCREEN [SENT: the full text sent; only its echo starts the answer]
  # With SENT only an echo of it starts the answer: a screen that does not show it (the engine
  # has not drawn it yet, or drew it differently) gives no answer, never another turn's.
  if [[ $1 == copilot ]]; then eng_answer_copilot "$2" "${3:-}"; return; fi
  P=${3:-} awk "$ECHO_AWK"'
    BEGIN { full = norm(ENVIRON["P"]); p = substr(full, 1, 40) }
    index($0, "────") == 1 { if (seen) ended = 1; next }
    index($0, "> ") == 1 { rest = substr($0, 3)
      if (matches(rest)) { seen = 1; ended = 0; delete a; n = 0; begin_echo(rest); next } }
    !seen || ended { next }
    continues($0) { next }
    /^[0-9.]+k? in \|/ || index($0, "└ Tip:") == 1 || index($0, "● ") == 1 { next }
    { sub(/[ \t]+$/, ""); a[n++] = $0 }
    END { for (i = 0; i < n; i++) print a[i] }' <<<"$2" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed -e '/./,$!d'
}
eng_answer_copilot() { # SCREEN [SENT]
  P=${2:-} awk "$ECHO_AWK"'
    BEGIN { full = norm(ENVIRON["P"]); p = substr(full, 1, 40) }
    { line = $0; sub(/^ *❯ +/, "", line) }
    ($0 ~ /^ *❯ +[^ ]/) && matches(line) { seen = 1; ended = 0; delete a; n = 0; begin_echo(line); next }
    !seen || ended { next }
    index($0, "────") == 1 || index($0, "[⎇") > 0 { ended = 1; next }
    continues($0) { next }
    index($0, "Copilot Fusion selected") > 0 { next }
    { sub(/[ \t]+$/, ""); a[n++] = $0 }
    END { for (i = 0; i < n; i++) print a[i] }' <<<"$1" | sed -e 's/^ ● //' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed -e '/./,$!d'
}

# Probed usage quota from ENGINE: cached in $FLEET_STATE/usage-<engine>.cache
# with TTL $FLEET_USAGE_TTL (default 300 s). Prints raw output on success,
# exits 127 if CLI is missing, exits 1 on probe failure / timeout.
eng_usage_raw() { # ENGINE
  local eng=$1
  local fake
  case $eng in
    agy) fake=${FLEET_AGY_USAGE-} ;;
    copilot) fake=${FLEET_COPILOT_USAGE-} ;;
  esac
  if [[ -n $fake ]]; then printf '%s\n' "$fake"; return 0; fi

  local cache="${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}/usage-$eng.cache"
  local ttl="${FLEET_USAGE_TTL:-300}"
  local now
  now=$(date +%s)

  if [[ -f "$cache" ]]; then
    local mtime
    mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    if (( now - mtime < ttl )); then
      cat "$cache"
      return 0
    fi
  fi

  if ! eng_has "$eng"; then
    return 127
  fi

  local bin out rc=0
  bin=$(eng_bin "$eng") || return 127
  local timeout_s="${FLEET_USAGE_TIMEOUT:-10}"
  mkdir -p -- "${cache%/*}" 2>/dev/null

  out=$(timeout "$timeout_s" "$bin" -p /usage 2>&1) || rc=$?

  if [[ -n "$out" ]] && grep -Eqi -- "$ENG_AUTH_RE" <<<"$out"; then
    printf '%s\n' "$out"
    return 0
  fi

  if [[ $eng == agy && $rc == 0 && -n "$out" ]]; then
    printf '%s\n' "$out" >"$cache.tmp" && mv -f -- "$cache.tmp" "$cache"
    printf '%s\n' "$out"
    return 0
  elif [[ $eng == copilot && -n "$out" ]] && { [[ $rc == 0 ]] || grep -Eqi 'exceeded|quota|rate.?limit|ai credits' <<<"$out"; }; then
    printf '%s\n' "$out" >"$cache.tmp" && mv -f -- "$cache.tmp" "$cache"
    printf '%s\n' "$out"
    return 0
  fi

  return 1
}

# Formats an epoch as a reset label:
# - today: "resets 3:26am"
# - tomorrow: "resets Sat 3:26am"
# - beyond tomorrow: "resets Fri Dec 4 5:26pm"
eng_reset_label() { # EPOCH [NOW]
  local epoch=$1 now=${2:-$(date +%s)}
  [[ $epoch =~ ^[1-9][0-9]*$ ]] || return 1
  local rday today tday
  rday=$(date -d "@$epoch" +%F 2>/dev/null) || return 1
  today=$(date -d "@$now" +%F 2>/dev/null) || return 1
  tday=$(date -d "@$(( now + 86400 ))" +%F 2>/dev/null) || return 1
  if [[ $rday == "$today" ]]; then
    date -d "@$epoch" '+resets %-I:%M%P'
  elif [[ $rday == "$tday" ]]; then
    date -d "@$epoch" '+resets %a %-I:%M%P'
  else
    date -d "@$epoch" '+resets %a %b %-d %-I:%M%P'
  fi
}

# Formatted usage line(s) for ENGINE, using NOW for reset times.
eng_usage() { # ENGINE [NOW]
  local eng=$1 now=${2:-$(date +%s)}
  local raw rc=0
  raw=$(eng_usage_raw "$eng") || rc=$?

  if (( rc == 127 )); then
    printf '  %s: not installed\n' "$eng"
    return 0
  elif (( rc != 0 )); then
    printf '  %s: probe failed\n' "$eng"
    return 0
  fi

  if grep -Eqi -- "$ENG_AUTH_RE" <<<"$raw"; then
    printf '  %s: not logged in\n' "$eng"
    return 0
  fi

  case $eng in
    agy)
      local lines
      lines=$(awk -F'\t' '
        {
          pool = $1
          sub(/ [Mm]odels$/, "", pool)
          sub(/ [Mm]odel$/, "", pool)
          if (!seen[pool]++) order[n++] = pool
          win = tolower($2)
          pct = $3
          reset = $4
          if (index(win, "five hour")) { five[pool] = pct; five_reset[pool] = reset }
          else if (index(win, "weekly")) { weekly[pool] = pct; weekly_reset[pool] = reset }
        }
        END {
          for (i = 0; i < n; i++) {
            p = order[i]
            print p "|" five[p] "|" five_reset[p] "|" weekly[p] "|" weekly_reset[p]
          }
        }' <<<"$raw" | while IFS='|' read -r pool five five_reset weekly weekly_reset; do
        [[ -z "$pool" ]] && continue
        local parts=""
        if [[ -n "$five" && "$five" != "disabled" ]]; then
          local f_lbl=""
          if [[ -n "$five_reset" && "$five_reset" != "disabled" ]]; then
            local epoch
            epoch=$(date -d "$five_reset" +%s 2>/dev/null || echo 0)
            if (( epoch > 0 )); then
              local lbl
              lbl=$(eng_reset_label "$epoch" "$now")
              [[ -n "$lbl" ]] && f_lbl=" ($lbl)"
            fi
          fi
          parts="five_hour room $five$f_lbl"
        fi
        if [[ -n "$weekly" && "$weekly" != "disabled" ]]; then
          local w_lbl=""
          if [[ -n "$weekly_reset" && "$weekly_reset" != "disabled" ]]; then
            local epoch
            epoch=$(date -d "$weekly_reset" +%s 2>/dev/null || echo 0)
            if (( epoch > 0 )); then
              local lbl
              lbl=$(eng_reset_label "$epoch" "$now")
              [[ -n "$lbl" ]] && w_lbl=" ($lbl)"
            fi
          fi
          local w_part="weekly room $weekly$w_lbl"
          [[ -n "$parts" ]] && parts="$parts, $w_part" || parts="$w_part"
        fi
        if [[ -n "$parts" ]]; then
          printf '  agy %s: %s\n' "$pool" "$parts"
        elif [[ "$five" == "disabled" && "$weekly" == "disabled" ]]; then
          printf '  agy %s: disabled\n' "$pool"
        fi
      done)
      if [[ -n "$lines" ]]; then
        printf '%s\n' "$lines"
      else
        printf '  agy: probe failed\n'
      fi
      ;;
    copilot)
      if grep -Eiq 'exceeded.*(monthly )?quota|(monthly )?quota.*exceeded' <<<"$raw"; then
        printf '  copilot: monthly quota exceeded\n'
      elif grep -Eiq 'monthly quota' <<<"$raw"; then
        local line
        line=$(grep -Ei 'monthly quota' <<<"$raw" | head -1)
        printf '  copilot: %s\n' "$line"
      elif grep -Eiq 'ai credits[[:space:]]+[1-9][0-9]*' <<<"$raw"; then
        local credits
        credits=$(grep -Eio 'ai credits[[:space:]]+[1-9][0-9]*' <<<"$raw" | head -1)
        printf '  copilot: %s\n' "$credits"
      elif grep -Eiq 'remaining' <<<"$raw"; then
        local line
        line=$(grep -Ei 'remaining' <<<"$raw" | head -1)
        printf '  copilot: %s\n' "$line"
      elif grep -Eqi -- "$ENG_LIMIT_RE" <<<"$raw"; then
        printf '  copilot: monthly quota exceeded\n'
      else
        printf '  copilot: monthly quota remaining\n'
      fi
      ;;
  esac
}


