#!/usr/bin/env bash
# Tests for `fleet delegate` and the engine adapters, against stub agy and
# copilot binaries and a private tmux server. The stubs record how they were
# started (argv, folder, what the folder held, the settings file) so the lock is
# tested as the command line and the folder the engine really got; the live
# attack test (fleet/attack_live.sh) runs the real engines once.
# Run: make test-delegate (it takes the heavy lock: it starts a tmux server)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
sock="dlg-test-$$"
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
cleanup() {
  tmux -L "$sock" kill-server 2>/dev/null
  rm -f -- "$sockdir/$sock"
  chmod -R u+w "$work" 2>/dev/null
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
# No inherited descriptor past stderr: a tmux server started here would keep a caller's lock.
for fd in "/proc/$$/fd"/*; do n=${fd##*/}; (( n > 2 && n < 255 )) && eval "exec $n>&-"; done

pass=0 fail=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"; fi
}
has() { grep -q -- "$2" <<<"$1" && echo yes || echo no; } # TEXT PATTERN

mkdir -p "$work/bin" "$work/state" "$work/rec"
export FLEET_STATE="$work/state" FLEET_HOOK_DIR="$root/hooks" FLEET_SOCK="$sock" FLEET_SYSTEMD_RUN=none
export FLEET_MIN_AVAIL_MB=1 FLEET_AGY="$work/bin/agy" FLEET_COPILOT="$work/bin/copilot" FLEET_SEND_CMD="$work/bin/fsend"
export FLEET_DELEGATE_POLL=0.5 HOME="$work/home"
mkdir -p "$HOME"
delegate="$here/delegate.sh"

# The stub engine, one script for both names. $STUB_DIR/mode-NAME holds ok, limit,
# auth, empty, fail, hang, longquota. Print mode writes its answer; interactive
# mode draws agy's box (rule, ">", rule, footer) and answers each line it reads.
cat >"$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
mode=$(cat "$STUB_DIR/mode-$name" 2>/dev/null || echo ok)
n=$(ls "$STUB_DIR" | grep -c "^run-")
rec="$STUB_DIR/run-$n"
mkdir -p "$rec"
printf '%s\n' "$@" >"$rec/argv"
readlink -f . >"$rec/cwd"
{ test -w . && echo writable || echo readonly; } >"$rec/cwdmode"
find . -type f | sort >"$rec/files"
cat TASK.md >"$rec/task" 2>/dev/null
cat AGENTS.md >"$rec/agents" 2>/dev/null
while (( $# )); do [[ $1 == --settings ]] && cp "$2" "$rec/settings.json"; shift; done
interactive=1
for a in $(cat "$rec/argv"); do [[ $a == -p ]] && interactive=0; done
if (( ! interactive )); then
  case $mode in
    ok) echo "ANSWER from $name" ;;
    limit) echo "Error: you have exhausted your quota for today" >&2; exit 1 ;;
    auth) echo "Error: not logged in, run login" >&2; exit 1 ;;
    shortlimit) echo "Rate limit reached, try again later" ;;
    longquota) { echo "The doc says quota and rate limit apply:"; head -c 1500 /dev/zero | tr '\0' x; } ;;
    empty) : ;;
    fail) echo "boom" >&2; exit 3 ;;
    hang) sleep 30 ;;
  esac
  exit 0
fi
# interactive: draw a screen, read a line, answer
hist=()
rule=$(printf '─%.0s' $(seq 60))
if [[ $name == copilot ]]; then
  draw() { # BUSY(0|1)
    printf '\033[2J\033[H'
    printf ' ● MCP Servers reloaded: 0 servers connected\n'
    printf '%s\n' "${hist[@]}"
    printf ' /work [⎇ main%%]\n%s\n❯ \n%s\n' "$rule" "$rule"
    if [[ $1 == 1 ]]; then printf ' ◎ Working ctrl+c interrupt\n'; else printf ' ← open sidebar · Interactive · Manual Approval · / commands\n'; fi
  }
  if [[ -e $STUB_DIR/trust ]]; then
    printf 'Do you trust the files in this folder?\n ❯ 1. Yes\n   3. No (Esc)\n ↑/↓ to navigate · enter to select · esc to cancel\n'
    IFS= read -r _ || exit 0
    echo trusted >"$STUB_DIR/trusted"
  fi
  idle=0
