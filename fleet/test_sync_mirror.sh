#!/usr/bin/env bash
# Tests for sync-briefing.sh's Drive mirror refusals (#380, #531): each row is a
# state in which rclone sync must not run, with the fetch counted. No tmux, no
# network: a local bare origin, stub rclone and gitleaks, a git wrapper.
# Run: bash fleet/test_sync_mirror.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'rm -rf -- "${W:?}"' EXIT
export FLEET_STATE="$W/state" FLEET_LOG="$W/fleet.log" KLEPSYDRA_DIR="$W/k" FLEET_BRIEFING="$W/none"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_TERMINAL_PROMPT=0
unset FLEET_BRIEFING_DRIVE FLEET_FETCH_TIMEOUT
mkdir -p "$W/bin" "$FLEET_STATE" "$KLEPSYDRA_DIR"; : >"$W/fetches"; : >"$W/rclone.log"
pass=0 fail=0
check() { # WHAT GOT WANT
  if [[ $2 == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi
}

printf '#!/bin/sh\nexit 0\n' >"$W/bin/gitleaks"
cat >"$W/bin/rclone" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/rclone.log"
[[ \$1 == listremotes ]] && echo gdrive:
exit 0
EOF
# git, with each fetch counted; MIRROR_FETCH=fail or hang makes a fetch fail or stall.
real_git=$(command -v git)
cat >"$W/bin/git" <<EOF
#!/usr/bin/env bash
if [[ \$1 == fetch ]]; then
  echo fetch >>"$W/fetches"
  [[ \${MIRROR_FETCH:-} == fail ]] && { echo "fatal: could not read from remote repository" >&2; exit 128; }
  [[ \${MIRROR_FETCH:-} == hang ]] && sleep 30
fi
exec "$real_git" "\$@"
EOF
chmod +x "$W/bin/gitleaks" "$W/bin/rclone" "$W/bin/git"

git init -q --bare "$W/origin.git"
git clone -q "$W/origin.git" "$W/a" 2>/dev/null
printf 'q\n' >"$W/a/queue.md"; git -C "$W/a" add queue.md; git -C "$W/a" commit -qm init; git -C "$W/a" push -q origin HEAD 2>/dev/null
git clone -q "$W/origin.git" "$W/b" 2>/dev/null

# One sync of CLONE with the marker cleared, so the mirror is always tried;
# prints "rc uploads fetches" for this pass.
sync() { # CLONE [VAR=VALUE...]
  local clone=$1 u0 f0 rc
  shift
  rm -f -- "$clone/.git/fleet-drive-mirror.head"
  u0=$(grep -c '^sync' "$W/rclone.log" 2>/dev/null); f0=$(wc -l <"$W/fetches" 2>/dev/null || echo 0)
  env PATH="$W/bin:$PATH" BRIEFING_DIR="$clone" FLEET_BRIEFING_DRIVE=gdrive:fleet-briefing \
    FLEET_GITLEAKS="$W/bin/gitleaks" FLEET_RCLONE="$W/bin/rclone" "$@" bash "$here/sync-briefing.sh" 2>/dev/null
  rc=$?
  echo "$rc $(( $(grep -c '^sync' "$W/rclone.log" 2>/dev/null) - ${u0:-0} )) $(( $(wc -l <"$W/fetches" 2>/dev/null || echo 0) - f0 ))"
}
last() { jq -r --arg m "$1" 'select(.message | contains($m)) | .level + (if .rc then " rc=" + .rc else "" end)' "$FLEET_LOG" | tail -1; }

check "in step with origin: one fetch, one upload" "$(sync "$W/b")" "0 1 1"
check "no rclone: no fetch, no upload" "$(sync "$W/b" FLEET_RCLONE="$W/no-rclone") $(last "rclone not installed")" "0 0 0 WARN"
check "an rclone remote that does not exist: no fetch, no upload" "$(sync "$W/b" FLEET_BRIEFING_DRIVE=nodrive:x) $(last "no such rclone remote")" "0 0 0 WARN"
check "a fetch that fails: no upload, its exit code logged" "$(sync "$W/b" MIRROR_FETCH=fail) $(last "the fetch failed")" "0 0 1 WARN rc=128"
start=$(date +%s)
got=$(sync "$W/b" MIRROR_FETCH=hang FLEET_FETCH_TIMEOUT=1)
took=$(( $(date +%s) - start ))
check "a fetch that hangs is stopped at its bound: no upload, rc 124, done in seconds" "$got $(last "the fetch failed") $(( took < 10 ))" "0 0 1 WARN rc=124 1"
printf 'newer\n' >"$W/a/README.md"; git -C "$W/a" add README.md; git -C "$W/a" commit -qm newer; git -C "$W/a" push -q origin HEAD 2>/dev/null
check "behind origin with nothing to push: no upload (it would roll Drive back)" "$(sync "$W/b") $(last "not at origin's commit")" "0 0 1 INFO"
git -C "$W/b" pull -q --ff-only 2>/dev/null
check "caught up: it mirrors" "$(sync "$W/b")" "0 1 1"
git clone -q "$W/origin.git" "$W/c" 2>/dev/null; git -C "$W/c" branch -q --unset-upstream
check "a branch with no upstream: no fetch, no upload" "$(sync "$W/c") $(last "tracks no upstream")" "0 0 0 WARN"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
