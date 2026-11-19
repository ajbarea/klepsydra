//! The gauges' on/off settings (#421): set in the wall's gear or by the
//! header's chevron, kept in prefs.json and sent to every window that
//! follows them, so a switch applies at once and the next start keeps it.

use klepsydra_fleet::hub::Hub;
use klepsydra_fleet::toggles;
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

/// Who follows the toggles, each sent every saved value when it subscribes
/// and again after each change.
#[derive(Default)]
pub struct Toggles(Hub<crate::fleet::Webview>);

/// A window follows the toggles from now on, starting with the saved ones.
#[tauri::command]
pub fn toggles_subscribe(
    window: tauri::WebviewWindow,
    toggles: tauri::State<'_, Toggles>,
    on_message: Channel<Value>,
) {
    toggles
        .0
        .subscribe(window.label(), crate::fleet::Webview(on_message));
}

/// Save one toggle and send every window the values now saved; an error
/// when the key is unknown or prefs.json did not take it, so the switch can
/// show the saved value again and say why.
#[tauri::command]
pub fn set_gauge_toggle(app: AppHandle, key: String, on: bool) -> Result<(), String> {
    let t = toggles::find(&key)?;
    crate::write_pref(&app, t.key, Value::Bool(on));
    // Read back once: what the windows get and what the reply says agree.
    let prefs = crate::read_prefs(&app);
    app.state::<Toggles>()
        .0
        .publish(toggles::all(prefs.as_ref()));
    toggles::confirm(t, on, prefs.as_ref())
}

/// Send the saved toggles to every subscribed window.
pub fn publish(app: &AppHandle) {
    let prefs = crate::read_prefs(app);
    app.state::<Toggles>()
        .0
        .publish(toggles::all(prefs.as_ref()));
}
