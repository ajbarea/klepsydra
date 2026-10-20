# IMPL

Current slice: Open terminal button marker, branch fix/button-marker (part of
#34). The button is neutral with a 4 px left marker in the character's accent
(6 px where the accent is under 3:1 on the button). Only a needs_you card
(quiet "needs you?" too) has a filled button: the needs amber, black ink, no
marker. Medallion cards get the plain button; disabled has no fill or marker.

## Done
- `jumpStyle()` in `src/fleet/model.js` -> `jumpKind` (off/needs/accent/plain)
  and `jumpMark`; `markerWidth()` in `src/fleet/contrast.js`.
- wall.js sets `data-kind`, `--accent`, `--mark-w`; wall.css draws them.
- Tests: model cases, per-accent marker contrast, needs-fill ink.
- README colours section; #34 constraints updated.

## Next
- Review and merge.
