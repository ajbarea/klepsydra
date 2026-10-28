//! The tray's Phone wall: the fleet crate's read-only wall server, on while
//! the box is ticked and remembered in prefs.json. It serves the bundled
//! frontend through Tauri's asset resolver, the fleet's latest snapshot and
//! the usage readings the gauge reads.

use std::sync::{Arc, Mutex};

use klepsydra_fleet::phone::{exact_assets, Assets, Clips, Server, Usage, ADDR};
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

/// Turn the server on or off and return whether it is on now: a port in
/// use leaves it off and says so in the log. Off closes the port and
/// every phone's stream before it returns.
pub fn set(app: &AppHandle, on: bool) -> bool {
    let state = app.state::<Phone>();
    let Ok(mut slot) = state.0.lock() else {
        return false;
    };
    if !on {
        if let Some(server) = slot.take() {
            server.stop();
            log::info!("phone: wall closed on {ADDR}");
        }
        return false;
    }
    if slot.is_some() {
        return true;
    }
    // Tauri's resolver answers a missing file with index.html; held to the
    // bundle's own paths, a missing file is a 404.
    let known: Vec<String> = app
        .asset_resolver()
        .iter()
        .map(|(key, _)| key.into_owned())
        .collect();
    let resolver = app.clone();
    let assets: Assets = exact_assets(known, move |path: &str| {
        resolver
            .asset_resolver()
            .get(path.to_string())
            .map(|a| a.bytes)
    });
    let dir = crate::klepsydra_dir(app);
    let clips: Clips = Arc::new(move |id: &str| klepsydra_fleet::reply::read(dir.as_deref()?, id));
    let dirs = crate::usage_dirs(app);
    let usage: Usage = Arc::new(move || klepsydra_fleet::usage::read(&dirs));
    match Server::spawn(ADDR, assets, clips, Some(usage)) {
        Ok(server) => {
            server.set_theme(crate::theme::saved(app));
            app.state::<crate::fleet::Fleet>()
                .with_latest(|v| server.publish(v));
            log::info!("phone: wall serving on {ADDR}");
            *slot = Some(server);
            true
        }
        Err(e) => {
            log::warn!("phone: no wall on {ADDR}, so Phone wall stays unticked: {e}");
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

/// Have a running server's phones wear theme `id`.
pub fn set_theme(app: &AppHandle, id: &str) {
    if let Ok(slot) = app.state::<Phone>().0.lock() {
        if let Some(server) = slot.as_ref() {
            server.set_theme(id);
        }
    }
}
