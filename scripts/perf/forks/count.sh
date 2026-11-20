#!/usr/bin/env bash
# count.sh LABEL CMD...: run CMD under strace -f and print one line: LABEL,
# the processes it created (clone/clone3/fork/vfork: every fork, a $(...)
# subshell included), the programs it exec'd, and the most exec'd programs.
# STRACE names the strace binary (default: strace on PATH); STDIN feeds CMD
# (default /dev/null); the raw trace is kept at $OUT/strace-LABEL.log.
# Only calls that succeeded count (-z): a PATH search tries several execs.
set -u
label=$1
shift
st=${STRACE:-strace}
out=${OUT:-${TMPDIR:-/tmp}}
log=$out/strace-$label.log
"$st" -f -qq -z -e trace=clone,clone3,fork,vfork,execve -e signal=none -o "$log" "$@" >/dev/null 2>&1 <"${STDIN:-/dev/null}"
forks=$(grep -cE ' (clone|clone3|fork|vfork)\(' "$log")
execs=$(grep -cE ' execve\(' "$log")
progs=$(grep -oE 'execve\("[^"]+"' "$log" | sed 's/.*\///; s/"//' | sort | uniq -c | sort -rn | head -12 | awk '{ printf "%s=%s ", $2, $1 }')
printf '%-22s forks=%-5s execs=%-5s %s\n' "$label" "$forks" "$execs" "$progs"
