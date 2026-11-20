#!/usr/bin/env bash
set -u
for i in 1 2 3; do
  echo "== before run $i"; "$(dirname "$0")/winrun.sh" /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-readers-before klepsydra-build-perf-before 100
  echo "== after run $i"; "$(dirname "$0")/winrun.sh" /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-readers klepsydra-build-perf-readers 100
done