else
  draw() { # BUSY(0|1)
    printf '\033[2J\033[H'
    printf '  Antigravity CLI stub\n'
    printf '%s\n' "${hist[@]}"
    printf '%s\n>\n%s\n%s\n' "$rule" "$rule" "$([[ $1 == 1 ]] && echo 'esc to cancel' || echo '? for shortcuts')"
  }
fi
draw 0
while IFS= read -r line; do
  [[ -z $line ]] && continue
  case $mode in die) exit 0 ;; esac
  if [[ $name == copilot ]]; then hist+=(" ❯ $line"); else hist+=("$rule" "> $line"); fi
  draw 1
  sleep "${STUB_BUSY:-1.5}"
  case $mode in
    hang) sleep 60 ;;
    limit) hist+=("  You have exhausted your quota for today.") ;;
    *) if [[ $name == copilot ]]; then hist+=(" ● Copilot Fusion selected a model" " ● STUB ANSWER $name to: $line")
       else hist+=("12.0k in | 750 out | 667 thinking" "● Read(TASK.md) (ctrl+o to expand)" "  STUB ANSWER $name to: $line"); fi ;;
  esac
  draw 0
done
EOF
chmod +x "$work/bin/stub"
ln -s stub "$work/bin/agy"; ln -s stub "$work/bin/copilot"
export STUB_DIR="$work/rec"
cat >"$work/bin/fsend" <<'EOF'
#!/usr/bin/env bash
{ printf 'TO %s\n' "$1"; cat; printf '\n'; } >>"$STUB_DIR/../sent.log"
echo sent
EOF
chmod +x "$work/bin/fsend"
sent() { cat "$work/sent.log" 2>/dev/null; }
mode() { printf '%s' "$2" >"$STUB_DIR/mode-$1"; } # ENGINE MODE
last() { ls "$STUB_DIR" | grep '^run-' | sort -t- -k2 -n | tail -1; }
runs() { ls "$STUB_DIR" | grep -c '^run-'; }
lastargs() { tr '\n' ' ' <"$STUB_DIR/$(last)/argv"; }

# A repo with committed files, a tracked secret, untracked secrets and a dirty change.
repo="$work/repo"
mkdir -p "$repo/src" && git -C "$repo" init -q . && {
  echo "hello" >"$repo/README.md"; echo "code" >"$repo/src/a.py"
  echo "TOKEN=1" >"$repo/.env"; echo "EXAMPLE=" >"$repo/.env.example"; echo "k" >"$repo/deploy.pem"
  ln -s /etc/hostname "$repo/link-out"
  git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  echo "TOKEN=2" >"$repo/.env.local"; echo "s" >"$repo/secrets.yaml"; echo "dirty" >>"$repo/README.md"
}
printf 'Summarise the repo.\n' >"$work/task.md"
dl() { bash "$delegate" "$@" 2>/dev/null; } # prints the one result line
field() { tr ' ' '\n' <<<"$1" | grep "^$2=" | head -1 | cut -d= -f2-; } # LINE KEY

