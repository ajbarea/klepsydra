# IMPL

Current slice: readings you can trust across two accounts.

## Done
- Hook publishes a session's reading only when it changes. A re-render
  (refreshInterval, a window's reset time, mode toggles) repeats the last API
  response; it no longer refreshes the timestamp or moves the reading to
  whichever login is current. A window Claude Code drops at its reset is no
  change. 45 hook tests.
- Overlay takes the most recently published reading per account and window.
  Same-second readings fall back to the later window, then the higher number.
  Highest-wins is gone: a mid-week reset and a plan upgrade both lowered the
  weekly under the same `resets_at`.
- The account you are not on stays: an ended window reads 0% with when it
  reset, and an account drops only after 30 days without a reading. An ended
  window the account's latest reading no longer carries is left out, so a
  misfiled one does not linger.
- Old readings say their age ("updated 2 hr ago") instead of dimming, so the
  other account stays legible. Only the empty panel dims. 36 gauge tests.

## Verified against real data, not inferred
- Replayed every published reading (197 files, two accounts): the shipped
  overlay shows Personal week 100%; this branch shows 33%, the newest
  session's figure. RIT session shows `0% used · Reset 6 hr ago` instead of
  vanishing.
- Transcripts' `credential_org` entries show running sessions changing login
  mid-session, and the misfiled "RIT week" rows carry Personal's weekly values
  verbatim: re-renders after a login switch, as diagnosed.
- The RIT seat never reported a `seven_day` window of its own.
- Screenshots: old reading, ended window, switched-away account, dropped
  account (`scripts/visual-check.sh`).

## Open
- Readings are per machine; usage on the other station shows only after a
  request from this one.
- Session files are never pruned (197 after four weeks, plus 17 orphaned
  `.tmp` files from renders cancelled mid-write).

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
