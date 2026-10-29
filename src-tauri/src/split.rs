//! Split mode: the wall on the left half of its monitor's work area, the
//! `fleet` Windows Terminal window on the right. Off by default; the wall's
//! toggle turns it on, and prefs.json remembers it as `wall_split` (written
//! true only once a split lands). Turning it off puts both windows back where
//! they were. While on, a watcher turns it off as soon as either window leaves
//! its half, leaving both where they are; while off, another turns it on once
//! AJ snaps both into those halves himself (#182), moving nothing. The
//! arithmetic is `geometry`'s; the win32 calls here stay thin.

use crate::geometry::Rect;
use serde_json::{Map, Value};
use std::sync::Mutex;
use tauri::ipc::Channel;

/// The prefs.json key, beside `wall_density`.
pub const SPLIT_KEY: &str = "wall_split";

/// The wall's note when no Windows Terminal tab is titled `FLEET_TAB`.
#[cfg_attr(not(windows), allow(dead_code))]
pub const NOT_OPEN: &str =
    "The fleet terminal is not open, so nothing moved. Open it with + New session, then turn Split on.";

/// The note when a Windows Terminal window hides its tabs, so the fleet tab
/// may be among them.
#[cfg_attr(not(windows), allow(dead_code))]
const HIDDEN: &str = "Windows Terminal is hiding its tabs (full screen or focus mode), so the fleet terminal could not be found and nothing moved. Show the tabs, then turn Split on.";

const WINDOWS_ONLY: &str = "Split mode works on Windows only.";

/// The note for a failed lookup of the fleet terminal.
#[cfg_attr(not(windows), allow(dead_code))]
fn lookup_error(e: crate::jump::JumpError) -> String {
    use klepsydra_fleet::tabs::TabError;
    match e {
        crate::jump::JumpError::Tab(TabError::NoMatch(_)) => NOT_OPEN.to_string(),
        crate::jump::JumpError::Tab(TabError::Hidden) => HIDDEN.to_string(),
        e => e.to_string(),
    }
}

/// The saved choice: on only for a stored `true`; anything else, a missing
/// key or an unreadable prefs.json reads as off.
fn split_of(prefs: Option<&Map<String, Value>>) -> bool {
    prefs
        .and_then(|p| p.get(SPLIT_KEY)?.as_bool())
        .unwrap_or(false)
}

/// The saved choice, or an error off Windows, where the wall hides the toggle.
#[tauri::command]
pub fn get_split_mode(app: tauri::AppHandle) -> Result<bool, String> {
    if cfg!(windows) {
        let on = split_of(crate::read_prefs(&app).as_ref());
        // Saved off: Split turns on when AJ snaps the windows himself.
        #[cfg(windows)]
        if !on {
            watch_for_snap(&app);
        }
        Ok(on)
    } else {
        Err(WINDOWS_ONLY.into())
    }
}

/// The wall's window handle.
#[cfg(windows)]
fn wall_hwnd(app: &tauri::AppHandle) -> Option<isize> {
    use tauri::Manager;
    let wall = app.get_webview_window(crate::fleet::WALL)?;
    Some(wall.hwnd().ok()?.0 as isize)
}

/// What the watchers do when a window leaves the split or both are snapped
/// into it: set together, so a split AJ made by hand turns off as one the
/// toggle made does.
#[cfg(windows)]
fn callbacks(app: &tauri::AppHandle) {
    let to = app.clone();
    win::when_left(move |note| turned_off(&to, note));
    let to = app.clone();
    win::when_snapped(move |wall, terminal| turned_on(&to, wall, terminal));
}

/// While split is off, watch for AJ snapping both windows into it (#182).
#[cfg(windows)]
fn watch_for_snap(app: &tauri::AppHandle) {
    let Some(wall) = wall_hwnd(app) else {
        return;
    };
    callbacks(app);
    win::watch_for_snap(wall);
}

/// AJ snapped both windows into the split: saved on, the wall told, and the
/// split watched from now on as one klepsydra made. Nothing moves.
#[cfg_attr(not(windows), allow(dead_code))]
fn turned_on(app: &tauri::AppHandle, wall: isize, terminal: isize) {
    use tauri::Manager;
    crate::write_pref(app, SPLIT_KEY, Value::Bool(true));
    let follow = app.state::<Follow>();
    let channel = follow.0.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(c) = channel.as_ref() {
        if c.send(serde_json::json!({ "on": true, "note": SNAPPED }))
            .is_err()
        {
            log::warn!(
                "split: on, but the wall did not hear it; its toggle shows off until it reloads"
            );
        }
    }
    drop(channel);
    #[cfg(windows)]
    win::watch_split(wall, terminal);
    #[cfg(not(windows))]
    let _ = (wall, terminal);
}

/// The wall's end of the split: told when a window left it. One window, the
/// wall, so the newest subscription replaces the last.
#[derive(Default)]
pub struct Follow(Mutex<Option<Channel<Value>>>);

/// The wall hears from now on when a window leaves the split.
#[tauri::command]
pub fn split_subscribe(follow: tauri::State<'_, Follow>, on_message: Channel<Value>) {
    *follow.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(on_message);
}

/// A window left the split, so it is off: saved off and the wall told why.
/// Nothing is put back; both windows stay where AJ put them, and snapping
/// them back turns it on again.
#[cfg_attr(not(windows), allow(dead_code))]
fn turned_off(app: &tauri::AppHandle, note: String) {
    use tauri::Manager;
    crate::write_pref(app, SPLIT_KEY, Value::Bool(false));
    let follow = app.state::<Follow>();
    let channel = follow.0.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(c) = channel.as_ref() {
        if c.send(serde_json::json!({ "on": false, "note": note }))
            .is_err()
        {
            log::warn!(
                "split: off, but the wall did not hear it; its toggle shows on until it reloads"
            );
        }
    }
    drop(channel);
    #[cfg(windows)]
    watch_for_snap(app);
}

/// Stop watching before klepsydra exits: Tauri hides every window on its way
/// out, which would read as the wall closed and save split off.
pub fn quitting() {
    #[cfg(windows)]
    win::stop_watching();
}

/// Split (`on`) or put both windows back, and say what happened. Off the
/// main thread, as Jump is: UI Automation lists every top-level window,
/// the wall's own among them.
#[tauri::command]
pub async fn set_split_mode(app: tauri::AppHandle, on: bool) -> Result<String, String> {
    #[cfg(windows)]
    {
        use tauri::Manager;
        let wall = app
            .get_webview_window(crate::fleet::WALL)
            .ok_or("The wall is not open.")?;
        let hwnd = wall.hwnd().map_err(|e| e.to_string())?.0 as isize;
        callbacks(&app);
        let said = tauri::async_runtime::spawn_blocking(move || {
            if on {
                win::split(hwnd)
            } else {
                Ok(win::unsplit(hwnd))
            }
        })
        .await
        .map_err(|e| format!("Could not split: {e}"))
        .and_then(|said| said);
        crate::write_pref(&app, SPLIT_KEY, Value::Bool(saved_on(on, said.is_ok())));
        if !saved_on(on, said.is_ok()) {
            watch_for_snap(&app);
        }
        said
    }
    #[cfg(not(windows))]
    {
        let _ = (app, on);
        Err(WINDOWS_ONLY.into())
    }
}

/// The choice to save after a call to split (`on`) or not: on only once a
/// split has landed, so a saved on that fails when the wall opens (the
/// terminal not open) is not tried again, and its note not repeated, at every
/// open.
#[cfg_attr(not(windows), allow(dead_code))]
fn saved_on(on: bool, landed: bool) -> bool {
    on && landed
}

/// The split's moves in order, as (window, visible frame, stacked under):
/// the wall onto the left half keeping its place in the z-order, then the
/// terminal onto the right half stacked right under the wall, so a window
/// over the terminal cannot cover the right half.
#[cfg_attr(not(windows), allow(dead_code))]
fn moves(
    wall: isize,
    terminal: isize,
    work: crate::geometry::Rect,
) -> [(isize, crate::geometry::Rect, Option<isize>); 2] {
    let (left, right) = crate::geometry::halves(work);
    [(wall, left, None), (terminal, right, Some(wall))]
}

/// A saved placement's show command, without activating: putting a window
/// back must not take the focus from the wall. Maximized has no quiet form.
#[cfg_attr(not(windows), allow(dead_code))]
fn quiet_show(cmd: u32) -> u32 {
    const SHOWNORMAL: u32 = 1;
    const SHOWMINIMIZED: u32 = 2;
    const SHOWNOACTIVATE: u32 = 4;
    const SHOWMINNOACTIVE: u32 = 7;
    match cmd {
        SHOWNORMAL => SHOWNOACTIVATE,
        SHOWMINIMIZED => SHOWMINNOACTIVE,
        other => other,
    }
}

