//! The character theme (#135): chosen in the wall's picker or on its
//! settings page (one code path, wall.js `chooseTheme`), kept in prefs.json, and sent to every window that follows
//! it and to the phone wall, so a switch applies without a restart.

use klepsydra_fleet::hub::Hub;
use klepsydra_fleet::theme;
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

/// Who follows the theme: the gauge's strip and the wall, each sent the saved
/// theme when it subscribes and again after each change. A type of its own,
/// since Tauri keys state by type.
#[derive(Default)]
pub struct Themes(Hub<crate::fleet::Webview>);

/// The saved theme, or the default.
pub fn saved(app: &AppHandle) -> &'static str {
    theme::of(crate::read_prefs(app).as_ref())
}

/// A window follows the theme from now on, starting with the saved one.
#[tauri::command]
pub fn theme_subscribe(
    window: tauri::WebviewWindow,
    themes: tauri::State<'_, Themes>,
    on_message: Channel<Value>,
) {
    themes
        .0
        .subscribe(window.label(), crate::fleet::Webview(on_message));
}

/// Save the theme chosen on the wall and apply it everywhere; an error when
/// prefs.json did not take it, so the wall can say why it wears the saved
/// theme again. The wall logs the refusal; `write_pref` logs its cause.
#[tauri::command]
pub fn set_theme(app: AppHandle, theme: String) -> Result<(), String> {
    crate::write_pref(&app, theme::KEY, theme::value(&theme)?);
    publish(&app);
    theme::confirm(&theme, crate::read_prefs(&app).as_ref())
}

/// Write theme `id`'s file to the data folder's `cast.json`, where the fleet
/// hook reads each session's tmux window colour; a failure is logged.
fn write_hook_cast(app: &AppHandle, id: &str) {
    let Some(dir) = crate::klepsydra_dir(app) else {
        return;
    };
    let bytes = app
        .asset_resolver()
        .get(format!("fleet/themes/{id}.json"))
        .map(|a| a.bytes);
    let written = match bytes {
        Some(b) => theme::write_cast(&dir, &b),
        None => Err(std::io::Error::other("not in the bundle")),
    };
    if let Err(e) = written {
        log::error!(
            "theme: {} not written for theme {id}, so tmux windows keep the last theme's colours: {e}",
            theme::HOOK_CAST
        );
    }
}

/// Send the theme now saved to every window (and to each that subscribes
/// later), the phone wall and the hook's cast, so all of them and the next
/// start agree even if the save failed. Run at start and after each save.
pub fn publish(app: &AppHandle) {
    let now = saved(app);
    write_hook_cast(app, now);
    app.state::<Themes>().0.publish(Value::from(now));
    crate::phone::set_theme(app, now);
}
