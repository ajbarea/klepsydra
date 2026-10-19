//! The fleet strip's Tauri side: runs the reader on its own thread and hands
//! each new snapshot to every webview that subscribed.

use std::path::{Path, PathBuf};
use std::time::Duration;

use klepsydra_fleet::hub::{Hub, Sink};
use klepsydra_fleet::problem_log::{append_capped, CAP};
use klepsydra_fleet::scan::Problem;
use klepsydra_fleet::watch::{unix_now, Reader, POLL};
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

/// A webview's end of the fleet.
pub struct Webview(Channel<Value>);

impl Sink for Webview {
    fn send(&self, message: Value) -> bool {
        self.0.send(message).is_ok()
    }
}

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
