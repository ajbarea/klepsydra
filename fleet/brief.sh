#!/usr/bin/env bash
# brief.sh NAME BODY-FILE: write task-NAME.src in the fleet's state folder as
# BODY-FILE's text followed by the canonical brief tail (brief-tail.md), the
# rules every brief shares. A brief it replaces is kept in archive/briefs/.
# brief.sh --check [FILE...]: list the briefs (default: every task-*.src) whose
# shared rules differ from what --refresh would write; fails when any does.
# brief.sh --refresh [FILE...]: rewrite those briefs with the current tail.
# Each keeps its body and any line added after its shared rules. A line that
# any version of the tail ever held (word for word, or by its label: its text
# before the first ":") is an old rule and gives way to the current tail, so a
# rule without a colon or with a renamed label never piles up (#262). The old
# brief is kept in archive/briefs/.
set -u
FLEET_TARGET=fleet::brief
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
TAIL=$here/brief-tail.md
# Every mode writes the tail: a missing or empty one (a checkout mid-switch, an
# editor's rewrite) would strip every brief's rules, so nothing runs without it.
if ! grep -q '^Resources: ' "$TAIL" 2>/dev/null; then
  flog ERROR "brief refused: the shared rules file is missing, empty or has no Resources: line" tail="$TAIL"
  err "no shared rules at $TAIL; nothing written"
  exit 2
fi
# Copy brief FILE into archive/briefs/ as NAME; fails when the copy is not made.
archive() { # FILE NAME
  mkdir -p -- "$FLEET_STATE/archive/briefs" && cp -- "$1" "$FLEET_STATE/archive/briefs/$2"
}
# A unique archive stamp: two writes in one second never share a name.
stamp() { printf '%s-%s' "$(date +%Y%m%d-%H%M%S.%N)" "$$"; }
# A brief's shared rules: from its "Resources:" line on.
rules() { sed -n '/^Resources: /,$p' "$1"; }
# Every line of the current tail and of each committed version of it (from
# this checkout's history; without one, the current tail alone).
tail_lines() {
  local root
  grep . "$TAIL"
  root=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$root" log --format='commit %H' --name-only --follow -- fleet/brief-tail.md 2>/dev/null |
    awk '/^commit / { h = $2; next } NF { print h, $0 }' |
    while read -r h path; do git -C "$root" show "$h:$path" 2>/dev/null; done | grep .
}

# BRIEF as the current tail would have it: its body, the tail, then the lines
# added after its old rules, less any line that is an old rule (tail_lines),
# word for word or by its label.
current() { # BRIEF
  sed '/^Resources: /,$d' "$1"
  cat -- "$TAIL"
  # ENVIRON, not -v: awk would read a backslash in a rule as an escape.
  rules "$1" | LABELS=$tail_labels OLD=$tail_old awk 'BEGIN {
      n = split(ENVIRON["LABELS"], l, "\n"); for (i = 1; i <= n; i++) rule[l[i]] = 1
      n = split(ENVIRON["OLD"], o, "\n"); for (i = 1; i <= n; i++) was[o[i]] = 1 }
    { label = $0; sub(/:.*/, "", label) } !($0 in was) && !($0 ~ /:/ && label in rule) && NF { print }'
}
if [[ ${1:-} == --check || ${1:-} == --refresh ]]; then
  tail_old=$(tail_lines | sort -u)
  tail_labels=$(grep ':' <<<"$tail_old" | sed 's/:.*//' | sort -u)
fi
# Whether BRIEF already reads as current() would write it (blank lines aside).
fresh() { cmp -s <(grep . "$1") <(current "$1" | grep .); }

if [[ ${1:-} == --check ]]; then
  shift
  stale=0
  (( $# )) || set -- "$FLEET_STATE"/task-*.src
  for f in "$@"; do
    [[ -e $f ]] || continue
    # A tail rule it lacks, an old rule it still carries, or one twice.
    if ! fresh "$f"; then
      echo "stale: ${f##*/}"
      stale=1
    fi
  done
  exit "$stale"
fi
if [[ ${1:-} == --refresh ]]; then
  shift
  (( $# )) || set -- "$FLEET_STATE"/task-*.src
  failed=0
  for f in "$@"; do
    [[ -e $f ]] || continue
    # An unreadable brief would rebuild as the tail alone: its body is lost.
    if [[ ! -r $f ]]; then
      flog ERROR "brief not refreshed: it cannot be read; the old one stays" path="$f"
      err "cannot read ${f##*/}; left as it was"
      failed=1
      continue
    fi
    fresh "$f" && continue
    # No temp file beside it, or no archive copy: no rewrite.
    if ! tmp=$(mktemp "$f.XXXXXX"); then
      flog ERROR "brief not refreshed: no temp file could be made beside it; the old one stays" path="$f"
      err "cannot write beside ${f##*/}; left as it was"
      failed=1
      continue
    fi
    if ! archive "$f" "${f##*/}.$(stamp)"; then
      rm -f -- "${tmp:?}"
      flog ERROR "brief not refreshed: its archive copy could not be written; the old one stays" path="$f"
      err "could not archive ${f##*/}; left as it was"
      failed=1
      continue
    fi
    if ! current "$f" >"$tmp" || ! grep -q '^Resources: ' "$tmp"; then
      rm -f -- "${tmp:?}"
      flog ERROR "brief not refreshed: building it failed; the old one stays" path="$f"
      err "could not refresh ${f##*/}; left as it was"
      failed=1
      continue
    fi
    mv -f -- "$tmp" "$f"
    flog INFO "brief refreshed with the current shared rules" path="$f" lines="$(wc -l <"$f")"
    echo "refreshed: ${f##*/}"
  done
  exit "$failed"
fi
(( $# == 2 )) || { err "usage: brief.sh NAME BODY-FILE | brief.sh --check | brief.sh --refresh"; exit 2; }
name=$1 body=$2
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { err "a brief name is lowercase letters, digits and dashes: $name"; exit 2; }
[[ -r $body ]] || { err "no body at $body"; exit 2; }
if grep -q '^Resources: ' "$body"; then err "$body already has the shared rules; give the body only"; exit 2; fi
out=$FLEET_STATE/task-$name.src
# As the refresh: a temp file first, then the archive copy, then a checked write.
if ! tmp=$(mktemp "$out.XXXXXX"); then
  flog ERROR "brief not written: no temp file could be made beside it" name="$name" path="$out"
  err "cannot write beside ${out##*/}; nothing written"
  exit 1
fi
if [[ -e $out ]] && ! archive "$out" "task-$name.$(stamp).src"; then
  rm -f -- "${tmp:?}"
  flog ERROR "brief not written: the one it replaces could not be archived" name="$name" path="$out"
  err "could not archive ${out##*/}; nothing written"
  exit 1
fi
if ! {
  cat -- "$body"
  [[ -n $(tail -c1 -- "$body") ]] && printf '\n'
  printf '\n'
  cat -- "$TAIL"
} >"$tmp" || ! grep -q '^Resources: ' "$tmp"; then
  rm -f -- "${tmp:?}"
  flog ERROR "brief not written: building it failed" name="$name" path="$out"
  err "could not write ${out##*/}; nothing written"
  exit 1
fi
mv -f -- "$tmp" "$out"
flog INFO "brief written" name="$name" path="$out" lines="$(wc -l <"$out")"
echo "$out"
