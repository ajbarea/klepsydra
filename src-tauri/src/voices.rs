//! The tray's Voices submenu (#183, #273, #337): who speaks through keryx. A
//! click saves the mode to prefs.json and runs `fleet voices` at once, so
//! keryx follows it for running sessions too (the resume service applies a
//! change it missed). Each time the tray menu opens, the tick follows what
//! keryx does now, read from keryx's own config, so a `keryx off` or a
//! `fleet voices heph` done elsewhere shows; a state no mode matches ticks
//! nothing, and the status line names it.

use klepsydra_fleet::voices::{self, Reader, Shown, VOICES};
use tauri::menu::{MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Manager, Wry};

/// The tray's id for each mode's item.
const MENU_PREFIX: &str = "voices:";

/// The tray's Voices items, the status line above them, and the reader that
/// fills both on each menu open. Nothing read is kept between opens.
#[derive(Default)]
pub struct VoicesMenu {
    items: crate::choice::ChoiceItems,
    status: std::sync::Mutex<Option<MenuItem<Wry>>>,
    reader: Reader,
}

/// The saved mode, or the default.
pub fn saved(app: &AppHandle) -> &'static str {
    voices::of(crate::read_prefs(app).as_ref())
}

/// keryx's state now: the tick and status line to show, or `None` while an
/// earlier read is still out (it shows its own answer when it lands).
fn read(app: &AppHandle) -> Option<Shown> {
    let saved = saved(app);
    let Some(dir) = crate::klepsydra_dir(app) else {
        return Some(voices::unknown("no data folder"));
    };
    let late_app = app.clone();
    app.state::<VoicesMenu>()
        .reader
        .read(&dir, saved, voices::WAIT, move |late| {
            // The menu changes only on the main thread, where opens and clicks
            // run too: a late answer waits its turn there and applies only if
            // nothing newer was shown meanwhile.
            let app = late_app.clone();
            let _ = late_app.run_on_main_thread(move || {
                if app.state::<VoicesMenu>().reader.current(&late) {
                    show(&app, &late.shown);
                }
            });
        })
}

/// Show `s`: tick its mode (or none) and set the status line.
fn show(app: &AppHandle, s: &Shown) {
    let m = app.state::<VoicesMenu>();
    m.items.tick(s.tick.unwrap_or(""));
    let status = m.status.lock().ok().and_then(|held| held.clone());
    if let Some(status) = status {
        let _ = status.set_text(&s.says);
    }
}

/// The tray's Voices submenu: a disabled status line, then one item per
/// mode, ticked to match keryx.
pub fn menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    let s = read(app).unwrap_or_else(|| voices::unknown("reading keryx's config"));
    let m = app.state::<VoicesMenu>();
    let submenu = m
        .items
        .build(app, "Voices", MENU_PREFIX, &VOICES, s.tick.unwrap_or(""))?;
    let status = MenuItem::with_id(app, "voices-status", &s.says, false, None::<&str>)?;
    submenu.prepend_items(&[&status, &PredefinedMenuItem::separator(app)?])?;
    if let Ok(mut held) = m.status.lock() {
        *held = Some(status);
    }
    Ok(submenu)
}

/// The tray menu may be about to open (the pointer entered the tray icon, or
/// pressed it): read keryx afresh and show it. The press comes before the
/// release that opens the menu; entering gives the read a head start when a
/// busy main thread handles the press late.
pub fn on_open(app: &AppHandle) {
    if let Some(s) = read(app) {
        log::debug!(tick = s.tick.unwrap_or("none"); "voices: {}", s.says);
        show(app, &s);
    }
}

/// A tray click: when it was on a mode's item, save that mode (a click on the
/// ticked item unticks it; the tick follows the saved mode until the next
/// open reads keryx again). False for any other item.
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
        log::info!(voices = id; "voices: saved; keryx follows it now (fleet voices)");
        crate::launch::apply_voices();
    } else {
        log::warn!(voices = id, saved = now; "voices: not saved; the mode is still the saved one");
    }
    let m = app.state::<VoicesMenu>();
    m.reader.supersede();
    m.items.tick(now);
    true
}
