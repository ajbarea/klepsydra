#!/usr/bin/env bash
# shellcheck disable=SC2016 # the mutation sed scripts match the code's literal $ signs
# Tests for the Playwright MCP browser closer (#379) against a fake /proc and a
# fake kill: no real process is ever signalled. Run: bash hooks/test_browser.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/klepsydra-browser.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

P=$work/proc H=$work/home NOW=1800000000
cache=$H/.cache/ms-playwright-mcp
# proc PID PPID COMM ARG...: a fake process (start time PID*10, so a reused pid
# differs), listed in its parent's task children file unless NOKIDS=1.
proc() {
  local pid=$1 ppid=$2 comm=$3
  shift 3
  mkdir -p "$P/$pid/task/$pid"
  [[ ${NOKIDS:-0} == 1 ]] || { mkdir -p "$P/$ppid/task/$ppid"; printf '%s ' "$pid" >>"$P/$ppid/task/$ppid/children"; }
  printf '%s (%s) S %s %s %s\n' "$pid" "$comm" "$ppid" "$(seq -s ' ' 2 18)" "$((pid * 10))" >"$P/$pid/stat"
  printf '%s\n' "$comm" >"$P/$pid/comm"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
}
profile() { mkdir -p "$1/Default"; touch -d "@$2" "$1" "$1/Default" "$1/Default/History"; }
tree() {
  rm -rf -- "${P:?}"
  proc 1 0 systemd /sbin/init
  proc 50 1 tmux tmux
  # This session: claude, npm exec, sh, the node server, its Chrome and a renderer.
  proc 100 50 claude claude
  proc 200 100 npm-exec npm exec @playwright/mcp@latest
  proc 201 200 sh sh -c playwright-mcp
  proc 202 201 node node "$H/.npm/_npx/98/node_modules/.bin/playwright-mcp"
  proc 300 202 chrome /opt/google/chrome/chrome --no-first-run "--user-data-dir=$cache/mcp-chrome-c35bcf5" about:blank
  proc 301 300 chrome /opt/google/chrome/chrome --type=renderer "--user-data-dir=$cache/mcp-chrome-c35bcf5"
  # AJ's own browsers, reparented to init as an orphan would be.
  proc 400 1 chrome /opt/google/chrome/chrome "--user-data-dir=$H/.config/google-chrome"
  proc 401 1 msedge /opt/microsoft/msedge/msedge "--user-data-dir=$H/.config/microsoft-edge"
  proc 402 1 chrome /opt/google/chrome/chrome "--user-data-dir=$H/.config/google-chrome/../../.cache/ms-playwright-mcp/mcp-chrome-up"
  proc 403 1 chrome /opt/google/chrome/chrome "--app=--user-data-dir=$cache/mcp-chrome-zz"
  proc 404 1 chrome /opt/google/chrome/chrome "--user-data-dir=$H/notes/mcp-chrome-notes"
  proc 405 1 chrome /opt/google/chrome/chrome
  # An orphan in the older profile folder, and one whose launcher is not init.
  proc 500 1 chrome /opt/google/chrome/chrome "--user-data-dir=$H/.cache/ms-playwright/mcp-chrome-old1"
  proc 600 50 bash bash
  proc 501 600 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-byhand"
  # Another session's browser, under a node .../@playwright/mcp/cli.js server.
  proc 700 50 claude claude
  proc 702 700 node node "$H/n/node_modules/@playwright/mcp/cli.js"
  proc 710 702 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-other"
}
profile "$cache/mcp-chrome-c35bcf5" $((NOW - 2700))
profile "$cache/mcp-chrome-other" $((NOW - 60))
cat >"$work/kill" <<EOF
#!/usr/bin/env bash
# The fake kill: logs "SIG PID"; a pid listed in stubborn survives TERM.
echo "\${1#-} \$2" >>"$work/kills"
[[ \$1 == -TERM ]] && grep -qx "\$2" "$work/stubborn" 2>/dev/null && exit 0
rm -rf -- "$P/\$2"
EOF
chmod +x "$work/kill"
export KLEPSYDRA_PROC=$P KLEPSYDRA_KILL=$work/kill KLEPSYDRA_NOW=$NOW KLEPSYDRA_BROWSER_WAIT_S=0
kills() { paste -sd, "$work/kills" 2>/dev/null; }
run() { : >"$work/kills"; "$@"; }

