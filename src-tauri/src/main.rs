#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    LogicalSize, Manager,
};

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
        let key = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        out.insert(key, value);
    }
    serde_json::Value::Object(out)
}

/// The panel grows a row per account window, so the frontend reports the height
/// it needs rather than the window guessing.
#[tauri::command]
fn set_height(window: tauri::Window, height: f64) -> Result<(), String> {
    let width = window.outer_size().map_err(|e| e.to_string())?.width as f64
        / window.scale_factor().map_err(|e| e.to_string())?;
    window
        .set_size(LogicalSize::new(width, height.max(1.0)))
        .map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_usage, set_height])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");

            // Click-through by default: the gauge is for reading, not clicking.
            // The tray toggles it off when you want to drag the panel.
            window.set_ignore_cursor_events(true)?;

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
                &[&interactive, &PredefinedMenuItem::separator(app)?, &quit],
            )?;

            let toggle = interactive.clone();
            TrayIconBuilder::new()
                .icon(app.default_window_icon().expect("bundled icon").clone())
                .tooltip("klepsydra")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id.as_ref() {
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
