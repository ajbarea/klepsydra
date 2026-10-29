//! The fleet strip's Tauri side: runs the reader on its own thread, hands each
//! new snapshot to every webview that subscribed, and opens the card wall.

use std::path::{Path, PathBuf};
use std::time::Duration;
#[cfg(windows)]
use std::time::Instant;

#[cfg(windows)]
use klepsydra_fleet::cue::Cues;
use klepsydra_fleet::hub::{Hub, Sink};
use klepsydra_fleet::ledger::{Ledger, Receiver, Shared, TodayView};
use klepsydra_fleet::queue;
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

/// Who follows the queue file, managed as app state: a type of its own, since
/// Tauri keys state by type.
#[derive(Default)]
pub struct QueueFeed(pub Hub<Webview>);

/// Who follows the CI watch's view (`ci.json`), managed as app state.
#[derive(Default)]
pub struct CiFeed(pub Hub<Webview>);

/// A window follows the CI watch from now on, starting with its latest view.
#[tauri::command]
pub fn ci_subscribe(
    window: tauri::WebviewWindow,
    feed: tauri::State<'_, CiFeed>,
    on_message: Channel<Value>,
) {
    feed.0.subscribe(window.label(), Webview(on_message));
}

/// Follow the CI watch's `ci.json` in the data folder for as long as the app
/// runs, sending each change to the wall and the phone.
pub fn start_ci(app: &AppHandle, dir: Option<PathBuf>) {
    let Some(dir) = dir else {
        return;
    };
    let app = app.clone();
    std::thread::spawn(move || {
        let mut follower = klepsydra_fleet::ci::Follower::default();
        loop {
            if let Some(view) = follower.step(&dir, unix_now()) {
                crate::phone::set_ci(&app, &view);
                app.state::<CiFeed>().0.publish(view);
            }
            std::thread::sleep(CI_POLL);
        }
    });
}

/// How often `ci.json` is looked at: the watch writes it every 2 minutes.
const CI_POLL: Duration = Duration::from_secs(5);

/// A webview asks for snapshots: the latest at once, then each new one.
#[tauri::command]
pub fn fleet_subscribe(
    window: tauri::WebviewWindow,
    fleet: tauri::State<'_, Fleet>,
    on_message: Channel<Value>,
) {
    fleet.subscribe(window.label(), Webview(on_message));
}

/// A webview asks for the queue file: the latest read at once, then each change.
#[tauri::command]
pub fn queue_subscribe(
    window: tauri::WebviewWindow,
    feed: tauri::State<'_, QueueFeed>,
    on_message: Channel<Value>,
) {
    feed.0.subscribe(window.label(), Webview(on_message));
}

/// The queue file's path: the `queue_path` pref, else the Desktop known
/// folder's `claude-queue.md`; a prefs.json that will not read is an error,
/// not the default. Read again on every step, so an edited pref takes effect
/// within a poll.
fn queue_path(app: &AppHandle) -> Result<PathBuf, String> {
    let pref = queue::pref(crate::prefs_path(app).as_deref())?;
    queue::resolve(pref.as_ref(), app.path().desktop_dir().ok())
}

/// The queue file, who keeps it and their voice: `queue.json`'s in the data
/// folder, else the pref's or the Desktop's, kept by no one.
fn queue_source(app: &AppHandle) -> (Result<PathBuf, String>, Option<String>, Option<String>) {
    match queue::kept(crate::klepsydra_dir(app).as_deref()) {
        Some(kept) => (kept.path, kept.by, kept.voice),
        None => (queue_path(app), None, None),
    }
}

/// The tray's "Choose queue file...": the file picked goes to `queue.json`,
/// kept by no session, starting in the current file's folder.
pub fn choose_queue(app: &AppHandle) {
    use tauri_plugin_dialog::DialogExt;
    let Some(dir) = crate::klepsydra_dir(app) else {
        return;
    };
    let mut pick = app
        .dialog()
        .file()
        .set_title("Choose the queue file")
        .add_filter("Markdown", &["md", "markdown"]);
    if let Some(folder) = queue_source(app)
        .0
        .ok()
        .and_then(|p| Some(p.parent()?.to_path_buf()))
    {
        pick = pick.set_directory(folder);
    }
    pick.pick_file(move |file| {
        if let Some(path) = file.and_then(|f| f.into_path().ok()) {
            if let Err(e) = queue::keep(&dir, &path, None) {
                // The user's own file, by name only: it may sit under their home.
                let name = path
                    .file_name()
                    .map_or_else(Default::default, |n| n.to_string_lossy());
                log::error!(
                    "the queue file choice {name} was not saved to {}: {e}",
                    queue::KEEPER
                );
            }
        }
    });
}

/// Follow the queue file for as long as the app runs, sending each change.
pub fn start_queue(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let mut follower = queue::Follower::default();
        let mut wait = Duration::ZERO;
        loop {
            let (path, by, voice) = queue_source(&app);
            follower.keep(by, voice);
            if let Some(view) = follower.step(&path, wait) {
                if let Ok(v) = serde_json::to_value(view) {
                    app.state::<QueueFeed>().0.publish(v);
                }
            }
            wait = POLL;
        }
    });
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