// SetWindowPos flags (winuser.h).
#[cfg_attr(not(windows), allow(dead_code))]
const SWP_NOZORDER: u32 = 0x0004;
#[cfg_attr(not(windows), allow(dead_code))]
const SWP_NOACTIVATE: u32 = 0x0010;
#[cfg_attr(not(windows), allow(dead_code))]
const SWP_NOOWNERZORDER: u32 = 0x0200;

/// The wall moves keeping its place in the z-order, without activating.
#[cfg_attr(not(windows), allow(dead_code))]
fn wall_pos_flags() -> u32 {
    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER
}

/// The terminal's last move: stacked right under the wall (the wall's handle
/// is hWndInsertAfter), so a window over the terminal cannot cover the right
/// half, still without activating.
#[cfg_attr(not(windows), allow(dead_code))]
fn terminal_pos_flags() -> u32 {
    SWP_NOACTIVATE | SWP_NOOWNERZORDER
}

/// Whether giving back a saved placement shown as `cmd` takes the
/// foreground: only maximized, which has no quiet form.
#[cfg_attr(not(windows), allow(dead_code))]
fn put_back_activates(cmd: u32) -> bool {
    const SHOWMAXIMIZED: u32 = 3;
    quiet_show(cmd) == SHOWMAXIMIZED
}

/// The show command and flags that take a maximized or minimized window to
/// its normal size without activating it, from its current `flags`. A window
/// maximized and then minimized is restored to normal, not maximized.
#[cfg_attr(not(windows), allow(dead_code))]
fn restore_placement(flags: u32) -> (u32, u32) {
    const SW_SHOWNOACTIVATE: u32 = 4;
    const WPF_RESTORETOMAXIMIZED: u32 = 2;
    (SW_SHOWNOACTIVATE, flags & !WPF_RESTORETOMAXIMIZED)
}

/// How far (physical px) an edge may drift from where the split left it and
/// still count as in place: a DPI change rounds an edge by a pixel or two.
#[cfg_attr(not(windows), allow(dead_code))]
const DRIFT_PX: i32 = 4;

/// How far (physical px) a window snapped by hand may sit from its half and
/// still count as in the split: Windows 11 snaps the visible frames edge to
/// edge, but rounds them by a few pixels at some scales.
#[cfg_attr(not(windows), allow(dead_code))]
const SNAP_PX: i32 = 8;

/// Whether visible frames `wall` and `terminal` sit as Split places them in
/// `work`: the wall on the left half, the terminal on the right, each edge
/// within `SNAP_PX`. A reversed or uneven snap is not the split.
#[cfg_attr(not(windows), allow(dead_code))]
fn in_split(work: Rect, wall: Rect, terminal: Rect) -> bool {
    let (left, right) = crate::geometry::halves(work);
    let near = |f: Rect, half: Rect| {
        [
            (f.x, half.x),
            (f.y, half.y),
            (f.right(), half.right()),
            (f.bottom(), half.bottom()),
        ]
        .iter()
        .all(|(a, b)| (a - b).abs() <= SNAP_PX)
    };
    near(wall, left) && near(terminal, right)
}

/// Whether a settled look at the windows turns split on: they are in the
/// split now and were not at the last look, so a layout already there when
/// watching began (or put back by turning split off) never counts.
#[cfg_attr(not(windows), allow(dead_code))]
fn snapped(was: bool, now: bool) -> bool {
    now && !was
}

/// The wall's note when AJ snapped both windows into the split.
#[cfg_attr(not(windows), allow(dead_code))]
const SNAPPED: &str = "Split on: the wall and the fleet terminal were snapped side by side.";

/// How a window left the split.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
enum Left {
    Closed,
    Hidden,
    Minimized,
    Maximized,
    Moved,
}

/// A window as the watcher reads it.
#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(windows), allow(dead_code))]
struct Seen {
    exists: bool,
    visible: bool,
    iconic: bool,
    zoomed: bool,
    /// The visible frame; None when DWM gives none, which says nothing.
    frame: Option<Rect>,
}

/// Whether a window held at `held` has left it, and how. A minimized
/// window's frame sits far off-screen, so the show state is read first.
#[cfg_attr(not(windows), allow(dead_code))]
fn left(held: Rect, seen: Seen) -> Option<Left> {
    let drifted = |f: Rect| {
        [
            (f.x, held.x),
            (f.y, held.y),
            (f.right(), held.right()),
            (f.bottom(), held.bottom()),
        ]
        .iter()
        .any(|(a, b)| (a - b).abs() > DRIFT_PX)
    };
    if !seen.exists {
        Some(Left::Closed)
    } else if seen.iconic {
        Some(Left::Minimized)
    } else if !seen.visible {
        Some(Left::Hidden)
    } else if seen.zoomed {
        Some(Left::Maximized)
    } else if seen.frame.is_some_and(drifted) {
        Some(Left::Moved)
    } else {
        None
    }
}

/// The wall's note when `who` left the split by `how`.
#[cfg_attr(not(windows), allow(dead_code))]
fn left_note(who: &str, how: Left) -> String {
    let did = match how {
        Left::Closed => "was closed",
        // A closing window is hidden before it is destroyed, so hidden reads as closed.
        Left::Hidden => "was closed",
        Left::Minimized => "was minimized",
        Left::Maximized => "was maximized",
        Left::Moved => "moved",
    };
    format!("Split off: {who} {did}, so both windows stay where they are.")
}

/// Whether to hand the foreground back after showing `moved`: Windows
/// activates a window restored from minimized even with SW_SHOWNOACTIVATE
/// (measured), and one put back maximized takes it too.
#[cfg_attr(not(windows), allow(dead_code))]
fn give_focus_back(before: isize, after: isize, moved: isize) -> bool {
    before != 0 && after == moved && before != moved
}

#[cfg(windows)]
mod win {
    use super::{
        give_focus_back, in_split, left, left_note, lookup_error, moves, put_back_activates,
        quiet_show, restore_placement, snapped, terminal_pos_flags, wall_pos_flags, Seen,
    };
    use crate::geometry::{frame_insets, widen, Insets, Rect};
    use std::sync::Mutex;
    use windows::Win32::Foundation::{HWND, LPARAM, RECT, WPARAM};
    use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::UI::HiDpi::{
        GetAwarenessFromDpiAwarenessContext, GetThreadDpiAwarenessContext,
        DPI_AWARENESS_PER_MONITOR_AWARE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetForegroundWindow, GetWindowPlacement, GetWindowRect, IsIconic, IsWindow,
        IsZoomed, SendMessageTimeoutW, SetForegroundWindow, SetWindowPlacement, SetWindowPos,
        SET_WINDOW_POS_FLAGS, SMTO_ABORTIFHUNG, WINDOWPLACEMENT, WINDOWPLACEMENT_FLAGS, WM_NULL,
    };

    const ON: &str = "Split: the wall on the left, the fleet terminal on the right.";
    const OFF: &str = "Split off: both windows are back where they were.";
    const HUNG: &str = "The fleet terminal is not responding, so nothing moved.";
    const STILL: &str = "A window stayed maximized or minimized, so both went back.";
    const NOT_AWARE: &str =
        "klepsydra is not per-monitor DPI aware here, so a split would misplace the windows.";
    /// How long (ms) a window has to answer before it counts as hung.
    const ANSWER_MS: u32 = 500;
    /// How long (ms) to wait for the foreground to settle, and how often to look.
    const SETTLE_MS: u64 = 250;
    const SETTLE_STEP_MS: u64 = 5;

    /// Each window's placement from before the split, with its handle as an
    /// integer (a placement is plain numbers, so this is Send). Taken on
    /// the way in (kept if the same window is split again) and given back on
    /// the way out; kept in memory only, so a restart forgets it. The lock is
    /// held only to read or change this, never across a call to a window.
    #[derive(Clone, Copy)]
    struct Saved {
        wall: Option<(isize, WINDOWPLACEMENT)>,
        terminal: Option<(isize, WINDOWPLACEMENT)>,
    }

    static SAVED: Mutex<Saved> = Mutex::new(Saved {
        wall: None,
        terminal: None,
    });

    fn saved() -> std::sync::MutexGuard<'static, Saved> {
        SAVED.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn hwnd(raw: isize) -> HWND {
        HWND(raw as *mut core::ffi::c_void)
    }

    fn rect(r: RECT) -> Rect {
        Rect::from_edges(r.left, r.top, r.right, r.bottom)
    }

