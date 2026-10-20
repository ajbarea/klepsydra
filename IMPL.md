# IMPL

Current slice: a fifteenth character, branch feat/hesychia. Hesychia (af_nicole,
keryx's pin-only voice) joins the cast, so all 14 pool voices and the pinned one
have a portrait.

## Done
- `assets/portraits/hesychia.jpg` (1024 px) and a crop box in `scripts/cut-portraits.py`
  (250, 40, 810, 600): head upper middle, the brooch shoulder in the circle. The 28
  existing webp files re-cut byte-identical.
- 2 new webp files, 2 LICENSES entries, one `cast.json` entry (accent `#A9B8D0`: 6.91:1 and
  5.91:1 on the button, so the 4 px marker; not a status tone).
- Tests: 15 characters; the cast is every pool voice plus af_nicole; hook ink parity
  covers 17 (15 + 2 threshold colours).
- Demo fixture gains an af_nicole session. README faces section; briefs doc marked done.

## Next
- Review and merge.
