# IMPL

Current slice: character colours (#34, first part), branch feat/char-colours.
Each kourai character's canon colour marks its session's tmux window and its
card's Open terminal button.

## Done
- ✅ `cast.json`: an `accent` per character (kourai `hex_color`); a test pins
  the ten canon values.
- ✅ `src/fleet/contrast.js`: luminance, contrast and `inkOn` (black or white),
  shared by the model and the style tests.
- ✅ `identity()`/`card()`: `accent` and `accentInk`, null for any other voice
  and for a malformed accent.
- ✅ `wall.js`/`wall.css`: an enabled Open terminal takes `--accent` and
  `--accent-ink`; a disabled one keeps the quiet look. The focus ring sits
  2px off the button, on the card colour. Status tones are untouched.
- ✅ `hooks/klepsydra-fleet.sh`: on the `klepsydra` socket only, at SessionStart
  or a changed voice, sets `window-status-style` and
  `window-status-current-style` from the cast (`KLEPSYDRA_CAST`, default
  `~/.claude/klepsydra-cast.json`); a voice with no character unsets both; a
  malformed accent or a missing cast makes no call. The hook's ink equals
  `inkOn` for all ten (tested).
- ✅ `test_fleet.sh` runs with a stub `tmux` on PATH for every case.
- ✅ README: install copies the cast; the colours are documented; the upgrade
  note says to re-copy it.
- ✅ Review round 1: the hook drops the fleet lock before it calls tmux; the
  hover is an inset ring in the ink (no filter), so the 4.5:1 holds; the accent
  check anchors with `\z`; `fire` uses a private cast and private socket paths.

## Verified
- ✅ Tests: all ten accents hold 4.5:1 with their ink and on hover; the hook's
  ink equals `inkOn` for the ten plus two colours at the black/white switch;
  a failing tmux leaves the hook silent, exit 0, file written; a hanging tmux
  does not keep another session's file from being written (fails if the lock
  is held across tmux).
- ✅ `?demo` wall at 1920 in Chromium: kourai buttons coloured, a medallion
  card neutral, disabled buttons quiet. A private tmux server showed both
  window styles set as the hook sets them.

## Next
- 📋 #34 second part: DECAC colouring for hand-opened Windows Terminal tabs.
- 📋 #32: an optional split mode for the fleet tab.
- 📋 #22: interrupt and exit from a card.

## Open
- A copied cast that predates `accent` colours nothing until it is re-copied.
