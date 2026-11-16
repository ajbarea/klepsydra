#!/usr/bin/env bash
# sync-briefing.sh: commit and push the private fleet-briefing repo (AJ's to-do
# file, the fleet queue, the morning file, shots and review drafts) when anything in it changed or a commit waits to be
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
# Google Drive mirror (#380): AJ's phone swipes screenshots and plays video in Drive, which the
# GitHub app cannot. Off unless FLEET_BRIEFING_DRIVE names an rclone remote and a folder in it;
# only the timer's unit sets it, and the tests unset it. One way, local to
# Drive, from a copy of the commit at HEAD: only committed files, never an edit still in the
# working tree (git archive drops a path marked export-ignore, so keep none). The sync deletes
# what the folder holds beyond that copy, so a bare remote, its root, a . or .. step, any space,
# or a commit with no files is refused.
DRIVE=${FLEET_BRIEFING_DRIVE:-}
RCLONE=${FLEET_RCLONE:-rclone}
snap=""
# The copy goes however the run ends, a stop from systemd included.
trap 'if [[ -n $snap ]]; then rm -rf -- "$snap"; fi' EXIT
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
mirror() {
  [[ -n $DRIVE ]] || return 0
  if [[ ! $DRIVE =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*:[^/] || $DRIVE =~ [[:space:]] || $DRIVE =~ (^|[:/])\.\.?(/|$) ]]; then
    flog ERROR "briefing mirror: FLEET_BRIEFING_DRIVE must be remote:folder (no root, no . or .., no spaces); not mirrored" remote="$DRIVE"
    return 0
  fi
  local head last out rc n
  head=$(git rev-parse -q --verify HEAD) || return 0
  last=$(cat "$gd/fleet-drive-mirror.head" 2>/dev/null)
  [[ "$head $DRIVE" == "$last" ]] && return 0
  command -v "$RCLONE" >/dev/null 2>&1 || { flog WARN "briefing mirror: rclone not installed" remote="$DRIVE"; return 0; }
  "$RCLONE" listremotes 2>/dev/null | grep -qxF "${DRIVE%%:*}:" || { flog WARN "briefing mirror: no such rclone remote; run rclone config create" remote="$DRIVE"; return 0; }
  snap=$(mktemp -d) || { flog WARN "briefing mirror: no temp folder; retried next pass"; return 0; }
  if ! (set -o pipefail; git archive --format=tar "$head" | tar -x -C "$snap"); then
    flog WARN "briefing mirror: could not copy the commit; retried next pass" commit="${head:0:7}"
    rm -rf -- "$snap"; snap=""; return 0
  fi
  n=$(find "$snap" -type f | wc -l)
  if (( n == 0 )); then
    flog ERROR "briefing mirror: the commit has no files to mirror; refused, so the Drive folder is not emptied" commit="${head:0:7}"
    rm -rf -- "$snap"; snap=""; return 0
  fi
  # --checksum: the copy's files are new on disk each time, so compare content, not times.
  out=$(timeout 300 "$RCLONE" sync "$snap" "$DRIVE" --checksum --transfers 4 --max-duration 240s -q 2>&1); rc=$?
  rm -rf -- "$snap"; snap=""
  out=$(grep -v 'shared Google Drive client_id' <<<"$out")
  if (( rc == 0 )); then
    printf '%s\n' "$head $DRIVE" >"$gd/fleet-drive-mirror.head"
    flog INFO "briefing mirrored to Drive" remote="$DRIVE" commit="${head:0:7}" files="$n"
  else
    flog WARN "briefing mirror failed; retried next pass" remote="$DRIVE" rc="$rc" said="$(tail -2 <<<"$out")"
  fi
}
export GIT_TERMINAL_PROMPT=0
cd "$R" 2>/dev/null || { flog ERROR "briefing sync: no repo" dir="$R"; exit 1; }
exec 9>"$(git rev-parse --git-dir)/fleet-sync.lock"
flock -w 60 9 || { flog WARN "briefing sync: another sync or prune holds the lock"; exit 0; }
gd=$(git rev-parse --git-dir)
if [[ -d $gd/rebase-merge || -d $gd/rebase-apply || -f $gd/MERGE_HEAD || -n $(git ls-files -u) ]]; then
  flog ERROR "briefing sync: a rebase or merge is unfinished; left for a person" dir="$R"
  exit 1
fi

# Up to five items GitHub's search finds for QUERY, one line each.
done_list() { # query
  "$FLEET_GH" api -X GET search/issues -f q="$1" -f per_page=5 -f sort=updated \
    --jq '.items[] | "- [#\(.number)] \(.title | gsub("[\r\n]"; " ")) (\(.repository_url | sub("^.*/repos/"; "")))"' || {
    flog ERROR "briefing today: GitHub search failed" query="$1"
    return 1
  }
}

