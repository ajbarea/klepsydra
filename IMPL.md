# IMPL

Current slice: readings you can trust across two accounts.

## Done
- Hook publishes a session's reading only for a new API response: its
  `cost.total_api_duration_ms` grew, or its windows changed. A re-render
  (refreshInterval, a window's reset time, mode toggles) no longer restamps
  the reading or moves it to whichever login is current; a window Claude Code
  drops at its reset is no change. Files carry `observed_at` and `api_ms`. A
  config that reads but does not parse (mid-write) publishes nothing rather
  than file under "unknown". 55 hook tests.
- Overlay takes the newest observed reading per account and window; ties fall
  back to the later window, then the higher number. Older hook files are
  ignored once observed readings overtake them. Highest-wins remains while an
  account has no observed reading, or an old hook is still writing, since
  those times say only which terminal redrew last.
- The account you are not on stays: an ended window reads 0% with when it
  reset, and an account drops only after 30 days without a reading. An ended
  window the account's latest reading no longer carries is left out, so a
  misfiled one does not linger.
- Old readings say their age ("updated 2 hr ago") instead of dimming, so the
  other account stays legible. Only the empty panel dims. 42 gauge tests.

## Verified against real data, not inferred
- Replayed every published reading (197 files, two accounts): the shipped
  overlay shows Personal week 100%. This branch shows the same figure,
  labelled `updated 1 day ago`, until the new hook's first reading, then 34%.
  RIT session shows `0% used · Reset 6 hr ago` instead of vanishing.
- Transcripts' `credential_org` entries show running sessions changing login
  mid-session, and the misfiled "RIT week" rows carry Personal's weekly values
  verbatim: re-renders after a login switch, as diagnosed.
- The RIT seat never reported a `seven_day` window of its own.
- Screenshots: old reading, ended window, switched-away account, dropped
  account (`scripts/visual-check.sh`).

## Open
- Right after the upgrade, a session whose numbers never move (pinned at 100%)
  stays on highest-wins until they do: its old file carries no API time to
  tell a response from a re-render, and restamping on equality would bring
  back the re-render bug.
- An "unknown" account an old hook filed from a torn config would show for up
  to 30 days. None exists on either station; the new hook cannot create one.
- Readings are per machine; usage on the other station shows only after a
  request from this one.
- Session files are never pruned (197 after four weeks, plus 17 orphaned
  `.tmp` files from renders cancelled mid-write).

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
