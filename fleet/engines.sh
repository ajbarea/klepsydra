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
#   eng_classify RC TEXT    ok|limit|auth|empty|error for a finished print run
#   eng_state SCREEN        busy|idle|limit|auth|unknown for an interactive pane
#   eng_answer SCREEN       the last turn's answer text from an interactive pane
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
  if [[ -n $both ]]; then
    if grep -Eqi -- "$ENG_LIMIT_RE" <<<"$both"; then echo limit; return; fi
    if grep -Eqi -- "$ENG_AUTH_RE" <<<"$both"; then echo auth; return; fi
  fi
  [[ $rc == 0 ]] || { echo error; return; }
  [[ -n ${out//[[:space:]]/} ]] && echo ok || echo empty
}

# An interactive pane's state from its screen. agy: the input box sits between
# two rules and the footer under it reads "esc to cancel" while a turn runs and
# "? for shortcuts" when idle. Copilot: the footer reads "Working ctrl+c
# interrupt" while a turn runs and "open sidebar ... Manual Approval" when idle,
# and a folder not yet trusted shows a dialog (state trust; eng_trust_key answers).
eng_state() { # ENGINE SCREEN
  local engine=$1 screen=$2 foot recent
  recent=$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -12)
  foot=$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -1)
  # Only the dialog's own footer, last on screen: the answered dialog stays in scrollback.
  if [[ $engine == copilot && $(grep -v '^[[:space:]]*$' <<<"$screen" | tail -2) == *"enter to select"* ]]; then echo trust; return; fi
  local footer=unknown
  if [[ $engine == agy && $foot == *"esc to cancel"* ]]; then footer=busy
  elif [[ $engine == agy && $foot == *"? for shortcuts"* ]]; then footer=idle
  elif [[ $engine == copilot && $foot == *"ctrl+c interrupt"* ]]; then footer=busy
  elif [[ $engine == copilot && ( $foot == *"open sidebar"* || $foot == *"Manual Approval"* ) ]]; then footer=idle; fi
  # A running turn is busy whatever the screen says. A quota or login message is the
  # engine's whole reply: short, and what the box last answered. A long answer that
  # merely mentions a rate limit (CI triage, API research) is an answer.
  if [[ $footer == busy ]]; then echo busy; return; fi
  local reply
  if [[ $footer == idle ]]; then reply=$(eng_answer "$engine" "$screen"); else reply=$recent; fi
  if (( ${#reply} < 400 )); then
    if grep -Eqi -- "$ENG_LIMIT_RE" <<<"$reply"; then echo limit; return; fi
    if grep -Eqi -- "$ENG_AUTH_RE" <<<"$reply"; then echo auth; return; fi
  fi
  echo "$footer"
}

# The key that answers a "trust this folder" dialog (Copilot's first option is Yes).
eng_trust_key() { echo Enter; } # ENGINE

# The last turn: what follows the last non-empty "> prompt" echo, up to the next
# rule (the input box's), without tool-call, token-count and tip lines. agy draws
# a rule before every prompt too, so a rule ends only the text after the last echo.
# index() and no multibyte brackets: mawk reads a UTF-8 range or `+` byte by byte.
eng_answer() { # ENGINE SCREEN [PROMPT: the text sent; only its echo starts the answer]
  if [[ $1 == copilot ]]; then eng_answer_copilot "$2" "${3:-}"; return; fi
  P=${3:-} awk '
    BEGIN { p = substr(ENVIRON["P"], 1, 40) }
    index($0, "────") == 1 { if (seen) ended = 1; next }
    (p == "" ? $0 ~ /^> +[^ ]/ : index($0, "> " p) == 1) { seen = 1; ended = 0; delete a; n = 0; next }
    !seen || ended { next }
    /^[0-9.]+k? in \|/ || index($0, "└ Tip:") == 1 || index($0, "● ") == 1 { next }
    { sub(/[ \t]+$/, ""); a[n++] = $0 }
    END { for (i = 0; i < n; i++) print a[i] }' <<<"$2" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed -e '/./,$!d'
}

# Copilot's last turn: after the last "❯ text" echo, up to the cwd line or rule
# under it; its answer lines start with a bullet, and the model-choice notice is dropped.
eng_answer_copilot() { # SCREEN [PROMPT]
  P=${2:-} awk '
    BEGIN { p = substr(ENVIRON["P"], 1, 40) }
    { line = $0; sub(/^ *❯ +/, "", line) }
    ($0 ~ /^ *❯ +[^ ]/) && (p == "" || index(line, p) == 1) { seen = 1; ended = 0; delete a; n = 0; next }
    !seen || ended { next }
    index($0, "────") == 1 || index($0, "[⎇") > 0 { ended = 1; next }
    index($0, "Copilot Fusion selected") > 0 { next }
    { sub(/[ \t]+$/, ""); a[n++] = $0 }
    END { for (i = 0; i < n; i++) print a[i] }' <<<"$1" | sed -e 's/^ ● //' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed -e '/./,$!d'
}
