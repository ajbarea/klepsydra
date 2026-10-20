# IMPL

Current slice (#30, branch feat/faces-place): place the faces strip around the
usage panel (right, left, above, below) or hide it, from a tray "Faces"
submenu, while the usage panel stays where the user docked it. AJ docks the
compact gauge in the taskbar and wants the faces wherever his overlays go.

Decisions (research in #30 and the 10-20 session): one radio group of 5 in a
"Faces" submenu (Microsoft: 2 to 7 mutually exclusive options suit a radio
group; one submenu level); no settings window until a setting needs more than
a choice (a second webview costs memory). One `faces` pref for both layouts.
The layout hub becomes a "look" hub carrying {layout, faces}, so the first
draw already knows the side (no jump). Sizing anchors on the panel, which also
stops the bar drifting left when a session starts on a right-anchored gauge.

## Done (WIP commit, Rust side only, NOT yet compiled)
- 📋→✅ `src-tauri/src/geometry.rs`: `grow_around_panel` (panel keeps its edges
  nearest the monitor's, the window hangs off it) + 6 tests.
- ✅ written, 📋 uncompiled `src-tauri/src/main.rs`: `pref_choice` + `LAYOUTS`
  / `FACES` consts, `layout_of`/`faces_of`/`look_of`; `Layouts` hub renamed
  `Look`, `layout_subscribe` -> `look_subscribe` publishing {layout, faces};
  `set_look(app, key, want)`; `Panel` managed state (in `with_state`);
  `set_size` takes `panel: Option<[f64;4]>` and uses `grow_around_panel` for
  non-zoom, non-first sizing; tray "Faces" Submenu of 5 CheckMenuItems
  (`faces:<side>`, Hidden after a separator), one checked from the saved
  value; test `a_saved_choice_is_read_only_from_its_list`.

## Next
1. Frontend `src/main.js`: `followLayout` -> follow `look_subscribe`, apply
   `look.layout` (existing async path) and `look.faces` (set
   `document.documentElement.dataset.faces`, render); harness `?faces=`;
   `stripRect()` null when faces hidden; send `panel` (rect of `#panel`) in the
   `set_size` invoke.
2. `src/style.css`: `:root[data-faces="left"] #frame {flex-direction:
   row-reverse}`, `above` column-reverse + align-items flex-start, `below`
   column + flex-start, `hidden` `#strip {display:none}`.
3. Node tests (style/guards) for the four data-faces rules and the look
   channel; `scripts/visual-check.sh` shots for each side in both layouts.
4. Compile + test on Windows: `bash scripts/build-windows.sh --check` (fix
   compile errors in the WIP Rust first). Only when host RAM is calm.
5. README (fleet strip + tray paragraph), spec addendum ruling, ROADMAP.
6. PR (label enhancement, assignee ajbarea, Closes #30), independent review,
   CI, merge; rebuild + install; live: click each Faces item, panel rect
   unchanged (`C:\Windows\Temp\kshot.ps1`), faces on the chosen side.

## Notes for the next session
- Tray menu item offsets (menu 134px tall before this change): Reset 14, Set
  home 36, Compact 66, Start with Windows 88, Quit 119. The Faces submenu
  shifts everything below Compact; re-measure with
  `C:\Windows\Temp\tray-menu-shot.ps1` before clicking (a miss on Quit
  kills the app).
- WSL interop dies when order-7 pages run out (`grep Normal
  /proc/buddyinfo`); fix from Windows PowerShell: `wsl -u root -- sh -c
  "sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 >
  /proc/sys/vm/compact_memory"`.
- The 8-hour memory reading (sampler pid 1499879, log
  `/tmp/klepsydra-memory-2.log`) was taken under heavy host memory pressure;
  treat its verdict as unreliable (working set can be trimmed) and retake it
  on a calm machine, ideally recording private bytes too.

## Open
- The tray icon still draws a bar in either layout.
- The default display name (`my-app-3f`) reaches no hook (`session_title`
  carries only a set name), so such a session is named by its folder.
- Some turns end with no hook (Esc on a need, an interrupt): the card keeps
  its state until the next prompt, or "working?" at 10 minutes. Probe
  2026-10-19 (2.1.301); the transcript's internal records are not parsed.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
