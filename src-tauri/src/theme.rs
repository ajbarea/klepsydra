//! The character theme (#135): chosen in the tray's Characters menu or the
//! wall's picker, kept in prefs.json, and sent to every window that follows
//! it and to the phone wall, so a switch applies without a restart.

use std::sync::Mutex;

use klepsydra_fleet::hub::Hub;
use klepsydra_fleet::theme::{self, THEMES};
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::menu::{CheckMenuItem, Submenu};
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
pub struct ThemeMenu(Mutex<Vec<(&'static str, CheckMenuItem<Wry>)>>);

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

/// Save the theme chosen on the wall and apply it everywhere.
#[tauri::command]
pub fn set_theme(app: AppHandle, theme: String) -> Result<(), String> {
    crate::write_pref(&app, theme::KEY, theme::value(&theme)?);
    publish(&app);
    Ok(())
}

/// Send the theme now saved to every window, the phone wall and the tray's
/// ticks, so all of them and the next start agree even if the save failed.
pub fn publish(app: &AppHandle) {
    let now = saved(app);
    app.state::<Themes>().0.publish(Value::from(now));
    crate::phone::set_theme(app, now);
    if let Ok(items) = app.state::<ThemeMenu>().0.lock() {
        for (id, item) in items.iter() {
            let _ = item.set_checked(*id == now);
        }
    }
}

/// The tray's Characters submenu, one ticked item per theme.
pub fn menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    let now = saved(app);
    let mut items = Vec::new();
    for (id, label) in THEMES {
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
    let submenu = Submenu::with_items(app, "Characters", true, &refs)?;
    if let Ok(mut held) = app.state::<ThemeMenu>().0.lock() {
        *held = items;
    }
    app.state::<Themes>().0.publish(Value::from(now));
    Ok(submenu)
}

/// A tray click: when it was on a theme's item, save that theme and apply it
/// everywhere (a click on the ticked item unticks it; `publish` ticks it
/// again). False for any other item.
pub fn on_menu(app: &AppHandle, menu_id: &str) -> bool {
    let Some(id) = menu_id
        .strip_prefix(MENU_PREFIX)
        .and_then(|w| THEMES.iter().map(|(t, _)| *t).find(|t| *t == w))
    else {
        return false;
    };
    if let Ok(v) = theme::value(id) {
        crate::write_pref(app, theme::KEY, v);
    }
    publish(app);
    true
}