echo "the engine adapters"
. "$here/lib.sh"; . "$here/engines.sh"
check "research and drafts go to agy first, review and CI triage to copilot" "$(eng_order research)|$(eng_order draft)|$(eng_order review)|$(eng_order ci)" "agy copilot|agy copilot|copilot agy|copilot agy"
check "agy and copilot each have a print and an interactive lane" "$(eng_can copilot print && echo p)$(eng_can copilot interactive && echo i)$(eng_can agy print && echo p)$(eng_can agy interactive && echo i)" "pipi"
check "a failure that names a quota is a limit" "$(eng_classify 1 '' 'Error: quota exceeded')" "limit"
check "so is a 429" "$(eng_classify 1 'HTTP 429' '')" "limit"
check "a login failure is auth" "$(eng_classify 1 '' 'please log in first')" "auth"
check "an exit 0 with a short limit line is a limit" "$(eng_classify 0 'Rate limit reached' '')" "limit"
check "a long answer that mentions quota is an answer" "$(eng_classify 0 "quota $(head -c 1200 /dev/zero | tr '\0' x)" '')" "ok"
check "an exit 0 with nothing on stdout is empty, even with stderr noise" "$(eng_classify 0 '' 'some log line')" "empty"
check "an unrecognised failure is an error (no fallback)" "$(eng_classify 2 '' 'segfault')" "error"
idle=$'  stub\n──────────\n>\n──────────\n? for shortcuts'
check "agy's footer: idle" "$(eng_state agy "$idle")" "idle"
check "agy's footer: busy" "$(eng_state agy "${idle/\? for shortcuts/esc to cancel}")" "busy"
check "agy: a quota message near the box is a limit" "$(eng_state agy $'  You have exhausted your quota\n────\n>\n────\n? for shortcuts')" "limit"
check "agy: an old quota word far above the box is not" "$(eng_state agy "$(printf 'quota\n%.0s' 1; printf 'x\n%.0s' $(seq 20); echo "$idle")")" "idle"
cidle=$' ● hello\n /w [⎇ main%]\n────\n❯ \n────\n ← open sidebar · Interactive · Manual Approval · / commands'
check "copilot's footer: idle" "$(eng_state copilot "$cidle")" "idle"
check "copilot's footer: busy" "$(eng_state copilot "${cidle/← open sidebar · Interactive · Manual Approval · \/ commands/◎ Working ctrl+c interrupt}")" "busy"
check "copilot: the trust dialog is its own state, answered with Enter; once answered it is not (it stays in scrollback)" "$(eng_state copilot $'Do you trust the files in this folder?\n ❯ 1. Yes\n enter to select')|$(eng_state copilot $'Do you trust the files in this folder?\n enter to select\n'"$cidle")|$(eng_trust_key copilot)" "trust|idle|Enter"
check "copilot: a quota message near the box is a limit" "$(eng_state copilot $' ● You have hit your rate limit\n────\n❯ \n────\n ← open sidebar · Interactive · Manual Approval')" "limit"
cscreen=$' ● MCP Servers reloaded\n ❯ first\n ● one\n ❯ second\n ● Copilot Fusion selected GPT\n ● two\n   more\n /w [⎇ main%]\n────\n❯ \n────\n ← open sidebar · Interactive'
check "copilot's answer is the last turn's: no echo, no model notice, bullet stripped, up to the cwd line" "$(eng_answer copilot "$cscreen")" $'two\n   more'
two=$'──────\n> first\n\n  one\n\n──────\n> second\n12.0k in | 5 out | 1 thinking\n● Read(x) (ctrl+o to expand)\n  two\n  lines\n──────\n>   \n──────\n? for shortcuts'
check "the answer is the last turn's, without the token, tool and box lines" "$(eng_answer agy "$two")" $'  two\n  lines'
check "a rule before the prompt echo does not end the last turn early (turn 1 was returned once)" "$(has "$(eng_answer agy "$two")" one)" "no"
check "an empty box prompt is no echo" "$(eng_answer agy $'────\n> ask\n  ans\n────\n>     \n────\n? for shortcuts')" "  ans"

echo "print mode"
mode agy ok; mode copilot ok
out=$(dl --engine agy --kind research --dir "$repo" "$work/task.md"); rc=$?
ans=$(field "$out" path)
check "one line: engine, model, status, path" "$rc $(field "$out" engine) $(field "$out" model) $(field "$out" status)" "0 agy gemini-3.8-flash-high ok"
check "the answer is stamped an unverified lead with engine and model, then the text" "$(head -1 "$ans" | cut -c1-50)|$(sed -n 3p "$ans")" "> Unverified lead from agy (gemini-3.8-flash-high)|ANSWER from agy"
check "the call is in the fleet log, for the ledger" "$(grep -c '"message":"delegate call".*"engine":"agy"' "$FLEET_LOG")" "1"
a=$(lastargs)
check "lock agy: print mode, the model, a settings file and --sandbox" "$(has "$a" '^-p ')$(has "$a" '--model gemini-3.8-flash-high')$(has "$a" '--sandbox')$(has "$a" '--settings')" "yesyesyesyes"
s="$STUB_DIR/$(last)/settings.json"
check "lock agy: writes, the shell, MCP and the browser are denied, and nothing outside the workspace" \
  "$(jq -r '[.allowNonWorkspaceAccess, .enableTerminalSandbox, (.permissions.deny | sort | join(","))] | join(" ")' "$s")" \
  "false true command(*),execute_url(*),mcp(*),unsandboxed(*),write_file(*)"
