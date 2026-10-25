//! Split mode: the wall on the left half of its monitor's work area, the
//! `fleet` Windows Terminal window on the right. Off by default; the wall's
//! toggle turns it on, and prefs.json remembers it as `wall_split` (written
//! true only once a split lands). Turning it off puts both windows back where
//! they were. The arithmetic is `geometry`'s; the win32 calls here stay thin.

use serde_json::{Map, Value};

/// The prefs.json key, beside `wall_density`.
pub const SPLIT_KEY: &str = "wall_split";

/// The wall's note when no Windows Terminal tab is titled `FLEET_TAB`.
pub const NOT_OPEN: &str =
    "The fleet terminal is not open, so nothing moved. Open it with + New session, then turn Split on.";

const WINDOWS_ONLY: &str = "Split mode works on Windows only.";

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
        .map_err(|e| format!("Could not split: {e}"))??;
        crate::write_pref(&app, SPLIT_KEY, Value::Bool(on));
        Ok(said)
    }
    #[cfg(not(windows))]
    {
        let _ = (app, on);
        Err(WINDOWS_ONLY.into())
    }
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

#[cfg(windows)]
mod win {
    use super::quiet_show;
    use crate::geometry::{frame_insets, halves, widen, Insets, Rect};
    use crate::jump::JumpError;
    use klepsydra_fleet::tabs::TabError;
    use std::sync::Mutex;
    use windows::Win32::Foundation::{HWND, RECT};
    use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::UI::HiDpi::{
        GetAwarenessFromDpiAwarenessContext, GetThreadDpiAwarenessContext,
        DPI_AWARENESS_PER_MONITOR_AWARE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetWindowPlacement, GetWindowRect, IsHungAppWindow, IsIconic, IsWindow,
        IsZoomed, SetWindowPlacement, SetWindowPos, ShowWindow, SWP_NOACTIVATE, SWP_NOOWNERZORDER,
        SWP_NOZORDER, SW_RESTORE, WINDOWPLACEMENT,
    };

    const ON: &str = "Split: the wall on the left, the fleet terminal on the right.";
    const OFF: &str = "Split off: both windows are back where they were.";
    const HUNG: &str = "The fleet terminal is not responding, so nothing moved.";
    const NOT_AWARE: &str =
        "klepsydra is not per-monitor DPI aware here, so a split would misplace the windows.";

    /// Each window's placement from before the split, with its handle as an
    /// integer (a placement is plain numbers, so this is Send). Taken on
    /// the way in (kept if the same window is split again) and given back on
    /// the way out; kept in memory only, so a restart forgets it.
    struct Saved {
        wall: Option<(isize, WINDOWPLACEMENT)>,
        terminal: Option<(isize, WINDOWPLACEMENT)>,
    }