write_today() {
  local today since owner tmp live pane name state screen_text
  today=$(date +%F)
  # Local midnight, in the UTC form GitHub's search takes.
  since=$(date -u -d "@$(date -d "$today 00:00" +%s)" '+%Y-%m-%dT%H:%M:%SZ') ||
    { flog ERROR "briefing today: could not calculate today's start"; return 1; }
  owner=$("$FLEET_GH" api user --jq .login) && [[ $owner =~ ^[A-Za-z0-9-]{1,39}$ ]] ||
    { flog ERROR "briefing today: GitHub user lookup failed"; return 1; }

  tmp=$(mktemp "$R/today.md.XXXXXX") || {
    flog ERROR "briefing today: could not create temporary file"
    return 1
  }
  trap 'rm -f -- "${tmp:-}"' RETURN

  {
    printf '# Today: %s\n\n' "$today"
    # One search per list across every repo the owner has, not a call per repo.
    printf '## Done today\n\n### Merged PRs\n'
    done_list "user:$owner is:pr is:merged merged:>=$since" || return 1
    printf '\n### Closed issues\n'
    done_list "user:$owner is:issue is:closed closed:>=$since" || return 1

    printf '\n## Running now\n\n'
    live=$(fleet_panes 2>/dev/null || true)
    if [[ -z $live ]]; then
      printf '_None._\n'
    else
      while IFS= read -r pane; do
        [[ -n $pane ]] || continue
        name=$(reg_field "$pane" 2 2>/dev/null || true)
        if [[ -z $name && $pane == "$(orchestrator 2>/dev/null || true)" ]]; then
          name=orchestrator
        fi
        state=waiting
        screen_text=$(screen "$pane" 2>/dev/null || true)
        busy "$screen_text" && state=working
        [[ $state == waiting ]] && has_input_box "$screen_text" && state=idle
        printf -- '- **%s**: %s\n' "${name:-$pane}" "$state"
      done <<<"$live"
    fi

    printf '\n## Needs you\n\n'
    if ! awk '
      /^## Needs you$/ { in_section=1; next }
      /^## / { in_section=0 }
      in_section && /^- / { print; count++; if (count == 5) exit }
    ' needs-you.md 2>/dev/null | grep -q .; then
      printf '_None._\n'
    else
      awk '
        /^## Needs you$/ { in_section=1; next }
        /^## / { in_section=0 }
        in_section && /^- / { print; count++; if (count == 5) exit }
      ' needs-you.md
    fi
  } >"$tmp" || {
    flog ERROR "briefing today: digest generation failed"
    return 1
  }
  mv -f -- "$tmp" "$R/today.md" || {
    flog ERROR "briefing today: could not replace today.md"
    return 1
  }
  tmp=
}

# A digest GitHub cannot fill keeps the last one; needs-you.md still syncs.
if [[ -n ${FLEET_GH:-} ]]; then
  write_today || flog WARN "briefing today: kept the previous digest"
fi

# Only paths that exist or are tracked: git add stops at the first pathspec that matches nothing.
paths=()
# The old names stay until #276 so a rename commits both sides (#277).
for f in morning.md queue.md claude-morning.md claude-queue.md needs-you.md today.md README.md shots review; do
  if [[ -e $f ]] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then paths+=("$f"); fi
done
if [[ -n $(git status --porcelain -- "${paths[@]}") ]]; then
  # A file over 50 MB would fail every push (GitHub's limit is 100 MB): left out, and logged.
  skip=()
  while IFS= read -r big; do
    [[ -n $big ]] || continue
    skip+=(":(exclude,literal)$big")
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
(( ahead > 0 )) || { mirror; exit 0; }
# Every commit about to leave is scanned, the prune's and any made by hand included.
range='@{u}..HEAD'
git rev-parse -q --verify '@{u}' >/dev/null || range='HEAD --not --remotes'
if ! out=$("$GITLEAKS" git --log-opts="$range --" --no-banner --redact --exit-code 1 --log-level error . 2>&1) || [[ -n $out ]]; then
  flog ERROR "briefing sync: gitleaks found something in a commit to push, or gave no verdict; not pushed" dir="$R" said="$(tail -3 <<<"$out")"
  exit 1
fi
if out=$(git push -q origin HEAD 2>&1); then
  flog INFO "briefing synced" commit="$(git rev-parse --short HEAD)" pushed="$ahead"
  mirror
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
  mirror
  exit 0
fi
git rebase --abort >/dev/null 2>&1
flog ERROR "briefing sync: push failed; still behind or diverged" said="$(tail -3 <<<"$out")" ahead="$ahead"
exit 1