check "lock agy: its settings are its own: AJ's agy settings file is not named anywhere" "$(has "$a" '\.gemini/')" "no"
check "lock agy: research may read URLs (the deny list has no read_url)" "$(jq -r '.permissions.deny | index("read_url(*)") // "none"' "$s")" "none"
dl --engine agy --kind draft --dir "$repo" "$work/task.md" >/dev/null
check "lock agy: a draft may not (read_url denied)" "$(jq -r '.permissions.deny | index("read_url(*)") != null' "$STUB_DIR/$(last)/settings.json")" "true"
check "lock agy: the one trusted workspace is the snapshot it ran in" "$(jq -r '.trustedWorkspaces[0]' "$s" | grep -c '/delegate/.*/work$')" "1"
dl --engine copilot --kind review --dir "$repo" "$work/task.md" >/dev/null
a=$(lastargs)
check "lock copilot: print, silent, no prompts" "$(has "$a" '^-p ')$(has "$a" ' -s ')$(has "$a" '--no-ask-user')" "yesyesyes"
check "lock copilot: only view, grep and glob exist, and write and shell are denied" "$(has "$a" '--available-tools view,grep,glob')$(has "$a" '--deny-tool=write')$(has "$a" '--deny-tool=shell')" "yesyesyes"
check "lock copilot: no built-in MCP servers (the GitHub one reaches the network)" "$(has "$a" '--disable-builtin-mcps')" "yes"
check "lock: the engine's folder is read-only" "$(cat "$STUB_DIR/$(last)/cwdmode")" "readonly"
files=$(cat "$STUB_DIR/$(last)/files")
check "snapshot: committed files are there, with TASK.md and AGENTS.md" "$(has "$files" 'src/a.py')$(has "$files" 'TASK.md')$(has "$files" 'AGENTS.md')" "yesyesyes"
check "snapshot: a tracked .env, an untracked .env.local, a key and secrets.yaml never arrive; .env.example does" \
  "$(has "$files" '/\.env$')$(has "$files" '\.env\.local')$(has "$files" 'deploy\.pem')$(has "$files" 'secrets\.yaml')$(has "$files" '\.env\.example')" "nonononoyes"
check "snapshot: the dirty working-tree change is not in it (committed content only)" "$(grep -c dirty "$STUB_DIR/$(last)/task" "$work/state/delegate"/*/work/README.md 2>/dev/null | grep -vc ':0')" "0"
check "snapshot: the helper rules are in AGENTS.md" "$(has "$(cat "$STUB_DIR/$(last)/agents")" 'read-only helper')" "yes"
check "snapshot: the task is TASK.md, not an argument visible in ps" "$(cat "$STUB_DIR/$(last)/task")" "$(cat "$work/task.md")"
check "snapshot: a tracked symlink (which a read tool would follow out of it) is not in it" "$(has "$files" 'link-out')" "no"
check "snapshot: removed when the call ends" "$(ls -d "$work/state/delegate"/*/work 2>/dev/null | wc -l)" "0"

echo "routing and fallback"
n0=$(runs); dl --kind research --dir "$repo" "$work/task.md" >/dev/null
check "auto, research: agy answers, copilot is not asked" "$(runs) $(cat "$STUB_DIR/$(last)/argv" | grep -c -- '--sandbox')" "$((n0 + 1)) 1"
out=$(dl --kind review --dir "$repo" "$work/task.md")
check "auto, review: copilot answers" "$(field "$out" engine)" "copilot"
mode agy limit
out=$(dl --kind research --dir "$repo" "$work/task.md")
check "agy at its quota: auto falls back to copilot, and says both tried" "$(field "$out" engine) $(field "$out" status) $(field "$out" note)" "copilot ok agy:limit,copilot:ok"
mode copilot auth
out=$(dl --kind research --dir "$repo" "$work/task.md"); rc=$?
check "both out (limit, auth): never Claude; the line says both-out and exits non-zero" "$(field "$out" status) $rc" "both-out 1"
check "and the answer file says so, stamped" "$(has "$(cat "$(field "$out" path)")" 'No answer')" "yes"
mode agy limit
out=$(dl --engine agy --kind research --dir "$repo" "$work/task.md")
check "an explicit engine does not fall back" "$(field "$out" engine) $(field "$out" status)" "agy limit"
mode agy shortlimit; mode copilot ok
out=$(dl --kind research --dir "$repo" "$work/task.md")
check "a short exit-0 limit line falls back too" "$(field "$out" engine)" "copilot"
mode agy longquota
out=$(dl --kind research --dir "$repo" "$work/task.md")
check "a long exit-0 answer that mentions quota is kept" "$(field "$out" engine) $(field "$out" status)" "agy ok"
mode agy fail; mode copilot ok
out=$(dl --kind research --dir "$repo" "$work/task.md")
check "an unrecognised failure is reported, not retried elsewhere" "$(field "$out" engine) $(field "$out" status)" "agy error"
mode agy empty
out=$(dl --kind research --dir "$repo" "$work/task.md")
check "an empty answer is status empty" "$(field "$out" status)" "empty"
mode agy hang
t0=$SECONDS; out=$(dl --engine agy --kind research --timeout 2 --dir "$repo" "$work/task.md")
check "a hung engine is stopped at the timeout" "$(field "$out" status) $(( SECONDS - t0 < 20 ? 1 : 0 ))" "timeout 1"
mode agy ok

