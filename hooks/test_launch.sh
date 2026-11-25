#!/usr/bin/env bash
# Tests for the launcher against a private tmux server and a stub wt.exe.
# Run: make test-launch (it takes the heavy lock)
set -uo pipefail
# A fleet session runs with its own KERYX_VOICE; no test may inherit it.
unset KERYX_VOICE

here=$(cd "$(dirname "$0")" && pwd)
launch="$here/klepsydra-launch.sh"
work=$(mktemp -d)
unset KLEPSYDRA_BACKGROUND # a fleet pane's own, never this suite's
# A headless job's own config folder sets an API key helper, which the
# launcher refuses (#260): the suite runs on none of its caller's.
unset CLAUDE_CONFIG_DIR
# The launcher reads the fleet's account list when set; the suite builds its own.
unset FLEET_ACCOUNTS FLEET_DEFAULT_CONFIG FLEET_DEFAULT_JSON
sock="kl-test-$$" sock2="kl-test2-$$" sock3="kl-test3-$$" sock4="kl-test4-$$" sock5="kl-test5-$$"
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" # where tmux puts a -L socket
clients=()
cleanup() {
  for p in "${clients[@]}" ${holder:-} $(cat "$work/stub-pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
  tmux -L "$sock" kill-server 2>/dev/null
  tmux -L "$sock2" kill-server 2>/dev/null
  tmux -L "$sock3" kill-server 2>/dev/null
  tmux -L "$sock4" kill-server 2>/dev/null
  tmux -L "$sock5" kill-server 2>/dev/null
  rm -f -- "$sockdir/$sock" "$sockdir/$sock2" "$sockdir/$sock3" "$sockdir/$sock4" "$sockdir/$sock5"
  rm -rf "$work"
}
trap cleanup EXIT
# A signal ends the run through exit, so the EXIT trap still stops the server (#239).
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
# No inherited descriptor past stderr: a tmux server started here would keep a
# caller's lock, such as flock's /tmp/fleet-heavy.lock, after the run (#193).
for fd in "/proc/$$/fd"/*; do n=${fd##*/}; (( n > 2 && n < 255 )) && eval "exec $n>&-"; done

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

mkdir -p "$work/bin" "$work/home" "$work/repos/my repos"
cat >"$work/bin/wt.exe" <<'EOF'
#!/usr/bin/env bash
# Logs its argv, then attaches like the real tab: WT_DELAY seconds after returning,
# with Windows Terminal's TERM, whatever the runner has (CI sets none).
# WT_DELAY=never is a tab that never attaches.
# WT_DRAIN=1 reads stdin dry, as WSL interop lets the real wt.exe do (#242).
printf '%s\n' "$*" >>"$WT_LOG"
[[ -n ${WT_DRAIN:-} ]] && cat >/dev/null
[[ ${WT_DELAY:-} == never ]] && exit 0
args=("$@")
for i in "${!args[@]}"; do [[ ${args[i]} == -e ]] && { cmd=("${args[@]:i+1}"); break; }; done
(
  sleep "${WT_DELAY:-0}"
  TERM=xterm-256color exec script -qfc "$(printf '%q ' "${cmd[@]}")" /dev/null
) >/dev/null 2>&1 </dev/null &
echo $! >>"$WT_PIDS"
EOF
chmod +x "$work/bin/wt.exe"
export WT_LOG="$work/wt.log" WT_PIDS="$work/stub-pids" HOME="$work/home" WSL_DISTRO_NAME=Test
# Locks live in this boot's folder in the (test) home's state folder, whatever
# the runtime folder: here one a WSL boot has not made yet (#517).
export XDG_RUNTIME_DIR="$work/no-runtime"
printf 'testhost\n' >"$work/hostname"
export KLEPSYDRA_HOSTNAME="$work/hostname"
ld="$HOME/.local/state/klepsydra/run-testhost-$(</proc/sys/kernel/random/boot_id)"
pending="$ld/klepsydra-tab-pending-$UID"
export KLEPSYDRA_TMUX_SOCKET="$sock" KLEPSYDRA_TMUX_CONF="$here/klepsydra-tmux.conf"
export KLEPSYDRA_CLAUDE="sleep 600" KLEPSYDRA_WT="$work/bin/wt.exe"
# Never the host's systemd: an agent's own scope sets INVOCATION_ID, which
# would put every test server in a real scope (#292 review 2). Cases that want
# the scope path pass their own stub; any other call is recorded and fails.
unset INVOCATION_ID
printf '#!/usr/bin/env bash\necho "$*" >>%q\nexit 1\n' "$work/systemd-run-guard.calls" >"$work/bin/systemd-run-guard"; chmod +x "$work/bin/systemd-run-guard"
export KLEPSYDRA_SYSTEMD_RUN="$work/bin/systemd-run-guard"
: >"$WT_LOG"