/// keryx's latest spoken reply for session `id`, as WAV bytes for the card
/// to play. Off the main thread: the read can take a moment on a slow disk.
#[tauri::command]
pub async fn reply_clip(app: AppHandle, id: String) -> Result<tauri::ipc::Response, String> {
    let dir = crate::klepsydra_dir(&app).ok_or("klepsydra has no data folder.")?;
    klepsydra_fleet::reply::read(&dir, &id)
        .map(tauri::ipc::Response::new)
        .ok_or_else(|| "No reply to play.".into())
}

/// The ledger the receiver writes, managed as app state once it is open.
pub struct LedgerState(Shared);

/// Today's ledger for the wall's drawer; given a `session`, its guardrail
/// log is that session's alone.
/// Off the main thread: the receiver holds the lock while it saves.
#[tauri::command]
pub async fn ledger_today(app: AppHandle, session: Option<String>) -> Result<TodayView, String> {
    let shared = app
        .try_state::<LedgerState>()
        .ok_or("klepsydra has no ledger: it has no data folder.")?
        .0
        .clone();
    tauri::async_runtime::spawn_blocking(move || {
        klepsydra_fleet::ledger::lock(&shared).today_view(unix_now(), session.as_deref())
    })
    .await
    .map_err(|e| format!("Could not read the ledger: {e}"))
}

/// A skipped session file, under the data folder the startup line names,
/// with its session id when its name holds one.
fn log_problem(p: &Problem) {
    // "fleet" names the directory itself, not a file inside it.
    let at = if p.file == "fleet" {
        "fleet".to_string()
    } else {
        format!("fleet/{}", p.file)
    };
    match session_of(&p.file) {
        Some(id) => log::warn!(session_id = id; "skipped {at}: {}", p.what),
        None => log::warn!("skipped {at}: {}", p.what),
    }
}

/// The session id a session file's name `<id>.json` holds.
fn session_of(file: &str) -> Option<&str> {
    file.strip_suffix(".json")
        .filter(|id| klepsydra_fleet::session::is_session_id(id))
}

/// How often a receiver that could not bind its port tries again: the port
/// may be held by a program that exits, or by the last run's connections.
const RETRY: Duration = Duration::from_secs(30);

/// Open the ledger in `<dir>/ledger` and start the OTLP receiver. While the
/// port is taken the overlay runs on without telemetry, says so on the
/// snapshot and in the log, and tries again every `RETRY`.
fn start_ledger(dir: &Path) -> Shared {
    let (ledger, problems) = Ledger::open_local(dir.join("ledger"), unix_now());
    for p in &problems {
        log::error!("ledger: {p}");
    }
    let ledger: Shared = std::sync::Arc::new(std::sync::Mutex::new(ledger));
    let shared = ledger.clone();
    std::thread::spawn(move || {
        let mut logged = false;
        loop {
            let (listening, error) = match receiver::spawn(receiver::ADDR, shared.clone()) {
                Ok(_) => (true, None),
                Err(e) => (false, Some(e.to_string())),
            };
            if let Some(e) = &error {
                if !logged {
                    log::warn!(
                        "otel: no receiver on {}, so no token counts until it binds; retrying every {} s: {e}",
                        receiver::ADDR,
                        RETRY.as_secs()
                    );
                    logged = true;
                }
            } else {
                log::info!("otel: receiver listening on {}", receiver::ADDR);
            }
            let mut l = klepsydra_fleet::ledger::lock(&shared);
            l.set_receiver(Receiver {
                addr: receiver::ADDR.to_string(),
                listening,
                error,
            });
            if listening {
                // Whatever the receiver missed while it was down is a gap.
                if let Err(e) = l.note_listening(unix_now()) {
                    log::error!(
                        "ledger: the gap while the receiver was down was not saved in ledger/: {e}"
                    );
                }
                return;
            }
            drop(l);
            std::thread::sleep(RETRY);
        }
    });
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
    app.manage(LedgerState(ledger.clone()));
    let stamp = ledger.clone();
    std::thread::spawn(move || {
        let mut reader = Reader::new(&dir).with_ledger(ledger);
        #[cfg(windows)]
        let mut cues = Cues::new(unix_now());
        let mut wait = Duration::ZERO;
        loop {
            let (snapshot, problems) = reader.step(wait, unix_now);
            for p in &problems {
                log_problem(p);
            }
            if let Some(snapshot) = snapshot {
                // Every snapshot moves the baseline, so turning Ping on never
                // replays what changed while it was off.
                #[cfg(windows)]
                if let Some(c) = cues.next(&snapshot, Instant::now(), unix_now()) {
                    crate::ping::cue(c);
                }
                if let Ok(v) = serde_json::to_value(snapshot) {
                    crate::phone::publish(&app, &v);
                    app.state::<Fleet>().publish(v);
                }
            }
            wait = POLL;
            // The stamp the next start reads its gap from.
            klepsydra_fleet::ledger::lock(&stamp).stamp_alive(unix_now());
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
    fn a_skipped_session_file_names_its_session() {
        let id = "0b1e5b4e-6f0e-4bbd-9d3c-2a7a1c0f9e11";
        assert_eq!(session_of(&format!("{id}.json")), Some(id));
        for other in [
            "fleet",
            "notes.json",
            &format!("{id}.json.tmp"),
            id,
            ".json",
        ] {
            assert_eq!(session_of(other), None, "{other}");
        }
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