    /// GetWindowRect and the DWM frame bounds agree only in physical pixels,
    /// which a per-monitor aware thread sees; tao makes the process so.
    fn per_monitor_aware() -> Result<(), String> {
        let awareness =
            unsafe { GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()) };
        if awareness == DPI_AWARENESS_PER_MONITOR_AWARE {
            Ok(())
        } else {
            Err(NOT_AWARE.into())
        }
    }

    /// Whether `h` answers a no-op message within `ANSWER_MS`: a call that
    /// waits on another process's window would otherwise hang on a hung one.
    fn responds(h: HWND) -> bool {
        let answered = unsafe {
            SendMessageTimeoutW(
                h,
                WM_NULL,
                WPARAM(0),
                LPARAM(0),
                SMTO_ABORTIFHUNG,
                ANSWER_MS,
                None,
            )
        };
        answered.0 != 0
    }

    fn answering(h: HWND) -> Result<(), String> {
        if responds(h) {
            Ok(())
        } else {
            Err(HUNG.into())
        }
    }

    /// The work area (the monitor less the taskbar) of the monitor `h` is on.
    fn work_area(h: HWND) -> Result<Rect, String> {
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let monitor = unsafe { MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST) };
        if unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
            Ok(rect(info.rcWork))
        } else {
            Err("Could not read the wall's monitor.".into())
        }
    }

    fn placement(h: HWND) -> Result<WINDOWPLACEMENT, String> {
        answering(h)?;
        let mut wp = WINDOWPLACEMENT {
            length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
            ..Default::default()
        };
        unsafe { GetWindowPlacement(h, &mut wp) }
            .map_err(|e| format!("Could not read a window's placement: {e}"))?;
        Ok(wp)
    }

    /// The visible frame of `h`: the DWM extended frame bounds.
    fn frame(h: HWND) -> Option<Rect> {
        let mut r = RECT::default();
        unsafe {
            DwmGetWindowAttribute(
                h,
                DWMWA_EXTENDED_FRAME_BOUNDS,
                &mut r as *mut RECT as *mut core::ffi::c_void,
                std::mem::size_of::<RECT>() as u32,
            )
        }
        .ok()?;
        Some(rect(r))
    }

    /// The invisible borders of `h`, as placed now; none when DWM gives no
    /// frame bounds, so the window is placed by its rect alone.
    fn insets(h: HWND) -> Insets {
        let mut window = RECT::default();
        match (unsafe { GetWindowRect(h, &mut window) }.is_ok(), frame(h)) {
            (true, Some(f)) => frame_insets(rect(window), f),
            _ => Insets::default(),
        }
    }

    fn set_rect(h: HWND, r: Rect, after: Option<HWND>, flags: u32) -> Result<(), String> {
        answering(h)?;
        unsafe { SetWindowPos(h, after, r.x, r.y, r.w, r.h, SET_WINDOW_POS_FLAGS(flags)) }
            .map_err(|e| format!("Could not move a window: {e}"))
    }

    fn sized(h: HWND) -> bool {
        unsafe { IsIconic(h).as_bool() || IsZoomed(h).as_bool() }
    }

    /// Put `h`'s visible frame on `visible`. A maximized or minimized window
    /// is first shown normal through its own placement, without activating
    /// it; one that stays so is an error. It moves there once so its borders
    /// are measured at that monitor's DPI, then again widened by them, last
    /// stacked under `under` when given.
    fn place(h: HWND, visible: Rect, under: Option<HWND>) -> Result<(), String> {
        if sized(h) {
            // Restored from minimized, Windows activates it anyway (measured).
            let minimized = unsafe { IsIconic(h) }.as_bool();
            let mut wp = placement(h)?;
            let (show, flags) = restore_placement(wp.flags.0);
            wp.showCmd = show;
            wp.flags = WINDOWPLACEMENT_FLAGS(flags);
            let before = settled_foreground();
            answering(h)?;
            unsafe { SetWindowPlacement(h, &wp) }
                .map_err(|e| format!("Could not restore a window: {e}"))?;
            hand_back(before, h, minimized);
            if sized(h) {
                return Err(STILL.into());
            }
        }
        set_rect(h, visible, None, wall_pos_flags())?;
        let last = widen(visible, insets(h));
        match under {
            Some(wall) => set_rect(h, last, Some(wall), terminal_pos_flags()),
            None => set_rect(h, last, None, wall_pos_flags()),
        }
    }

    fn foreground() -> isize {
        unsafe { GetForegroundWindow() }.0 as isize
    }

    /// The foreground window once it has one: it reads none while activation
    /// passes between windows (a window just minimized hands it on), and a
    /// window restored then takes it with no one to give it back to. None
    /// after `SETTLE_MS` means no window has it.
    fn settled_foreground() -> isize {
        let start = std::time::Instant::now();
        loop {
            let fg = foreground();
            if fg != 0 || start.elapsed() >= std::time::Duration::from_millis(SETTLE_MS) {
                return fg;
            }
            std::thread::sleep(std::time::Duration::from_millis(SETTLE_STEP_MS));
        }
    }

    /// The foreground once `moved` has it, or after `SETTLE_MS`: another
    /// process's window takes it when its own thread gets to it.
    fn taken_by(moved: isize) -> isize {
        let start = std::time::Instant::now();
        loop {
            let fg = foreground();
            if fg == moved || start.elapsed() >= std::time::Duration::from_millis(SETTLE_MS) {
                return fg;
            }
            std::thread::sleep(std::time::Duration::from_millis(SETTLE_STEP_MS));
        }
    }

    /// Give the foreground back to `before` if showing `moved` took it;
    /// `expected` when the show is one that takes it, so it is waited for.
    fn hand_back(before: isize, moved: HWND, expected: bool) {
        let raw = moved.0 as isize;
        let after = if expected {
            taken_by(raw)
        } else {
            foreground()
        };
        if give_focus_back(before, after, raw) && exists(before) {
            let _ = unsafe { SetForegroundWindow(hwnd(before)) };
        }
    }

    /// A placement saved before the split, given back: rcNormalPosition is in
    /// workspace coordinates, so it goes straight to SetWindowPlacement.
    fn put_back(h: HWND, mut wp: WINDOWPLACEMENT) -> bool {
        wp.showCmd = quiet_show(wp.showCmd);
        responds(h) && unsafe { SetWindowPlacement(h, &wp) }.is_ok()
    }

    fn is_terminal(h: HWND) -> bool {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(h, &mut class) } as usize;
        String::from_utf16_lossy(&class[..n.min(class.len())]) == crate::jump::TERMINAL_CLASS
    }

    fn exists(raw: isize) -> bool {
        unsafe { IsWindow(Some(hwnd(raw))).as_bool() }
    }

    /// Give back what was saved, skipping a window that closed meanwhile (or
    /// a handle now another program's); whether anything moved. The
    /// foreground goes back to whoever had it if the terminal took it.
    fn restore(was: Saved, wall: isize) -> bool {
        let before = settled_foreground();
        let mut moved = false;
        if let Some((raw, wp)) = was.wall {
            if raw == wall && exists(raw) {
                moved |= put_back(hwnd(raw), wp);
            }
        }
        if let Some((raw, wp)) = was.terminal {
            if exists(raw) && is_terminal(hwnd(raw)) {
                moved |= put_back(hwnd(raw), wp);
                hand_back(before, hwnd(raw), put_back_activates(wp.showCmd));
            }
        }
        moved
    }

    /// Take what is saved, leaving nothing.
    fn take() -> Saved {
        let mut s = saved();
        let was = *s;
        *s = Saved {
            wall: None,
            terminal: None,
        };
        was
    }

    pub fn split(wall: isize) -> Result<String, String> {
        // The split's own moves never count as leaving it.
        let generation = watch::disarm();
        per_monitor_aware()?;
        let terminal = crate::jump::fleet_window().map_err(lookup_error)?;
        let (w, t) = (hwnd(wall), hwnd(terminal));
        let work = work_area(w)?;
        // Both read before either is kept, so a failed read keeps nothing.
        let (before_w, before_t) = (placement(w)?, placement(t)?);
        {
            let mut s = saved();
            if s.wall.map(|(h, _)| h) != Some(wall) {
                s.wall = Some((wall, before_w));
            }
            if s.terminal.map(|(h, _)| h) != Some(terminal) {
                s.terminal = Some((terminal, before_t));
            }
        }
        let placed = moves(wall, terminal, work)
            .into_iter()
            .try_for_each(|(h, r, under)| place(hwnd(h), r, under.map(hwnd)));
        if let Err(e) = placed {
            // Half a split is no split: both go back.
            restore(take(), wall);
            return Err(e);
        }
        watch::arm(generation, wall, terminal);
        Ok(ON.into())
    }

    pub fn unsplit(wall: isize) -> String {
        watch::disarm();
        if restore(take(), wall) {
            OFF.into()
        } else {
            "Split off.".into()
        }
    }

    pub use watch::{when_left, when_snapped};

    pub fn stop_watching() {
        watch::quit();
    }

    /// While split is off: watch for AJ snapping the wall and the fleet
    /// terminal into the split himself (`watch::arm_snap`).
    pub fn watch_for_snap(wall: isize) {
        let generation = watch::disarm();
        watch::arm_snap(
            generation,
            wall,
            Box::new(|| crate::jump::fleet_window_quiet().ok()),
        );
    }

    /// Watch a split AJ made himself, as one klepsydra made: nothing is saved
    /// to put back, so turning it off later moves nothing.
    pub fn watch_split(wall: isize, terminal: isize) {
        let generation = watch::disarm();
        watch::arm(generation, wall, terminal);
    }

    /// Whether `wall` and `terminal` are both shown normal on one monitor, in
    /// the split's halves of its work area.
    fn in_split_now(wall: isize, terminal: isize) -> bool {
        let (w, t) = (seen(hwnd(wall)), seen(hwnd(terminal)));
        let normal = |s: &Seen| s.exists && s.visible && !s.iconic && !s.zoomed;
        if !(normal(&w) && normal(&t)) {
            return false;
        }
        let (Some(fw), Some(ft)) = (w.frame, t.frame) else {
            return false;
        };
        let monitor = |h: isize| unsafe { MonitorFromWindow(hwnd(h), MONITOR_DEFAULTTONEAREST) };
        if monitor(wall) != monitor(terminal) {
            return false;
        }
        work_area(hwnd(wall)).is_ok_and(|work| in_split(work, fw, ft))
    }

    /// A window as it is now.
    fn seen(h: HWND) -> Seen {
        use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;
        let exists = exists(h.0 as isize);
        Seen {
            exists,
            visible: exists && unsafe { IsWindowVisible(h) }.as_bool(),
            iconic: exists && unsafe { IsIconic(h) }.as_bool(),
            zoomed: exists && unsafe { IsZoomed(h) }.as_bool(),
            frame: if exists { frame(h) } else { None },
        }
    }

    /// The watcher: while split is on, a thread of its own hooks the two
    /// windows' location, show-state and destroy events (SetWinEventHook, out
    /// of context, so the events come to that thread's message loop and the
    /// UI thread never wakes for them) and turns split off the moment either
    /// leaves its half. Each split or unsplit starts a new generation, which
    /// ends the last watcher, so the app's own moves are never seen as AJ's.
    mod watch {
        use super::{
            exists, hwnd, in_split_now, is_terminal, left, left_note, saved, seen, snapped, Rect,
        };
        use std::cell::{Cell, RefCell};
        use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
        use std::sync::{Mutex, OnceLock};
        use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
        use windows::Win32::System::Threading::GetCurrentThreadId;
        use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
        use windows::Win32::UI::WindowsAndMessaging::{
            GetMessageW, GetWindowThreadProcessId, KillTimer, PeekMessageW, PostQuitMessage,
            PostThreadMessageW, SetTimer, MSG, PM_NOREMOVE, WM_QUIT, WM_TIMER,
        };

        // WinEvents (winuser.h).
        const EVENT_SYSTEM_MOVESIZEEND: u32 = 0x000B;
        const EVENT_SYSTEM_MINIMIZESTART: u32 = 0x0016;
        const EVENT_OBJECT_DESTROY: u32 = 0x8001;
        const EVENT_OBJECT_SHOW: u32 = 0x8002;
        const EVENT_OBJECT_HIDE: u32 = 0x8003;
        const EVENT_OBJECT_LOCATIONCHANGE: u32 = 0x800B;
        const WINEVENT_OUTOFCONTEXT: u32 = 0;
        const OBJID_WINDOW: i32 = 0;
        const CHILDID_SELF: i32 = 0;
        /// How long (ms) after the split's last move before watching starts:
        /// a window crossing to another DPI resizes itself once more.
        const ARM_AFTER_MS: u64 = 500;

        /// Bumped by every split, unsplit and leave; a watcher whose
        /// generation is not current has nothing to watch.
        static GENERATION: AtomicU64 = AtomicU64::new(0);
        /// The running watcher's thread, to end it.
        static WATCHER: Mutex<Option<u32>> = Mutex::new(None);
        /// klepsydra is exiting: no watcher starts again (Tauri hides every
        /// window on its way out, which a split watcher would read as closed).
        static QUITTING: AtomicBool = AtomicBool::new(false);

        /// End any watcher for good, before exit.
        pub fn quit() {
            QUITTING.store(true, Ordering::SeqCst);
            disarm();
        }
        type OnLeft = Box<dyn Fn(String) + Send + Sync>;
        static ON_LEFT: OnceLock<OnLeft> = OnceLock::new();

        /// Set once what to do when a window leaves the split.
        pub fn when_left(f: impl Fn(String) + Send + Sync + 'static) {
            let _ = ON_LEFT.set(Box::new(f));
        }

        type OnSnapped = Box<dyn Fn(isize, isize) + Send + Sync>;
        static ON_SNAPPED: OnceLock<OnSnapped> = OnceLock::new();

        /// Set once what to do when AJ snaps both windows into the split
        /// (given the wall and the terminal).
        pub fn when_snapped(f: impl Fn(isize, isize) + Send + Sync + 'static) {
            let _ = ON_SNAPPED.set(Box::new(f));
        }

        /// How long (ms) both windows must sit still after a move before the
        /// layout is read: a snap animates, and Snap Assist places the second
        /// window a moment after the first.
        const SNAP_SETTLE_MS: u32 = 1000;

        type Find = Box<dyn Fn() -> Option<isize> + Send>;

        /// The snap watcher's state, on its own thread.
        struct Snap {
            generation: u64,
            wall: isize,
            /// The fleet terminal, looked up again at a settle when unknown or gone.
            terminal: Option<isize>,
            /// The threads whose windows' events are hooked.
            hooked: Vec<u32>,
            hooks: Vec<HWINEVENTHOOK>,
            /// While the terminal is unknown: any Windows Terminal window shown
            /// or moved, on every thread, starts a settle (a terminal opened
            /// and snapped beside a wall already in place moves no wall).
            any: Vec<HWINEVENTHOOK>,
            /// Whether the windows were in the split at the last look.
            was: bool,
        }

        thread_local! {
            static SNAP: RefCell<Option<Snap>> = const { RefCell::new(None) };
            static TIMER: Cell<usize> = const { Cell::new(0) };
        }

        /// Hook the move and resize events of the windows on `h`'s thread.
        fn hook_snap(snap: &mut Snap, h: isize) {
            let thread = unsafe { GetWindowThreadProcessId(hwnd(h), None) };
            if thread == 0 || snap.hooked.contains(&thread) {
                return;
            }
            snap.hooked.push(thread);
            // A close (destroy, hide) starts a settle too, which finds the
            // terminal gone and watches every thread for the next one.
            for (min, max) in [
                (EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND),
                (EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE),
                (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE),
            ] {
                let hook = unsafe {
                    SetWinEventHook(
                        min,
                        max,
                        None,
                        Some(on_snap_event),
                        0,
                        thread,
                        WINEVENT_OUTOFCONTEXT,
                    )
                };
                if hook.is_invalid() {
                    log::warn!(
                        "split: could not hook a window's moves, so a hand-made split is not seen"
                    );
                } else {
                    snap.hooks.push(hook);
                }
            }
        }

        /// Hook, or unhook, every thread's Windows Terminal windows being shown
        /// or moved, as the terminal is unknown or known.
        fn watch_any_terminal(snap: &mut Snap) {
            if snap.terminal.is_some() {
                for hook in snap.any.drain(..) {
                    let _ = unsafe { UnhookWinEvent(hook) };
                }
                return;
            }
            if !snap.any.is_empty() {
                return;
            }
            for event in [EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE] {
                let hook = unsafe {
                    SetWinEventHook(
                        event,
                        event,
                        None,
                        Some(on_any_terminal),
                        0,
                        0,
                        WINEVENT_OUTOFCONTEXT,
                    )
                };
                if !hook.is_invalid() {
                    snap.any.push(hook);
                }
            }
        }

        /// Start the settle again: each move replaces the same timer.
        fn restart_settle() {
            let id = TIMER.with(|t| t.get());
            let id = unsafe { SetTimer(None, id, SNAP_SETTLE_MS, None) };
            TIMER.with(|t| t.set(id));
        }

        unsafe extern "system" fn on_any_terminal(
            _hook: HWINEVENTHOOK,
            _event: u32,
            h: HWND,
            object: i32,
            child: i32,
            _thread: u32,
            _ms: u32,
        ) {
            if object == OBJID_WINDOW && child == CHILDID_SELF && is_terminal(h) {
                restart_settle();
            }
        }

        /// While split is off, watch the wall and the terminal `find` names
        /// (and names again once it is gone). Once both have sat still for
        /// `SNAP_SETTLE_MS` after a move, in the split's halves where they
        /// were not at the last look, split is on: `ON_SNAPPED`. Nothing
        /// moves. Ended, like the split watcher, by the next generation.
        pub fn arm_snap(generation: u64, wall: isize, find: Find) {
            if QUITTING.load(Ordering::SeqCst) {
                return;
            }
            let spawned = std::thread::Builder::new()
                .name("split-snap".into())
                .spawn(move || run_snap(generation, wall, find));
            if let Err(e) = spawned {
                log::warn!("split: not watching for a hand-made split: {e}");
            }
        }

        fn run_snap(generation: u64, wall: isize, find: Find) {
            std::thread::sleep(std::time::Duration::from_millis(ARM_AFTER_MS));
            let terminal = find();
            let mut snap = Snap {
                generation,
                wall,
                terminal,
                hooked: Vec::new(),
                hooks: Vec::new(),
                any: Vec::new(),
                was: terminal.is_some_and(|t| in_split_now(wall, t)),
            };
            let mut msg = MSG::default();
            let _ = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE) };
            hook_snap(&mut snap, wall);
            if let Some(t) = terminal {
                hook_snap(&mut snap, t);
            }
            watch_any_terminal(&mut snap);
            SNAP.with(|s| *s.borrow_mut() = Some(snap));
            let named = {
                let mut w = watcher();
                let current = GENERATION.load(Ordering::SeqCst) == generation;
                if current {
                    *w = Some(unsafe { GetCurrentThreadId() });
                }
                current
            };
            if named {
                log::debug!("split: watching for a hand-made split");
                while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
                    if msg.message == WM_TIMER && msg.hwnd.is_invalid() {
                        settled(&find);
                    }
                }
            }
            let left = SNAP.with(|s| s.borrow_mut().take());
            for hook in left.map(|s| [s.hooks, s.any].concat()).unwrap_or_default() {
                let _ = unsafe { UnhookWinEvent(hook) };
            }
            let timer = TIMER.with(|t| t.replace(0));
            if timer != 0 {
                let _ = unsafe { KillTimer(None, timer) };
            }
            forget_me();
        }

        unsafe extern "system" fn on_snap_event(
            _hook: HWINEVENTHOOK,
            _event: u32,
            h: HWND,
            object: i32,
            child: i32,
            _thread: u32,
            _ms: u32,
        ) {
            if object != OBJID_WINDOW || child != CHILDID_SELF {
                return;
            }
            let raw = h.0 as isize;
            let ours = SNAP.with(|s| {
                s.try_borrow()
                    .ok()
                    .and_then(|s| s.as_ref().map(|s| raw == s.wall || s.terminal == Some(raw)))
                    .unwrap_or(false)
            });
            // A move that comes while `settled` holds the state (if UI Automation
            // pumps sent messages during its lookup) is dropped: the layout is
            // read after the lookup anyway.
            if ours {
                restart_settle();
            }
        }

        /// The windows have sat still: read the layout, and turn split on if
        /// they have just come into it.
        fn settled(find: &Find) {
            let id = TIMER.with(|t| t.replace(0));
            if id != 0 {
                let _ = unsafe { KillTimer(None, id) };
            }
            let fire = SNAP.with(|s| {
                let mut s = s.try_borrow_mut().ok()?;
                let snap = s.as_mut()?;
                if !snap.terminal.is_some_and(exists) {
                    snap.terminal = find();
                    if let Some(t) = snap.terminal {
                        hook_snap(snap, t);
                    }
                    watch_any_terminal(snap);
                }
                let now = snap.terminal.is_some_and(|t| in_split_now(snap.wall, t));
                let fire = snapped(snap.was, now);
                snap.was = now;
                fire.then(|| (snap.generation, snap.wall, snap.terminal.unwrap_or(0)))
            });
            let Some((generation, wall, terminal)) = fire else {
                return;
            };
            // A split or unsplit that starts now either ends this generation
            // first or comes after it.
            let current = {
                let mut s = saved();
                let current = GENERATION
                    .compare_exchange(
                        generation,
                        generation + 1,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    )
                    .is_ok();
                if current {
                    // AJ placed them: turning split off puts nothing back.
                    s.wall = None;
                    s.terminal = None;
                }
                current
            };
            unsafe { PostQuitMessage(0) };
            if !current {
                return;
            }
            forget_me();
            log::info!("split: on, the wall and the fleet terminal were snapped into its halves");
            if let Some(f) = ON_SNAPPED.get() {
                f(wall, terminal);
            }
        }

        /// The two windows and where the split left them, on the watcher's
        /// thread, where its hook callback reads them.
        struct Held {
            generation: u64,
            windows: [(&'static str, isize, Rect); 2],
        }

        thread_local! {
            static HELD: RefCell<Option<Held>> = const { RefCell::new(None) };
        }

        fn watcher() -> std::sync::MutexGuard<'static, Option<u32>> {
            WATCHER.lock().unwrap_or_else(|e| e.into_inner())
        }

        /// End any watcher and start a new generation, returned.
        pub fn disarm() -> u64 {
            let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
            // Posted under the lock: the watcher clears its id under it before
            // exiting, so the id cannot pass to a new thread in between.
            let mut w = watcher();
            if let Some(thread) = w.take() {
                let _ = unsafe { PostThreadMessageW(thread, WM_QUIT, WPARAM(0), LPARAM(0)) };
            }
            drop(w);
            generation
        }

        /// Watch the split `generation` placed, once it has settled.
        pub fn arm(generation: u64, wall: isize, terminal: isize) {
            if QUITTING.load(Ordering::SeqCst) {
                return;
            }
            let spawned = std::thread::Builder::new()
                .name("split-watch".into())
                .spawn(move || run(generation, wall, terminal));
            if let Err(e) = spawned {
                log::warn!("split: not watched, so it will not turn itself off: {e}");
            }
        }

        fn run(generation: u64, wall: isize, terminal: isize) {
            std::thread::sleep(std::time::Duration::from_millis(ARM_AFTER_MS));
            let frame = |h: isize| seen(hwnd(h)).frame;
            let (Some(w), Some(t)) = (frame(wall), frame(terminal)) else {
                log::warn!(
                    "split: a window has no frame to watch, so split will not turn itself off"
                );
                return;
            };
            HELD.with(|held| {
                *held.borrow_mut() = Some(Held {
                    generation,
                    windows: [("the wall", wall, w), ("the fleet terminal", terminal, t)],
                })
            });
            // A queue for WM_QUIT before this thread is named as the watcher.
            let mut msg = MSG::default();
            let _ = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE) };
            let mut hooks = Vec::new();
            for h in [wall, terminal] {
                let thread = unsafe { GetWindowThreadProcessId(hwnd(h), None) };
                for (min, max) in [
                    (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZESTART),
                    (EVENT_OBJECT_DESTROY, EVENT_OBJECT_LOCATIONCHANGE),
                ] {
                    let hook = unsafe {
                        SetWinEventHook(
                            min,
                            max,
                            None,
                            Some(on_event),
                            0,
                            thread,
                            WINEVENT_OUTOFCONTEXT,
                        )
                    };
                    if hook.is_invalid() {
                        log::warn!("split: could not hook a window's events, so split will not turn itself off");
                    } else {
                        hooks.push(hook);
                    }
                }
            }
            let named = {
                let mut w = watcher();
                // A split or unsplit since then leaves this watcher nothing to do.
                let current = GENERATION.load(Ordering::SeqCst) == generation;
                if current {
                    *w = Some(unsafe { GetCurrentThreadId() });
                }
                current
            };
            if named && hooks.len() == 4 {
                log::debug!("split: watching both windows");
                // Moved while settling: it left before the hooks were in.
                check(None);
                while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {}
            }
            for hook in hooks {
                let _ = unsafe { UnhookWinEvent(hook) };
            }
            forget_me();
        }

        /// Clear the watcher's thread id if it is this thread's: a stale id
        /// would have the next disarm post WM_QUIT to whichever thread reuses it.
        fn forget_me() {
            let me = unsafe { GetCurrentThreadId() };
            let mut w = watcher();
            if *w == Some(me) {
                *w = None;
            }
        }

        unsafe extern "system" fn on_event(
            _hook: HWINEVENTHOOK,
            event: u32,
            h: HWND,
            object: i32,
            child: i32,
            _thread: u32,
            _ms: u32,
        ) {
            if object == OBJID_WINDOW && child == CHILDID_SELF {
                check(Some((h.0 as isize, event)));
            }
        }

        /// Whether either window left its half, `event` being the one that
        /// woke the watcher; if so split goes off and the watcher ends.
        fn check(event: Option<(isize, u32)>) {
            let gone = HELD.with(|held| {
                // A window call below never pumps messages, but a re-entered
                // callback must not panic across the FFI boundary.
                let held = held.try_borrow().ok()?;
                let held = held.as_ref()?;
                if let Some((h, _)) = event {
                    if !held.windows.iter().any(|(_, w, _)| *w == h) {
                        return None;
                    }
                }
                held.windows.iter().find_map(|(who, w, at)| {
                    let destroyed = event == Some((*w, EVENT_OBJECT_DESTROY));
                    let mut now = seen(hwnd(*w));
                    now.exists &= !destroyed;
                    left(*at, now).map(|how| (held.generation, *who, how))
                })
            });
            let Some((generation, who, how)) = gone else {
                return;
            };
            // Under the saved placements' lock, so a split that starts now
            // either ends this generation first or saves after the clear.
            let current = {
                let mut s = saved();
                let current = GENERATION
                    .compare_exchange(
                        generation,
                        generation + 1,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    )
                    .is_ok();
                if current {
                    // Nothing goes back on the next unsplit but what the next
                    // split finds.
                    s.wall = None;
                    s.terminal = None;
                }
                current
            };
            HELD.with(|held| {
                if let Ok(mut held) = held.try_borrow_mut() {
                    *held = None;
                }
            });
            unsafe { PostQuitMessage(0) };
            if !current {
                return;
            }
            forget_me();
            log::info!(window = who, how = format!("{how:?}"); "split: off, a window left its half; both stay where they are");
            if let Some(f) = ON_LEFT.get() {
                f(left_note(who, how));
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::geometry::halves;
        use windows::core::w;
        use windows::Win32::UI::HiDpi::{
            SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        use windows::Win32::UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, ShowWindow, SW_MINIMIZE, SW_SHOWMAXIMIZED,
            WINDOW_EX_STYLE, WPF_RESTORETOMAXIMIZED, WS_OVERLAPPEDWINDOW,
        };

        /// A top-level window this test made, destroyed when dropped. The
        /// test moves only this window.
        struct Own(HWND);

        impl Drop for Own {
            fn drop(&mut self) {
                let _ = unsafe { DestroyWindow(self.0) };
            }
        }

        /// The watcher's notes, in order; tests that arm it take `ONE` first,
        /// since the generation and the note sink are process-wide.
        static NOTES: Mutex<Vec<String>> = Mutex::new(Vec::new());
        static ONE: Mutex<()> = Mutex::new(());

        fn throwaway(x: i32) -> Own {
            use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNOACTIVATE;
            let own = Own(unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    w!("STATIC"),
                    w!("klepsydra split watch test"),
                    WS_OVERLAPPEDWINDOW,
                    x,
                    120,
                    400,
                    300,
                    None,
                    None,
                    None,
                    None,
                )
            }
            .expect("a throwaway window"));
            unsafe {
                let _ = ShowWindow(own.0, SW_SHOWNOACTIVATE);
            }
            own
        }

        /// The notes said within `ms`, once at least one is in.
        fn notes_within(ms: u64) -> Vec<String> {
            let start = std::time::Instant::now();
            while start.elapsed() < std::time::Duration::from_millis(ms) {
                if !NOTES.lock().unwrap().is_empty() {
                    // A second note would come right behind the first.
                    std::thread::sleep(std::time::Duration::from_millis(200));
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            std::mem::take(&mut *NOTES.lock().unwrap())
        }

        /// Two windows "split" and watched, then `leave` done to them.
        fn watched(leave: impl FnOnce(HWND, HWND)) -> Vec<String> {
            let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
            unsafe {
                SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            }
            watch::when_left(|note| NOTES.lock().unwrap().push(note));
            NOTES.lock().unwrap().clear();
            let (wall, terminal) = (throwaway(100), throwaway(520));
            let generation = watch::disarm();
            watch::arm(generation, wall.0 .0 as isize, terminal.0 .0 as isize);
            // Past the settle and the hooks going in.
            std::thread::sleep(std::time::Duration::from_millis(1200));
            leave(wall.0, terminal.0);
            let said = notes_within(2000);
            watch::disarm();
            said
        }

        fn nudge(h: HWND, dx: i32, dw: i32) {
            let f = frame(h).unwrap();
            let r = widen(Rect::new(f.x + dx, f.y, f.w + dw, f.h), insets(h));
            set_rect(h, r, None, wall_pos_flags()).unwrap();
        }

        #[test]
        fn each_way_of_leaving_turns_split_off_once_and_says_which_window() {
            use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
            let t = "the fleet terminal";
            for (case, leave, expected) in [
                (
                    "drag",
                    Box::new(|_, t| nudge(t, 60, 0)) as Box<dyn FnOnce(HWND, HWND)>,
                    format!("Split off: {t} moved, so both windows stay where they are."),
                ),
                (
                    "resize",
                    Box::new(|_, t| nudge(t, 0, -80)),
                    format!("Split off: {t} moved, so both windows stay where they are."),
                ),
                (
                    "maximize",
                    Box::new(|_, t| unsafe {
                        let _ = ShowWindow(t, SW_SHOWMAXIMIZED);
                    }),
                    format!("Split off: {t} was maximized, so both windows stay where they are."),
                ),
                (
                    "minimize",
                    Box::new(|_, t| unsafe {
                        let _ = ShowWindow(t, SW_MINIMIZE);
                    }),
                    format!("Split off: {t} was minimized, so both windows stay where they are."),
                ),
                (
                    "close",
                    Box::new(|_, t| unsafe {
                        let _ = DestroyWindow(t);
                    }),
                    format!("Split off: {t} was closed, so both windows stay where they are."),
                ),
                (
                    "wall dragged",
                    Box::new(|w, _| nudge(w, -60, 0)),
                    "Split off: the wall moved, so both windows stay where they are.".to_string(),
                ),
                (
                    "wall closed (hidden)",
                    Box::new(|w, _| unsafe {
                        let _ = ShowWindow(w, SW_HIDE);
                    }),
                    "Split off: the wall was closed, so both windows stay where they are."
                        .to_string(),
                ),
            ] {
                assert_eq!(watched(leave), vec![expected], "{case}");
            }
        }

        #[test]
        fn the_split_settling_or_a_moved_back_window_never_turns_it_off() {
            let quiet = [
                (
                    "a no-op move",
                    Box::new(|_, t| nudge(t, 0, 0)) as Box<dyn FnOnce(HWND, HWND)>,
                ),
                ("a DPI rounding", Box::new(|_, t| nudge(t, 2, -1))),
                (
                    "an unsplit before AJ moves",
                    Box::new(|_, t| {
                        watch::disarm();
                        nudge(t, 60, 0);
                    }),
                ),
            ];
            for (case, leave) in quiet {
                assert!(watched(leave).is_empty(), "{case}");
            }
            // A window moved by the split itself, before the watch is armed.
            let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
            NOTES.lock().unwrap().clear();
            let (wall, terminal) = (throwaway(100), throwaway(520));
            let generation = watch::disarm();
            watch::arm(generation, wall.0 .0 as isize, terminal.0 .0 as isize);
            nudge(terminal.0, 30, 0);
            assert!(
                notes_within(1500).is_empty(),
                "the settle is the split's own"
            );
            watch::disarm();
        }

        /// What the snap watcher reported, in order.
        static SNAPS: Mutex<Vec<(isize, isize)>> = Mutex::new(Vec::new());

        /// Two windows, watched for a hand-made split from where `start`
        /// leaves them, then `snap` done to them; what the watcher reported
        /// within 3 s.
        fn snap_watched(
            start: impl FnOnce(HWND, HWND),
            snap: impl FnOnce(HWND, HWND),
        ) -> Vec<(isize, isize)> {
            let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
            unsafe {
                SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            }
            watch::when_snapped(|w, t| SNAPS.lock().unwrap().push((w, t)));
            SNAPS.lock().unwrap().clear();
            let (wall, terminal) = (throwaway(100), throwaway(520));
            start(wall.0, terminal.0);
            let t = terminal.0 .0 as isize;
            let generation = watch::disarm();
            watch::arm_snap(generation, wall.0 .0 as isize, Box::new(move || Some(t)));
            std::thread::sleep(std::time::Duration::from_millis(1200));
            snap(wall.0, terminal.0);
            let start = std::time::Instant::now();
            while start.elapsed() < std::time::Duration::from_secs(3)
                && SNAPS.lock().unwrap().is_empty()
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            watch::disarm();
            std::mem::take(&mut *SNAPS.lock().unwrap())
        }

        fn into_halves(w: HWND, t: HWND) {
            let (l, r) = halves(work_area(w).unwrap());
            place(w, l, None).unwrap();
            place(t, r, None).unwrap();
        }

        #[test]
        fn snapping_both_windows_into_the_split_turns_it_on_once_moving_nothing() {
            let got = snap_watched(|_, _| {}, into_halves);
            assert_eq!(got.len(), 1, "turned on once");
            assert_ne!(got[0].1, 0, "with the terminal it found");
        }

        /// A Windows Terminal-class window on a thread of its own, pumping
        /// messages until told to stop: a terminal the watcher's hooks on the
        /// wall's thread cannot see.
        fn terminal_on_its_own_thread() -> (isize, std::thread::JoinHandle<()>, u32) {
            use std::sync::mpsc;
            use windows::core::w;
            use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
            use windows::Win32::UI::WindowsAndMessaging::{
                DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW, TranslateMessage,
                MSG, SW_SHOWNOACTIVATE, WNDCLASSW,
            };
            unsafe extern "system" fn proc_(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
                unsafe { DefWindowProcW(h, m, w, l) }
            }
            let (tx, rx) = mpsc::channel();
            let owner = std::thread::spawn(move || {
                let class = WNDCLASSW {
                    lpfnWndProc: Some(proc_),
                    lpszClassName: w!("CASCADIA_HOSTING_WINDOW_CLASS"),
                    ..Default::default()
                };
                unsafe { RegisterClassW(&class) };
                let h = unsafe {
                    CreateWindowExW(
                        WINDOW_EX_STYLE(0),
                        w!("CASCADIA_HOSTING_WINDOW_CLASS"),
                        w!("klepsydra snap test terminal"),
                        WS_OVERLAPPEDWINDOW,
                        900,
                        200,
                        400,
                        300,
                        None,
                        None,
                        None,
                        None,
                    )
                }
                .expect("a terminal-class window");
                unsafe {
                    let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
                }
                let me = unsafe { windows::Win32::System::Threading::GetCurrentThreadId() };
                tx.send((h.0 as isize, me)).unwrap();
                let mut msg = MSG::default();
                while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
                    unsafe {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                }
                let _ = unsafe { DestroyWindow(h) };
            });
            let (h, thread) = rx.recv().unwrap();
            (h, owner, thread)
        }

        #[test]
        fn a_terminal_found_only_once_it_is_snapped_beside_the_wall_turns_split_on() {
            use std::sync::atomic::{AtomicIsize, Ordering};
            use std::sync::Arc;
            use windows::Win32::Foundation::{LPARAM, WPARAM};
            use windows::Win32::UI::WindowsAndMessaging::{PostThreadMessageW, WM_QUIT};
            let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
            unsafe {
                SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            }
            watch::when_snapped(|w, t| SNAPS.lock().unwrap().push((w, t)));
            SNAPS.lock().unwrap().clear();
            let wall = throwaway(100);
            let (l, r) = halves(work_area(wall.0).unwrap());
            place(wall.0, l, None).unwrap();
            let (term, owner, thread) = terminal_on_its_own_thread();
            // The fleet tab is not found until the terminal holds it.
            let found = Arc::new(AtomicIsize::new(0));
            let seen = found.clone();
            let generation = watch::disarm();
            watch::arm_snap(
                generation,
                wall.0 .0 as isize,
                Box::new(move || Some(seen.load(Ordering::SeqCst)).filter(|h| *h != 0)),
            );
            std::thread::sleep(std::time::Duration::from_millis(1200));
            found.store(term, Ordering::SeqCst);
            place(hwnd(term), r, None).unwrap();
            let start = std::time::Instant::now();
            while start.elapsed() < std::time::Duration::from_secs(4)
                && SNAPS.lock().unwrap().is_empty()
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            watch::disarm();
            let got = std::mem::take(&mut *SNAPS.lock().unwrap());
            unsafe {
                let _ = PostThreadMessageW(thread, WM_QUIT, WPARAM(0), LPARAM(0));
            }
            owner.join().unwrap();
            assert_eq!(
                got,
                vec![(wall.0 .0 as isize, term)],
                "seen through every thread's hooks"
            );
        }

        #[test]
        fn a_reversed_snap_one_window_alone_or_a_split_already_there_does_not() {
            let none = Vec::<(isize, isize)>::new();
            assert_eq!(
                snap_watched(|_, _| {}, |w, t| into_halves(t, w)),
                none,
                "reversed"
            );
            assert_eq!(
                snap_watched(
                    |_, _| {},
                    |w, _| {
                        let (l, _) = halves(work_area(w).unwrap());
                        place(w, l, None).unwrap();
                    }
                ),
                none,
                "the wall alone"
            );
            assert_eq!(
                snap_watched(into_halves, |_, t| nudge(t, 3, 0)),
                none,
                "a split already there when watching began (put back by an unsplit)"
            );
        }

        #[test]
        fn a_maximized_then_minimized_window_is_placed_normal_without_the_focus() {
            // The watcher tests' windows come and go; one of them could hold the
            // foreground this test reads.
            let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
            // As the app's threads are: physical pixels for both rects.
            unsafe {
                SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            }
            let own = Own(unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    w!("STATIC"),
                    w!("klepsydra split test"),
                    WS_OVERLAPPEDWINDOW,
                    100,
                    100,
                    640,
                    480,
                    None,
                    None,
                    None,
                    None,
                )
            }
            .expect("a throwaway window"));
            let h = own.0;
            unsafe {
                let _ = ShowWindow(h, SW_SHOWMAXIMIZED);
                // Minimize hands the activation to the next window.
                let _ = ShowWindow(h, SW_MINIMIZE);
            }
            let wp = placement(h).unwrap();
            assert!(unsafe { IsIconic(h) }.as_bool(), "minimized");
            assert!(
                wp.flags.contains(WPF_RESTORETOMAXIMIZED),
                "it would restore maximized"
            );
            // Read once activation has passed on: mid-handoff it reads none.
            let before = hwnd(settled_foreground());
            assert!(!before.is_invalid(), "a window has the foreground");
            assert_ne!(before, h);
            let (left, _) = halves(work_area(h).unwrap());
            let target = Rect::new(left.x + 40, left.y + 40, 720, 520);
            place(h, target, None).unwrap();
            assert!(!sized(h), "neither minimized nor maximized");
            assert_eq!(frame(h), Some(target), "the visible frame is on the target");
            let after = unsafe { GetForegroundWindow() };
            assert_ne!(after, h, "placing it never activated it");
            assert_eq!(after, before);
        }

        #[test]
        fn a_window_that_stops_answering_is_refused_within_a_second() {
            use std::sync::mpsc;
            use std::time::{Duration, Instant};
            use windows::Win32::UI::WindowsAndMessaging::{PeekMessageW, MSG, PM_REMOVE};
            let (made_tx, made) = mpsc::channel::<isize>();
            let (go, go_rx) = mpsc::channel::<()>();
            // A window whose thread stops pumping messages until told to go:
            // hung, to every other thread.
            let owner = std::thread::spawn(move || {
                let h = unsafe {
                    CreateWindowExW(
                        WINDOW_EX_STYLE(0),
                        w!("STATIC"),
                        w!("klepsydra hung test"),
                        WS_OVERLAPPEDWINDOW,
                        100,
                        100,
                        320,
                        240,
                        None,
                        None,
                        None,
                        None,
                    )
                }
                .expect("a throwaway window");
                made_tx.send(h.0 as isize).unwrap();
                let _ = go_rx.recv();
                let mut msg = MSG::default();
                while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {}
                let _ = unsafe { DestroyWindow(h) };
            });
            let raw = made.recv().unwrap();
            let (done_tx, done) = mpsc::channel();
            std::thread::spawn(move || {
                let h = hwnd(raw);
                let t = Instant::now();
                let read = placement(h).err();
                let read_in = t.elapsed();
                let t = Instant::now();
                let moved = set_rect(h, Rect::new(0, 0, 200, 200), None, wall_pos_flags()).err();
                let _ = done_tx.send((read, read_in, moved, t.elapsed()));
            });
            let got = done.recv_timeout(Duration::from_secs(5));
            go.send(()).unwrap();
            owner.join().unwrap();
            let (read, read_in, moved, moved_in) =
                got.expect("both calls to a hung window return within 5 s");
            let second = Duration::from_millis(1000);
            assert_eq!(read.as_deref(), Some(HUNG), "reading its placement");
            assert!(read_in < second, "read refused in {read_in:?}");
            assert_eq!(moved.as_deref(), Some(HUNG), "moving it");
            assert!(moved_in < second, "move refused in {moved_in:?}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hand_made_split_is_the_wall_left_and_the_terminal_right_within_a_few_pixels() {
        let work = Rect::new(0, 0, 2560, 1392);
        let (l, r) = crate::geometry::halves(work);
        assert!(in_split(work, l, r), "exactly on the halves");
        let off = |f: Rect, dx: i32, dw: i32| Rect::new(f.x + dx, f.y, f.w + dw, f.h);
        assert!(
            in_split(work, off(l, 0, -7), off(r, 7, -7)),
            "a snap's rounding"
        );
        assert!(!in_split(work, r, l), "reversed");
        let sixty = (work.w * 3) / 5;
        assert!(
            !in_split(
                work,
                Rect::new(0, 0, sixty, work.h),
                Rect::new(sixty, 0, work.w - sixty, work.h)
            ),
            "60/40"
        );
        assert!(
            !in_split(work, l, off(r, 40, -40)),
            "the terminal not to the edge"
        );
        assert!(
            !in_split(work, Rect::new(0, 0, l.w, 700), r),
            "the wall half height"
        );
        let second = Rect::new(-1920, 0, 1920, 1040);
        let (sl, sr) = crate::geometry::halves(second);
        assert!(in_split(second, sl, sr), "on a monitor left of the primary");
        assert!(!in_split(work, sl, sr), "halves of another monitor");
    }

    #[test]
    fn only_coming_into_the_split_turns_it_on() {
        assert!(snapped(false, true), "snapped into it");
        assert!(!snapped(true, true), "already there when watching began");
        assert!(!snapped(false, false));
        assert!(!snapped(true, false), "left it");
    }

    fn prefs(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn split_is_off_unless_saved_on() {
        assert!(!split_of(None), "prefs.json unreadable");
        assert!(!split_of(Some(&prefs(serde_json::json!({})))));
        for bad in [
            serde_json::json!("true"),
            serde_json::json!(1),
            serde_json::json!("on"),
            Value::Null,
            serde_json::json!({ "on": true }),
        ] {
            let p = prefs(serde_json::json!({ "wall_split": bad }));
            assert!(!split_of(Some(&p)), "{bad} reads as off");
        }
    }

    #[test]
    fn a_saved_choice_reads_back() {
        for on in [true, false] {
            // As write_pref stores it, beside the other prefs.
            let mut p = prefs(serde_json::json!({ "zoom": 2, "wall_density": "compact" }));
            p.insert(SPLIT_KEY.into(), Value::Bool(on));
            let text = Value::Object(p).to_string();
            let back: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(split_of(back.as_object()), on);
        }
    }

    #[test]
    fn the_terminal_goes_under_the_wall_and_neither_activates() {
        let t = terminal_pos_flags();
        assert_eq!(t & SWP_NOZORDER, 0, "its z-order is set, after the wall");
        assert_ne!(t & SWP_NOACTIVATE, 0);
        assert_ne!(t & SWP_NOOWNERZORDER, 0);
        let w = wall_pos_flags();
        assert_ne!(w & SWP_NOZORDER, 0, "the wall keeps its place");
        assert_ne!(w & SWP_NOACTIVATE, 0);
    }

    #[test]
    fn restoring_shows_normal_without_activating_or_maximizing() {
        const WPF_SETMINPOSITION: u32 = 1;
        const WPF_RESTORETOMAXIMIZED: u32 = 2;
        const SW_SHOWNOACTIVATE: u32 = 4;
        assert_eq!(restore_placement(0), (SW_SHOWNOACTIVATE, 0), "maximized");
        assert_eq!(
            restore_placement(WPF_RESTORETOMAXIMIZED),
            (SW_SHOWNOACTIVATE, 0),
            "maximized then minimized comes back normal"
        );
        assert_eq!(
            restore_placement(WPF_RESTORETOMAXIMIZED | WPF_SETMINPOSITION),
            (SW_SHOWNOACTIVATE, WPF_SETMINPOSITION),
            "other flags are kept"
        );
    }

    #[test]
    fn only_a_window_put_back_maximized_is_waited_on_for_the_focus() {
        // SW_HIDE, SW_SHOWNORMAL, SW_SHOWMINIMIZED, SW_SHOWMAXIMIZED, SW_SHOWNOACTIVATE.
        for (cmd, takes) in [(0, false), (1, false), (2, false), (3, true), (4, false)] {
            assert_eq!(put_back_activates(cmd), takes, "show command {cmd}");
        }
    }

    #[test]
    fn each_lookup_failure_has_its_own_note() {
        use crate::jump::JumpError;
        use klepsydra_fleet::tabs::TabError;
        assert_eq!(
            lookup_error(JumpError::Tab(TabError::NoMatch("x".into()))),
            NOT_OPEN
        );
        assert_eq!(lookup_error(JumpError::Tab(TabError::Hidden)), HIDDEN);
        assert!(HIDDEN.contains("Split"), "said for split, not for Jump");
        let two = lookup_error(JumpError::Tab(TabError::ManyFixed("t".into(), 2)));
        assert!(two.contains("Close all but one"), "{two}");
        assert_eq!(
            lookup_error(JumpError::Failed("Could not start UI Automation: x".into())),
            "Could not start UI Automation: x"
        );
    }

    #[test]
    fn the_focus_goes_back_only_from_a_window_that_took_it() {
        let (wall, terminal, other) = (1, 2, 3);
        assert!(give_focus_back(wall, terminal, terminal));
        assert!(give_focus_back(other, terminal, terminal));
        assert!(
            !give_focus_back(terminal, terminal, terminal),
            "it had it before"
        );
        assert!(!give_focus_back(wall, wall, terminal));
        assert!(
            !give_focus_back(wall, other, terminal),
            "someone else took it"
        );
        assert!(!give_focus_back(0, terminal, terminal), "no window had it");
    }

    #[test]
    fn the_wall_takes_the_left_and_the_terminal_goes_right_under_it() {
        use crate::geometry::{halves, Rect};
        let work = Rect::new(-1920, 40, 1921, 1000);
        let (left, right) = halves(work);
        let (wall, terminal) = (10, 20);
        assert_eq!(
            moves(wall, terminal, work),
            [(wall, left, None), (terminal, right, Some(wall))],
            "the wall keeps its place in the z-order; the terminal is stacked under it"
        );
    }

    #[test]
    fn only_a_split_that_landed_is_saved_on() {
        assert!(saved_on(true, true));
        assert!(
            !saved_on(true, false),
            "a saved on that fails at load is not tried again at every open"
        );
        assert!(!saved_on(false, true));
        assert!(!saved_on(false, false));
    }

    fn seen(frame: Rect) -> Seen {
        Seen {
            exists: true,
            visible: true,
            iconic: false,
            zoomed: false,
            frame: Some(frame),
        }
    }

    #[test]
    fn a_window_leaves_by_closing_hiding_sizing_or_moving_past_the_drift() {
        let held = Rect::new(960, 0, 960, 1040);
        assert_eq!(left(held, seen(held)), None);
        for (dx, dy, dw, dh) in [
            (DRIFT_PX, 0, 0, 0),
            (0, -DRIFT_PX, 0, DRIFT_PX),
            (0, 0, -DRIFT_PX, 0),
        ] {
            let r = Rect::new(held.x + dx, held.y + dy, held.w + dw, held.h + dh);
            assert_eq!(left(held, seen(r)), None, "within {DRIFT_PX} px: {r:?}");
        }
        for r in [
            Rect::new(held.x + DRIFT_PX + 1, held.y, held.w, held.h),
            Rect::new(held.x, held.y, held.w - DRIFT_PX - 1, held.h),
            Rect::new(held.x, held.y + 300, held.w, held.h),
            Rect::new(-1920, 0, 960, 1040),
        ] {
            assert_eq!(left(held, seen(r)), Some(Left::Moved), "{r:?}");
        }
        let far = Some(Rect::new(-32000, -32000, 160, 28));
        let s = seen(held);
        assert_eq!(
            left(
                held,
                Seen {
                    exists: false,
                    frame: None,
                    ..s
                }
            ),
            Some(Left::Closed)
        );
        assert_eq!(
            left(
                held,
                Seen {
                    iconic: true,
                    frame: far,
                    ..s
                }
            ),
            Some(Left::Minimized),
            "not Moved: the show state first"
        );
        assert_eq!(
            left(
                held,
                Seen {
                    visible: false,
                    ..s
                }
            ),
            Some(Left::Hidden)
        );
        assert_eq!(
            left(
                held,
                Seen {
                    zoomed: true,
                    frame: Some(Rect::new(-8, -8, 1936, 1056)),
                    ..s
                }
            ),
            Some(Left::Maximized)
        );
        assert_eq!(
            left(held, Seen { frame: None, ..s }),
            None,
            "no frame says nothing"
        );
    }

    #[test]
    fn the_note_names_the_window_and_how_it_left() {
        assert_eq!(
            left_note("the fleet terminal", Left::Maximized),
            "Split off: the fleet terminal was maximized, so both windows stay where they are."
        );
        assert_eq!(
            left_note("the wall", Left::Hidden),
            left_note("the wall", Left::Closed),
            "the wall's close hides it"
        );
        assert!(left_note("the wall", Left::Moved).contains("the wall moved,"));
    }

    #[test]
    fn putting_a_window_back_never_activates_it() {
        assert_eq!(quiet_show(1), 4, "normal shows without activating");
        assert_eq!(quiet_show(2), 7, "minimized stays inactive");
        assert_eq!(quiet_show(3), 3, "maximized has no quiet form");
        assert_eq!(quiet_show(4), 4);
    }
}