t() { tmux -L "$sock" "$@"; }
# kill-server returns before the server exits; a launch that reached the dying
# server would lose its session with it, so wait until the process is gone.
stop_server() {
  local pid _
  pid=$(t display -p '#{pid}' 2>/dev/null) || return 0
  t kill-server 2>/dev/null
  for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
}
windows() { t list-windows -t =fleet 2>/dev/null | wc -l; }
tabs() { wc -l <"$WT_LOG"; }
attach() { # a real client on a pty, like the tab would be
  TERM=xterm-256color script -qfc "tmux -L $sock attach -t =fleet" /dev/null >/dev/null 2>&1 </dev/null &
  clients+=($!)
  for _ in $(seq 50); do [[ -n $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}
pane_pid() { t display -p -t "$1" '#{pane_pid}'; }
stat_fields() { # pid index...: /proc/PID/stat fields after the command name (index 0 is field 3)
  local raw st i vals=(); raw=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a st <<<"${raw##*") "}"; shift
  for i; do vals+=("${st[i]}"); done
  echo "${vals[*]}"
}
pstart() { stat_fields "$1" 19; } # pid: field 22, as proc_stat in the launcher's proc stat block reads it
jmp() { bash "$launch" jump "$socket" "$1" "$2" "$3"; } # pane pid start
detach_all() {
  for p in "${clients[@]}" $(cat "$WT_PIDS" 2>/dev/null); do kill "$p" 2>/dev/null; done
  clients=(); : >"$WT_PIDS"
  for _ in $(seq 50); do [[ -z $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}

echo "new"
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "first: exit 0" "$rc" "0"
check "first: says where" "$out" "Started a session in $work/repos."
check "first: one window" "$(windows)" "1"
check "first: one tab" "$(tabs)" "1"
check "first: the tab attaches by the socket's path" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe -d Test -e tmux -S $(t display -p '#{socket_path}') attach -t =fleet"
check "first: an attached tab leaves no pending stamp" "$([[ -e $pending ]] && echo left)" ""
check "first: conf loaded" "$(t show -gv automatic-rename-format)" "#{pane_title}"
check "first: focus events on" "$(t show -gv focus-events)" "on"
attach
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "second: two windows" "$(windows)" "2"
check "second: no new tab" "$(tabs)" "1"
check "second: the new window comes forward" "$(t display -p -t =fleet: '#{window_index}')" "1"
t select-window -t =fleet:0
KLEPSYDRA_BACKGROUND=1 bash "$launch" new "$work/repos" >/dev/null 2>&1
check "#216: a fleet launch opens behind, the window in view keeps focus" "$(windows) $(t display -p -t =fleet: '#{window_index}')" "3 0"

echo "new: Antigravity (#323)"
mkdir -p "$work/bin"
cat >"$work/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == models ]]; then
  printf 'Fetching available models...\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\nbad;id\tEvil\nclaude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\nmystery-1\tMystery One\n'
  exit 0
fi
# The quota as agy -p /quota --output-format json reports it (captured 11-19);
# AGY_3P_LEFT sets the Claude and GPT group's five-hour fraction, AGY_QUOTA=none answers nothing.
if [[ ${1:-} == -p && ${2:-} == /quota ]]; then
  [[ ${AGY_QUOTA:-} == none ]] && exit 1
  printf '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","description":"Models within this group: Gemini 3.8 Flash","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.68,"reset_time":"2026-11-25T15:15:16Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.74,"reset_time":"2026-11-19T11:15:16Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Sonnet 4.6, Claude Opus 4.6, GPT-OSS 120B","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.49,"reset_time":"2026-11-25T15:32:48Z"},{"id":"3p-5h","window":"5h","remaining_fraction":%s,"reset_time":"2026-11-19T13:24:14Z"}]}]}}}\n' "${AGY_3P_LEFT:-1}"
  exit 0
fi
exec sleep 600
EOF
chmod +x "$work/bin/agy"
printf '# Helper rules\nRead only.\n' >"$work/rules.md"
export KLEPSYDRA_AGY="$work/bin/agy" KLEPSYDRA_RULES_SRC="$work/rules.md" KLEPSYDRA_AGY_RULES="$work/gemini/config/rules/klepsydra-fleet.md"
export KLEPSYDRA_AGY_LOCK="$here/klepsydra-agy-locked.json"
w0=$(windows)
check "#323: models lists agy's as one line of JSON, dropping its fetching line and any id that is not one" \
  "$(AGY_QUOTA=none bash "$launch" models 2>&1)" '[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)"},{"id":"claude-opus-4-6-thinking","label":"Claude Opus 4.6 (Thinking)"},{"id":"mystery-1","label":"Mystery One"}]'
check "#440: each model carries its quota group as agy's /quota names its members, never by id; one no group names gets none" \
  "$(bash "$launch" models 2>&1)" '[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)","group":"gemini"},{"id":"claude-opus-4-6-thinking","label":"Claude Opus 4.6 (Thinking)","group":"3p"},{"id":"mystery-1","label":"Mystery One"}]'
check "#440: a spent group says when it comes back" \
  "$(AGY_3P_LEFT=0 bash "$launch" models 2>&1 | jq -c '[.[] | .spent // "-"]')" '["-","2026-11-19T13:24:14Z","-"]'
before=$(windows)
out=$(AGY_3P_LEFT=0 bash "$launch" new "$work/repos" agy claude-opus-4-6-thinking 2>&1); rc=$?
check "#440: a model whose group is spent starts nothing, even from a menu drawn before it ran out" "$rc $(( $(windows) - before )) $out" \
  "1 0 Not started: Antigravity's quota for claude-opus-4-6-thinking is spent until 2026-11-19T13:24:14Z."
out=$(AGY_3P_LEFT=0 bash "$launch" new "$work/repos" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#440: the other group's model still starts" "$rc $(( $(windows) - before ))" "0 1"
out=$(AGY_3P_LEFT=0 AGY_QUOTA=none bash "$launch" new "$work/repos" agy claude-opus-4-6-thinking 2>&1); rc=$?
check "#440: with no quota answer the launch goes ahead (agy reports a spent quota itself)" "$rc $(( $(windows) - before ))" "0 2"
# The cases after count agy's windows from here.
t list-panes -a -F '#{window_id} #{pane_start_command}' | awk -v a="$work/bin/agy" 'index($0, a) { print $1 }' | xargs -r -n1 tmux -L "$sock" kill-window -t
before=$(windows)
out=$(bash "$launch" new "$work/repos" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323: an agy session starts in a window of its own, said so" "$rc $(( $(windows) - before )) $out" "0 1 Started a locked Antigravity session (gemini-3.8-flash-high) in $work/repos."
check "#323: on the model asked for" "$(t list-panes -a -F '#{pane_start_command}' | grep -c -- "$work/bin/agy --model gemini-3.8-flash-high")" "1"
# The lock (agy-copilot lanes): every agy session the fleet starts is read-only, no shell, sandboxed.
sf=$(t list-panes -a -F '#{pane_start_command}' | grep -o -- "--settings [^ ]*" | head -1 | cut -d' ' -f2 | tr -d "'\"")
check "#323 lock: the session gets --sandbox and a settings file of its own, never AJ's" \
  "$(t list-panes -a -F '#{pane_start_command}' | grep -c -- "--sandbox") $([[ $sf == "$KLEPSYDRA_AGY_LOCK" ]] && echo policy)" "1 policy"
check "#323 lock: that file denies writes, the shell, MCP, URL reads and the browser, and asks before anything else (headless, that is a denial)" \
  "$(jq -r '[.toolPermission, .allowNonWorkspaceAccess, .enableTerminalSandbox, (.permissions.deny | sort | join(","))] | join(" ")' "$sf")" \
  "request-review false true command(*),execute_url(*),mcp(*),read_url(*),write_file(*)"
check "#323 lock: it names no trusted workspace, so agy asks before trusting a folder (a repo's hooks load only under trust)" "$(jq -c '.trustedWorkspaces // "none"' "$sf")" '"none"'
check "#323: the helper rules reach agy as an always-on rule made from the one source" \
  "$(sed -n 2p "$KLEPSYDRA_AGY_RULES") $(grep -c '^Read only.$' "$KLEPSYDRA_AGY_RULES")" "trigger: always_on 1"
check "#323: the shipped rules fit agy's 24000-byte limit and name no person, course or account" \
  "$([[ $(stat -c %s "$here/klepsydra-engine-rules.md") -le 24000 ]] && echo fits) $(grep -cwE 'AJ|ajbar|RIT|CISC|Ben|makesense|Anthropic|Claude' "$here/klepsydra-engine-rules.md")" "fits 0"
touch -d '2026-01-01' "$KLEPSYDRA_AGY_RULES"
bash "$launch" new "$work/repos" agy gemini-3.8-flash-high >/dev/null 2>&1
check "#323: unchanged rules are not written again" "$(date -r "$KLEPSYDRA_AGY_RULES" +%F)" "2026-01-01"
before=$(windows)
out=$(bash "$launch" new "$work/repos" agy 'x;touch /tmp/pwned' 2>&1); rc=$?
check "#323: a model that is no id starts nothing" "$rc $(( $(windows) - before )) $out" "1 0 That is not an agy model id: x;touch /tmp/pwned"
out=$(KLEPSYDRA_RULES_SRC="$work/no-rules.md" bash "$launch" new "$work/repos" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323: with the helper rules unreadable, no agy session starts" "$rc $(( $(windows) - before ))" "1 0"
lb=$(windows)
out=$(KLEPSYDRA_AGY_LOCK="$work/no-lock.json" bash "$launch" new "$work/repos" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: with the lock policy unreadable, no agy session starts (never an unlocked one)" "$rc $(( $(windows) - lb ))" "1 0"
lb=$(windows)
for f in hooks plugins skills; do
  mkdir -p "$work/ships-$f/.agents"; echo '{}' >"$work/ships-$f/.agents/$f.json"
  out=$(bash "$launch" new "$work/ships-$f" agy gemini-3.8-flash-high 2>&1); rc=$?
  check "#323 lock: a folder that ships .agents/$f.json is no locked agy workspace (its trust dialog is the only gate)" "$rc $(( $(windows) - lb )) $(grep -c "ships agy workspace configuration" <<<"$out")" "1 0 1"
done
git init -q "$work/anc" && mkdir -p "$work/anc/.agents" "$work/anc/sub" && echo '{}' >"$work/anc/.agents/hooks.json"
out=$(bash "$launch" new "$work/anc/sub" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: a folder whose repo root ships .agents is refused (agy walks up to it)" "$rc $(( $(windows) - lb ))" "1 0"
for nm in _agents _agent .agent; do
  mkdir -p "$work/nm$nm/$nm"
  out=$(bash "$launch" new "$work/nm$nm" agy gemini-3.8-flash-high 2>&1); rc=$?
  check "#323 lock: $nm is refused too (agy loads workspace configuration from all four folder names)" "$rc $(( $(windows) - lb ))" "1 0"
done
mkdir -p "$work/winmnt/c/proj"
out=$(KLEPSYDRA_WINDOWS_MOUNT="$work/winmnt" bash "$launch" new "$work/winmnt/c/proj" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: a folder on the Windows side is no agy workspace (its user folders hold credentials)" "$rc $(( $(windows) - lb )) $(grep -c 'Windows side' <<<"$out")" "1 0 1"
out=$(bash "$launch" new / agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: / is no agy workspace" "$rc $(( $(windows) - lb ))" "1 0"
out=$(bash "$launch" new "${HOME%/*}" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: neither is a folder that holds the home folder (the parent of it)" "$rc $(( $(windows) - lb ))" "1 0"
out=$(bash "$launch" new "$HOME" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323 lock: the whole home folder is never an agy workspace (its reads would reach every secret in it)" "$rc $(( $(windows) - before ))" "1 0"
mkdir -p "$work/gemini/config/rules"
printf -- '---\ntrigger: always_on\ndescription: "AJ'"'"'s global rules, made from /x/CLAUDE.md by klepsydra; edit that file, not this one."\n---\nold\n' >"$work/gemini/config/rules/claude-global.md"
printf -- 'my own rule\n' >"$work/gemini/config/rules/mine.md"
bash "$launch" new "$work/repos" agy gemini-3.8-flash-high >/dev/null 2>&1
check "#323: the earlier launcher's whole-CLAUDE.md rule is removed; a rule that is not klepsydra's stays" "$([[ -e $work/gemini/config/rules/claude-global.md ]] && echo old-kept || echo gone) $(cat "$work/gemini/config/rules/mine.md")" "gone my own rule"
printf -- 'someone else\n' >"$work/gemini/config/rules/claude-global.md"
bash "$launch" new "$work/repos" agy gemini-3.8-flash-high >/dev/null 2>&1
check "#323: and a claude-global.md that is not klepsydra's is left alone" "$(cat "$work/gemini/config/rules/claude-global.md")" "someone else"
before=$(windows) # the two launches above opened windows
head -c 24100 /dev/zero | tr '\0' x >"$work/big-rules.md"
out=$(KLEPSYDRA_RULES_SRC="$work/big-rules.md" bash "$launch" new "$work/repos" agy gemini-3.8-flash-high 2>&1); rc=$?
check "#323: rules over agy's 24000-byte limit start nothing" "$rc $(( $(windows) - before ))" "1 0"
check "#323: a launch of anything else is refused" "$(bash "$launch" new "$work/repos" codex x >/dev/null 2>&1; echo $?) $(( $(windows) - before ))" "1 0"
# The cases after count the fleet's windows: the agy ones this section opened go.
t list-panes -a -F '#{window_id} #{pane_start_command}' | awk -v a="$work/bin/agy" 'index($0, a) { print $1 }' | xargs -r -n1 tmux -L "$sock" kill-window -t
check "#323: and its windows are closed again" "$(windows)" "$w0"

echo "new: Copilot (#440)"
printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$work/bin/copilot"; chmod +x "$work/bin/copilot"
export KLEPSYDRA_COPILOT="$work/bin/copilot"
before=$(windows)
out=$(bash "$launch" new "$work/repos" copilot 2>&1); rc=$?
check "#440: a Copilot session starts in a window of its own, on auto when no model is named" "$rc $(( $(windows) - before )) $out" "0 1 Started a locked Copilot session (auto) in $work/repos."
check "#440: locked as fleet delegate runs it: reads only, no writes, no shell, no built-in MCP" \
  "$(t list-panes -a -F '#{pane_start_command}' | grep -c -- "$work/bin/copilot --model auto --allow-all-tools --available-tools view,grep,glob --deny-tool=write --deny-tool=shell --disable-builtin-mcps --disallow-temp-dir")" "1"
out=$(bash "$launch" new "$work/repos" copilot gpt-5.6-sol 2>&1); rc=$?
check "#440: on the model asked for" "$rc $(t list-panes -a -F '#{pane_start_command}' | grep -c -- "copilot --model gpt-5.6-sol ")" "0 1"
before=$(windows)
out=$(bash "$launch" new "$work/repos" copilot 'x;id' 2>&1); rc=$?
check "#440: a Copilot model that is no id starts nothing" "$rc $(( $(windows) - before )) $out" "1 0 That is not a Copilot model id: x;id"
for f in .github/hooks .github/mcp.json .mcp.json .vscode/mcp.json .copilot .claude/skills .agents/skills; do
  d="$work/cp-${f//\//_}"; mkdir -p "$d/$f"
  out=$(bash "$launch" new "$d" copilot 2>&1); rc=$?
  check "#440 lock: a folder that ships $f is no locked Copilot workspace (folder trust loads it)" "$rc $(( $(windows) - before )) $(grep -c 'ships Copilot workspace configuration' <<<"$out")" "1 0 1"
done
mkdir -p "$work/cphk/.claude"
printf '{"permissions": {}}\n' >"$work/cphk/.claude/settings.json"
out=$(bash "$launch" new "$work/cphk" copilot 2>&1); rc=$?
check "#440 lock: Claude Code project settings without hooks are no bar to Copilot" "$rc $(( $(windows) - before ))" "0 1"
before=$(windows)
for f in settings.json settings.local.json; do
  d="$work/cphk-$f"; mkdir -p "$d/.claude"; printf '{"hooks": {"Stop": []}}\n' >"$d/.claude/$f"
  out=$(bash "$launch" new "$d" copilot 2>&1); rc=$?
  check "#440 lock: .claude/$f with hooks is refused (Copilot runs them)" "$rc $(( $(windows) - before )) $(grep -c 'sets hooks' <<<"$out")" "1 0 1"
done
d="$work/cphk-bad"; mkdir -p "$d/.claude"; printf 'not json' >"$d/.claude/settings.json"
out=$(bash "$launch" new "$d" copilot 2>&1); rc=$?
check "#440 lock: a settings file that does not read is refused (fail closed)" "$rc $(( $(windows) - before ))" "1 0"
git init -q "$work/cpanc" && mkdir -p "$work/cpanc/.github/hooks" "$work/cpanc/sub"
out=$(bash "$launch" new "$work/cpanc/sub" copilot 2>&1); rc=$?
check "#440 lock: a folder whose repo root ships Copilot hooks is refused" "$rc $(( $(windows) - before ))" "1 0"
out=$(bash "$launch" new "$HOME" copilot 2>&1); rc=$?
check "#440 lock: the home folder is never a Copilot workspace" "$rc $(( $(windows) - before )) $(grep -c 'whole home folder' <<<"$out")" "1 0 1"
mkdir -p "$work/winmnt/c/proj"
out=$(KLEPSYDRA_WINDOWS_MOUNT="$work/winmnt" bash "$launch" new "$work/winmnt/c/proj" copilot 2>&1); rc=$?
check "#440 lock: nor the Windows side" "$rc $(( $(windows) - before ))" "1 0"
out=$(KLEPSYDRA_COPILOT=no-such-copilot bash "$launch" new "$work/repos" copilot 2>&1); rc=$?
check "#440: no copilot: says so, starts nothing" "$rc $(( $(windows) - before )) $out" "1 0 copilot (GitHub Copilot CLI) was not found on PATH."
t list-panes -a -F '#{window_id} #{pane_start_command}' | awk -v a="$work/bin/copilot" 'index($0, a) { print $1 }' | xargs -r -n1 tmux -L "$sock" kill-window -t
check "#440: Copilot's windows are closed again" "$(windows)" "$w0"

echo "new: Claude on a chosen account (#440)"
# Two logins whose folder names say the opposite of what they hold, as on AJ's PC
# (~/.claude is one account, ~/.claude-rit the other), and a folder with no login.
mkdir -p "$HOME/.claude" "$HOME/.claude-rit" "$HOME/.claude-nologin"
printf '{"oauthAccount":{"accountUuid":"aaaa1111-0000-0000-0000-000000000001"}}\n' >"$HOME/.claude.json"
printf '{"oauthAccount":{"accountUuid":"bbbb2222-0000-0000-0000-000000000002"}}\n' >"$HOME/.claude-rit/.claude.json"
printf '{"oauthAccount":{"accountUuid":"cccc3333-0000-0000-0000-000000000003"}}\n' >"$HOME/.claude-nologin/.claude.json"
: >"$HOME/.claude/.credentials.json"; : >"$HOME/.claude-rit/.credentials.json"
printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$work/bin/claude"; chmod +x "$work/bin/claude"
check "#440: engines names each account with a login here, and the engines on PATH" \
  "$(KLEPSYDRA_AGY=no-agy bash "$launch" engines 2>&1)" '{"claude":["aaaa1111-0000-0000-0000-000000000001","bbbb2222-0000-0000-0000-000000000002"],"agy":false,"copilot":true}'
check "#440: FLEET_ACCOUNTS, when set, is the list" \
  "$(FLEET_ACCOUNTS="$HOME/.claude-rit" bash "$launch" engines 2>&1 | jq -c .claude)" '["bbbb2222-0000-0000-0000-000000000002"]'
before=$(windows)
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude bbbb2222-0000-0000-0000-000000000002 opus 2>&1); rc=$?
check "#440: claude starts on the folder logged in to the account, found by its login, on the model asked for" \
  "$rc $(( $(windows) - before )) $(t list-panes -a -F '#{pane_start_command}' | grep -c -- "env CLAUDE_CONFIG_DIR=$HOME/.claude-rit $work/bin/claude --model opus")" "0 1 1"
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude aaaa1111-0000-0000-0000-000000000001 2>&1); rc=$?
check "#440: the default folder's account starts with CLAUDE_CONFIG_DIR unset, no --model when none is named" \
  "$rc $(t list-panes -a -F '#{pane_start_command}' | grep -c -- "env -u CLAUDE_CONFIG_DIR $work/bin/claude\"\$")" "0 1"
check "#440: both still run on the subscription only (#260)" \
  "$(t list-panes -a -F '#{pane_start_command}' | grep -- "$work/bin/claude" | grep -c 'env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_PROFILE env ')" "2"
before=$(windows)
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude cccc3333-0000-0000-0000-000000000003 2>&1); rc=$?
check "#440: an account whose folder holds no login starts nothing" "$rc $(( $(windows) - before )) $(grep -c 'No Claude Code folder here is logged in' <<<"$out")" "1 0 1"
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude '../x;id' 2>&1); rc=$?
check "#440: an account that is no id starts nothing" "$rc $(( $(windows) - before )) $out" "1 0 That is not a Claude account id: ../x;id"
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude bbbb2222-0000-0000-0000-000000000002 'opus;id' 2>&1); rc=$?
check "#440: a model that is no alias or name starts nothing" "$rc $(( $(windows) - before )) $out" "1 0 That is not a Claude model: opus;id"
printf '{"apiKeyHelper": "x"}\n' >"$HOME/.claude-rit/settings.json"
out=$(KLEPSYDRA_CLAUDE="$work/bin/claude" bash "$launch" new "$work/repos" claude bbbb2222-0000-0000-0000-000000000002 2>&1); rc=$?
check "#440: the key check reads the chosen account's folder, not the server's" "$rc $(( $(windows) - before )) $(grep -c 'sets an API key or key helper' <<<"$out")" "1 0 1"
rm -f -- "$HOME/.claude-rit/settings.json"
t list-panes -a -F '#{window_id} #{pane_start_command}' | awk -v a="$work/bin/claude" 'index($0, a) { print $1 }' | xargs -r -n1 tmux -L "$sock" kill-window -t
rm -rf -- "${HOME:?}/.claude" "${HOME:?}/.claude-rit" "${HOME:?}/.claude-nologin" "${HOME:?}/.claude.json"
check "#440: its windows are closed again" "$(windows)" "$w0"
unset KLEPSYDRA_COPILOT
unset KLEPSYDRA_AGY KLEPSYDRA_RULES_SRC KLEPSYDRA_AGY_RULES KLEPSYDRA_AGY_LOCK
# A fleet launch that starts the server (a cold recover) must not hand the flag
# to the server's environment, or every later pane, the wall's included, opens behind.
# Its own stub log: the tab it opens is not one of the fleet socket's tabs counted below.
WT_LOG="$work/wt4.log" KLEPSYDRA_TMUX_SOCKET="$sock4" KLEPSYDRA_BACKGROUND=1 bash "$launch" new "$work/repos" >/dev/null 2>&1
check "#229 review: a flagged launch that starts the server keeps the flag out of its environment" \
  "$(tmux -L "$sock4" has-session -t =fleet 2>/dev/null && echo up) $(tmux -L "$sock4" show-environment -g 2>/dev/null | grep -c '^KLEPSYDRA_BACKGROUND=')" "up 0"
tmux -L "$sock4" kill-server 2>/dev/null
# Nor the command a fleet launch passes (#440 live check): the 11-16 server kept Heph's,
# session id and all, and a launch from one of its panes ran that instead of claude.
WT_LOG="$work/wt6.log" KLEPSYDRA_TMUX_SOCKET="$sock4" KLEPSYDRA_BACKGROUND=1 KLEPSYDRA_CLAUDE="sleep 601" bash "$launch" new "$work/repos" >/dev/null 2>&1
check "#440: a fleet launch that starts the server keeps its command out of the server's environment" \
  "$(tmux -L "$sock4" show-environment -g 2>/dev/null | grep -c '^KLEPSYDRA_CLAUDE=') $(tmux -L "$sock4" list-panes -a -F '#{pane_start_command}' 2>/dev/null | grep -c 'sleep 601')" "0 1"
tmux -L "$sock4" kill-server 2>/dev/null
# Nor a session's voice (#395 review): it goes into the session's command alone.
WT_LOG="$work/wt5.log" KLEPSYDRA_TMUX_SOCKET="$sock4" KERYX_VOICE=bf_emma bash "$launch" new "$work/repos" >/dev/null 2>&1
check "#395 review: a launch with a voice that starts the server keeps it out of the server's environment" \
  "$(tmux -L "$sock4" show-environment -g 2>/dev/null | grep -c '^KERYX_VOICE=') $(tmux -L "$sock4" list-panes -a -F '#{pane_start_command}' 2>/dev/null | grep -c 'KERYX_VOICE=bf_emma')" "0 1"
tmux -L "$sock4" kill-server 2>/dev/null
t kill-window -t "=fleet:$(t list-windows -t =fleet -F '#{window_index}' | tail -1)"
detach_all
check "closed tab: sessions survive" "$(windows)" "2"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "closed tab: a window" "$(windows)" "3"
check "closed tab: one tab to reattach" "$(tabs)" "2"
# shellcheck disable=SC2088 # the overlay passes a literal ~
bash "$launch" new "~/../repos/my repos" >/dev/null 2>&1; rc=$?
check "folder with a space: exit 0" "$rc" "0"
check "folder with a space: cwd" "$(t display -p -t =fleet: '#{pane_current_path}')" "$work/repos/my repos"
out=$(bash "$launch" new "$work/nowhere" 2>&1); rc=$?
check "missing folder: exit 1" "$rc" "1"
check "missing folder: says so" "$out" "The folder $work/nowhere does not exist."
out=$(KLEPSYDRA_CLAUDE=no-such-claude bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no claude: exit 1" "$rc" "1"
check "no claude: says so" "$out" "claude was not found on PATH."
detach_all
got=$(printf 'row 2\nrow 3\n' | { WT_DRAIN=1 bash "$launch" new "$work/repos" >/dev/null 2>&1; cat; })
check "#242: a tab opened from a loop leaves the loop's stdin alone" "$(tabs) $got" $'3 row 2\nrow 3'

stop_server; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "concurrent: one session" "$(t list-sessions | wc -l)" "1"
check "concurrent: two windows" "$(windows)" "2"
check "concurrent: one tab" "$(tabs)" "1"

echo "jump"
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
socket=$(t display -p '#{socket_path}')
second=$(t list-panes -s -t =fleet -F '#{pane_id}' | sed -n 2p)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
spid=$(pane_pid "$second"); sstart=$(pstart "$spid")
attach; : >"$WT_LOG"
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "jump: exit 0" "$rc" "0"
check "jump: says so" "$out" "Selected the session's tmux window."
check "jump: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump with a client: no tab" "$(tabs)" "0"
t select-window -t "$second"
out=$(jmp "$first" "$spid" "$sstart" 2>&1); rc=$?
check "another pane's process: exit 1" "$rc" "1"
check "another pane's process: says so" "$out" "That session's tmux pane now belongs to another session."
check "another pane's process: no window change" "$(t display -p -t =fleet: '#{pane_id}')" "$second"
out=$(jmp "$first" 2999999 "$fstart" 2>&1); rc=$?
check "dead pid: exit 1" "$rc" "1"
check "dead pid: says so" "$out" "That session's tmux pane now belongs to another session."
out=$(jmp "$first" "$fpid" "$((fstart + 1))" 2>&1); rc=$?
check "reused pid: exit 1" "$rc" "1"
check "reused pid: says so" "$out" "That session's tmux pane now belongs to another session."
for bad in 12a "" 0 01; do
  out=$(jmp "$first" "$bad" "$fstart" 2>&1); rc=$?
  check "bad pid '$bad': exit 1" "$rc" "1"
  check "bad pid '$bad': says so" "$out" "Not a process id: $bad"
done
for bad in 12a ""; do
  out=$(jmp "$first" "$fpid" "$bad" 2>&1); rc=$?
  check "bad start '$bad': says so" "$out" "Not a process start time: $bad"
done
check "refusals: window unchanged" "$(t display -p -t =fleet: '#{pane_id}')" "$second"
# Run "$@" every 0.1 s until it succeeds, at most 10 s.
until_true() { local _; for _ in $(seq 100); do "$@" && return 0; sleep 0.1; done; return 1; }
has_child() { [[ -n $(pgrep -P "$1") ]]; }
zombie_child() { local c; c=$(pgrep -P "$1" | head -1); [[ -n $c && $(awk '{print $3}' "/proc/$c/stat" 2>/dev/null) == Z ]]; }
# The walk: claude is a descendant of pane_pid, not pane_pid itself.
leaf() { local p=$1 c _; for _ in 1 2 3 4 5 6 7 8; do c=$(pgrep -P "$p" | head -1); [[ -n $c ]] || break; p=$c; done; echo "$p"; }
deep=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 600; true'")
until_true has_child "$(pane_pid "$deep")"
dleaf=$(leaf "$(pane_pid "$deep")"); dstart=$(pstart "$dleaf")
check "descendant: leaf is not the pane pid" "$([[ $dleaf != "$(pane_pid "$deep")" ]] && echo yes)" "yes"
out=$(jmp "$deep" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant: exit 0" "$rc" "0"
check "descendant: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$deep"
out=$(jmp "$first" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant against another pane: refused" "$out" "That session's tmux pane now belongs to another session."
# A zombie child is not Claude.
zp=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 0.2 & exec sleep 600'")
until_true zombie_child "$(pane_pid "$zp")"
zleaf=$(leaf "$(pane_pid "$zp")")
check "zombie: made" "$(awk '{print $3}' "/proc/$zleaf/stat")" "Z"
out=$(jmp "$zp" "$zleaf" "$(pstart "$zleaf")" 2>&1); rc=$?
check "zombie: refused" "$out" "That session's tmux pane now belongs to another session."
t select-window -t "$second"
out=$(bash "$launch" jump "$socket" "$first" "$fpid" 2>&1); rc=$?
check "missing start: exit 1" "$rc" "1"
out=$(jmp '%3;x' "$fpid" "$fstart" 2>&1); rc=$?
check "bad pane: exit 1" "$rc" "1"
check "bad pane: says so" "$out" "Not a tmux pane: %3;x"
out=$(bash "$launch" jump "rel/sock" "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "relative socket: exit 1" "$rc" "1"
check "relative socket: says so" "$out" "Not a tmux socket path: rel/sock"
check "bad arguments: no tab" "$(tabs)" "0"
out=$(jmp '%99999' "$fpid" "$fstart" 2>&1); rc=$?
check "unknown pane: exit 1" "$rc" "1"
check "unknown pane: says so" "$out" "That session's tmux pane is gone."
detach_all
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "jump without a client: one tab" "$(tabs)" "1"
check "jump's tab names the socket" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe -d Test -e tmux -S $socket attach -t =fleet"
# A hand-started tmux on another socket gets a plain tab.
tmux -L "$sock2" -f /dev/null new-session -d -s hand "sleep 600"
socket2=$(tmux -L "$sock2" display -p '#{socket_path}')
pane2=$(tmux -L "$sock2" display -p '#{pane_id}')
p2=$(tmux -L "$sock2" display -p '#{pane_pid}')
: >"$WT_LOG"
out=$(bash "$launch" jump "$socket2" "$pane2" "$p2" "$(pstart "$p2")" 2>&1); rc=$?
check "other socket: exit 0" "$rc" "0"
check "other socket: a plain tab" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -S $socket2 attach -t =hand"
tmux -L "$sock2" kill-server 2>/dev/null
# The user's ~/.tmux.conf can turn focus events back off.
printf 'set -g focus-events off\n' >"$HOME/.tmux.conf"
tmux -L "$sock3" -f "$KLEPSYDRA_TMUX_CONF" new-session -d -s optout "sleep 600"
check "the user's tmux.conf turns focus events off" "$(tmux -L "$sock3" show -gv focus-events)" "off"
check "the user's tmux.conf keeps the window names" "$(tmux -L "$sock3" show -gv automatic-rename-format)" "#{pane_title}"
tmux -L "$sock3" kill-server 2>/dev/null; rm -f "$HOME/.tmux.conf"
detach_all; : >"$WT_LOG"
bash "$launch" jump "$socket" "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "fleet socket: titled tab" "$(head -1 "$WT_LOG" | grep -c -- "^-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe")" "1"
echo "end and interrupt"
# Draws Claude Code's input box as capture-pane shows it (U+276F, a no-break
# space, rules above and below) and logs each key that matters and what Enter
# submits. FAKE_DROP is a key it loses, as keys typed during a redraw are;
# FAKE_STAY makes it ignore /exit.
cat >"$work/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
log=$1 buf=""
stty -icanon -echo -isig
mark=$'\xe2\x9d\xaf\xc2\xa0'
draw() {
  # FAKE_TAIL: a recorded screen tail, its input line showing what was typed.
  if [[ -n ${FAKE_TAIL:-} ]]; then
    printf '\033[2J\033[Hhistory\n'
    while IFS= read -r line; do
      [[ $line == "$mark"* ]] && line=$mark$buf
      printf '%s\n' "$line"
    done <"$FAKE_TAIL"
    return
  fi
  printf '\033[2J\033[Hhistory\n\xe2\x9d\xaf\xc2\xa0/exit\nout\n'
  # An older Claude Code's spinner, with its hint, just above the input box.
  [[ -z ${FAKE_BUSY:-} ]] || printf '\xe2\x9c\xbb Thinking\xe2\x80\xa6 (12s \xc2\xb7 esc to interrupt)\n'
  printf '\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\xc2\xa0%s\n\xe2\x94\x80\xe2\x94\x80\n  \xe2\x9d\xaf /exit   Exit the CLI\n' "$buf"
}
draw
# dd, not read -n: bash's read turns ISIG back on, and Ctrl+C would kill it.
while c=$(dd bs=1 count=1 2>/dev/null); do
  case $c in
    "") printf 'submit:%s\n' "$buf" >>"$log"; [[ $buf == /exit && -z ${FAKE_STAY:-} ]] && exit 0; buf="" ;;
    $'\e') printf 'esc\n' >>"$log" ;;
    $'\x03') printf 'ctrl-c\n' >>"$log"; buf="" ;;
    "${FAKE_DROP:-}") ;;
    *) buf+=$c ;;
  esac
  draw
done
EOF
chmod +x "$work/bin/fake-claude"
export KLEPSYDRA_END_WAIT=3
fake() { # [env...]: a fleet window running the fake; prints its pane id
  local p _
  p=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "env $* $work/bin/fake-claude $work/fake.log")
  for _ in $(seq 50); do t capture-pane -p -t "$p" | grep -q '^history' && break; sleep 0.1; done
  echo "$p"
}
send() { bash "$launch" "$1" "$socket" "$2" "$(pane_pid "$2")" "$(pstart "$(pane_pid "$2")")"; } # verb pane
alive() { [[ -n $(t display -p -t "$1" '#{pane_id}' 2>/dev/null) ]] && echo alive || echo gone; }
# The session is gone once its process is: tmux closes the pane, or, under
# load, has seen the terminal close but not yet reaped the process (#134: dead=1
# and no status after 10 s). A non-zero exit keeps the pane (remain-on-exit
# failed) and is not gone. Waits up to 20 s; a pane still there says why.
gone() { # pane pid start
  local why
  { until_true ended "$@" || until_true ended "$@"; } && { echo gone; return; }
  why=$(t display -p -t "$1" 'dead=#{pane_dead} status=#{pane_dead_status} signal=#{pane_dead_signal}')
  ended "$@" && { echo gone; return; }
  echo "alive ($why; pid $2 $(proc_state "$2" "$3"))"
}
ended() { # pane pid start
  # The process first: one tmux reaps after this read shows its status below.
  local proc; proc=$(proc_state "$2" "$3")
  is_gone "$1" && return 0
  [[ $(t display -p -t "$1" '#{pane_dead}:#{pane_dead_status}' 2>/dev/null) == 1: ]] || return 1
  [[ $proc == exited || $proc == zombie:0 ]]
}
proc_state() { # pid start: exited, running, or zombie:N with N its wait status (field 52)
  [[ $2 =~ ^[0-9]+$ ]] || { echo "no start time"; return; }
  local f start state code
  f=$(stat_fields "$1" 19 0 49) || { echo exited; return; }
  read -r start state code <<<"$f"
  [[ $start == "$2" ]] || { echo exited; return; }
  [[ $state == Z ]] && echo "zombie:$code" || echo running
}
is_gone() { [[ $(alive "$1") == gone ]]; }
# The fake logs a key when it reads it, which can be after the launch script
# returns: check its key log once it reads WANT, or as it stands after 10 s.
check_keys() { # name want
  until_true keys_read "$2"
  check "$1" "$(paste -sd' ' "$work/fake.log")" "$2"
}
keys_read() { [[ $(paste -sd' ' "$work/fake.log") == "$1" ]]; }
detach_all; tabs0=$(tabs)

: >"$work/fake.log"; p=$(fake)
t send-keys -t "$p" -l 'half a draft'; sleep 0.2
pid=$(pane_pid "$p"); start=$(pstart "$pid")
out=$(send end "$p" 2>&1); rc=$?
check "end: exit 0" "$rc" "0"
check "end: says so" "$out" "Ended the session."
check_keys "end: Esc, Ctrl+C, then /exit alone" "esc ctrl-c submit:/exit"
check "end: the process is gone" "$(gone "$p" "$pid" "$start")" "gone"

: >"$work/fake.log"; p=$(fake FAKE_DROP=x)
out=$(send end "$p" 2>&1); rc=$?
check "lost keys: exit 1" "$rc" "1"
check "lost keys: says so" "$out" "The session's prompt did not read /exit, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
check_keys "lost keys: the line is cleared" "esc ctrl-c ctrl-c"
check "lost keys: Enter never pressed" "$(grep -c '^submit:' "$work/fake.log")" "0"
check "lost keys: still running" "$(alive "$p")" "alive"
t kill-pane -t "$p"

: >"$work/fake.log"; p=$(fake FAKE_STAY=1)
out=$(send end "$p" 2>&1); rc=$?
check "ignored /exit: exit 1" "$rc" "1"
check "ignored /exit: says so" "$out" "Sent /exit, but the session is still running. Open its terminal to see why."
t kill-pane -t "$p"

: >"$work/fake.log"; p=$(fake)
out=$(send interrupt "$p" 2>&1); rc=$?
check "interrupt: exit 0" "$rc" "0"
check "interrupt: says so" "$out" "Sent Esc to the session."
check_keys "interrupt: Esc alone" "esc"
check "interrupt: still running" "$(alive "$p")" "alive"

# A pane in copy mode would eat the keys as copy-mode commands.
: >"$work/fake.log"; p=$(fake)
t copy-mode -t "$p"
check "copy mode: the pane is in it" "$(t display -p -t "$p" '#{pane_in_mode}')" "1"
out=$(send end "$p" 2>&1); rc=$?
check "copy mode, end: exit 0" "$rc" "0"
check "copy mode, end: says so" "$out" "Ended the session."
check_keys "copy mode, end: the keys reached the session" "esc ctrl-c submit:/exit"
: >"$work/fake.log"; p=$(fake)
t copy-mode -t "$p"
out=$(send interrupt "$p" 2>&1); rc=$?
check "copy mode, interrupt: exit 0" "$rc" "0"
check_keys "copy mode, interrupt: Esc reached the session" "esc"
check "copy mode, interrupt: out of copy mode" "$(t display -p -t "$p" '#{pane_in_mode}')" "0"

# An End the app gave up on may still be running: a second one is refused.
: >"$work/fake.log"; p=$(fake)
exec {held}>>"$ld/klepsydra-pane-$UID-${p#%}.lock"; flock -n "$held"
for verb in end interrupt wrapup; do
  out=$(send "$verb" "$p" 2>&1); rc=$?
  check "pane locked, $verb: exit 1" "$rc" "1"
  if [[ $verb == wrapup ]]; then
    check "pane locked, $verb: says so in its own words" "$out" \
      "klepsydra is already sending that session something; ask it by hand: type /klepsydra-wrapup in its terminal."
  else
    check "pane locked, $verb: says so" "$out" "That session is already being ended or interrupted."
  fi
done
check "pane locked: no key sent" "$(wc -c <"$work/fake.log")" "0"
exec {held}>&-
# A fleet script typing into the pane (#325) holds its typing lock: End waits, then gives up untyped.
mkdir -p "$HOME/.local/state/fleet-orchestrator/locks"
exec {held}>>"$HOME/.local/state/fleet-orchestrator/locks/send-${p#%}"; flock -n "$held"
out=$(KLEPSYDRA_TYPING_WAIT=1 send end "$p" 2>&1); rc=$?
check "fleet typing: end exits 1 and says why" "$rc $out" "1 A fleet script is typing into that session; try again in a moment."
check "fleet typing: no key sent" "$(wc -c <"$work/fake.log")" "0"
exec {held}>&-
rm -rf -- "${HOME:?}/.local/state/fleet-orchestrator"
out=$(send interrupt "$p" 2>&1)
check "pane unlocked: interrupt runs" "$out" "Sent Esc to the session."
t kill-pane -t "$p"

# KLEPSYDRA_END_WAIT reaches arithmetic: only 1 to 999 counts, else 10 s.
: >"$work/fake.log"; p=$(fake FAKE_STAY=1)
rm -f "$work/crafted"
out=$(KLEPSYDRA_END_WAIT="a[\$(touch $work/crafted)]" send end "$p" 2>&1); rc=$?
check "END_WAIT crafted: no command ran" "$([[ -e $work/crafted ]] && echo ran || echo none)" "none"
check "END_WAIT crafted: waits out and says so" "$out" "Sent /exit, but the session is still running. Open its terminal to see why."
t kill-pane -t "$p"

echo "wrap up"
: >"$work/fake.log"; p=$(fake)
t send-keys -t "$p" -l 'a draft'; sleep 0.2
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup: exit 0" "$rc" "0"
check "wrapup: says so" "$out" "Asked the session to wrap up."
check_keys "wrapup: Ctrl+C, then the command alone, no Esc" "ctrl-c submit:/klepsydra-wrapup"
check "wrapup: still running" "$(alive "$p")" "alive"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake FAKE_BUSY=1)
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup mid-turn: exit 1" "$rc" "1"
check "wrapup mid-turn: says so" "$out" "The session is mid-turn; it is asked when the turn ends."
check "wrapup mid-turn: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# Claude Code 2.1.302 at work: a spinner above the box, no "esc to interrupt" anywhere.
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$here/fixtures/pane-working-2.1.302.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, 2.1.302 at work: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, 2.1.302 at work: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# 2.1.302 running a tool: a tip sits under the spinner, and the footer reads "esc to interrupt".
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$here/fixtures/pane-working-tool-2.1.302.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, 2.1.302 running a tool: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, 2.1.302 running a tool: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# The footer's hint alone, with the transcript's last line above the box: refused.
sed '$s/$/ \xc2\xb7 esc to interrupt/' "$here/fixtures/pane-idle-2.1.302.txt" >"$work/footer-hint.txt"
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$work/footer-hint.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, esc hint in the footer: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, esc hint in the footer: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# Idle, though its transcript quotes the hint and a spinner line: only the line above the box counts.
{ printf 'it read \xe2\x9c\xbb Thinking\xe2\x80\xa6 (12s \xc2\xb7 esc to interrupt)\n'; cat "$here/fixtures/pane-idle-2.1.302.txt"; } >"$work/idle-quoting.txt"
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$work/idle-quoting.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, idle 2.1.302 quoting the hint: typed" "$rc $out" "0 Asked the session to wrap up."
check_keys "wrapup, idle 2.1.302 quoting the hint: Ctrl+C, then the command" "ctrl-c submit:/klepsydra-wrapup"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake FAKE_DROP=k)
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, lost keys: refused" "$out" "The session's prompt did not read /klepsydra-wrapup, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
check_keys "wrapup, lost keys: the line is cleared, Enter never pressed" "ctrl-c ctrl-c"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake)

# Every refusal Jump makes, End, Interrupt and Wrap up make too, before any key.
: >"$work/fake.log"
ppid_=$(pane_pid "$p"); pst=$(pstart "$ppid_")
for verb in end interrupt wrapup; do
  out=$(bash "$launch" "$verb" "$socket" "$p" "$spid" "$sstart" 2>&1)
  check "$verb, another pane's process: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" "$p" 2999999 "$pst" 2>&1)
  check "$verb, dead pid: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" "$p" "$ppid_" "$((pst + 1))" 2>&1)
  check "$verb, reused pid: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" '%3;x' "$ppid_" "$pst" 2>&1)
  check "$verb, bad pane: refused" "$out" "Not a tmux pane: %3;x"
  out=$(bash "$launch" "$verb" "$socket" '%99999' "$ppid_" "$pst" 2>&1)
  check "$verb, unknown pane: refused" "$out" "That session's tmux pane is gone."
  out=$(bash "$launch" "$verb" "rel/sock" "$p" "$ppid_" "$pst" 2>&1)
  check "$verb, relative socket: refused" "$out" "Not a tmux socket path: rel/sock"
  bash "$launch" "$verb" "$socket" "$p" "$ppid_" >/dev/null 2>&1; rc=$?
  check "$verb, missing start: exit 1" "$rc" "1"
