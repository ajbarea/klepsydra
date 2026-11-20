#!/usr/bin/env bash
set -u
for i in 1 2 3; do
  echo "== before run $i"; /tmp/claude-1001/-home-ajbar-ajsoftworks/7c7ccfd6-16da-49ed-bf3d-3f10ad019357/scratchpad/winrun.sh /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-readers-before klepsydra-build-perf-before 100
  echo "== after run $i"; /tmp/claude-1001/-home-ajbar-ajsoftworks/7c7ccfd6-16da-49ed-bf3d-3f10ad019357/scratchpad/winrun.sh /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-readers klepsydra-build-perf-readers 100
done
