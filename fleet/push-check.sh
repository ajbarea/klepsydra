#!/usr/bin/env bash
# push-check.sh: check whether a branch is handed over to review (PR label 'review'
# or 'in-review'). If an open PR for the branch carries the review label, pushing
# to it is refused (exit 1). With --run, runs the check first, then executes
# `git push "$@"`.
#
# Usage:
#   fleet push-check [BRANCH]
#   fleet push [GIT-PUSH-ARGS...]
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"

run_mode=0
if [[ ${1:-} == "--run" ]]; then
  run_mode=1
  shift
fi

# Parse target branch from arguments or git HEAD
branch=""
if (( run_mode )); then
  args=("$@")
  pos_args=()
  for arg in "${args[@]}"; do
    case $arg in
      -*) ;; # skip flags
      *) pos_args+=("$arg") ;;
    esac
  done
  if (( ${#pos_args[@]} >= 2 )); then
    ref=${pos_args[1]}
    ref=${ref#+}
    ref=${ref%%:*}
    ref=${ref#refs/heads/}
    branch=$ref
  elif (( ${#pos_args[@]} == 1 )); then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  else
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  fi
else
  if (( $# >= 2 )); then
    ref=$2
    ref=${ref#+}
    ref=${ref%%:*}
    ref=${ref#refs/heads/}
    branch=$ref
  elif (( $# == 1 )); then
    ref=$1
    ref=${ref#+}
    ref=${ref%%:*}
    ref=${ref#refs/heads/}
    branch=$ref
  else
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  fi
fi

# A detached HEAD or empty branch has nothing to check
if [[ -z $branch || $branch == "HEAD" ]]; then
  if (( run_mode )); then
    exec git push "$@"
  fi
  exit 0
fi

# Query GitHub for an open PR on this branch
GH=${FLEET_GH:-gh}
if command -v "$GH" >/dev/null 2>&1; then
  out=$("$GH" pr view "$branch" --json number,labels,state 2>/dev/null || true)
  if [[ -n $out && $out == "{"* ]]; then
    in_review=$(jq -r 'select(.state == "OPEN") | [.labels[]?.name | ascii_downcase] | any(. == "review" or . == "in-review")' <<<"$out" 2>/dev/null || true)
    if [[ $in_review == "true" ]]; then
      num=$(jq -r '.number // empty' <<<"$out" 2>/dev/null || true)
      flog WARN "push refused: branch is in review" branch="$branch" pr="${num:-unknown}"
      printf 'refused: branch "%s" is in review (PR #%s has label "review"); worker pushes are stopped\n' "$branch" "${num:-unknown}" >&2
      exit 1
    fi
  fi
fi

if (( run_mode )); then
  exec git push "$@"
fi
exit 0
