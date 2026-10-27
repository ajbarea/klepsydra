//! Split mode: the wall on the left half of its monitor's work area, the
//! `fleet` Windows Terminal window on the right. Off by default; the wall's
//! toggle turns it on, and prefs.json remembers it as `wall_split` (written
//! true only once a split lands). Turning it off puts both windows back where
//! they were. The arithmetic is `geometry`'s; the win32 calls here stay thin.

use serde_json::{Map, Value};

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
        Ok(split_of(crate::read_prefs(&app).as_ref()))
    } else {
        Err(WINDOWS_ONLY.into())
    }
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

/// The show command and flags that take a maximized or minimized window to
/// its normal size without activating it, from its current `flags`. A window
/// maximized and then minimized is restored to normal, not maximized.
#[cfg_attr(not(windows), allow(dead_code))]
fn restore_placement(flags: u32) -> (u32, u32) {
    const SW_SHOWNOACTIVATE: u32 = 4;
    const WPF_RESTORETOMAXIMIZED: u32 = 2;
    (SW_SHOWNOACTIVATE, flags & !WPF_RESTORETOMAXIMIZED)
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
        give_focus_back, lookup_error, moves, quiet_show, restore_placement, terminal_pos_flags,
        wall_pos_flags,
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
            let mut wp = placement(h)?;
            let (show, flags) = restore_placement(wp.flags.0);
            wp.showCmd = show;
            wp.flags = WINDOWPLACEMENT_FLAGS(flags);
            answering(h)?;
            let before = settled_foreground();
            unsafe { SetWindowPlacement(h, &wp) }
                .map_err(|e| format!("Could not restore a window: {e}"))?;
            hand_back(before, h);
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

    /// Give the foreground back to `before` if showing `moved` took it.
    fn hand_back(before: isize, moved: HWND) {
        if give_focus_back(before, foreground(), moved.0 as isize) && exists(before) {
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
                hand_back(before, hwnd(raw));
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
        Ok(ON.into())
    }

    pub fn unsplit(wall: isize) -> String {
        if restore(take(), wall) {
            OFF.into()
        } else {
            "Split off.".into()
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

        #[test]
        fn a_maximized_then_minimized_window_is_placed_normal_without_the_focus() {
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

    #[test]
    fn putting_a_window_back_never_activates_it() {
        assert_eq!(quiet_show(1), 4, "normal shows without activating");
        assert_eq!(quiet_show(2), 7, "minimized stays inactive");
        assert_eq!(quiet_show(3), 3, "maximized has no quiet form");
        assert_eq!(quiet_show(4), 4);
    }
}