echo "refusals"
n0=$(runs)
out=$(FLEET_MIN_AVAIL_MB=999999999 bash "$delegate" --dir "$repo" "$work/task.md" 2>/dev/null); rc=$?
check "under the memory floor nothing starts" "$rc $(has "$out" HOLD) $(runs)" "2 yes $n0"
printf 'use key %s now\n' "AK""IAABCDEFGHIJKLMNOP" >"$work/secret.md"
check "a task holding a secret is refused before anything is sent" "$(bash "$delegate" --dir "$repo" "$work/secret.md" >/dev/null 2>&1; echo $?) $(runs)" "2 $n0"
printf 'fix the task-spawning-and-return-path-design-for-agents\n' >"$work/word.md"
check "a word that merely ends in sk- is no secret" "$(field "$(dl --dir "$repo" "$work/word.md")" status)" "ok"
head -c 70000 /dev/zero | tr '\0' a >"$work/big.md"
check "a task over the size cap is refused" "$(bash "$delegate" --dir "$repo" "$work/big.md" >/dev/null 2>&1; echo $?)" "2"
mkdir -p "$work/plain"
mkdir -p "$work/empty" && git -C "$work/empty" init -q .
out=$(dl --dir "$work/empty" "$work/task.md"); rc=$?
check "a repo with no commit is refused, nothing run" "$rc $(field "$out" status)" "1 refused"
out=$(dl --dir "$work/plain" "$work/task.md"); rc=$?
check "a folder that is no git repo is refused, nothing run" "$rc $(field "$out" status)" "1 refused"
check "the home folder is never snapshotted" "$(cd "$HOME" && git init -q . 2>/dev/null; dl --dir "$HOME" "$work/task.md" | tr ' ' '\n' | grep -c 'status=refused')" "1"
check "a bad kind, engine or model is refused" "$(for o in '--kind x' '--engine codex' '--model a;b'; do bash "$delegate" $o "$work/task.md" >/dev/null 2>&1; echo -n "$? "; done)" "2 2 2 "
check "no engine installed: unavailable, exit 3" "$(FLEET_AGY=/nonexistent FLEET_COPILOT=/nonexistent bash "$delegate" --dir "$repo" "$work/task.md" 2>/dev/null | grep -c 'status=unavailable') $(FLEET_AGY=/nonexistent FLEET_COPILOT=/nonexistent bash "$delegate" --dir "$repo" "$work/task.md" >/dev/null 2>&1; echo $?)" "1 3"
n1=$(runs)
out=$(FLEET_AGY_LOCK="$work/no-lock.json" bash "$delegate" --engine agy --dir "$repo" "$work/task.md" 2>/dev/null)
check "with the lock policy unreadable, agy is not started" "$(field "$out" status) $(( $(runs) - n1 ))" "error 0"

echo "return path, print mode"
: >"$work/sent.log"
mode agy ok
dl --engine agy --kind research --notify %7 --dir "$repo" "$work/task.md" >/dev/null
check "a notified call tells the pane engine, status and path, through fleet send" "$(head -1 "$work/sent.log") $(has "$(sent)" 'engine=agy status=ok answer=')$(has "$(sent)" 'unverified lead')" "TO %7 yesyes"
: >"$work/sent.log"; mode agy limit; mode copilot limit
dl --kind research --notify %7 --dir "$repo" "$work/task.md" >/dev/null
check "and a limit round trip says both-out (the orchestrator decides)" "$(has "$(sent)" 'status=both-out')" "yes"
mode agy ok; mode copilot ok

