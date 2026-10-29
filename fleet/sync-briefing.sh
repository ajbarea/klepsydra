#!/usr/bin/env bash
# sync-briefing.sh: commit and push the private fleet-briefing repo (AJ's queue,
# morning file and shots) when anything in it changed, after a gitleaks scan of
# the working tree. A finding blocks the commit; nothing is ever forced. Run
# every 5 minutes by the fleet-sync-briefing timer.
set -u
FLEET_TARGET=fleet::sync-briefing
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
R=${BRIEFING_DIR:-/mnt/c/Users/ajbar/fleet-briefing}
GITLEAKS=${FLEET_GITLEAKS:-gitleaks}
cd "$R" 2>/dev/null || { flog ERROR "briefing sync: no repo" dir="$R"; exit 1; }
[[ -z $(git status --porcelain -- claude-morning.md claude-queue.md README.md shots) ]] && exit 0
if ! out=$("$GITLEAKS" dir . --no-banner --exit-code 1 2>&1); then
  flog ERROR "briefing sync: gitleaks found something; not committed" dir="$R" said="$(tail -3 <<<"$out")"
  exit 1
fi
# Only paths that exist or are tracked: git add stops at the first pathspec that matches nothing.
paths=()
for f in claude-morning.md claude-queue.md README.md shots; do
  if [[ -e $f ]] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then paths+=("$f"); fi
done
git add -A -- "${paths[@]}"
git diff --cached --quiet && exit 0
git -c core.autocrlf=false commit -q -m "Update $(date '+%F %H:%M')" >/dev/null || { flog ERROR "briefing sync: commit failed"; exit 1; }
if out=$(git push -q origin HEAD 2>&1); then
  flog INFO "briefing synced" commit="$(git rev-parse --short HEAD)"
else
  flog ERROR "briefing sync: push failed" said="$(tail -3 <<<"$out")"
  exit 1
fi
