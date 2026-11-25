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
# proc PID PPID COMM ARG...: a fake process (start time PID*10, so a reused pid differs).
proc() {
  local pid=$1 ppid=$2 comm=$3
  shift 3
  mkdir -p "$P/$pid"
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
check "usage on a bad mode" "$(bash "$script" --bogus 2>&1; echo "rc=$?")" "usage: klepsydra-browser.sh [--list | --reap STATE]
rc=2"

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
check "settings: SessionEnd only" "$(jq -c '.hooks | keys' <<<"$settings" 2>/dev/null)" '["SessionEnd"]'
check "settings: the browser script, not async, a timeout that covers its wait" \
  "$(jq -c '.hooks.SessionEnd[0].hooks[0] | [(.command | ltrimstr("~")), has("async"), (.timeout >= 2)]' <<<"$settings")" '["/.claude/klepsydra-browser.sh",false,true]'
check "make install-hooks installs it" "$(grep -c '"hooks/klepsydra-browser.sh klepsydra-browser.sh"' "$here/../fleet/lib.sh")" "1"
pblock() { sed -n '/^# --- proc stat/,/^# --- end proc stat ---$/p' "$1"; }
check "proc stat block identical in the fleet hook" "$(pblock "$script")" "$(pblock "$here/klepsydra-fleet.sh")"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
