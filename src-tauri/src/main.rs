#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

/// `%LOCALAPPDATA%\Klepsydra\usage.json` -- the file the statusLine hook publishes.
fn usage_path() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("KLEPSYDRA_FILE") {
        return Some(PathBuf::from(explicit));
    }
    let base = std::env::var("LOCALAPPDATA").ok()?;
    Some(PathBuf::from(base).join("Klepsydra").join("usage.json"))
}

/// Raw file contents, or None when it is missing or unreadable. Parsing and
/// validation belong to the frontend, which already handles malformed input.
#[tauri::command]
fn read_usage() -> Option<String> {
    std::fs::read_to_string(usage_path()?).ok()
}

/// Tray selections are pushed to the frontend, which owns all rendering state.
fn emit_windows(app: &tauri::AppHandle, primary: &str, secondary: Option<&str>) {
    let _ = app.emit(
        "window-changed",
        serde_json::json!({ "primary": primary, "secondary": secondary }),
    );
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_usage])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");

            // Click-through by default: the gauge is for reading, not clicking.
            // The tray toggles it off when you want to drag the panel.
            window.set_ignore_cursor_events(true)?;

            let show_5h = MenuItem::with_id(app, "w:five_hour", "Session (5h)", true, None::<&str>)?;
            let show_7d = MenuItem::with_id(app, "w:seven_day", "Week (7d)", true, None::<&str>)?;
            let show_both = MenuItem::with_id(app, "w:both", "Both", true, None::<&str>)?;
            let interactive = CheckMenuItem::with_id(
                app,
                "interactive",
                "Interactive (drag to move)",
                true,
                false,
                None::<&str>,
            )?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;

            let menu = Menu::with_items(
                app,
                &[
                    &show_5h,
                    &show_7d,
                    &show_both,
                    &PredefinedMenuItem::separator(app)?,
                    &interactive,
                    &PredefinedMenuItem::separator(app)?,
                    &quit,
                ],
            )?;

            let toggle = interactive.clone();
            TrayIconBuilder::new()
                .icon(app.default_window_icon().expect("bundled icon").clone())
                .tooltip("klepsydra")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "w:five_hour" => emit_windows(app, "five_hour", None),
                    "w:seven_day" => emit_windows(app, "seven_day", None),
                    "w:both" => emit_windows(app, "five_hour", Some("seven_day")),
                    "interactive" => {
                        if let Some(w) = app.get_webview_window("main") {
                            // The checkbox has already flipped; mirror it onto the window.
                            let now_interactive = toggle.is_checked().unwrap_or(false);
                            let _ = w.set_ignore_cursor_events(!now_interactive);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running klepsydra");
}
