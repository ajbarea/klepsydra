# IMPL

Current slice: character theming on the Comfortable card (#62) with the bigger,
clickable portrait (#44). Branch `feat/card-theming`. AJ picked direction A
(a portrait-backed header band) on 10-21; the mock of all three directions is
on the local branch `mock/card-theming-looks` (reference only). The plan of
record is the #62 comment of 10-21.

## Tasks
1. ✅ Cast: `epithet` and `head` [x, y, r] (fractions of the figure) per
   character; tests pin both.
2. ✅ Assets: `scripts/cut-portraits.py` writes `<face>-figure.webp` (half-figure
   cut-out) and `<face>-full.webp` (#44's full portrait) with LICENSES entries.
   Ten kourai figures come from the kourai transparent PNGs; the five newer
   ones from isnet-anime cut-outs committed as `assets/portraits/<name>-cutout.webp`
   (`scripts/cutout-portraits.py`, run once). BiRefNet needed over 3.5 GB a
   run; two at once likely took WSL down on 10-21. isnet-anime: 3 s, 1.2 GB.
3. ✅ Model: `identity` adds epithet, figure, full; `card` adds `accentInk`
   (`readableOn` in contrast.js), and the crew marks (`crewKinds`, shared with
   the ring).
4. ✅ Band (wall.css, wall.html, wall.js): stage light capped under text, the
   figure breaking the top edge, Cinzel nameplate, epithet with sprig, pill in
   the corner, crew marks on a plinth (the ring stays for medallions and
   Compact), speaking waves behind the head, needs amber light, dim light on
   quiet cards, arrival via `@starting-style`.
5. ✅ #44 dialog: `.look` button on the figure (on the face in Compact), native
   `<dialog>`, focus back to the button or the wall.
6. ✅ Compact: face 56 -> 64 px (fit bottoms 963 and 984 px); the name keeps its own face.
7. ✅ Hesychia rotates now (keryx 0.9.3): README, `fleet-cast.test.js`, briefs.
8. 📋 Docs ✅; screenshots of all 15 at 1920 and 945, review, PR (Closes #62, #44),
   merge, deploy, live check.

## Verify
- `PATH=~/.nvm/versions/node/v24.18.0/bin:$PATH node --test src/*.test.js`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `cd src-tauri && cargo test -p klepsydra-fleet`; the hooks' `test_*.sh`.
- Serve the repo root and open `/src/wall.html?demo`.
