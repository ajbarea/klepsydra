#!/usr/bin/env bash
# Fixture-driven tests for the fleet hook. Run: bash hooks/test_fleet.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/klepsydra-fleet.sh"
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

# shellcheck source=hooks/klepsydra-fleet.sh
source "$hook"

echo "where"

# Repos laid out by git itself: a main checkout with a linked worktree, a
# superproject with a submodule, and a folder outside any repo.
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main \
  -c protocol.file.allow=always "$@"; }
repos="$work/repos"
mkdir -p "$repos/loose/notes"
for r in klepsydra ideas subsrc; do
  g init -q "$repos/$r" && g -C "$repos/$r" commit -q --allow-empty -m init
done
g -C "$repos/klepsydra" worktree add -q -b feat/fleet-visualizer "$repos/klepsydra/.claude/worktrees/fleet"
mkdir -p "$repos/klepsydra/src/deep" "$repos/klepsydra/.claude/worktrees/fleet/src"
g -C "$repos/ideas" submodule add -q "$repos/subsrc" vendor/subsrc >/dev/null 2>&1
g -C "$repos/subsrc" checkout -q --detach

where() { git_where "$1"; printf '%s|%s|%s' "$where_repo" "$where_worktree" "$where_branch"; }
# The branch as git reports it, or a detached commit's first 7 characters.
git_branch() { git -C "$1" symbolic-ref --short -q HEAD || git -C "$1" rev-parse --short=7 HEAD; }

check "plain repo" "$(where "$repos/klepsydra")" "klepsydra||main"
check "repo subdir" "$(where "$repos/klepsydra/src/deep")" "klepsydra||main"
check "linked worktree" "$(where "$repos/klepsydra/.claude/worktrees/fleet")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "worktree subdir" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "file not written yet" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src/new.rs")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "submodule" "$(where "$repos/ideas/vendor/subsrc")" \
  "subsrc||$(git_branch "$repos/ideas/vendor/subsrc")"
check "detached HEAD" "$(where "$repos/subsrc")" "subsrc||$(git_branch "$repos/subsrc")"
check "outside any repo" "$(where "$repos/loose/notes")" "notes||"
check "filesystem root" "$(where /)" "||"

# keryx names the same repos; when its source is here, ask it directly.
keryx_src=${KERYX_SRC:-$HOME/ajsoftworks/keryx/src}
if [[ -f "$keryx_src/keryx/hook.py" ]]; then
  for p in klepsydra klepsydra/src/deep klepsydra/.claude/worktrees/fleet ideas/vendor/subsrc subsrc loose/notes; do
    got=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from keryx.hook import source_name; print(source_name(sys.argv[2]))' \
      "$keryx_src" "$repos/$p")
    git_where "$repos/$p"
    check "keryx agrees: $p" "$where_repo" "$got"
  done
else
  echo "  skip keryx parity: no keryx source at $keryx_src"
fi

echo "identity"

# A /proc tree: pid, parent, name, start time, state, then argv.
mkproc() {
  local d="$work/proc/$1"
  mkdir -p "$d"
  printf '%s (%s) %s %s 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100\n' \
    "$1" "$3" "${5:-S}" "$2" "$4" >"$d/stat"
  printf '%s\n' "$3" >"$d/comm"
  if (( $# > 5 )); then printf '%s\0' "${@:6}" >"$d/cmdline"; else : >"$d/cmdline"; fi
}
mkproc 1 0 systemd 1
mkproc 500 1 claude 8717628 S claude
mkproc 550 500 'sh) (x' 8717700 S /bin/sh -c "$hook"
mkproc 600 550 klepsydra-fleet 8717701 S bash "$hook"
mkproc 700 1 node 9000000 S node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
mkproc 710 700 bash 9000001 S bash "$hook"
mkproc 800 1 bash 9100000 S bash
mkproc 810 800 bash 9100001 S bash "$hook"
PROC_ROOT="$work/proc"

ancestor() { claude_ancestor "$1"; printf '%s:%s' "$found_pid" "$found_start"; }
check "nearest claude above the hook" "$(ancestor 600)" "500:8717628"
check "an npm install found by its argv" "$(ancestor 710)" "700:9000000"
check "no claude above" "$(ancestor 810)" ":"
check "a missing pid" "$(ancestor 999)" ":"

printf '{"homes":{"klepsydra":{"voice":"am_michael","seen":1}},"holders":{"500:8717628":{"voice":"am_michael","seen":1},"700:9000000":{"voice":"af_heart(0.5)+af_bella(0.5)","seen":1}}}\n' >"$work/voices.json"
VOICES="$work/voices.json"
check "the holder's voice" "$(holder_voice 500 8717628)" "am_michael"
check "a blend is a voice too" "$(holder_voice 700 9000000)" "af_heart(0.5)+af_bella(0.5)"
check "no hold, no voice" "$(holder_voice 500 1)" ""
VOICES="$work/missing.json"
check "no keryx, no voice" "$(holder_voice 500 8717628)" ""

# With HOME unset the default voices.json path has no home: no voice, no output, no abort.
# shellcheck disable=SC2016 # the script is for the child shell to expand
out=$(env -u HOME -u XDG_CACHE_HOME -u KERYX_VOICES KLEPSYDRA_PROC="$work/proc" \
  bash -uc 'source "$1"; v=$(holder_voice 500 8717628); claude_ancestor 600; printf "[%s][%s:%s]" "$v" "$found_pid" "$found_start"' _ "$hook" 2>&1); rc=$?
check "unset HOME: identity exit 0" "$rc" "0"
check "unset HOME: empty voice, no output" "$out" "[][500:8717628]"

block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block present" "$([[ -n "$(block "$hook")" ]] && echo yes)" "yes"
check "sourceable from a set -e script" \
  "$(KLEPSYDRA_DIR=/x/dev.ajsoftworks.klepsydra bash -ec 'source "$1"; echo "$KLEPSYDRA_DIR"' _ "$hook")" \
  "/x/dev.ajsoftworks.klepsydra"
check "dir block identical in the statusline" "$(block "$hook")" "$(block "$here/../statusline/klepsydra-statusline.sh")"

# A hook must stay silent and exit 0 even when its environment is bare.
out=$(env -u USER -u HOME bash "$hook" </dev/null 2>&1); rc=$?
check "unset USER and HOME: exit 0" "$rc" "0"
check "unset USER and HOME: no output" "$out" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