echo "--list"
tree
out=$(bash "$script" --list | sort -n)
check "lists the MCP browsers' main processes only" "$(cut -f1 <<<"$out" | paste -sd,)" "300,500,501,710"
check "this session's: its node server, its claude, idle since the profile's last write" "$(grep '^300' <<<"$out")" \
  "$(printf '300\t202\t100\t2700\t%s' "$cache/mcp-chrome-c35bcf5")"
check "an @playwright/mcp/cli.js server is a server" "$(grep '^710' <<<"$out" | cut -f2,3,4)" "$(printf '702\t700\t60')"
check "an orphan has no server nor claude; a profile gone reads idle -" "$(grep '^500' <<<"$out" | cut -f2-4)" "$(printf -- '-\t-\t-')"
check "AJ's Chrome, Edge, a .. path, a look-alike argument or folder: never listed" "$(grep -cE '^40[0-5]' <<<"$out")" "0"
proc 302 202 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-zombie"
sed -i 's/ S 202 / Z 202 /' "$P/302/stat"
check "a zombie is not listed" "$(bash "$script" --list | grep -c '^302')" "0"
check "no browser: nothing printed" "$(KLEPSYDRA_PROC=$work/none bash "$script" --list)" ""

echo "SessionEnd hook"
tree
run env KLEPSYDRA_PPID=201 bash "$script" </dev/null; rc=$?
check "closes this session's browser and no other" "$(kills)" "TERM 300"
check "exit 0" "$rc" "0"
tree
run env KLEPSYDRA_PPID=702 bash "$script" <<<'{"hook_event_name":"SessionEnd","reason":"exit"}'
check "the other session closes only its own" "$(kills)" "TERM 710"
tree
echo 300 >"$work/stubborn"
run env KLEPSYDRA_PPID=100 bash "$script" </dev/null
check "a browser still up after the wait gets KILL" "$(kills)" "TERM 300,KILL 300"
rm -f "$work/stubborn"
tree
run env KLEPSYDRA_PPID=600 bash "$script" </dev/null
check "a hook outside any claude does nothing" "$(kills)" ""
tree
rm -rf -- "${P:?}/202"
run env KLEPSYDRA_PPID=100 bash "$script" </dev/null
check "a browser whose server is gone is left to the reaper" "$(kills)" ""

echo "--reap"
tree
state=$work/reaped
run env KLEPSYDRA_BROWSER_GRACE_S=10 bash "$script" --reap "$state" >"$work/out"
check "an orphan gets TERM; AJ's, live sessions' and a non-init launcher's are left" "$(kills)" "TERM 500"
check "the action is printed" "$(cat "$work/out")" "$(printf 'term\t500\t%s\t0' "$H/.cache/ms-playwright/mcp-chrome-old1")"
tree
echo 500 >"$work/stubborn"
run env KLEPSYDRA_BROWSER_GRACE_S=10 bash "$script" --reap "$state" >/dev/null
check "within the grace: TERM is not repeated, no KILL" "$(kills)" ""
run env KLEPSYDRA_NOW=$((NOW + 10)) KLEPSYDRA_BROWSER_GRACE_S=10 bash "$script" --reap "$state" >"$work/out"
check "past the grace: KILL" "$(kills)" "KILL 500"
check "the KILL is printed with the time since TERM" "$(cut -f1,2,4 "$work/out")" "$(printf 'kill\t500\t10')"
run env KLEPSYDRA_NOW=$((NOW + 70)) bash "$script" --reap "$state" >"$work/out"
check "once gone: closed, and the state is cleared" "$(cut -f1,2,4 "$work/out"; [[ -e $state ]] && echo kept)" "$(printf 'closed\t500\t70')"
rm -f "$work/stubborn"
tree
printf '500 %s %s\n' 4242 $((NOW - 100)) >"$state"
run bash "$script" --reap "$state" >"$work/out"
check "a reused pid (another start time) is TERMed afresh, never KILLed" "$(kills)" "TERM 500"
tree
proc 1500 1 init /init
proc 503 1500 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-wsl"
rm -f "$state"
run bash "$script" --reap "$state" >/dev/null
check "an orphan reparented to WSL's init is reaped too" "$(kills)" "TERM 500,TERM 503"
check "usage on a bad mode exits 1, which never blocks a hook" "$(bash "$script" --bogus 2>&1; echo "rc=$?")" "usage: klepsydra-browser.sh [--list | --reap STATE | --sync | --pre-tool]
rc=1"

