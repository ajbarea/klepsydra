# shellcheck shell=bash
# oom-tool.sh: rank this shell, and all it starts, first for the kernel's OOM
# killer (#353), so a memory cap inside fleet.slice kills the growing job, not
# an agent. launch.sh hands it to every fleet claude as BASH_ENV, which bash
# sources at the start of each non-interactive shell (its Bash tool calls and
# hooks, and the scripts they run); delegate.sh runs it as a wrapper,
# `bash oom-tool.sh CMD...`, which ranks CMD the same way.
# 1000 is OOM_SCORE_ADJ_MAX: within a cgroup the kernel adds adj/1000 of the
# cgroup's limit to each process's score, so any process ranked here outscores
# every claude (left at 0, the lowest a user may set without CAP_SYS_RESOURCE),
# and among these the largest goes first. The group's redirect keeps a failed
# write, and bash -x's trace of either line, off the caller's stderr; `|| :` keeps a
# `set -e` caller alive.
{ echo 1000 >/proc/self/oom_score_adj; } 2>/dev/null || :
if { [[ ${BASH_SOURCE[0]} == "$0" ]] && (( $# )); } 2>/dev/null; then exec "$@"; fi
