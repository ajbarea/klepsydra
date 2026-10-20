//! The fleet strip's Tauri side: runs the reader on its own thread, hands each
//! new snapshot to every webview that subscribed, and opens the card wall.

use std::path::{Path, PathBuf};
use std::time::Duration;

use klepsydra_fleet::hub::{Hub, Sink};
use klepsydra_fleet::problem_log::{append_capped, CAP};
use klepsydra_fleet::scan::Problem;
use klepsydra_fleet::watch::{unix_now, Reader, POLL};
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

/// The card wall's window label.
// The window guard reads the builder's label as a literal, so it repeats this.
pub const WALL: &str = "wall";

/// A webview's end of the fleet.
pub struct Webview(pub Channel<Value>);

impl Sink for Webview {
    fn send(&self, message: Value) -> bool {
        self.0.send(message).is_ok()
    }
}

/// The fleet strip's rectangle in CSS pixels from the gauge window's top-left,
/// as the grip's is; None while it is hidden. The pointer watcher makes the
/// window interactive over it too.
#[derive(Default)]
pub struct Strip(pub std::sync::Mutex<Option<[f64; 4]>>);

/// Who follows the fleet, managed as app state.
pub type Fleet = Hub<Webview>;

/// A webview asks for snapshots: the latest at once, then each new one.
#[tauri::command]
pub fn fleet_subscribe(
    window: tauri::WebviewWindow,
    fleet: tauri::State<'_, Fleet>,
    on_message: Channel<Value>,
) {
    fleet.subscribe(window.label(), Webview(on_message));
}

/// Remove an ended or silent session's card. A session still running brings
/// its file back at its next hook event.
#[tauri::command]
pub fn clear_session(app: AppHandle, id: String) -> Result<(), String> {
    use klepsydra_fleet::clear::{check_clearable, remove_session};
    app.state::<Fleet>()
        .with_latest(|v| check_clearable(Some(v), &id))
        .unwrap_or_else(|| check_clearable(None, &id))?;
    let dir = crate::klepsydra_dir(&app).ok_or("klepsydra has no data folder.")?;
    remove_session(&dir.join("fleet"), &id)
}

/// A skipped file goes to stderr for dev runs and to `<dir>/fleet.log`, which
/// release builds have instead of a console.
fn log_problem(dir: &Path, p: &Problem) {
    // "fleet" names the directory itself, not a file inside it.
    let at = if p.file == "fleet" {
        "fleet".to_string()
    } else {
        format!("fleet/{}", p.file)
    };
    eprintln!("klepsydra: skipped {at}: {}", p.what);
    let line = format!("{} {at}: {}", unix_now(), p.what);
    append_capped(&dir.join("fleet.log"), &line, CAP);
}

/// Follow `<dir>/fleet` for as long as the app runs. Each skipped file is
/// logged once, and the rest of the fleet still renders.
pub fn start(app: &AppHandle, dir: Option<PathBuf>) {
    let Some(dir) = dir else {
        return;
    };
    let app = app.clone();
    std::thread::spawn(move || {
        let mut reader = Reader::new(&dir);
        let mut wait = Duration::ZERO;
        loop {
            let (snapshot, problems) = reader.step(wait, unix_now);
            for p in &problems {
                log_problem(&dir, p);
            }
            if let Some(v) = snapshot.and_then(|s| serde_json::to_value(s).ok()) {
                app.state::<Fleet>().publish(v);
            }
            wait = POLL;
        }
    });
}

/// Show the card wall with session `focus`'s card in view. The wall is made
/// on the first call, from an async command since a window made in a sync one
/// deadlocks on Windows, and after that only hidden and shown, never closed.
#[tauri::command]
pub async fn open_wall(app: AppHandle, focus: String) -> Result<(), String> {
    app.state::<Fleet>().focus(WALL, &focus);
    if let Some(wall) = app.get_webview_window(WALL) {
        wall.show().map_err(|e| e.to_string())?;
        let _ = wall.unminimize();
        let _ = wall.set_focus();
        return Ok(());
    }
    let wall = WebviewWindowBuilder::new(&app, "wall", WebviewUrl::App("wall.html".into()))
        .title("klepsydra fleet")
        .inner_size(1280.0, 800.0)
        .min_inner_size(420.0, 320.0)
        .build()
        .map_err(|e| e.to_string())?;
    let handle = wall.clone();
    wall.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let _ = handle.hide();
        }
    });
    Ok(())
}

/// The wall's card density choices, as prefs.json keeps them under
/// `wall_density`; the first is the default (wall `density.js` DENSITIES).
const DENSITIES: [&str; 3] = ["auto", "comfortable", "compact"];
const DENSITY_KEY: &str = "wall_density";

/// The saved density, or the default for a missing or unknown value.
fn density_of(prefs: Option<&serde_json::Map<String, Value>>) -> &'static str {
    let saved = prefs.and_then(|p| p.get(DENSITY_KEY)?.as_str());
    DENSITIES
        .into_iter()
        .find(|d| Some(*d) == saved)
        .unwrap_or(DENSITIES[0])
}

/// The value to save for `density`, or an error naming the choices.
fn density_value(density: &str) -> Result<Value, String> {
    if DENSITIES.contains(&density) {
        Ok(Value::from(density))
    } else {
        Err(format!(
            "unknown density {density:?}; one of {}",
            DENSITIES.join(", ")
        ))
    }
}

/// The wall's saved card density, read like the other prefs.
#[tauri::command]
pub fn get_wall_density(app: AppHandle) -> String {
    density_of(crate::read_prefs(&app).as_ref()).to_owned()
}

/// Save the density chosen on the wall.
#[tauri::command]
pub fn set_wall_density(app: AppHandle, density: String) -> Result<(), String> {
    crate::write_pref(&app, DENSITY_KEY, density_value(&density)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prefs(v: Value) -> serde_json::Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn density_defaults_to_auto() {
        assert_eq!(density_of(None), "auto", "prefs.json unreadable");
        assert_eq!(density_of(Some(&prefs(serde_json::json!({})))), "auto");
        for bad in [
            serde_json::json!("dense"),
            serde_json::json!(1),
            Value::Null,
        ] {
            let p = prefs(serde_json::json!({ "wall_density": bad }));
            assert_eq!(density_of(Some(&p)), "auto");
        }
    }

    #[test]
    fn a_saved_density_reads_back() {
        for d in DENSITIES {
            let saved = density_value(d).unwrap();
            let p = prefs(serde_json::json!({ "zoom": 2, "wall_density": saved }));
            assert_eq!(density_of(Some(&p)), d);
        }
    }

    #[test]
    fn an_unknown_density_is_refused() {
        let err = density_value("Compact").unwrap_err();
        assert!(err.contains("auto, comfortable, compact"), "{err}");
        assert!(density_value("").is_err());
    }
}
