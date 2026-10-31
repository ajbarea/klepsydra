//! The tray's Voices submenu (#183): who speaks through keryx, kept in
//! prefs.json where `fleet/launch.sh` reads it, so a change applies to each
//! session launch.sh starts from then on.

use klepsydra_fleet::voices::{self, VOICES};
use tauri::menu::Submenu;
use tauri::{AppHandle, Manager, Wry};

/// The tray's id for each mode's item.
const MENU_PREFIX: &str = "voices:";

/// The tray's Voices items, ticked to match the saved mode after any change.
#[derive(Default)]
pub struct VoicesMenu(crate::choice::ChoiceItems);

/// The saved mode, or the default.
pub fn saved(app: &AppHandle) -> &'static str {
    voices::of(crate::read_prefs(app).as_ref())
}

/// The tray's Voices submenu, one ticked item per mode.
pub fn menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    app.state::<VoicesMenu>()
        .0
        .build(app, "Voices", MENU_PREFIX, &VOICES, saved(app))
}

/// A tray click: when it was on a mode's item, save that mode (a click on the
/// ticked item unticks it; the tick follows the saved mode again). False for
/// any other item.
pub fn on_menu(app: &AppHandle, menu_id: &str) -> bool {
    let Some(id) = crate::choice::picked(menu_id, MENU_PREFIX, &VOICES) else {
        return false;
    };
    if let Ok(v) = voices::value(id) {
        crate::write_pref(app, voices::KEY, v);
    }
    // write_pref logs its own failure; this says which mode holds now.
    let now = saved(app);
    if now == id {
        log::info!(voices = id; "voices: saved; sessions fleet/launch.sh starts from now on take it");
    } else {
        log::warn!(voices = id, saved = now; "voices: not saved; the mode is still the saved one");
    }
    app.state::<VoicesMenu>().0.tick(now);
    true
}