echo "holders (#533)"
K=$work/dev.ajsoftworks.klepsydra
export KLEPSYDRA_DIR=$K KLEPSYDRA_STATE=$work/state
S1=11111111-1111-4111-8111-111111111111 S2=22222222-2222-4222-8222-222222222222 S3=33333333-3333-4333-8333-333333333333
# sess SID CLAUDE_PID START [MARK [ENDED]]: a session file as the fleet hook writes it (one line).
sess() {
  mkdir -p "$K/fleet"
  jq -nc --arg s "$1" --argjson p "$2" --argjson st "$3" --arg m "${4:-}" --argjson e "${5:-null}" \
    '{v: 1, session_id: $s, claude: {pid: $p, start: $st}, ended: $e} + (if $m == "" then {} else {browser: $m} end)' >"$K/fleet/$1.json"
}
mark() { jq -r '.browser // "-"' "$K/fleet/$1.json"; }
sessions() { rm -rf -- "${K:?}/fleet"; sess $S1 100 1000; sess $S2 700 7000; sess $S3 100 999 open; }
tree; sessions
bash "$script" --sync
check "a sync marks each live session whose claude holds a browser open" "$(mark $S1),$(mark $S2)" "open,open"
check "an earlier claude on a reused pid (another start time) died: its mark goes" "$(mark $S3)" "-"
before=$(stat -c '%i %Y' "$K/fleet/$S1.json"); touch -d @1 "$K/fleet/$S1.json"; before=$(stat -c '%i %Y' "$K/fleet/$S1.json")
bash "$script" --sync
check "an unchanged sync writes nothing" "$(stat -c '%i %Y' "$K/fleet/$S1.json")" "$before"
rm -rf -- "${P:?}/300"
bash "$script" --sync
check "a window gone under a live session: closed; the other stays open" "$(mark $S1),$(mark $S2)" "closed,open"
rm -rf -- "${P:?}/700"
bash "$script" --sync
check "a claude that died (no SessionEnd): its mark goes" "$(mark $S2)" "-"
tree; sessions; sess $S2 700 7000 open '{"at":1}'
rm -rf -- "${P:?}/710"
bash "$script" --sync
check "an ended session's file is never written" "$(mark $S2)" "open"
tree; sessions
check "no data dir of the overlay's own: a sync writes nothing" "$(KLEPSYDRA_DIR=$work/elsewhere bash "$script" --sync; mark $S1)" "-"
lockfile=$(echo "$work"/state/run-*/klepsydra-fleet-"$UID".lock)
exec {held}>>"$lockfile"; flock "$held"
KLEPSYDRA_LOCK_WAIT_S=0.2 bash "$script" --sync
check "the fleet hook's lock held: the sync writes nothing" "$(mark $S1)" "-"
exec {held}>&-
bash "$script" --sync
check "the lock free: it writes" "$(mark $S1)" "open"

check "an inherited LOCK is not the fleet hook's lock" "$(tree; sessions; LOCK= bash "$script" --sync; mark $S1)" "open"

