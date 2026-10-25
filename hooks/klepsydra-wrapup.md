---
description: Checkpoint this session for a restart and tell klepsydra whether it is safe to stop.
disable-model-invocation: true
---
klepsydra is wrapping up every session, because AJ may restart the machine. In this turn:

1. Stop at a clean point. Finish the current step or checkpoint it; do not race to finish the task.
2. Write the resume state (the branch's IMPL.md, or the handoff memory) and commit it. Push where this repo's rules allow, never straight to a protected default branch or a branch someone else owns; otherwise say it is committed locally only.
3. List what is still running (background tasks and subagents, reviews, builds, systemd units, deploys not yet live) and mark each one: **survives** the restart, **reruns or resumes** from the handoff (say what it costs), or **lost**.
4. Report it as your last step:
   - Nothing would be lost: `~/.claude/klepsydra-wrapup.sh ready ${CLAUDE_SESSION_ID}`
   - Something would be lost that no handoff can recover: `~/.claude/klepsydra-wrapup.sh blocked ${CLAUDE_SESSION_ID} "<what would be lost, and roughly how long until it is safe>"`

Ready means nothing would be lost that a handoff cannot recover. Unfinished work that the handoff records is ready; a review round or a test run that reruns from it is ready.
