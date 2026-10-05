# IMPL

Current slice: Linux (X11) port, built and running on Debian 13 / XFCE.

## Done
- Hook picks the overlay's data dir per platform: the XDG data dir on Linux,
  the Windows side under WSL. Both defaults asserted against the bundle
  identifier, and the Linux one exercised end to end. 37 hook tests.
- Shell: drag reads pointer and button with one XQueryPointer (`x11rb`, on
  the watcher thread's own connection, reconnecting after a failure); window
  geometry cached, refreshed twice a second. Inert off X11. Visible on all
  workspaces. Tray item reads "Start at login" off Windows. Legacy-dir
  fallback limited to Windows, the only build that ever wrote there.
- Linux window made resizable at startup: GTK floors a non-resizable window
  at 200x200 (tauri#6125), which left the 52px panel in a 200px window. The
  grip stops short of tao's 5px edge-resize band that this arms.
- `scripts/build-linux.sh` builds the `.deb`; refuses if the harness fixture
  is present, mirroring the Windows staging exclusion.
- CI: Rust fmt + clippy as a Windows/Ubuntu matrix.

## Verified against the running window on XFCE/X11, not inferred
- 32-bit ARGB window; `_NET_WM_STATE` = ABOVE, STICKY, SKIP_TASKBAR,
  SKIP_PAGER; on all desktops.
- No WebKitGTK 2.54 + NVIDIA blank window (RTX 5060 Ti, driver 615.71), so
  no DMABUF workaround shipped.
- Height followed `set_height` (52px) once resizable.
- Click-through: the bar passes the pointer to the window below; the grip
  takes it. One input pixel remains at the top-left corner (tao's 1x1 region).
- Drag by synthesised press-move-release moved exactly (-100,-50); a press
  starting off the handle moved nothing; presses in the top and left edge
  bands beside the grip neither dragged nor resized.
- Idle CPU 0.93% of a core over 30s, down from 3.0% when every tick asked
  the main thread for cursor, position, size and scale.
- Stayed top of `_NET_CLIENT_LIST_STACKING` after another window was raised,
  and above the XFCE panel when the panel was revealed.
- Tray: registered with the StatusNotifierWatcher, icon drawn as the bar,
  menu renders all three items, "Reset position" landed at (1280,1028).
- Reading on screen matched the higher of two live sessions (0% and 1%).

- Installed `.deb`: first launch wrote `~/.config/autostart/klepsydra.desktop`
  with `Exec=/usr/bin/klepsydra`.

## Open
- Wayland unsupported: no global pointer, so the handle stays inert.

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    (cd src-tauri && cargo clippy --all-targets -- -D warnings)
    bash scripts/build-linux.sh