echo "interactive lane (agy)"
wait_sent() { local i; for i in $(seq 80); do grep -q -- "$1" "$work/sent.log" 2>/dev/null && return 0; sleep 0.5; done; return 1; } # PATTERN
: >"$work/sent.log"
out=$(dl --interactive --engine agy --kind research --notify %5 --dir "$repo" "$work/task.md"); rc=$?
id=$(field "$out" id)
check "launch: working, with the pane and window named" "$rc $(field "$out" status) $(has "$out" 'window=eng-agy-')" "0 working yes"
a=$(tr '\n' ' ' <"$STUB_DIR/$(last)/argv")
check "lock agy interactive: --sandbox and a settings file of its own, no -p" "$(has "$a" '--sandbox')$(has "$a" '--settings')$(has "$a" '^-p ')" "yesyesno"
check "lock agy interactive: the lane's folder is the read-only snapshot" "$(cat "$STUB_DIR/$(last)/cwdmode") $(cat "$STUB_DIR/$(last)/files" | grep -c '\.env$')" "readonly 0"
wait_sent 'turn=1'
check "turn end: the orchestrator is told, through fleet send, with engine, status and the path" "$(head -1 "$work/sent.log") $(has "$(sent)" 'engine=agy status=ok turn=1')" "TO %5 yes"
ans="$work/state/delegate/$id/answer.md"
check "the answer is captured outside the model: stamped, the stub's text, no tool or token lines" \
  "$(head -1 "$ans" | cut -c1-23)|$(has "$(cat "$ans")" 'STUB ANSWER agy to: Read TASK.md')|$(has "$(cat "$ans")" 'Read(TASK')|$(has "$(cat "$ans")" 'thinking')" "> Unverified lead from |yes|no|no"
check "fleet delegate read prints it" "$(bash "$delegate" read "$id" 2>/dev/null | grep -c 'STUB ANSWER')" "1"
: >"$work/sent.log"
check "a follow-up goes in once the lane is idle" "$(bash "$delegate" msg "$id" 'second question' 2>/dev/null)" "sent"
wait_sent 'turn=2'
check "turn 2 is its own answer (the rule before a prompt did not cut it short)" "$(has "$(cat "$work/state/delegate/$id/answer.md")" 'to: second question')$(has "$(cat "$work/state/delegate/$id/answer-1.md")" 'to: Read TASK')" "yesyes"
check "ls shows the lane" "$(bash "$delegate" ls 2>/dev/null | grep -c "^$id interactive agy")" "1"
STUB_BUSY=20 bash "$delegate" msg "$id" 'slow one' >/dev/null 2>&1
check "a message to a busy lane is refused, not queued blind" "$(bash "$delegate" msg "$id" 'again' 2>/dev/null)" "not-idle:busy"
check "stop: window, watcher and snapshot go; the answer stays" \
  "$(bash "$delegate" stop "$id" 2>/dev/null) $(tmux -L "$sock" list-windows -t =engines -F '#{window_name}' 2>/dev/null | grep -c "$id") $(ls -d "$work/state/delegate/$id/work" 2>/dev/null | wc -l) $([[ -f $work/state/delegate/$id/answer.md ]] && echo kept)" "stopped 0 0 kept"

: >"$work/sent.log"; mode agy limit
out=$(dl --interactive --engine agy --kind research --notify %5 --dir "$repo" "$work/task.md"); id=$(field "$out" id)
wait_sent 'status=limit'
check "a lane that hits its quota: the orchestrator is told, status limit, screen saved" "$(has "$(sent)" "$id engine=agy status=limit") $([[ -s $work/state/delegate/$id/screen.txt ]] && echo screen)" "yes screen"
bash "$delegate" stop "$id" >/dev/null 2>&1

: >"$work/sent.log"; mode agy hang
out=$(FLEET_DELEGATE_TURN_TIMEOUT=3 dl --interactive --engine agy --kind research --notify %5 --dir "$repo" "$work/task.md"); id=$(field "$out" id)
wait_sent 'status=timeout'
check "a lane that never finishes: timeout notified" "$(has "$(sent)" "$id engine=agy status=timeout")" "yes"
: >"$work/sent.log"
out=$(dl --interactive --engine agy --kind research --notify %5 --dir "$repo" "$work/task.md"); id2=$(field "$out" id)
pane=$(jq -r .pane "$work/state/delegate/$id2/meta.json")
tmux -L "$sock" kill-window -t "$pane"
wait_sent 'status=gone'
check "a window that closes under the watcher: gone, notified" "$(has "$(sent)" "$id2 engine=agy status=gone")" "yes"
bash "$delegate" stop "$id" >/dev/null 2>&1; bash "$delegate" stop "$id2" >/dev/null 2>&1

