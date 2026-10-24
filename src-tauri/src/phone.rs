//! The tray's Phone wall: the fleet crate's read-only wall server, on while
//! the box is ticked and remembered in prefs.json. It serves the bundled
//! frontend through Tauri's asset resolver and the fleet's latest snapshot.

use std::sync::{Arc, Mutex};

use klepsydra_fleet::phone::{Assets, Server, ADDR};
use klepsydra_fleet::receiver::Log;
use tauri::{AppHandle, Manager};

/// prefs.json's key for the box.
pub const PREF: &str = "phone_wall";

/// The running server, while the box is ticked.
#[derive(Default)]
pub struct Phone(Mutex<Option<Server>>);

/// Whether prefs.json has the box ticked; off when missing or unreadable.
pub fn saved(app: &AppHandle) -> bool {
    crate::read_prefs(app)
        .and_then(|p| p.get(PREF)?.as_bool())
        .unwrap_or(false)
}

fn log(app: &AppHandle, what: &str) {
    match crate::klepsydra_dir(app) {
        Some(dir) => crate::fleet::log_line(&dir, what),
        None => eprintln!("klepsydra: {what}"),
    }
}

/// Turn the server on or off and return whether it is on now: a port in
/// use leaves it off and says so in `fleet.log`. Off closes the port and
/// every phone's stream before it returns.
pub fn set(app: &AppHandle, on: bool) -> bool {
    let state = app.state::<Phone>();
    let Ok(mut slot) = state.0.lock() else {
        return false;
    };
    if !on {
        if let Some(server) = slot.take() {
            server.stop();
            log(app, &format!("phone: wall closed on {ADDR}"));
        }
        return false;
    }
    if slot.is_some() {
        return true;
    }
    let resolver = app.clone();
    let assets: Assets = Arc::new(move |path: &str| {
        resolver
            .asset_resolver()
            .get(path.to_string())
            .map(|a| a.bytes)
    });
    let handle = app.clone();
    let server_log: Log = Arc::new(move |l: String| log(&handle, &l));
    match Server::spawn(ADDR, assets, server_log) {
        Ok(server) => {
            app.state::<crate::fleet::Fleet>()
                .with_latest(|v| server.publish(v));
            log(app, &format!("phone: wall serving on {ADDR}"));
            *slot = Some(server);
            true
        }
        Err(e) => {
            log(app, &format!("phone: no wall on {ADDR}: {e}"));
            false
        }
    }
}

/// Hand a running server the fleet's new snapshot.
pub fn publish(app: &AppHandle, snapshot: &serde_json::Value) {
    if let Ok(slot) = app.state::<Phone>().0.lock() {
        if let Some(server) = slot.as_ref() {
            server.publish(snapshot);
        }
    }
}
