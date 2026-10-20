# IMPL

Current slice: speaking avatar, the klepsydra side (#33), branch
feat/speaking-ripple. keryx 0.9.2 (keryx #39) writes `speaking.json` into the
fleet folder per sentence; the wall shows gold waves around the speaking
card's portrait. Contract: keryx `docs/speaking-signal.md`.

## Done
- Reader (`src-tauri/fleet/src/speaking.rs`): the scan passes `speaking.json`
  over by name (test); `read` takes only a regular file under 256 KiB;
  `parse` rejects v != 1, malformed JSON, out-of-range times, a negative or
  over-600 s span, and negative levels; levels over 1 are held to 1.
  `owner` matches pid+start, then session_id, then the one live card wearing
  the voice (two such cards: none). A line whose `ends_at` is before the
  reader's second is dropped. Rides on the snapshot as `speaking`
  {session_id, envelope, started_at, ends_at}; a malformed file is silence,
  not a fleet.log problem.
- Wall (`src/fleet/speaking.js`, `wall.js`): `Speaker` tracks the line;
  SPEAK_HOLD_MS = 600 holds through sentence gaps, a null mid-clip is a
  cut-off (fade now), SPEAK_FADE_MS = 300. Waves: a steady gold ring at
  r 43.5 that swells with the level, plus two ripples r 46.5 to 56 that
  start #F1D2A1 and darken to #C9944A. rAF only while a line shows; reduced
  motion: one still ring, taken down by a timer. Live region "<Name>
  speaking" once per utterance (same words twice are cleared and re-set).
- Strip: the speaking face gets `.speaking` (gold box-shadow ring) and
  ", speaking" in its label, through the hold.
- Demo: `scripts/fixtures/fleet-demo.json` has a 3.2 s line for Hermes with
  `ends_at` far ahead; in a browser `feed.js` replays it every sentence plus
  400 ms.
- Gates: the whole audit list, build-windows --check.

## Next
- Independent review, then merge.
- Live check: install the build, run keryx 0.9.2, and watch a real line.

## Verify
- `node --test src/*.test.js`; `cd src-tauri && cargo test -p klepsydra-fleet`.
- Serve the repo root, open `/src/wall.html?demo` at 1920 wide.