    static SAVED: Mutex<Saved> = Mutex::new(Saved {
        wall: None,
        terminal: None,
    });

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
        let mut wp = WINDOWPLACEMENT {
            length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
            ..Default::default()
        };
        unsafe { GetWindowPlacement(h, &mut wp) }
            .map_err(|e| format!("Could not read a window's placement: {e}"))?;
        Ok(wp)
    }

    /// The invisible borders of `h`, as placed now; none when DWM gives no
    /// frame bounds, so the window is placed by its rect alone.
    fn insets(h: HWND) -> Insets {
        let (mut window, mut frame) = (RECT::default(), RECT::default());
        let ok = unsafe {
            GetWindowRect(h, &mut window).is_ok()
                && DwmGetWindowAttribute(
                    h,
                    DWMWA_EXTENDED_FRAME_BOUNDS,
                    &mut frame as *mut RECT as *mut core::ffi::c_void,
                    std::mem::size_of::<RECT>() as u32,
                )
                .is_ok()
        };
        if ok {
            frame_insets(rect(window), rect(frame))
        } else {
            Insets::default()
        }
    }

    fn set_rect(h: HWND, r: Rect) -> Result<(), String> {
        unsafe {
            SetWindowPos(
                h,
                None,
                r.x,
                r.y,
                r.w,
                r.h,
                SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
            )
        }
        .map_err(|e| format!("Could not move a window: {e}"))
    }

    /// Put `h`'s visible frame on `visible`. A maximized or minimized window
    /// is restored first. It moves there once so its borders are measured at
    /// that monitor's DPI, then again widened by them.
    fn place(h: HWND, visible: Rect) -> Result<(), String> {
        unsafe {
            if IsIconic(h).as_bool() || IsZoomed(h).as_bool() {
                let _ = ShowWindow(h, SW_RESTORE);
            }
        }
        set_rect(h, visible)?;
        set_rect(h, widen(visible, insets(h)))
    }

    /// A placement saved before the split, given back: rcNormalPosition is in
    /// workspace coordinates, so it goes straight to SetWindowPlacement.
    fn put_back(h: HWND, mut wp: WINDOWPLACEMENT) -> bool {
        wp.showCmd = quiet_show(wp.showCmd);
        unsafe { SetWindowPlacement(h, &wp) }.is_ok()
    }

    fn is_terminal(h: HWND) -> bool {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(h, &mut class) } as usize;
        String::from_utf16_lossy(&class[..n.min(class.len())]) == crate::jump::TERMINAL_CLASS
    }

    /// Whether `raw` is still a window that can be given its placement back.
    fn alive(raw: isize) -> bool {
        let h = hwnd(raw);
        unsafe { IsWindow(Some(h)).as_bool() && !IsHungAppWindow(h).as_bool() }
    }

    /// Give back what `saved` holds, skipping a window that closed meanwhile
    /// (or a handle now another program's); whether anything moved.
    fn restore(saved: &mut Saved, wall: isize) -> bool {
        let mut moved = false;
        if let Some((raw, wp)) = saved.wall.take() {
            if raw == wall && alive(raw) {
                moved |= put_back(hwnd(raw), wp);
            }
        }
        if let Some((raw, wp)) = saved.terminal.take() {
            if alive(raw) && is_terminal(hwnd(raw)) {
                moved |= put_back(hwnd(raw), wp);
            }
        }
        moved
    }

    pub fn split(wall: isize) -> Result<String, String> {
        per_monitor_aware()?;
        let terminal = crate::jump::fleet_window().map_err(|e| match e {
            JumpError::Tab(TabError::NoMatch(_)) => super::NOT_OPEN.to_string(),
            e => e.to_string(),
        })?;
        let (w, t) = (hwnd(wall), hwnd(terminal));
        if unsafe { IsHungAppWindow(t) }.as_bool() {
            return Err(HUNG.into());
        }
        let work = work_area(w)?;
        let mut saved = SAVED
            .lock()
            .map_err(|_| "Split mode is stuck; restart klepsydra.")?;
        // Both read before either is kept, so a failed read keeps nothing.
        let (before_w, before_t) = (placement(w)?, placement(t)?);
        if saved.wall.map(|(h, _)| h) != Some(wall) {
            saved.wall = Some((wall, before_w));
        }
        if saved.terminal.map(|(h, _)| h) != Some(terminal) {
            saved.terminal = Some((terminal, before_t));
        }
        let (left, right) = halves(work);
        if let Err(e) = place(w, left).and_then(|_| place(t, right)) {
            // Half a split is no split: both go back.
            restore(&mut saved, wall);
            return Err(e);
        }
        Ok(ON.into())
    }

    pub fn unsplit(wall: isize) -> String {
        let moved = match SAVED.lock() {
            Ok(mut saved) => restore(&mut saved, wall),
            Err(_) => false,
        };
        if moved {
            OFF.into()
        } else {
            "Split off.".into()
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
    fn putting_a_window_back_never_activates_it() {
        assert_eq!(quiet_show(1), 4, "normal shows without activating");
        assert_eq!(quiet_show(2), 7, "minimized stays inactive");
        assert_eq!(quiet_show(3), 3, "maximized has no quiet form");
        assert_eq!(quiet_show(4), 4);
    }
}
