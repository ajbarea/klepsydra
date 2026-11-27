#!/usr/bin/env bash
# scripts/shellcheck.sh [OPTION...] FILE...: `make shellcheck`'s runner (#503).
# ShellCheck's dataflow analysis of fleet/test_fleet.sh alone peaks at 3.4 GB, past
# the room a worker has on WSL, where the kernel kills it (exit 137). Without that
# analysis the same file takes about 240 MB and a few seconds. Files over
# FLEET_SHELLCHECK_BIG_LINES run together and need FLEET_SHELLCHECK_NEED_MIB for the
# full check; the rest run together and need FLEET_SHELLCHECK_SMALL_NEED_MIB. A run
# whose need is over the least room in this process's cgroups and MemAvailable (or
# when that room cannot be read) is checked without dataflow (--extended-analysis=false),
# with a note: every check but the dataflow ones (SC2030, SC2031 and the like) still
# runs, and CI runs them all. SC2086 is left out of those runs too: it reads values
# through dataflow (ShellCheck 0.9.0 changelog), and without it flagged 73 safe
# expansions in this tree (11-24), all of which the full check clears. Full analysis
# always on CI (CI or GITHUB_ACTIONS set) or with FLEET_SHELLCHECK_ALL=1;
# in CI (unless -f/--format is passed), findings emit GitHub ::error annotations.
# The exit status is the checker's own: no file is skipped.
set -uo pipefail

read -r -a sc <<<"${SHELLCHECK_BIN:-uvx --from shellcheck-py shellcheck}"
need_mib=${FLEET_SHELLCHECK_NEED_MIB:-4000}
# The rest of the tree (57 files, 11-24) peaked at 1456 MiB in full: that and a tenth.
small_need_mib=${FLEET_SHELLCHECK_SMALL_NEED_MIB:-1600}
big_lines=${FLEET_SHELLCHECK_BIG_LINES:-3000}

