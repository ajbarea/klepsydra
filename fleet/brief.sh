#!/usr/bin/env bash
# brief.sh NAME BODY-FILE: write task-NAME.src in the fleet's state folder as
# BODY-FILE's text followed by the canonical brief tail (brief-tail.md), the
# rules every brief shares. A brief it replaces is kept in archive/briefs/.
# brief.sh --check [FILE...]: list the briefs (default: every task-*.src) whose
# shared rules differ from the tail; fails when any does.
# brief.sh --refresh [FILE...]: rewrite those briefs with the current tail.
# Each keeps its body and any line added after its shared rules; a line whose
# label (its text before the first ":") is a tail rule's is that rule's old
# wording and gives way to the new one. The old brief is kept in archive/briefs/.
set -u
FLEET_TARGET=fleet::brief
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
TAIL=$here/brief-tail.md
# A brief's shared rules: from its "Resources:" line on.
rules() { sed -n '/^Resources: /,$p' "$1"; }

if [[ ${1:-} == --check ]]; then
  shift
  stale=0
  (( $# )) || set -- "$FLEET_STATE"/task-*.src
  for f in "$@"; do
    [[ -e $f ]] || continue
    # A rule of the tail that the brief lacks, word for word.
    if grep . "$TAIL" | grep -qvxF -f <(rules "$f"); then
      echo "stale: ${f##*/}"
      stale=1
    fi
  done
  exit "$stale"
fi
if [[ ${1:-} == --refresh ]]; then
  shift
  (( $# )) || set -- "$FLEET_STATE"/task-*.src
  labels=$(grep . "$TAIL" | sed 's/:.*//' | sort -u)
  for f in "$@"; do
    [[ -e $f ]] || continue
    grep . "$TAIL" | grep -qvxF -f <(rules "$f") || continue
    mkdir -p -- "$FLEET_STATE/archive/briefs"
    cp -- "$f" "$FLEET_STATE/archive/briefs/${f##*/}.$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp "$f.XXXXXX")
    {
      sed '/^Resources: /,$d' "$f"
      cat -- "$TAIL"
      # Lines added after the old rules: kept, unless they are an old rule.
      rules "$f" | awk -v labels="$labels" 'BEGIN { n = split(labels, l, "\n"); for (i = 1; i <= n; i++) rule[l[i]] = 1 }
        { label = $0; sub(/:.*/, "", label) } !($0 ~ /:/ && label in rule) && NF { print }'
    } >"$tmp"
    mv -f -- "$tmp" "$f"
    flog INFO "brief refreshed with the current shared rules" path="$f"
    echo "refreshed: ${f##*/}"
  done
  exit 0
fi
(( $# == 2 )) || { err "usage: brief.sh NAME BODY-FILE | brief.sh --check | brief.sh --refresh"; exit 2; }
name=$1 body=$2
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { err "a brief name is lowercase letters, digits and dashes: $name"; exit 2; }
[[ -r $body ]] || { err "no body at $body"; exit 2; }
if grep -q '^Resources: ' "$body"; then err "$body already has the shared rules; give the body only"; exit 2; fi
out=$FLEET_STATE/task-$name.src
if [[ -e $out ]]; then
  mkdir -p -- "$FLEET_STATE/archive/briefs"
  cp -- "$out" "$FLEET_STATE/archive/briefs/task-$name.$(date +%Y%m%d-%H%M%S).src"
fi
tmp=$(mktemp "$out.XXXXXX")
{
  cat -- "$body"
  [[ -n $(tail -c1 -- "$body") ]] && printf '\n'
  printf '\n'
  cat -- "$TAIL"
} >"$tmp"
mv -f -- "$tmp" "$out"
flog INFO "brief written" name="$name" path="$out" lines="$(wc -l <"$out")"
echo "$out"