pw=mcp__plugin_playwright_playwright__browser
pre() { # SID TOOL [payload spacing]
  printf '{"session_id":%s"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "${3:-}" "$1" "$2" | bash "$script" --pre-tool
  echo "rc=$?"
}
note() { jq -r '.hookSpecificOutput | [.hookEventName, (.additionalContext | test("closed.*Tell the user")), has("permissionDecision")] | @tsv' 2>/dev/null; }
tree; sessions; bash "$script" --sync
check "pre-tool: its window open: silent, exit 0" "$(pre $S1 ${pw}_navigate)" "rc=0"
check "pre-tool: another tool: silent" "$(rm -rf -- "${P:?}/300"; pre $S1 Bash)" "rc=0"
check "pre-tool: browser_close: silent" "$(pre $S1 ${pw}_close)" "rc=0"
out=$(pre $S1 ${pw}_click)
check "pre-tool: its window closed: context for Claude, no decision, exit 0" "$(head -1 <<<"$out" | note),$(tail -1 <<<"$out")" "$(printf 'PreToolUse\ttrue\tfalse'),rc=0"
check "pre-tool: it says so once (the mark is dropped)" "$(mark $S1),$(pre $S1 ${pw}_click)" "-,rc=0"
check "pre-tool: the other session's open window: silent" "$(pre $S2 ${pw}_click)" "rc=0"
tree; sessions; sess $S1 100 1000 closed
check "pre-tool: a mark the sync set to closed tells it too" "$(rm -rf -- "${P:?}/300"; pre $S1 ${pw}_click | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 closed
check "pre-tool: closed but open again (relaunched): silent" "$(pre $S1 ${pw}_click)" "rc=0"
tree; sessions; sess $S1 100 1000 open
check "pre-tool: a never-marked session is never told" "$(rm -rf -- "${P:?}/300"; pre $S2 ${pw}_click; sess $S2 700 7000; pre $S2 ${pw}_click)" "rc=0
rc=0"
tree; sessions; sess $S1 100 1000 open
rm -rf -- "${P:?}/202"; proc 300 1 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-c35bcf5"
check "pre-tool: after an MCP restart (server gone, window orphaned) it tells, never denies" "$(pre $S1 ${pw}_navigate | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 open
rm -rf -- "${P:?}/300"
proc 800 100 bash bash; proc 801 800 claude claude; proc 802 801 node node "$H/n/node_modules/@playwright/mcp/cli.js"
proc 810 802 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-nested"
check "pre-tool: a nested claude's browser is not its own" "$(pre $S1 ${pw}_navigate | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 open
check "pre-tool: JSON with spaces after the colons is read" "$(rm -rf -- "${P:?}/300"; pre $S1 ${pw}_navigate ' ' | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
NOKIDS=1 tree; sessions; sess $S1 100 1000 open
check "no children files: the scan decides (open: silent)" "$(pre $S1 ${pw}_click)" "rc=0"
check "no children files: the scan decides (closed: told)" "$(rm -rf -- "${P:?}/300"; pre $S1 ${pw}_click | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 open
mkdir -p "$work/elsewhere/fleet"; cp "$K/fleet/$S1.json" "$work/elsewhere/fleet/"
check "pre-tool: a session file outside the overlay's dir is never read" "$(rm -rf -- "${P:?}/300"; KLEPSYDRA_DIR=$work/elsewhere pre $S1 ${pw}_click)" "rc=0"
check "pre-tool: the same file in the overlay's dir is" "$(pre $S1 ${pw}_click | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 open
sed -i 's/ S 202 / Z 202 /' "$P/300/stat"
check "pre-tool: a zombie window is a closed one" "$(pre $S1 ${pw}_click | head -1 | note)" "$(printf 'PreToolUse\ttrue\tfalse')"
tree; sessions; sess $S1 100 1000 used
check "pre-tool: a used mark whose claude holds its MCP browser is confirmed open, silently" "$(pre $S1 ${pw}_click),$(mark $S1)" "rc=0,open"
# An --isolated server's Chrome has a temporary profile, never an mcp-chrome-* one.
tree; sessions; sess $S1 100 1000 used
proc 300 202 chrome /opt/google/chrome/chrome "--user-data-dir=/tmp/playwright_chromiumdev_profile-x1"
check "pre-tool: a used mark it cannot confirm (--isolated) is never told closed" "$(pre $S1 ${pw}_click),$(mark $S1)" "rc=0,used"
bash "$script" --sync
check "the sync drops a used mark it cannot confirm" "$(mark $S1)" "-"
check "pre-tool: a bad session id reads nothing" "$(pre ../$S1 ${pw}_click)" "rc=0"
check "pre-tool: no stdin at all: exit 0" "$(bash "$script" --pre-tool </dev/null; echo "rc=$?")" "rc=0"
# The registered command, with a script that has no --pre-tool (main before #533 exited 2,
# which blocks a PreToolUse call): `|| true` keeps every browser call going.
reg=$(sed -n '/^<!-- browser-settings:start -->$/,/^<!-- browser-settings:end -->$/p' "$here/../README.md" | grep -v -e '^<!--' -e '^```' |
  jq -r '.hooks.PreToolUse[0].hooks[0].command')