# Whether a short-option group (-x, -s, -xs) takes its value from the next word:
# its first value-taking letter is its last (-sbash carries its own value), and -C
# takes only an attached value (-Calways), so the rest of the group is that value.
short_takes_next() { # GROUP
  local g=${1#-} i
  for (( i = 0; i < ${#g}; i++ )); do
    case ${g:i:1} in
      C) return 1 ;;
      [iefoPsSW]) (( i == ${#g} - 1 )); return ;;
    esac
  done
  return 1
}

# Whether a long option takes its value from the next word, written whole or
# shortened as ShellCheck accepts it (--sev for --severity).
long_takes_next() { # OPTION
  local o
  for o in include exclude extended-analysis format rcfile enable source-path shell severity wiki-link-count; do
    [[ --$o == "$1"* ]] && return 0
  done
  return 1
}

# Whether a grouped short option includes -f before any value-taking option.
short_has_format() { # GROUP
  local g=${1#-} i
  for (( i = 0; i < ${#g}; i++ )); do
    case ${g:i:1} in
      f) return 0 ;;
      [CeioPsSW]) return 1 ;;
    esac
  done
  return 1
}

opts=() small=() big=() ends=0 user_format=0
while (( $# )); do
  f=$1; shift
  if (( !ends )) && [[ $f == -- ]]; then
    ends=1
  elif (( !ends )) && [[ $f == -?* ]]; then
    opts+=("$f")
    case $f in
      --*)
        [[ ${f%%=*} == --f* && --format == "${f%%=*}"* ]] && user_format=1
        long_takes_next "$f" && (( $# )) && { opts+=("$1"); shift; }
        ;;
      *)
        short_has_format "$f" && user_format=1
        short_takes_next "$f" && (( $# )) && { opts+=("$1"); shift; }
        ;;
    esac
  elif (( $( { wc -l <"$f"; } 2>/dev/null || echo 0) > big_lines )); then
    big+=("$f")
  else
    small+=("$f")
  fi
done

# The least memory this process may still take, in MiB: each cgroup from its own
# up to the root caps it (memory.max less memory.current), and so does the machine.
room_mib() {
  local root=${FLEET_CGROUP_ROOT:-/sys/fs/cgroup} cg d max cur least=""
  cg=$(awk -F: '$1 == "0" { print $3; exit }' "${FLEET_PROC:-/proc}/self/cgroup" 2>/dev/null)
  if [[ -n $cg ]]; then
    d=$root${cg%/}
    while [[ $d == "$root"* ]]; do
      max=$(cat -- "$d/memory.max" 2>/dev/null) cur=$(cat -- "$d/memory.current" 2>/dev/null)
      if [[ $max =~ ^[0-9]+$ ]]; then
        [[ $cur =~ ^[0-9]+$ ]] || cur=0
        (( max - cur < 0 )) && cur=$max
        (( ${#least} == 0 || (max - cur) / 1048576 < least )) && least=$(( (max - cur) / 1048576 ))
      elif [[ -e $d/memory.max && $max != max ]]; then
        printf unknown # a limit that cannot be read may be the tightest
        return
      fi
      [[ $d == "$root" ]] && break
      d=${d%/*}
    done
  fi
  local avail
  avail=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${FLEET_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  [[ $avail =~ ^[0-9]+$ ]] && (( ${#least} == 0 || avail < least )) && least=$avail
  printf '%s' "${least:-unknown}"
}

full_room=0 ci_mode=0 room=""
[[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} ]] && ci_mode=1
if [[ ${FLEET_SHELLCHECK_ALL:-} == 1 ]] || (( ci_mode )); then
  full_room=1
elif (( ${#small[@]} + ${#big[@]} )); then
  room=$(room_mib) # read once: the two runs follow one another
fi

run_sc() { # [FLAGS_AND_FILES...]
  if (( !ci_mode || user_format )); then
    "${sc[@]}" "$@"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    "${sc[@]}" -f gcc "$@"
    return
  fi
  local out rc
  out=$("${sc[@]}" -f json "$@")
  rc=$?
  if [[ -n $out ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    jq -r '
      def esc_data: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
      def esc_prop: esc_data | gsub(":"; "%3A") | gsub(","; "%2C");
      .[] | "::error title=shellcheck (SC\(.code)),file=\(.file | esc_prop),line=\(.line),col=\(.column),endLine=\(.endLine),endColumn=\(.endColumn)::\("\(.file):\(.line):\(.column): \(.level): \(.message) [SC\(.code)]" | esc_data)"
    ' <<<"$out"
  elif [[ -n $out ]]; then
    printf '%s\n' "$out"
  fi
  return "$rc"
}

check() { # NEED FILE...: in full when the room covers NEED, else without dataflow
  local need=$1 what; shift
  what=$*; (( $# > 3 )) && what="$# files"
  if (( full_room )) || { [[ $room =~ ^[0-9]+$ ]] && (( room >= need )); }; then
    run_sc "${opts[@]}" -- "$@"
  else
    local left="room unknown"
    [[ $room =~ ^[0-9]+$ ]] && left="$room MiB of room"
    printf 'note: %s checked without dataflow analysis or SC2086: %s, under the %s MiB it needs; CI runs the full check (FLEET_SHELLCHECK_ALL=1 runs it here)\n' \
      "$what" "$left" "$need" >&2
    # Before the caller's options, so an explicit --extended-analysis of theirs wins.
    run_sc --extended-analysis=false --exclude=SC2086 "${opts[@]}" -- "$@"
  fi
}

rc=0
(( ${#small[@]} + ${#big[@]} )) || { "${sc[@]}" "${opts[@]}"; exit; } # no file: the checker reports its own usage error
(( ${#small[@]} )) && { check "$small_need_mib" "${small[@]}" || rc=$?; }
(( ${#big[@]} )) && { check "$need_mib" "${big[@]}" || rc=$?; }
exit "$rc"
