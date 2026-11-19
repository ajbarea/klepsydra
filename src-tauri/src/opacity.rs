//! The gauge's background opacity (#438): set on the wall's slider, kept in
//! prefs.json and sent to every window that draws a gauge, so a change
//! shows at once on the floating strip and the next start keeps it.

use klepsydra_fleet::hub::Hub;
use klepsydra_fleet::opacity;
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

/// Who follows the opacity: the gauge and the wall, each sent the saved
/// value when it subscribes and again after each change.
#[derive(Default)]
pub struct Opacities(Hub<crate::fleet::Webview>);

/// The saved opacity, or the default.
pub fn saved(app: &AppHandle) -> u8 {
    opacity::of(crate::read_prefs(app).as_ref())
}

/// A window follows the opacity from now on, starting with the saved one.
#[tauri::command]
pub fn opacity_subscribe(
    window: tauri::WebviewWindow,
    opacities: tauri::State<'_, Opacities>,
    on_message: Channel<Value>,
) {
    opacities
        .0
        .subscribe(window.label(), crate::fleet::Webview(on_message));
}

/// Save the opacity picked on the wall and apply it everywhere; an error
/// when it is not 0 to 100, or prefs.json did not take it, so the slider
/// can show the saved value again and say why.
#[tauri::command]
pub fn set_gauge_opacity(app: AppHandle, opacity: f64) -> Result<(), String> {
    let v = opacity::value(opacity)?;
    let asked = opacity::snap(opacity);
    crate::write_pref(&app, opacity::KEY, v);
    publish(&app);
    opacity::confirm(asked, saved(&app))
}

/// Send the opacity now saved to every subscribed window, so they and the
/// next start agree even if the save failed.
pub fn publish(app: &AppHandle) {
    app.state::<Opacities>().0.publish(Value::from(saved(app)));
}
