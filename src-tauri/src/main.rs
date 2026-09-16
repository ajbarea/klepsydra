#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    LogicalSize, Manager,
};
use tauri_plugin_autostart::ManagerExt;

/// The grab handle, in CSS pixels relative to the window's top-left. The
/// frontend owns the layout and reports it, so restyling cannot desync this.
#[derive(Default)]
struct Grip(Mutex<Option<[f64; 4]>>);

/// `%LOCALAPPDATA%\Klepsydra` -- where the statusLine hook publishes.
fn klepsydra_dir() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("KLEPSYDRA_DIR") {
        return Some(PathBuf::from(explicit));
    }
    Some(PathBuf::from(std::env::var("LOCALAPPDATA").ok()?).join("Klepsydra"))
}

/// Every signed-in account's latest reading, keyed by account id.
///
/// One file per account means terminals on different logins never contend for
/// the same file. Parsing and validation stay in the frontend, which already
/// treats every field as untrusted.
#[tauri::command]
fn read_usage() -> serde_json::Value {
    let mut out = serde_json::Map::new();
    let Some(dir) = klepsydra_dir() else {
        return serde_json::Value::Object(out);
    };
    let Ok(entries) = std::fs::read_dir(dir.join("accounts")) else {
        return serde_json::Value::Object(out);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
        let key = path.file_stem().and_then(|s| s.to_str()).unwrap_or("unknown");
        out.insert(key.to_string(), value);
    }
    serde_json::Value::Object(out)
}

