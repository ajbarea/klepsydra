#!/usr/bin/env bash
# sync-briefing.sh: commit and push the private fleet-briefing repo (AJ's queue,
# morning file, shots and review drafts) when anything in it changed or a commit waits to be
# pushed. The staged content is scanned by gitleaks before it is committed, so
# what is scanned is what is committed; a finding unstages it and blocks the
# commit. A rejected push rebases once onto the remote and retries; nothing is
# ever forced. Holds .git/fleet-sync.lock, which prune_shots.py takes too. Run
# every 5 minutes by the fleet-sync-briefing timer.
set -u
FLEET_TARGET=fleet::sync-briefing
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
R=${BRIEFING_DIR:-/mnt/c/Users/ajbar/fleet-briefing}
GITLEAKS=${FLEET_GITLEAKS:-gitleaks}
export GIT_TERMINAL_PROMPT=0
cd "$R" 2>/dev/null || { flog ERROR "briefing sync: no repo" dir="$R"; exit 1; }
exec 9>"$(git rev-parse --git-dir)/fleet-sync.lock"
flock -w 60 9 || { flog WARN "briefing sync: another sync or prune holds the lock"; exit 0; }
gd=$(git rev-parse --git-dir)
if [[ -d $gd/rebase-merge || -d $gd/rebase-apply || -f $gd/MERGE_HEAD || -n $(git ls-files -u) ]]; then
  flog ERROR "briefing sync: a rebase or merge is unfinished; left for a person" dir="$R"
  exit 1
fi

# Only paths that exist or are tracked: git add stops at the first pathspec that matches nothing.
paths=()
for f in claude-morning.md claude-queue.md README.md shots review; do
  if [[ -e $f ]] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then paths+=("$f"); fi
done
if [[ -n $(git status --porcelain -- "${paths[@]}") ]]; then
  # A file over 50 MB would fail every push (GitHub's limit is 100 MB): left out, and logged.
  skip=()
  while IFS= read -r big; do
    [[ -n $big ]] || continue
    skip+=(":(exclude)$big")
    flog WARN "briefing sync: a file over 50 MB left out" file="$big"
  done < <(find "${paths[@]}" -type f -size +50M 2>/dev/null)
  git add -A -- "${paths[@]}" "${skip[@]}"
  if ! git diff --cached --quiet; then
    if ! out=$("$GITLEAKS" git --staged --no-banner --redact --exit-code 1 --log-level error . 2>&1) || [[ -n $out ]]; then
      git reset -q -- "${paths[@]}"
      flog ERROR "briefing sync: gitleaks found something or gave no verdict; unstaged, not committed" dir="$R" said="$(tail -3 <<<"$out")"
      exit 1
    fi
    git commit -q -m "Update $(date '+%F %H:%M')" >/dev/null || { flog ERROR "briefing sync: commit failed"; exit 1; }
  fi
fi

ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)
(( ahead > 0 )) || exit 0
# Every commit about to leave is scanned, the prune's and any made by hand included.
range='@{u}..HEAD'
git rev-parse -q --verify '@{u}' >/dev/null || range='HEAD --not --remotes'
if ! out=$("$GITLEAKS" git --log-opts="$range --" --no-banner --redact --exit-code 1 --log-level error . 2>&1) || [[ -n $out ]]; then
  flog ERROR "briefing sync: gitleaks found something in a commit to push, or gave no verdict; not pushed" dir="$R" said="$(tail -3 <<<"$out")"
  exit 1
fi
if out=$(git push -q origin HEAD 2>&1); then
  flog INFO "briefing synced" commit="$(git rev-parse --short HEAD)" pushed="$ahead"
  exit 0
fi
# Rejected (the remote moved, e.g. AJ ticked a box on the phone): rebase once and retry,
# only on a clean tree (an autostash that conflicts reports success and leaves markers).
if ! git diff --quiet || ! git diff --cached --quiet; then
  flog WARN "briefing sync: push rejected and the tree has edits; rebasing next pass" said="$(tail -3 <<<"$out")"
  exit 1
fi
if git pull -q --rebase origin "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 && [[ -z $(git ls-files -u) ]] && out=$(git push -q origin HEAD 2>&1); then
  flog INFO "briefing synced after a rebase" commit="$(git rev-parse --short HEAD)"
  exit 0
fi
git rebase --abort >/dev/null 2>&1
flog ERROR "briefing sync: push failed; still behind or diverged" said="$(tail -3 <<<"$out")" ahead="$ahead"
exit 1