mode agy ok
out=$(FLEET_COPILOT=/nonexistent dl --interactive --engine copilot --kind review --dir "$repo" "$work/task.md"); rc=$?
check "an interactive lane whose engine is not installed: unavailable, nothing started, exit 3" "$(field "$out" status) $rc" "unavailable 3"
out=$(FLEET_COPILOT=/nonexistent dl --interactive --kind review --dir "$repo" "$work/task.md"); id3=$(field "$out" id)
check "auto, interactive, review with copilot missing: agy takes it" "$(field "$out" engine)" "agy"
bash "$delegate" stop "$id3" >/dev/null 2>&1

echo "interactive lane (copilot)"
: >"$work/sent.log"; mode copilot ok; : >"$STUB_DIR/trust"
out=$(dl --interactive --kind review --notify %5 --dir "$repo" "$work/task.md"); idc=$(field "$out" id)
check "auto, interactive, review: copilot, launched" "$(field "$out" engine) $(field "$out" status)" "copilot working"
a=$(tr '\n' ' ' <"$STUB_DIR/$(last)/argv")
check "lock copilot interactive: the same tool list and denies as print mode, no MCP" "$(has "$a" '--available-tools view,grep,glob')$(has "$a" '--deny-tool=write')$(has "$a" '--deny-tool=shell')$(has "$a" '--disable-builtin-mcps')$(has "$a" '^-p ')" "yesyesyesyesno"
check "the trust dialog was answered once, by the adapter" "$(cat "$STUB_DIR/trusted" 2>/dev/null)" "trusted"
wait_sent 'turn=1'
check "copilot turn end: told through fleet send; the answer is captured outside the model" "$(has "$(sent)" "$idc engine=copilot status=ok turn=1")$(has "$(cat "$work/state/delegate/$idc/answer.md")" 'STUB ANSWER copilot to: Read TASK.md')$(has "$(cat "$work/state/delegate/$idc/answer.md")" 'Fusion')" "yesyesno"
: >"$work/sent.log"
bash "$delegate" msg "$idc" 'second' >/dev/null 2>&1; wait_sent 'turn=2'
check "copilot follow-up: turn 2" "$(has "$(cat "$work/state/delegate/$idc/answer.md")" 'to: second')" "yes"
bash "$delegate" stop "$idc" >/dev/null 2>&1
rm -f "$STUB_DIR/trust"
: >"$work/sent.log"; mode copilot limit
out=$(dl --interactive --engine copilot --kind review --notify %5 --dir "$repo" "$work/task.md"); idc=$(field "$out" id)
wait_sent 'status=limit'
check "copilot at its quota: told, status limit" "$(has "$(sent)" "$idc engine=copilot status=limit")" "yes"
bash "$delegate" stop "$idc" >/dev/null 2>&1
mode copilot ok

echo "a reply faster than the watcher's first poll"
: >"$work/sent.log"
out=$(STUB_BUSY=0.05 FLEET_DELEGATE_POLL=2 dl --interactive --engine agy --kind research --notify %5 --dir "$repo" "$work/task.md"); idf=$(field "$out" id)
wait_sent 'turn=1'
check "a turn that ended before the first poll is still a turn end, not a timeout" "$(has "$(sent)" "$idf engine=agy status=ok turn=1")" "yes"
bash "$delegate" stop "$idf" >/dev/null 2>&1
check "no window is left on the server" "$(tmux -L "$sock" list-windows -a 2>/dev/null | wc -l)" "0"

echo "the shared policy"
check "the helper rules fit agy's 24000-byte limit" "$([[ $(stat -c %s "$root/hooks/klepsydra-engine-rules.md") -le 24000 ]] && echo fits)" "fits"
check "a person, course, team or account name appears in no shipped rule or policy" "$(cat "$root/hooks/klepsydra-engine-rules.md" "$root/hooks/klepsydra-agy-locked.json" | grep -cwE 'AJ|ajbar|RIT|CISC|Ben|makesense|Anthropic|Claude')" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