/// The panel grows a row per account window, so the frontend reports the height
/// it needs rather than the window guessing.
#[tauri::command]
fn set_height(window: tauri::Window, height: f64) -> Result<(), String> {
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let width = window.outer_size().map_err(|e| e.to_string())?.width as f64 / scale;
    window
        .set_size(LogicalSize::new(width, height.max(1.0)))
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn set_grip(grip: tauri::State<'_, Grip>, x: f64, y: f64, w: f64, h: f64) {
    if let Ok(mut g) = grip.0.lock() {
        *g = Some([x, y, w, h]);
    }
}

/// Re-assert topmost above every other topmost window, the taskbar included.
///
/// The taskbar is itself WS_EX_TOPMOST, and within that band z-order goes to
/// whoever was raised last -- so clicking the taskbar buries a gauge sitting
/// over it, taking the drag handle out of reach with it. Tauri's
/// `set_always_on_top` diffs against the flag it already holds and does
/// nothing, so re-inserting at the top of the band means calling SetWindowPos
/// directly. NOMOVE/NOSIZE keep the user's position, NOACTIVATE keeps focus
/// where it was.
#[cfg(windows)]
fn raise_above_taskbar(window: &tauri::WebviewWindow) {
    const HWND_TOPMOST: isize = -1;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOACTIVATE: u32 = 0x0010;

    #[link(name = "user32")]
    unsafe extern "system" {
        fn SetWindowPos(
            hwnd: isize,
            insert_after: isize,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
            flags: u32,
        ) -> i32;
    }

    if let Ok(hwnd) = window.hwnd() {
        unsafe {
            SetWindowPos(
                hwnd.0 as isize,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }
}

#[cfg(not(windows))]
fn raise_above_taskbar(_window: &tauri::WebviewWindow) {}

/// Put the gauge back somewhere reachable, for when it has been dragged
/// off-screen or onto a monitor that is no longer attached.
#[tauri::command]
fn reset_position(window: tauri::WebviewWindow) -> Result<(), String> {
    let monitor = window
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or("no primary monitor")?;
    let scale = monitor.scale_factor();
    let screen = monitor.size();
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let x = (screen.width as f64 - size.width as f64) / scale - 220.0;
    let y = (screen.height as f64 - size.height as f64) / scale;
    window
        .set_position(tauri::LogicalPosition::new(x.max(0.0), y.max(0.0)))
        .map_err(|e| e.to_string())
}

/// Windows has no per-region hit testing for a click-through window: ignoring
/// cursor events is all-or-nothing. So we watch the pointer and switch the
/// whole window interactive only while it is over the grab handle. Everywhere
/// else the gauge stays click-through and never eats a click.
fn watch_grip(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut interactive = false;
        let mut ticks: u32 = 0;
        loop {
            std::thread::sleep(Duration::from_millis(16));
            ticks = ticks.wrapping_add(1);
            let Some(window) = app.get_webview_window("main") else { continue };
            let Some(rect) = app.state::<Grip>().0.lock().ok().and_then(|g| *g) else { continue };
            let (Ok(cursor), Ok(origin), Ok(scale)) = (
                app.cursor_position(),
                window.outer_position(),
                window.scale_factor(),
            ) else {
                continue;
            };

            // Grip rect in physical desktop coordinates. While already
            // interactive the region is grown slightly, so a drag that outruns
            // the window by a pixel does not drop the mouse mid-move.
            let margin = if interactive { 8.0 } else { 0.0 };
            let left = origin.x as f64 + rect[0] * scale - margin;
            let top = origin.y as f64 + rect[1] * scale - margin;
            let right = left + rect[2] * scale + margin * 2.0;
            let bottom = top + rect[3] * scale + margin * 2.0;

            let inside = cursor.x >= left && cursor.x <= right && cursor.y >= top && cursor.y <= bottom;
            if inside != interactive {
                interactive = inside;
                let _ = window.set_ignore_cursor_events(!inside);
            }

            // Twice a second. Measured: after the taskbar takes foreground the
            // gauge is buried until the next re-assert, so this interval is the
            // worst case it stays hidden.
            if ticks % 30 == 0 {
                raise_above_taskbar(&window);
            }
        }
    });
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_window_state::Builder::default()
                // Position only: the window sizes itself to its rows, so a
                // restored height would fight set_height on every launch.
                .with_state_flags(tauri_plugin_window_state::StateFlags::POSITION)
                .build(),
        )
        .manage(Grip::default())
        .invoke_handler(tauri::generate_handler![read_usage, set_height, set_grip, reset_position])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");
            window.set_ignore_cursor_events(true)?;

            // Enable autostart once, on first run. Re-enabling unconditionally
            // would quietly undo the user turning it off from the tray. When it
            // is already on, re-register anyway so the recorded path follows the
            // executable if it moves.
            let autostart = app.autolaunch();
            let marker = klepsydra_dir().map(|d| d.join("autostart-initialised"));
            let first_run = marker.as_ref().map(|m| !m.exists()).unwrap_or(false);
            if first_run {
                let _ = autostart.enable();
                if let Some(m) = &marker {
                    if let Some(parent) = m.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    let _ = std::fs::write(m, "");
                }
            } else if autostart.is_enabled().unwrap_or(false) {
                let _ = autostart.enable();
            }
            let start_item = CheckMenuItem::with_id(
                app,
                "autostart",
                "Start with Windows",
                true,
                autostart.is_enabled().unwrap_or(false),
                None::<&str>,
            )?;
            let reset = MenuItem::with_id(app, "reset", "Reset position", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[
                    &reset,
                    &PredefinedMenuItem::separator(app)?,
                    &start_item,
                    &PredefinedMenuItem::separator(app)?,
                    &quit,
                ],
            )?;

            let toggle = start_item.clone();
            TrayIconBuilder::new()
                .icon(app.default_window_icon().expect("bundled icon").clone())
                .tooltip("klepsydra")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "autostart" => {
                        // The checkbox has already flipped; mirror it onto the system.
                        let want = toggle.is_checked().unwrap_or(false);
                        let mgr = app.autolaunch();
                        let _ = if want { mgr.enable() } else { mgr.disable() };
                        let _ = toggle.set_checked(mgr.is_enabled().unwrap_or(want));
                    }
                    "reset" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = reset_position(w.clone());
                            raise_above_taskbar(&w);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            raise_above_taskbar(&window);
            watch_grip(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running klepsydra");
}