mkdir -p "$work/oldhome/.claude"; printf '#!/usr/bin/env bash\necho "usage" >&2; exit 2\n' >"$work/oldhome/.claude/klepsydra-browser.sh"
chmod +x "$work/oldhome/.claude/klepsydra-browser.sh"
check "the registered command exits 0 even when the installed script exits 2" "$(HOME=$work/oldhome bash -c "$reg" </dev/null 2>/dev/null; echo "rc=$?")" "rc=0"

# Each new guard, removed in a copy, must change an outcome above.
echo "holder mutations"
hmutant() { # NAME SED CHECK-FUNCTION WANT-FROM-THE-MUTANT
  local m=$work/hmutant.sh
  sed "$2" "$script" >"$m"
  cmp -s "$script" "$m" && { check "$1: the mutation applies" "unchanged" "changed"; return; }
  check "$1: caught" "$(script=$m "$3")" "$4"
}
locked_sync() {
  tree; sessions
  exec {held}>>"$lockfile"; flock "$held"
  KLEPSYDRA_LOCK_WAIT_S=0.2 bash "$script" --sync
  exec {held}>&-
  mark $S1
}
check "locked_sync on the real script writes nothing" "$(locked_sync)" "-"
hmutant "a sync that skips the fleet lock writes under it" 's/if flock -w "\${KLEPSYDRA_LOCK_WAIT_S:-5}" "\$lock"; then/if true; then/' locked_sync "open"
nested() {
  tree; sessions; sess $S1 100 1000 open; rm -rf -- "${P:?}/300"
  proc 800 100 bash bash; proc 801 800 claude claude; proc 802 801 node node "$H/n/node_modules/@playwright/mcp/cli.js"
  proc 810 802 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-nested"
  pre $S1 ${pw}_navigate | head -1 | note
}
check "nested on the real script tells" "$(nested)" "$(printf 'PreToolUse\ttrue\tfalse')"
hmutant "a walk into a nested claude takes its browser as the caller's (silent)" 's/is_claude "\$p" \&\& continue/:/' nested ""
scan_open() { NOKIDS=1 tree; sessions; sess $S1 100 1000 open; pre $S1 ${pw}_click; }
hmutant "no fallback scan: no children files reads as closed" 's/\[\[ \$claude == "\$root" \]\] \&\& return 0/:/' scan_open \
  "$(printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\nrc=0' "$(sed -n "s/^CLOSED_NOTE='\(.*\)'$/\1/p" "$script")")"
crashed() { tree; sessions; sess $S2 700 7000 open; rm -rf -- "${P:?}/700"; bash "$script" --sync; mark $S2; }
hmutant "no liveness check keeps a dead claude's mark" 's/if ! proc_is "\$cpid" "\$cstart"; then/if false; then/' crashed "closed"
unset KLEPSYDRA_DIR KLEPSYDRA_STATE

# Mutation checks: each guard that keeps AJ's own browsers out, removed in a
# copy, must change what is listed, so the cases above would catch its loss.
echo "mutations"
tree
mutant() { # NAME SED
  local m=$work/mutant.sh
  sed "$2" "$script" >"$m"
  cmp -s "$script" "$m" && { check "$1: the mutation applies" "unchanged" "changed"; return; }
  check "$1: caught" "$(bash "$m" --list | cut -f1 | sort -n | paste -sd,)" "$3"
}
mutant "no profile-folder guard takes a look-alike folder" \
  '/ms-playwright-mcp\/mcp-chrome-\* || \$dir == /d' "300,404,500,501,710"
