//! The tray's Voices submenu (#183): who speaks through keryx, kept in
//! prefs.json where `fleet/launch.sh` reads it, so a change applies at each
//! session's next fresh start.

use std::sync::Mutex;

use klepsydra_fleet::voices::{self, VOICES};
use tauri::menu::{CheckMenuItem, Submenu};
use tauri::{AppHandle, Manager, Wry};

/// The tray's id for each mode's item.
const MENU_PREFIX: &str = "voices:";

/// The tray's Voices items, ticked to match the saved mode after any change.
#[derive(Default)]
pub struct VoicesMenu(Mutex<Vec<(&'static str, CheckMenuItem<Wry>)>>);

/// The saved mode, or the default.
pub fn saved(app: &AppHandle) -> &'static str {
    voices::of(crate::read_prefs(app).as_ref())
}

/// Tick the saved mode's item, and only it.
fn tick(app: &AppHandle) {
    let now = saved(app);
    if let Ok(items) = app.state::<VoicesMenu>().0.lock() {
        for (id, item) in items.iter() {
            let _ = item.set_checked(*id == now);
        }
    }
}

/// The tray's Voices submenu, one ticked item per mode.
pub fn menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    let now = saved(app);
    let mut items = Vec::new();
    for (id, label) in VOICES {
        let item = CheckMenuItem::with_id(
            app,
            format!("{MENU_PREFIX}{id}"),
            label,
            true,
            id == now,
            None::<&str>,
        )?;
        items.push((id, item));
    }
    let refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> = items
        .iter()
        .map(|(_, i)| i as &dyn tauri::menu::IsMenuItem<Wry>)
        .collect();
    let submenu = Submenu::with_items(app, "Voices", true, &refs)?;
    if let Ok(mut held) = app.state::<VoicesMenu>().0.lock() {
        *held = items;
    }
    Ok(submenu)
}

/// A tray click: when it was on a mode's item, save that mode (a click on the
/// ticked item unticks it; `tick` ticks it again). False for any other item.
pub fn on_menu(app: &AppHandle, menu_id: &str) -> bool {
    let Some(id) = menu_id
        .strip_prefix(MENU_PREFIX)
        .and_then(|w| VOICES.iter().map(|(v, _)| *v).find(|v| *v == w))
    else {
        return false;
    };
    if let Ok(v) = voices::value(id) {
        crate::write_pref(app, voices::KEY, v);
        log::info!(voices = id; "voices: saved; each session takes it at its next fresh start");
    }
    tick(app);
    true
}
