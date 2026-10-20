# IMPL

Current slice: four new characters, branch feat/four-characters. Chronos
(bm_george), Argos (am_fenrir), Hermes (bm_fable) and Elpis (af_alloy) join the
cast, so all 14 keryx pool voices have a portrait.

## Done
- `assets/portraits/<name>.jpg` (1024 px) are the sources; `scripts/cut-portraits.py`
  now holds a source and crop box per character. The ten kourai webp files re-cut
  byte-identical.
- 8 new webp files and LICENSES entries; 4 `cast.json` entries.
- Hermes's accent is `#E07B39`, not the brief's `#E69F00` (the needs amber).
- Tests: 14 characters covering the pool, new accents, no new accent equals a
  status tone, marker widths unchanged (no new accent is under 3:1).
- Demo fixture gains Chronos, Argos (needs you) and Elpis; Hermes was already there.
- README faces section; briefs doc marked done.

## Next
- Review and merge.
- Cupid, Aidos, Puck and Aletheia canon accents equal a status tone; left as is.