mutant "no .. guard takes a path that climbs out of AJ's profile" 's/ \&\& \$dir != \*\.\.\*//' "300,402,500,501,710"
mutant "no profile guards and no pre-filter: AJ's Chrome and Edge are matched" \
  '/ms-playwright-mcp\/mcp-chrome-\* || \$dir == /d; /dir##\*\/} == mcp-chrome-/d; s/grep -lsaF -- .mcp-chrome-./grep -lsaF -- "" /' \
  "1,50,100,200,201,202,300,400,401,402,403,404,405,500,501,600,700,702,710"
mutant "no --type= guard lists the renderer" 's/--type=\*) main=0 ;;/--type=*) ;;/' "300,301,500,501,710"
mutant "a loose --user-data-dir match takes a look-alike argument" \
  's/--user-data-dir=\*) dir=\${arg#--user-data-dir=}/*--user-data-dir=*) dir=${arg#*--user-data-dir=}/' "300,403,500,501,710"
proc 406 1 chrome /opt/google/chrome/chrome "--user-data-dir=$cache/mcp-chrome-x/nested/google-chrome"
mutant "no basename guard takes a nested folder" 's/\[\[ \${dir##\*\/} == mcp-chrome-\* \&\& /[[ /' "300,406,500,501,710"
check "with the guard, the nested folder is not listed" "$(bash "$script" --list | grep -c '^406')" "0"

echo "install block"
settings=$(sed -n '/^<!-- browser-settings:start -->$/,/^<!-- browser-settings:end -->$/p' "$here/../README.md" |
  grep -v -e '^<!--' -e '^```')
check "settings: PreToolUse and SessionEnd" "$(jq -c '.hooks | keys' <<<"$settings" 2>/dev/null)" '["PreToolUse","SessionEnd"]'
check "settings: pre-tool only on the Playwright browser tools, never blocking, a short timeout" \
  "$(jq -c '.hooks.PreToolUse[0] | [.matcher, .hooks[0].command, .hooks[0].timeout <= 10, has("async")]' <<<"$settings")" \
  '["mcp__.*playwright.*__browser_.*","~/.claude/klepsydra-browser.sh --pre-tool || true",true,false]'
m=$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$settings")
check "the matcher takes the plugin's and a plain server's browser tools, not another browser server's" \
  "$(for n in mcp__plugin_playwright_playwright__browser_click mcp__playwright__browser_navigate mcp__chrome__browser_navigate Bash; do [[ $n =~ $m ]] && echo y || echo n; done | paste -sd,)" "y,y,n,n"
names="mcp__plugin_playwright_playwright__browser_click mcp__playwright__browser_navigate mcp__chrome__browser_navigate Bash mcp__plugin_playwright_playwright__browser_close mcp__x__browser_playwright_y"
check "the hook's own tool test agrees with the matcher read as Claude Code reads it (a JavaScript RegExp, unanchored)" \
  "$(node -e 'const m = new RegExp(process.argv[1]); console.log(process.argv.slice(2).map((n) => (m.test(n) ? "y" : "n")).join(","))' "$m" $names)" \
  "$(for n in $names; do [[ $n =~ ^mcp__.*playwright.*__browser_ ]] && echo y || echo n; done | paste -sd,)"
check "settings: the browser script, not async, a timeout that covers its wait" \
  "$(jq -c '.hooks.SessionEnd[0].hooks[0] | [(.command | ltrimstr("~")), has("async"), (.timeout >= 2)]' <<<"$settings")" '["/.claude/klepsydra-browser.sh",false,true]'
check "make install-hooks installs it" "$(grep -c '"hooks/klepsydra-browser.sh klepsydra-browser.sh"' "$here/../fleet/lib.sh")" "1"
pblock() { sed -n '/^# --- proc stat/,/^# --- end proc stat ---$/p' "$1"; }
check "proc stat block identical in the fleet hook" "$(pblock "$script")" "$(pblock "$here/klepsydra-fleet.sh")"
for b in "klepsydra dir" "lock dir" "session rows"; do
  blk() { sed -n "/^# --- $b/,/^# --- end $b ---\$/p" "$1"; }
  check "$b block identical in the fleet hook" "$( [[ -n $(blk "$script") ]] && blk "$script")" "$(blk "$here/klepsydra-fleet.sh")"
done

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
