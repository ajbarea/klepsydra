//! The character theme (#135): chosen in the tray's Characters menu or the
//! wall's picker, kept in prefs.json, and sent to every window that follows
//! it and to the phone wall, so a switch applies without a restart.

use klepsydra_fleet::hub::Hub;
use klepsydra_fleet::theme::{self, THEMES};
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::menu::Submenu;
use tauri::{AppHandle, Manager, Wry};

/// The tray's id for each theme's item.
const MENU_PREFIX: &str = "theme:";

/// Who follows the theme: the gauge's strip and the wall, each sent the saved
/// theme when it subscribes and again after each change. A type of its own,
/// since Tauri keys state by type.
#[derive(Default)]
pub struct Themes(Hub<crate::fleet::Webview>);

/// The tray's theme items, ticked to match the saved theme after any change.
#[derive(Default)]
pub struct ThemeMenu(crate::choice::ChoiceItems);

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
    theme::confirm(&theme, saved(&app))
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

/// Send the theme now saved to every window, the phone wall, the hook's
/// cast and the tray's ticks, so all of them and the next start agree even
/// if the save failed.
pub fn publish(app: &AppHandle) {
    let now = saved(app);
    write_hook_cast(app, now);
    app.state::<Themes>().0.publish(Value::from(now));
    crate::phone::set_theme(app, now);
    app.state::<ThemeMenu>().0.tick(now);
}

/// The tray's Characters submenu, one ticked item per theme.
pub fn menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    let now = saved(app);
    let submenu = app
        .state::<ThemeMenu>()
        .0
        .build(app, "Characters", MENU_PREFIX, &THEMES, now)?;
    app.state::<Themes>().0.publish(Value::from(now));
    write_hook_cast(app, now);
    Ok(submenu)
}

/// A tray click: when it was on a theme's item, save that theme and apply it
/// everywhere (a click on the ticked item unticks it; `publish` ticks it
/// again). False for any other item.
pub fn on_menu(app: &AppHandle, menu_id: &str) -> bool {
    let Some(id) = crate::choice::picked(menu_id, MENU_PREFIX, &THEMES) else {
        return false;
    };
    if let Ok(v) = theme::value(id) {
        crate::write_pref(app, theme::KEY, v);
    }
    publish(app);
    true
}
