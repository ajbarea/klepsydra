//! The fleet strip's Tauri side: runs the reader on its own thread, hands each
//! new snapshot to every webview that subscribed, and opens the card wall.

use std::path::{Path, PathBuf};
use std::time::Duration;
#[cfg(windows)]
use std::time::Instant;

#[cfg(windows)]
use klepsydra_fleet::cue::Cues;
use klepsydra_fleet::hub::{Hub, Sink};
use klepsydra_fleet::ledger::{Ledger, Shared};
use klepsydra_fleet::problem_log::{append_capped, CAP};
use klepsydra_fleet::receiver;
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

/// A line for stderr, for dev runs, and for `<dir>/fleet.log`, which release
/// builds have instead of a console.
fn log_line(dir: &Path, what: &str) {
    eprintln!("klepsydra: {what}");
    let line = format!("{} {what}", unix_now());
    append_capped(&dir.join("fleet.log"), &line, CAP);
}

fn log_problem(dir: &Path, p: &Problem) {
    // "fleet" names the directory itself, not a file inside it.
    let at = if p.file == "fleet" {
        "fleet".to_string()
    } else {
        format!("fleet/{}", p.file)
    };
    log_line(dir, &format!("skipped {at}: {}", p.what));
}

/// Open the ledger in `<dir>/ledger` and start the OTLP receiver. A port
/// already in use is logged and the overlay runs on without telemetry.
fn start_ledger(dir: &Path) -> Shared {
    let (ledger, problems) = Ledger::open(dir.join("ledger"), unix_now());
    for p in &problems {
        log_line(dir, &format!("ledger: {p}"));
    }
    let ledger: Shared = std::sync::Arc::new(std::sync::Mutex::new(ledger));
    let log_dir = dir.to_path_buf();
    let log: receiver::Log = std::sync::Arc::new(move |l: String| log_line(&log_dir, &l));
    if let Err(e) = receiver::spawn(receiver::ADDR, ledger.clone(), log) {
        log_line(
            dir,
            &format!("otel: no receiver on {}: {e}", receiver::ADDR),
        );
    }
    ledger
}

/// Follow `<dir>/fleet` for as long as the app runs. Each skipped file is
/// logged once, and the rest of the fleet still renders.
pub fn start(app: &AppHandle, dir: Option<PathBuf>) {
    let Some(dir) = dir else {
        return;
    };
    let app = app.clone();
    let ledger = start_ledger(&dir);
    std::thread::spawn(move || {
        let mut reader = Reader::new(&dir).with_ledger(ledger);
        #[cfg(windows)]
        let mut cues = Cues::new(unix_now());
        let mut wait = Duration::ZERO;
        loop {
            let (snapshot, problems) = reader.step(wait, unix_now);
            for p in &problems {
                log_problem(&dir, p);
            }
            if let Some(snapshot) = snapshot {
                // Every snapshot moves the baseline, so turning Ping on never
                // replays what changed while it was off.
                #[cfg(windows)]
                if let Some(c) = cues.next(&snapshot, Instant::now(), unix_now()) {
                    crate::ping::cue(c);
                }
                if let Ok(v) = serde_json::to_value(snapshot) {
                    app.state::<Fleet>().publish(v);
                }
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