done
tmux -L "$sock2" -f /dev/null new-session -d -s hand "$work/bin/fake-claude $work/fake.log"
for _ in $(seq 50); do tmux -L "$sock2" capture-pane -p | grep -q '^history' && break; sleep 0.1; done
socket2=$(tmux -L "$sock2" display -p '#{socket_path}')
pane2=$(tmux -L "$sock2" display -p '#{pane_id}')
p2=$(tmux -L "$sock2" display -p '#{pane_pid}')
for verb in end interrupt wrapup; do
  out=$(bash "$launch" "$verb" "$socket2" "$pane2" "$p2" "$(pstart "$p2")" 2>&1); rc=$?
  check "$verb, a hand-started tmux: exit 1" "$rc" "1"
  check "$verb, a hand-started tmux: says so" "$out" "That session is not in klepsydra's tmux, so klepsydra will not type into it."
done
tmux -L "$sock2" kill-server 2>/dev/null
check "refusals: no key reached a session" "$(wc -l <"$work/fake.log")" "0"
check "end and interrupt: never a tab" "$(tabs)" "$tabs0"
t kill-pane -t "$p"

out=$(bash "$launch" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"
check "unknown command: says so" "$out" "usage: klepsydra-launch.sh new DIR [agy MODEL | claude ACCOUNT [MODEL] | copilot [MODEL]] | models | engines | voices | jump|end|interrupt|wrapup SOCKET PANE PID START"
check "unknown command: no tab" "$(tabs)" "1"

# #273: the tray's Voices change runs the installed fleet voices at once, with
# no mode: the tray has saved it, and fleet voices reads it.
mkdir -p "$work/fbin"
printf '#!/usr/bin/env bash\nprintf "[%%s]\\n" "$*" >>"%s/fleet.calls"\n' "$work" >"$work/fbin/fleet"; chmod +x "$work/fbin/fleet"
out=$(FLEET_BIN="$work/fbin" bash "$launch" voices 2>&1); rc=$?
check "#273: voices runs fleet voices with no mode, and opens no tab" "$rc $(cat "$work/fleet.calls") $(tabs)" "0 [voices] 1"
out=$(FLEET_BIN="$work/fbin" bash "$launch" voices everyone 2>&1); rc=$?
check "#273: a mode argument is refused before anything runs" "$rc $(wc -l <"$work/fleet.calls")" "1 1"
out=$(FLEET_BIN="$work/nofleet" bash "$launch" voices 2>&1); rc=$?
check "#273: without the fleet installed it says so" "$rc $out" "1 The fleet commands are not installed (make install-fleet)."

# Another click holding the lock past its 10 s: the window is selected anyway.
detach_all; : >"$WT_LOG"
lock="$ld/klepsydra-launch-$UID.lock"
( exec 9>>"$lock"; flock 9; exec sleep 30 ) &
holder=$!
for _ in $(seq 100); do flock -n "$lock" true || break; sleep 0.05; done
attach
started=$SECONDS
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "attached jump beside a held lock: exit 0" "$rc" "0"
check "attached jump beside a held lock: says so" "$out" "Selected the session's tmux window."
check "attached jump beside a held lock: no wait" "$(( SECONDS - started < 5 ))" "1"
detach_all; : >"$WT_LOG"
t select-window -t "$(t list-windows -t =fleet -F '#{window_id}' | tail -1)"
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "jump behind a held lock: exit 1" "$rc" "1"
check "jump behind a held lock: says no launch" "$out" \
  "Selected the session's tmux window, but another click is still opening a terminal tab. Try again."
check "jump behind a held lock: window selected" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump behind a held lock: no tab" "$(tabs)" "0"
# #518 N5: with no lock folder the window is still selected, and the message
# says so and that no tab opened.
t select-window -t "$(t list-windows -t =fleet -F '#{window_id}' | tail -1)"
ln -s "$HOME/.local/state/klepsydra" "$work/jstate-link"
out=$(export KLEPSYDRA_STATE="$work/jstate-link"; jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "#518 N5: jump with no lock folder says the window changed and no tab opened" "$rc|$out" \
  "1|Selected the session's tmux window, but klepsydra has no lock folder ($work/jstate-link is a symlink), so no terminal tab opened for it."
check "#518 N5: and the window is selected, with no tab" "$(t display -p -t =fleet: '#{pane_id}') $(tabs)" "$first 0"
rm -f -- "$work/jstate-link"

echo "one lock folder for every launch (#517)"
# At a WSL boot XDG_RUNTIME_DIR names a folder logind makes minutes later, and
# the overlay's non-login shells may not have it at all: every launch still
# takes the one lock in this boot's state folder, never waits, never splits.
stop_server; detach_all; : >"$WT_LOG"
lk="$ld/klepsydra-launch-$UID.lock"
( exec 9>>"$lk"; flock 9; exec sleep 30 ) &
holder=$!
for _ in $(seq 100); do flock -n "$lk" true || break; sleep 0.05; done
mkdir -m 700 "$work/run-made"
s=$EPOCHREALTIME
out=$(KLEPSYDRA_LOCK_WAIT=0.1 XDG_RUNTIME_DIR="$work/run-not-yet" bash "$launch" new "$work/repos" 2>&1); rc=$?
e=$EPOCHREALTIME
check "#517 B2: before the runtime folder exists, a held launch refuses a second" "$rc|$out" "1|Another launch is still running."
check "#517 B1: and it never waits for that folder" "$(( (${e/./} - ${s/./}) < 3000000 ))" "1"
out=$(KLEPSYDRA_LOCK_WAIT=0.1 XDG_RUNTIME_DIR="$work/run-made" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517 B2: once it exists, the same lock refuses it" "$rc|$out" "1|Another launch is still running."
out=$(env -u XDG_RUNTIME_DIR KLEPSYDRA_LOCK_WAIT=0.1 bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517 B2: and so it does for a shell without XDG_RUNTIME_DIR" "$rc|$out" "1|Another launch is still running."
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "#517 B2: none of them started a session or a tab" "$(windows) $(tabs)" "0 0"

# The tab-pending stamp is shared the same way: a cold tab opened before the
# runtime folder exists keeps a launch after it from opening a second tab.
stop_server; detach_all; : >"$WT_LOG"
export WT_DELAY=never
out=$(XDG_RUNTIME_DIR="$work/run-not-yet" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517 B2: a cold tab before the folder exists stamps this boot's folder" \
  "$rc $([[ -f $pending ]] && echo stamped)" "0 stamped"
out=$(XDG_RUNTIME_DIR="$work/run-made" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517 B2: and a launch after it sees the stamp: one tab, two windows" "$rc $(tabs) $(windows)" "0 1 2"
unset WT_DELAY
rm -f -- "$pending" # or the next cases' first tab waits on it

# No lock folder of its own: nothing starts, and it says why.
stop_server; detach_all; : >"$WT_LOG"
ln -s "$HOME/.local/state/klepsydra" "$work/state-link"
out=$(KLEPSYDRA_STATE="$work/state-link" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517: no lock folder of its own: new is refused and says why" "$rc|$out|$(windows) $(tabs)" \
  "1|klepsydra has no lock folder ($work/state-link is a symlink), so this click went no further.|0 0"
rm -f -- "$work/state-link"
# A lock wait that is no number of seconds is the 10 s default, not "another launch".
out=$(KLEPSYDRA_LOCK_WAIT=abc bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#517 review: KLEPSYDRA_LOCK_WAIT=abc still launches" "$rc $(windows)" "0 1"

echo "one tab per fleet"
stop_server; detach_all; : >"$WT_LOG"
export WT_DELAY=0.5
bash "$launch" new "$work/repos" >/dev/null 2>&1
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "slow tab, two new: one tab" "$(tabs)" "1"
check "slow tab, two new: two windows" "$(windows)" "2"
stop_server; detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "slow tab, concurrent new: one tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
socket=$(t display -p '#{socket_path}')
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "slow tab, new then jump: one tab" "$(tabs)" "1"
unset WT_DELAY

echo "a tab that has not attached yet"
stop_server; detach_all; : >"$WT_LOG"
# A cold WSL: the tab attaches after the launcher stops waiting. The launcher's
# poll runs longer on a loaded machine, so any fixed delay can land inside it
# and leave no pending stamp; this tab never attaches.
export WT_DELAY=never
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "cold tab: exit 0" "$rc" "0"
check "cold tab: says the tab has not attached" "$out" \
  "Started a session in $work/repos. The terminal tab has not attached yet."
check "cold tab: a pending stamp" "$(read -r at key <"$pending"; echo "$key")" "-S $(t display -p '#{socket_path}') =fleet"
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "cold tab, second new: exit 0" "$rc" "0"
check "cold tab, second new: one tab, not two" "$(tabs)" "1"
check "cold tab, second new: two windows" "$(windows)" "2"
check "cold tab, second new: says so" "$out" "Started a session in $work/repos. The terminal tab has not attached yet."
socket=$(t display -p '#{socket_path}')
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "cold tab, then jump: one tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
read -r at key <"$pending"; printf '%s %s\n' "$((at - 31))" "$key" >"$pending"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "a stamp over 30 s old: a new tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
read -r at key <"$pending"; printf '%s %s\n' "$at" "-S /tmp/elsewhere =fleet" >"$pending"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "another server's stamp: a new tab" "$(tabs)" "1"
unset WT_DELAY
detach_all; rm -f "$pending"

echo "a stamp that is not our own file"
socket=$(t display -p '#{socket_path}')
mkfifo "$pending"; : >"$WT_LOG"
timeout 5 bash "$launch" new "$work/repos" >/dev/null 2>&1; rc=$?
check "a FIFO stamp: no block, exit 0" "$rc" "0"
check "a FIFO stamp: ignored, a tab" "$(tabs)" "1"
check "a FIFO stamp: removed" "$([[ -p $pending ]] && echo fifo)" ""
detach_all; rm -f "$pending"; : >"$WT_LOG"
printf -v now '%(%s)T' -1
printf '%s %s\n' "$now" "-S $socket =fleet" >"$work/planted"
ln -s "$work/planted" "$pending"
timeout 5 bash "$launch" new "$work/repos" >/dev/null 2>&1; rc=$?
check "a symlinked stamp: exit 0" "$rc" "0"
check "a symlinked stamp: not followed, a tab" "$(tabs)" "1"
check "a symlinked stamp: its target untouched" "$(cat "$work/planted")" "$now -S $socket =fleet"
check "a symlinked stamp: the link removed" "$([[ -L $pending ]] && echo link)" ""
detach_all; rm -f "$pending"

echo "failed tab"
stop_server; detach_all; : >"$WT_LOG"
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, no session: exit 1" "$rc" "1"
check "wt fails, no session: says so" "$out" "Windows Terminal did not open a tab."
check "wt fails, no session: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
bash "$launch" new "$work/repos" >/dev/null 2>&1; detach_all
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, session: exit 1" "$rc" "1"
check "wt fails, session: window count unchanged" "$(windows)" "1"
stop_server
out=$(KLEPSYDRA_WT=no-such-wt bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no wt.exe: exit 1" "$rc" "1"
check "no wt.exe: says so" "$out" "wt.exe was not found, so no terminal tab could be opened."
check "no wt.exe: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
out=$(WSL_DISTRO_NAME='a;b' bash "$launch" new "$work/repos" 2>&1); rc=$?
check "bad distro name: exit 1" "$rc" "1"
check "bad distro name: says so" "$out" "WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
check "bad distro name: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
odd="$work/a;b"; mkdir -p "$odd"; : >"$WT_LOG"
out=$(TMUX_TMPDIR="$odd" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "a socket path wt.exe would split: exit 1" "$rc" "1"
check "a socket path wt.exe would split: says so" "$out" \
  "The tmux socket path cannot be passed to a tab: $odd/tmux-$(id -u)/$sock"
check "a socket path wt.exe would split: nothing running, no tab" \
  "$(TMUX_TMPDIR="$odd" tmux -L "$sock" list-sessions 2>/dev/null | wc -l)|$(tabs)" "0|0"

echo "native Linux (Debian): no WSL, stub terminals and xdotool"
# The suite runs on WSL, so the launcher is told it is not there: no
# WSL_DISTRO_NAME and a fake /proc whose kernel release has no "microsoft".
# PATH holds only the tools the launcher needs, so no terminal on the host can
# be found by accident.
lbin="$work/lx-bin" lbase="$work/lx-base" lproc="$work/lx-proc"
mkdir -p "$lbin" "$lbase" "$lproc/sys/kernel"
for c in awk tail sort find xargs uniq tee printenv realpath tmux flock seq sleep head cat rm mktemp stat cmp mkdir date env bash sh grep sed tr wc cut dirname basename readlink ln id uname touch chmod mv cp script jq timeout; do
  p=$(command -v "$c") && ln -sf "$p" "$lbase/$c"
done
printf '6.12.0-amd64\n' >"$lproc/sys/kernel/osrelease"
mkproc() { # a fake /proc that reads every live process as the real one does
  local d; for d in /proc/[0-9]*; do ln -sfn "$d" "$lproc/${d##*/}"; done
}
cat >"$lbin/.term" <<'EOF'
#!/usr/bin/env bash
# A stub terminal emulator: logs its name and arguments, then by TERM_MODE
#   attach (default): stays up as the tab, running the tmux command (from the
#     first "tmux" argument) on a pty
#   fail: exits 1 at once
#   handoff: exits 0 at once; a detached child carries the tab, as a terminal server does
printf '%s %s\n' "${0##*/}" "$*" >>"$TERM_LOG"
[[ ${TERM_MODE:-attach} == fail ]] && exit 1
args=("$@")
for i in "${!args[@]}"; do [[ ${args[i]} == tmux ]] && { cmd=("${args[@]:i}"); break; }; done
tab() { TERM=xterm-256color exec script -qfc "$(printf '%q ' "${cmd[@]}")" /dev/null; }
if [[ ${TERM_MODE:-attach} == handoff ]]; then
  ( tab ) >/dev/null 2>&1 </dev/null &
  echo $! >>"$WT_PIDS"
  exit 0
fi
echo $$ >>"$WT_PIDS"
tab
EOF
chmod +x "$lbin/.term"
mkterm() { for n in "$@"; do cp "$lbin/.term" "$lbin/$n"; done; }
rmterm() { for n in "$@"; do rm -f -- "${lbin:?}/$n"; done; }
cat >"$lbin/.xdg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$XDG_LOG"
exit "${XDG_RC:-0}"
EOF
cat >"$lbin/.xdotool" <<'EOF'
#!/usr/bin/env bash
# search [--onlyvisible] --pid PID answers for XDO_PID alone: all windows are
# the unmanaged leader 4241 and the terminal's own 4242; visible only, 4242,
# unless XDO_HIDDEN (a minimized window is unmapped). windowactivate is logged.
printf '%s\n' "$*" >>"$XDO_LOG"
if [[ $1 == search && $2 == --onlyvisible ]]; then
  [[ $4 == "$XDO_PID" && -z ${XDO_HIDDEN:-} ]] && echo 4242
elif [[ $1 == search ]]; then
  [[ $3 == "$XDO_PID" ]] && printf '4241\n4242\n'
fi
exit 0
EOF
cat >"$lbin/.xprop" <<'EOF'
#!/usr/bin/env bash
# xprop -id WID WM_STATE: 4242 is in state XPROP_STATE (Normal by default,
# none for a window manager that sets no WM_STATE); any other window has none.
if [[ $2 == 4242 && ${XPROP_STATE:-Normal} != none ]]; then
  printf 'WM_STATE(WM_STATE):\n\t\twindow state: %s\n\t\ticon window: 0x0\n' "${XPROP_STATE:-Normal}"
else
  printf 'WM_STATE:  not found.\n'
fi
EOF
chmod +x "$lbin/.xdg" "$lbin/.xdotool" "$lbin/.xprop"
export TERM_LOG="$work/term.log" XDG_LOG="$work/xdg.log" XDO_LOG="$work/xdo.log"
lx() { env -u WSL_DISTRO_NAME KLEPSYDRA_PROC="$lproc" PATH="$lbin:$lbase" "$@"; }
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"

out=$(lx bash "$launch" new "$work/repos" 2>&1); rc=$?
check "linux: no terminal found: exit 1" "$rc" "1"
check "linux: no terminal found: says so" "$out" "No terminal emulator found (e.g. xfce4-terminal, gnome-terminal, x-terminal-emulator, xterm)."
check "linux: no terminal found: nothing was created" "$(t list-sessions 2>/dev/null | wc -l)" "0"
out=$(lx env KLEPSYDRA_TERMINAL=no-such-term bash "$launch" new "$work/repos" 2>&1); rc=$?
check "linux: KLEPSYDRA_TERMINAL that is missing fails, never another terminal" "$rc $(t list-sessions 2>/dev/null | wc -l)" "1 0"
check "linux: KLEPSYDRA_TERMINAL that is missing is named" "$out" "KLEPSYDRA_TERMINAL is no-such-term, which is not a command that can be run."

# The order: xfce4-terminal, gnome-terminal, konsole, kitty, alacritty, x-terminal-emulator, xterm.
order=(xfce4-terminal gnome-terminal konsole kitty alacritty x-terminal-emulator xterm)
for n in "${order[@]}"; do mkterm "$n"; done
got=()
for n in "${order[@]}"; do
  stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
  lx bash "$launch" new "$work/repos" >/dev/null 2>&1
  got+=("$(head -1 "$TERM_LOG" | cut -d' ' -f1)")
  rmterm "$n"
done
check "linux: the first emulator on PATH in the documented order is the one started" "${got[*]}" "${order[*]}"
mkterm xterm gnome-terminal
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
lx env KLEPSYDRA_TERMINAL=xterm bash "$launch" new "$work/repos" >/dev/null 2>&1
check "linux: KLEPSYDRA_TERMINAL picks its own" "$(head -1 "$TERM_LOG" | cut -d' ' -f1)" "xterm"

# What each emulator is asked to run: a titled tab attached by the socket's path.
sp=$(t display -p '#{socket_path}')
want_tail="tmux -S $sp attach -t =fleet"
check "linux: xterm gets title, -e and the attach" "$(head -1 "$TERM_LOG")" "xterm -T klepsydra sessions -e $want_tail"
check "linux: an attached tab: windows 1, pending stamp gone" "$(windows) $([[ -e $pending ]] && echo left)" "1 "
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
mkfifo "$pending"
lx env KLEPSYDRA_TERMINAL=xterm bash "$launch" new "$work/repos" >/dev/null 2>&1; rc=$?
check "linux: a FIFO at the shared pending stamp is removed, not ignored" "$rc|$([[ -p $pending ]] && echo fifo)" "0|"
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
lx bash "$launch" new "$work/repos" >/dev/null 2>&1
check "linux: gnome-terminal gets a titled tab" "$(head -1 "$TERM_LOG")" "gnome-terminal --tab --title=klepsydra sessions -- $want_tail"
mkterm xfce4-terminal konsole kitty alacritty
for n in xfce4-terminal:"--disable-server -T klepsydra sessions -x" konsole:"--new-tab -p tabtitle=klepsydra sessions -e" kitty:"-T klepsydra sessions" alacritty:"-T klepsydra sessions -e"; do
  stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
  lx env KLEPSYDRA_TERMINAL="${n%%:*}" bash "$launch" new "$work/repos" >/dev/null 2>&1
  check "linux: ${n%%:*} command line" "$(head -1 "$TERM_LOG")" "${n%%:*} ${n#*:} $want_tail"
done

# A launch that fails: the terminal exits non-zero, nothing is left behind.
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
out=$(lx env TERM_MODE=fail KLEPSYDRA_TERMINAL=xterm bash "$launch" new "$work/repos" 2>&1); rc=$?
check "linux: a terminal that fails: exit 1" "$rc" "1"
check "linux: a terminal that fails: says so" "$out" "xterm did not open a tab."
check "linux: a terminal that fails: the session made for it is undone" "$(t list-sessions 2>/dev/null | wc -l)" "0"
check "linux: a terminal that fails: no pending stamp" "$([[ -e $pending ]] && echo left)" ""
# With a session already there, a failed launch leaves it and its windows.
lx bash "$launch" new "$work/repos" >/dev/null 2>&1; detach_all; rm -f "$pending"
out=$(lx env TERM_MODE=fail KLEPSYDRA_TERMINAL=xterm bash "$launch" new "$work/repos" 2>&1); rc=$?
check "linux: a failed terminal over a live session: exit 1, windows unchanged" "$rc $(windows)" "1 1"
# gnome-terminal's server model: the command returns 0 and the tab arrives from elsewhere.
stop_server; detach_all; : >"$TERM_LOG"; rm -f "$pending"
out=$(lx env TERM_MODE=handoff KLEPSYDRA_TERMINAL=xterm bash "$launch" new "$work/repos" 2>&1); rc=$?
check "linux: a terminal that hands off and exits 0 is not a failure, its tab attaches" "$rc $(windows) $([[ -n $(t list-clients -t =fleet 2>/dev/null) ]] && echo attached)" "0 1 attached"

# Jump: raise the terminal window that owns the tmux client, found by walking
# up from the client's pid; the fleet's own tab and a hand-started tmux alike.
echo "native Linux: jump raises the session's own window"
cp "$lbin/.xdotool" "$lbin/xdotool"
mkproc
detach_all
attach
cpid=$(t list-clients -t =fleet -F '#{client_pid}' | head -1)
cparent=$(stat_fields "$cpid" 1)
lpane=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1); lpid=$(pane_pid "$lpane"); lstart=$(pstart "$lpid")
mkproc; : >"$XDO_LOG"
out=$(lx env XDO_PID="$cparent" bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
check "linux jump: exit 0, says so" "$rc $out" "0 Selected the session's tmux window."
check "linux jump: asks about the client, then its parent, and activates the parent's window" \
  "$(tr '\n' '|' <"$XDO_LOG")" "search --onlyvisible --pid $cpid|search --onlyvisible --pid $cparent|windowactivate 4242|"
: >"$XDO_LOG"
out=$(lx env XDO_PID=1999999 bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
check "linux jump: no window found: still selects the window, activates nothing" "$rc $(grep -c windowactivate "$XDO_LOG")" "0 0"
# With xprop: the managed window (WM_STATE), minimized too, never the leader.
cp "$lbin/.xprop" "$lbin/xprop"
for state in Normal Iconic; do
  : >"$XDO_LOG"
  hidden=""; [[ $state == Iconic ]] && hidden=1
  out=$(lx env XDO_PID="$cparent" XDO_HIDDEN="$hidden" XPROP_STATE="$state" bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
  check "linux jump: a $state terminal is raised by its managed window, not the leader" \
    "$rc $(grep windowactivate "$XDO_LOG" | tr '\n' '|')" "0 windowactivate 4242|"
done
: >"$XDO_LOG"
# A withdrawn window is unmapped, so the visible-only search misses it too.
out=$(lx env XDO_PID="$cparent" XDO_HIDDEN=1 XPROP_STATE=Withdrawn bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
check "linux jump: a withdrawn window is not raised" "$rc $(grep -c windowactivate "$XDO_LOG")" "0 0"
# A window manager that sets no WM_STATE: the visible window, as without xprop.
: >"$XDO_LOG"
out=$(lx env XDO_PID="$cparent" XPROP_STATE=none bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
check "linux jump: no window reports WM_STATE: the visible window is raised, never the leader" \
  "$rc $(grep windowactivate "$XDO_LOG" | tr '\n' '|')" "0 windowactivate 4242|"
rm -f "$lbin/xprop"
rm -f "$lbin/xdotool"
out=$(lx bash "$launch" jump "$sp" "$lpane" "$lpid" "$lstart" 2>&1); rc=$?
check "linux jump: no xdotool: still exit 0" "$rc $out" "0 Selected the session's tmux window."
# A hand-started tmux (another socket): its own client's window, never the fleet's title.
hand="kl-test2-$$"
tmux -L "$hand" new-session -d -s hand "sleep 600"
hsock=$(tmux -L "$hand" display -p '#{socket_path}')
TERM=xterm-256color script -qfc "tmux -L $hand attach -t =hand" /dev/null >/dev/null 2>&1 </dev/null &
clients+=($!)
for _ in $(seq 50); do [[ -n $(tmux -L "$hand" list-clients -t =hand 2>/dev/null) ]] && break; sleep 0.1; done
hcpid=$(tmux -L "$hand" list-clients -t =hand -F '#{client_pid}' | head -1)
hpane=$(tmux -L "$hand" display -p '#{pane_id}'); hpid=$(tmux -L "$hand" display -p '#{pane_pid}'); hstart=$(pstart "$hpid")
cp "$lbin/.xdotool" "$lbin/xdotool"; mkproc; : >"$XDO_LOG"
out=$(lx env XDO_PID="$hcpid" bash "$launch" jump "$hsock" "$hpane" "$hpid" "$hstart" 2>&1); rc=$?
check "linux jump: a hand-started tmux raises its own client's window, not the fleet's title" \
  "$rc $(tr '\n' '|' <"$XDO_LOG")" "0 search --onlyvisible --pid $hcpid|windowactivate 4242|"
check "linux jump: the fleet's title is never searched" "$(grep -c -- '--name' "$XDO_LOG")" "0"
tmux -L "$hand" kill-server 2>/dev/null
rm -f -- "$sockdir/${hand:?}" "$lbin/xdotool"

# The folder and github verbs: xdg-open, which must exist and must not fail at once.
echo "native Linux: folder and github verbs"
cp "$lbin/.xdg" "$lbin/xdg-open"; : >"$XDG_LOG"
out=$(lx bash "$launch" folder "$work/repos" 2>&1); rc=$?
check "linux folder: opens the folder with xdg-open" "$rc [$out] $(cat "$XDG_LOG")" "0 [] $work/repos"
: >"$XDG_LOG"
# shellcheck disable=SC2088 # the literal ~/ the overlay sends
out=$(lx bash "$launch" folder '~/' 2>&1); rc=$?
check "linux folder: ~/ is the home folder" "$rc $(cat "$XDG_LOG")" "0 $HOME/"
out=$(lx bash "$launch" folder "$work/gone" 2>&1); rc=$?
check "linux folder: a folder that is gone is said" "$rc $out" "1 The folder $work/gone does not exist."
: >"$XDG_LOG"
out=$(lx bash "$launch" github "https://github.com/ajbarea/klepsydra/pull/458" 2>&1); rc=$?
check "linux github: opens the page with xdg-open" "$rc [$out] $(cat "$XDG_LOG")" "0 [] https://github.com/ajbarea/klepsydra/pull/458"
out=$(lx bash "$launch" github "https://evil.example/x" 2>&1); rc=$?
check "linux github: only github.com" "$rc $out" "1 That is not a GitHub URL."
out=$(lx env XDG_RC=3 bash "$launch" folder "$work/repos" 2>&1); rc=$?
check "linux folder: xdg-open that fails is a failure, not a success" "$rc $out" "1 xdg-open could not open it."
out=$(lx env XDG_RC=3 bash "$launch" github "https://github.com/a/b" 2>&1); rc=$?
check "linux github: xdg-open that fails is a failure" "$rc $out" "1 xdg-open could not open it."
rm -f "$lbin/xdg-open"
out=$(lx bash "$launch" folder "$work/repos" 2>&1); rc=$?
check "linux folder: no xdg-open is said, not reported as success" "$rc $out" "1 xdg-open was not found, so nothing could be opened."
out=$(lx bash "$launch" github "https://github.com/a/b" 2>&1); rc=$?
check "linux github: no xdg-open is said" "$rc $out" "1 xdg-open was not found, so nothing could be opened."
# On WSL (WSL_DISTRO_NAME, or "microsoft" in the kernel release) the same verbs go to explorer.exe, unchanged.
# shellcheck disable=SC2016 # the stub's own $* and $XDG_LOG
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$XDG_LOG"\nexit 1\n' >"$lbin/explorer.exe"; chmod +x "$lbin/explorer.exe"
: >"$XDG_LOG"
out=$(WSL_DISTRO_NAME=Test KLEPSYDRA_PROC="$lproc" PATH="$lbin:$lbase" bash "$launch" folder "$work/repos" 2>&1); rc=$?
check "wsl folder: explorer.exe, its exit 1 is success" "$rc [$out] $(cat "$XDG_LOG")" "0 [] $work/repos"
printf '5.15.153.1-microsoft-standard-WSL2\n' >"$lproc/sys/kernel/osrelease"
: >"$XDG_LOG"
out=$(lx bash "$launch" github "https://github.com/a/b" 2>&1); rc=$?
check "wsl by kernel release alone (no WSL_DISTRO_NAME): explorer.exe" "$rc [$out] $(cat "$XDG_LOG")" "0 [] https://github.com/a/b"
stop_server; detach_all; rm -f "$pending" # no live tab: a new session needs one
out=$(lx bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wsl by kernel release alone: takes the Windows Terminal path, which needs WSL_DISTRO_NAME" "$rc $out" "1 WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
rm -f "$lbin/explorer.exe"
stop_server; detach_all; rm -f "$pending"

echo "a server started from a systemd unit gets its own scope (#292 review)"
# A oneshot unit's end kills what it leaves in its cgroup: the tmux watchdog's
# recover starts the fleet's server from one, so the launcher wraps it.
cat >"$work/bin/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/systemd-run.calls"
while [[ \$# -gt 0 && \$1 != -- ]]; do shift; done
shift
exec "\$@"
EOF
chmod +x "$work/bin/systemd-run"
ss="kl-scope-$$"
out=$(INVOCATION_ID=abc KLEPSYDRA_SYSTEMD_RUN="$work/bin/systemd-run" KLEPSYDRA_TMUX_SOCKET="$ss" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#292 review: from a unit, the new server starts inside systemd-run --user --scope" \
  "$rc $(grep -c -- '--user --scope --quiet --collect --unit=klepsydra-tmux-[0-9]* -- tmux -L '"$ss" "$work/systemd-run.calls") $(tmux -L "$ss" list-sessions -F '#{session_name}' 2>/dev/null)" "0 1 fleet"
tmux -L "$ss" kill-server 2>/dev/null; : >"$work/systemd-run.calls"
out=$(env -u INVOCATION_ID KLEPSYDRA_SYSTEMD_RUN="$work/bin/systemd-run" KLEPSYDRA_TMUX_SOCKET="$ss" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#292 review: from a terminal, as before: no scope" "$rc $(wc -l <"$work/systemd-run.calls")" "0 0"
tmux -L "$ss" kill-server 2>/dev/null
# A CI runner is a systemd service with no user manager: systemd-run fails.
printf '#!/usr/bin/env bash\necho "Failed to connect to bus" >&2\nexit 1\n' >"$work/bin/systemd-run-nobus"; chmod +x "$work/bin/systemd-run-nobus"
out=$(INVOCATION_ID=abc KLEPSYDRA_SYSTEMD_RUN="$work/bin/systemd-run-nobus" KLEPSYDRA_TMUX_SOCKET="$ss" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#292 review: with no user manager to make a scope, the server starts as from a terminal" \
  "$rc $(tmux -L "$ss" list-sessions -F '#{session_name}' 2>/dev/null)" "0 fleet"
tmux -L "$ss" kill-server 2>/dev/null

echo "the pane-died hook (#290)"
# The 11-03 crash: tmux 3.4 sent focus-out to a pane whose process had ended
# (kept by remain-on-exit failed) and died. The hook starts such a pane again.
# The client runs in an outer server's pane, so send-keys there types focus
# reports into it the way a terminal does.
mkdir -p "$HOME/.claude"; cp "$here/klepsydra-pane-died.sh" "$HOME/.claude/"
in4="kl-test4-$$" out4="kl-test5-$$"
ti() { tmux -L "$in4" "$@"; }
to() { tmux -L "$out4" "$@"; }
KLEPSYDRA_DEAD_DIR="$work/dead" FLEET_BIN="$work/nobin" ti -f "$KLEPSYDRA_TMUX_CONF" new-session -d -s s -x 80 -y 24 \
  "printf 'last words\n\033[?1004h'; until [ -e $work/die4 ]; do sleep 0.1; done; kill -TERM \$\$"
spid=$(ti display -p '#{pid}')
v0=$(ti display -p -t s '#{pane_id}') # the first viewer's pane, whatever window is current later
to -f /dev/null new-session -d -s o -x 80 -y 24 "TERM=xterm-256color tmux -L $in4 attach -t s"
sleep 1
to send-keys -t o -l $'\033[I'; sleep 0.5
touch "$work/die4"
for _ in $(seq 50); do [[ -n $(ti show -pqv -t s @klepsydra_dead 2>/dev/null) ]] && break; sleep 0.1; done
check "#290: a pane whose process was killed is started again at once, marked with why" \
  "$(ti display -p -t s '#{pane_dead}') $(ti show -pqv -t s @klepsydra_dead | cut -d' ' -f2-)" "0 its process ended on signal 15"
check "#292 review 3: the mark names the viewer's own pid" "$(ti show -pqv -t s @klepsydra_dead | cut -d' ' -f1)" "$(ti display -p -t s '#{pane_pid}')"
check "#290: its last screen is saved" "$(cat "$work"/dead/*.txt 2>/dev/null | grep -c '^last words$')" "1"
to send-keys -t o -l $'\033[O'; sleep 0.5
to send-keys -t o -l $'\033[I'; sleep 0.5
check "#290: focus moving off it and back leaves the server running (tmux 3.4 died here)" "$(kill -0 "$spid" 2>/dev/null && echo alive || echo died)" "alive"
shown=$(ti capture-pane -p -J -S - -t s)
check "#290: the pane shows its saved screen and how to close it" \
  "$(grep -q '^last words *$' <<<"$shown" && echo screen) $(grep -q 'process ended on signal 15\. .*Press Enter to close\.' <<<"$shown" && echo note)" "screen note"
# A viewer killed instead of closed with Enter is closed, never started again.
w2=$(ti new-window -d -P -F '#{pane_id}' -t s: "sh -c 'sleep 0.3; exit 3'")
for _ in $(seq 50); do [[ -n $(ti show -pqv -t "$w2" @klepsydra_dead 2>/dev/null) ]] && break; sleep 0.1; done
check "#290: a non-zero exit is marked with its status" "$(ti show -pqv -t "$w2" @klepsydra_dead | cut -d' ' -f2-)" "its process exited with status 3"
kill -TERM "$(ti display -p -t "$w2" '#{pane_pid}')"; sleep 1
# (display -t names a gone pane with empty fields and exit 0 in tmux 3.4, so the list decides.)
check "#290: its viewer killed: the pane is closed" "$(ti list-panes -a -F '#{pane_id}' | grep -cx -- "$w2")" "0"
# #292 review 3 (m2): a viewer's pane started again by hand keeps the old mark;
# the program there dying is a new death, saved and shown, never closed unsaved.
w3=$(ti new-window -d -P -F '#{pane_id}' -t s: "sh -c 'sleep 0.3; exit 3'")
for _ in $(seq 50); do [[ -n $(ti show -pqv -t "$w3" @klepsydra_dead 2>/dev/null) ]] && break; sleep 0.1; done
ti respawn-pane -k -t "$w3" "sh -c 'echo second words; sleep 0.3; exit 4'"
for _ in $(seq 50); do [[ $(ti show -pqv -t "$w3" @klepsydra_dead 2>/dev/null) == *"status 4" ]] && break; sleep 0.1; done
check "#292 review 3: a program started by hand in a viewer's pane dies: shown again, marked anew, its screen saved" \
  "$(ti list-panes -a -F '#{pane_id}' | grep -cx -- "$w3") $(ti show -pqv -t "$w3" @klepsydra_dead | cut -d' ' -f2-) $(cat "$work"/dead/*.txt 2>/dev/null | grep -c '^second words$')" \
  "1 its process exited with status 4 1"
ti kill-pane -t "$w3" 2>/dev/null
for _ in $(seq 50); do
  ti list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$v0" || break
  ti send-keys -t "$v0" Enter 2>/dev/null
  sleep 0.1
done
check "#290: Enter closes a dead pane's viewer" "$(ti list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx -- "$v0") (left: $(ti list-panes -a -F '#{pane_id}:#{pane_start_command}' 2>/dev/null | tr '\n' ' '))" "0 (left: )"
ti kill-server 2>/dev/null; to kill-server 2>/dev/null
rm -f -- "$sockdir/${in4:?}" "$sockdir/${out4:?}"

# tmux 3.8 prints an empty #{pane_pid} for a dead pane (3.4 and 3.5a print the
# pid): a stub tmux answers as 3.8 does, so the hook's no-pid branch runs here.
fakebin="$work/pane-died-bin"; mkdir -p "$fakebin"
cat >"$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case $3 in
  display-message) printf '1\t-\t-\t15\t%s\n' "$STUB_CMD" ;;
  show) printf '%s\n' "$STUB_MARK" ;;
esac
exit 0
EOF
chmod +x "$fakebin/tmux"
nopid() { # start command, mark: the hook's tmux calls
  : >"$work/stub.log"
  STUB_LOG="$work/stub.log" STUB_CMD="$1" STUB_MARK="$2" PATH="$fakebin:$PATH" FLEET_BIN="$work/nobin" \
    KLEPSYDRA_DEAD_DIR="$work/dead38" bash "$here/klepsydra-pane-died.sh" /s %9 >/dev/null 2>&1
  grep -c 'kill-pane' "$work/stub.log"
}
check "3.8: a dead viewer (empty pane_pid) is closed by its command" "$(nopid "cat /x/saved.txt; read -r _" "4242 its process ended on signal 15")" "1"
check "3.8: a dead program that is not the viewer is not closed" "$(nopid "claude" "4242 its process ended on signal 15")" "0"

# #260: a session runs on the tmux server's config folder whenever the server is
# up, even with no fleet session (fleet delegate's engines session shares the
# socket); a server started on a keyed folder refuses a clean caller's launch.
mkdir -p "$work/keyed-cfg"
printf '{"apiKeyHelper": "x"}\n' >"$work/keyed-cfg/settings.json"
CLAUDE_CONFIG_DIR="$work/keyed-cfg" tmux -L "$sock5" new-session -d -s other "sleep 600"
out=$(env -u CLAUDE_CONFIG_DIR KLEPSYDRA_TMUX_SOCKET="$sock5" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "#260: a server on a keyed config folder: refused" "$rc $(grep -c "^Not started: $work/keyed-cfg/settings.json" <<<"$out")" "1 1"
check "#260: and no fleet session was made" "$(tmux -L "$sock5" has-session -t =fleet 2>/dev/null && echo made || echo none)" "none"
tmux -L "$sock5" kill-server 2>/dev/null

check "#292 review 2: no case reached the host's systemd-run" "$(cat "$work/systemd-run-guard.calls" 2>/dev/null)" ""
# shellcheck disable=SC2016 # literal pattern checked against the source
check "#518 r4: pending stamp path defined once from \$ld" \
  "$(grep -E 'klepsydra-tab[-]pending|[/][^[:space:]]*tab[-]pending' "$here/test_launch.sh")" \
  'pending="$ld/klepsydra-tab''-pending-$UID"'

echo "cleanup"
cleanup; trap - EXIT
check "no socket files left" "$(find "$sockdir" -maxdepth 1 \( -name "$sock" -o -name "$sock2" -o -name "$sock3" -o -name "$sock4" -o -name "$sock5" \) 2>/dev/null)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
