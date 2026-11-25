# Design pass, 2026-11-18

Static mockups for AJ to pick from before anything is built. Nothing here ships.
They cover #421 (the gauge strip, plus the optional System chip and per-card RAM/CPU), #438 (bar opacity), #440 (+ New session) and #384 (the settings page).

| Page | Surface | Variant |
|---|---|---|
| `gauge-a.html` | Gauge strip | A: Readout, text first (NVIDIA HUD grammar) |
| `gauge-b.html` | Gauge strip | B: Dial, a ring per account with its logo inside |
| `new-session-a.html` | + New session | A: split button and engine menu |
| `new-session-b.html` | + New session | B: engine picker with tiles |
| `settings-a.html` | Settings | A: one column (Spotify) |
| `settings-b.html` | Settings | B: section rail and cards (Windows 11) |
| `wall-cards.html` | Wall cards | Option: each agent's RAM and CPU (AJ 11-18, #421) |
| `wall-header.html` | Gauges | Docked in the wall header, and the pinned floating strip (AJ 11-18) |

Open any page in a browser. Add `?theme=light` or `?theme=dark` to force a theme; otherwise the page follows the system.
`review.md` compares the variants and gives a recommendation. `shots/` holds the screenshots.

- **Readings:** every gauge and quota figure comes from `readings.js`, klepsydra's newest reading per account at 1:23 PM EST on 11-18. Earlier readings appear only in captioned state examples. System figures (`SYS`, `TREES`) are from /proc, the fleet slice's cgroup and nvidia-smi at 4:00 PM.
- **Tokens:** colours and type are the app's own (`src/style.css`, `src/fleet/wall.css`); `mock.css` names its source for each.
- **Icons:** the brand marks are copied from `MAKER_ICONS` in `src/fleet/wall.js`.

Screenshots: `uv run --no-project --with playwright python shoot.py OUT_DIR` writes every page at 1920x1080 and at 390 wide, in both themes, and prints the linear strip's width at 1920 and 1366.
