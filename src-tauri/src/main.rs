#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod fleet;
mod folder;
mod geometry;
mod jump;
mod launch;
mod logging;
mod phone;
#[cfg(windows)]
mod ping;
mod split;
mod theme;
mod voices;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use geometry::{Display, Home, Rect};
use tauri::{
    ipc::Channel,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager, PhysicalPosition,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_window_state::AppHandleExt;

/// The grab handle, in CSS pixels relative to the window's top-left. The
/// frontend owns the layout and reports it, so restyling cannot desync this.
#[derive(Default)]
struct Grip(Mutex<Option<[f64; 4]>>);

/// Set when the window moves or resizes other than by dragging, so the grip
/// watcher re-reads its cached placement at once rather than up to half a
/// second later, when a wheel notch could already have missed the grip.
#[derive(Default)]
struct Moved(AtomicBool);

/// Whether the window has been sized since launch. The first sizing restores
/// the last placement by the edges it sat on; later ones grow away from them.
#[derive(Default)]
struct Sized(AtomicBool);

/// The placement last requested, and when. X11 applies moves and resizes
/// asynchronously, so for a moment the window still reports its old rect;
/// sizing and the grip watcher use this one until it has had time to land.
#[derive(Default)]
struct Requested(Mutex<Option<(Rect, Instant)>>);

const SETTLE: Duration = Duration::from_millis(500);

/// Where the statusLine hook publishes: `%LOCALAPPDATA%\dev.ajsoftworks.klepsydra`
/// on Windows, `$XDG_DATA_HOME/dev.ajsoftworks.klepsydra` (else under
/// `~/.local/share`) on Linux. Tauri's app-local-data dir rather than the install dir: a
/// per-machine install puts the latter under Program Files, where the hook
/// cannot write, and the uninstaller's "delete app data" only reaches this one.
fn klepsydra_dir(app: &tauri::AppHandle) -> Option<PathBuf> {
    // An override that is empty or relative would put `accounts` under whatever
    // the working directory happens to be -- for a Run-key launch, the install
    // directory again.
    match std::env::var("KLEPSYDRA_DIR").map(PathBuf::from) {
        Ok(explicit) if explicit.is_absolute() => return Some(explicit),
        _ => {}
    }
    app.path().app_local_data_dir().ok()
}

/// Where readings and the autostart marker lived before they moved out of the
/// install directory. Read, never written. Only Windows builds ever wrote there.
///
/// Resolved through the same call as the new location rather than through
/// `%LOCALAPPDATA%`: Windows answers the known-folder query and the environment
/// variable separately, and under folder redirection they disagree -- which
/// here would read as a fresh install.
fn legacy_dir(app: &tauri::AppHandle) -> Option<PathBuf> {
    if !cfg!(windows) {
        return None;
    }
    let root = app.path().local_data_dir().ok()?;
    root.is_absolute().then(|| root.join("klepsydra"))
}

/// Where the statusLine hook has published: the data folder, and the old
/// location too, since the hook is a copy in the user's ~/.claude and an
/// upgraded overlay meets a hook still publishing where it always did.
fn usage_dirs(app: &tauri::AppHandle) -> Vec<PathBuf> {
    [klepsydra_dir(app), legacy_dir(app)]
        .into_iter()
        .flatten()
        .collect()
}

/// Every published reading, one per Claude Code session.
///
/// A file per session (under a directory per account) means neither separate
/// logins nor several terminals on one login ever contend for a file. Sessions
/// of the same account disagree routinely -- each holds whatever the last API
/// response it saw reported -- so reconciling them is the frontend's job, as
/// is a session appearing in both folders.
#[tauri::command]
fn read_usage(app: tauri::AppHandle) -> serde_json::Value {
    serde_json::Value::Array(klepsydra_fleet::usage::read(usage_dirs(&app)))
}

/// The prefs file's name in the data folder.
const PREFS_FILE: &str = "prefs.json";

/// Small settings the gauge keeps for itself: the zoom level, the saved home,
/// where the window last sat, the wall's card density, split mode, the
/// character theme and the Voices mode.
fn prefs_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    klepsydra_dir(app).map(|d| d.join(PREFS_FILE))
}

/// The prefs, empty when there is no file yet. `None` when one exists but
/// cannot be read or parsed, so a write never replaces it with less.
fn read_prefs(app: &tauri::AppHandle) -> Option<serde_json::Map<String, serde_json::Value>> {
    read_prefs_at(&prefs_path(app)?)
}

fn read_prefs_at(path: &std::path::Path) -> Option<serde_json::Map<String, serde_json::Value>> {
    match std::fs::read_to_string(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(Default::default()),
        Err(_) => None,
        Ok(text) => serde_json::from_str::<serde_json::Value>(&text)
            .ok()?
            .as_object()
            .cloned(),
    }
}

fn write_pref(app: &tauri::AppHandle, key: &str, value: serde_json::Value) {
    if let Some(path) = prefs_path(app) {
        write_pref_at(&path, key, value);
    }
}

/// One prefs.json write at a time in this process: each is a read, a change
/// and a rename, so two at once would lose one key or share the tmp file.
static PREFS_WRITE: Mutex<()> = Mutex::new(());

fn write_pref_at(path: &std::path::Path, key: &str, value: serde_json::Value) {
    let _one = PREFS_WRITE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(mut prefs) = read_prefs_at(path) else {
        log::error!(
            "{key} not saved: {PREFS_FILE} is not a readable JSON object, and is left as it is"
        );
        return;
    };
    prefs.insert(key.into(), value);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // tmp-then-rename, so a crash mid-write leaves the old file whole.
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::Value::Object(prefs).to_string();
    if let Err(e) = std::fs::write(&tmp, text).and_then(|()| std::fs::rename(&tmp, path)) {
        log::error!("{key} not saved to {PREFS_FILE}: {e}");
    }
}

/// Each layout keeps its own zoom: compact is sized to the taskbar, the full
/// layout to the desk.
fn zoom_key(layout: Option<&str>) -> &'static str {
    if layout == Some("compact") {
        "zoom_compact"
    } else {
        "zoom"
    }
}

#[tauri::command]
fn get_zoom(app: tauri::AppHandle, layout: Option<String>) -> i64 {
    read_prefs(&app)
        .and_then(|p| p.get(zoom_key(layout.as_deref()))?.as_i64())
        .unwrap_or(0)
}

fn rect_json(r: Rect) -> serde_json::Value {
    serde_json::json!({ "x": r.x, "y": r.y, "w": r.w, "h": r.h })
}

fn json_rect(v: &serde_json::Value) -> Option<Rect> {
    let int = |k: &str| -> Option<i32> { Some(v.get(k)?.as_i64()? as i32) };
    Some(Rect::new(int("x")?, int("y")?, int("w")?, int("h")?))
}

#[tauri::command]
fn set_zoom(app: tauri::AppHandle, level: i64, layout: Option<String>) {
    write_pref(&app, zoom_key(layout.as_deref()), serde_json::json!(level));
}

/// The gauge's layout: "compact" (a ring per window in one row, low enough to
/// sit inside the taskbar) or "full" (a bar per window).
fn layout_of(app: &tauri::AppHandle) -> &'static str {
    match read_prefs(app).and_then(|p| p.get("layout")?.as_str().map(str::to_owned)) {
        Some(l) if l == "compact" => "compact",
        _ => "full",
    }
}

/// Who follows the layout: the gauge, sent the saved layout when it subscribes
/// and again after each change from Settings. A type of its own, not an alias:
/// the fleet's hub is managed state of the same shape.
#[derive(Default)]
struct Layouts(klepsydra_fleet::hub::Hub<fleet::Webview>);

#[tauri::command]
fn layout_subscribe(
    window: tauri::WebviewWindow,
    layouts: tauri::State<'_, Layouts>,
    on_message: Channel<serde_json::Value>,
) {
    layouts
        .0
        .subscribe(window.label(), fleet::Webview(on_message));
}

/// Save a layout chosen in settings and send the gauge the layout now saved,
/// so the gauge, the page and the next start agree even if the save failed.
/// True when that layout is compact.
fn set_layout(app: &tauri::AppHandle, compact: bool) -> bool {
    let want = if compact { "compact" } else { "full" };
    write_pref(app, "layout", serde_json::json!(want));
    let saved = layout_of(app);
    app.state::<Layouts>().0.publish(serde_json::json!(saved));
    saved == "compact"
}

/// Whether the gauge is compact now, for the settings page.
#[tauri::command]
fn get_layout(app: tauri::AppHandle) -> bool {
    layout_of(&app) == "compact"
}

/// Settings' "Compact layout": what [`set_layout`] saved and sent the gauge.
#[tauri::command]
fn set_layout_mode(app: tauri::AppHandle, compact: bool) -> bool {
    set_layout(&app, compact)
}

/// Start at login as the system has it, whether `KLEPSYDRA_NO_AUTOSTART`
/// holds it as it is, and the row's name on this system.
#[derive(serde::Serialize)]
struct Autostart {
    on: bool,
    held: bool,
    label: &'static str,
}

fn autostart_now(app: &tauri::AppHandle) -> Autostart {
    Autostart {
        on: app.autolaunch().is_enabled().unwrap_or(false),
        held: autostart_held(),
        label: if cfg!(windows) {
            "Start with Windows"
        } else {
            "Start at login"
        },
    }
}

#[tauri::command]
fn get_autostart(app: tauri::AppHandle) -> Autostart {
    autostart_now(&app)
}

/// Settings' "Start with Windows": set the login entry unless held, then
/// return what the system has, which is what the row shows.
#[tauri::command]
fn set_autostart(app: tauri::AppHandle, enabled: bool) -> Autostart {
    if !autostart_held() {
        let mgr = app.autolaunch();
        let done = if enabled { mgr.enable() } else { mgr.disable() };
        if let Err(e) = done {
            log::error!(enabled = enabled; "autostart: the login entry did not change: {e}");
        }
    }
    autostart_now(&app)
}

/// Ping's saved state. Ping plays only on Windows; elsewhere the settings
/// page hides the row, as the tray had no Ping item there.
#[tauri::command]
fn get_ping(app: tauri::AppHandle) -> Result<bool, String> {
    if !cfg!(windows) {
        return Err("Ping plays on Windows only.".into());
    }
    Ok(ping_saved(&app))
}

fn ping_saved(app: &tauri::AppHandle) -> bool {
    read_prefs(app)
        .and_then(|p| p.get("ping")?.as_bool())
        .unwrap_or(false)
}

/// Settings' "Ping": save it, play the chime it turns on, and return the
/// state prefs.json kept.
#[tauri::command]
fn set_ping(app: tauri::AppHandle, on: bool) -> Result<bool, String> {
    if !cfg!(windows) {
        return Err("Ping plays on Windows only.".into());
    }
    write_pref(&app, "ping", serde_json::json!(on));
    let saved = ping_saved(&app);
    #[cfg(windows)]
    {
        ping::set(saved);
        if saved && on {
            ping::preview(klepsydra_fleet::cue::Cue::NeedsYou);
        }
    }
    Ok(saved)
}

/// Whether the phone wall is serving now (a busy port leaves it off even
/// when saved on).
#[tauri::command]
fn get_phone_wall(app: tauri::AppHandle) -> bool {
    phone::serving(&app)
}

/// Settings' "Phone wall": save the choice and return whether it serves now.
#[tauri::command]
fn set_phone_wall(app: tauri::AppHandle, on: bool) -> bool {
    write_pref(&app, phone::PREF, serde_json::json!(on));
    phone::set(&app, on)
}

/// Settings' "Reset position".
#[tauri::command]
fn reset_gauge_position(app: tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = reset_position(w.clone());
        raise_above_taskbar(&w);
    }
}

/// Settings' "Set home here".
#[tauri::command]
fn set_gauge_home(app: tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        set_home(&w);
    }
}

/// The tray menu's items (#384): every setting lives on the settings page.
const TRAY_MENU_ITEMS: [(&str, &str); 3] = [
    ("open_wall", "Open wall"),
    ("settings", "Settings..."),
    ("quit", "Quit"),
];

/// The tray menu, one item per [`TRAY_MENU_ITEMS`] entry.
fn build_tray_menu<R: tauri::Runtime, M: tauri::Manager<R>>(app: &M) -> tauri::Result<Menu<R>> {
    let items = TRAY_MENU_ITEMS
        .iter()
        .map(|(id, label)| MenuItem::with_id(app, *id, *label, true, None::<&str>))
        .collect::<tauri::Result<Vec<_>>>()?;
    let refs: Vec<&dyn tauri::menu::IsMenuItem<R>> = items
        .iter()
        .map(|i| i as &dyn tauri::menu::IsMenuItem<R>)
        .collect();
    Menu::with_items(app, &refs)
}

/// Where the window is: the rect last requested while it may still be landing,
/// else what the window reports.
fn current(window: &tauri::WebviewWindow) -> Option<Rect> {
    let requested = window.state::<Requested>().0.lock().ok().and_then(|r| *r);
    requested
        .filter(|(_, at)| at.elapsed() < SETTLE)
        .map(|(r, _)| r)
        .or_else(|| placement(window))
}

fn placement(window: &tauri::WebviewWindow) -> Option<Rect> {
    let pos = window.outer_position().ok()?;
    let size = window.outer_size().ok()?;
    Some(Rect::new(
        pos.x,
        pos.y,
        size.width as i32,
        size.height as i32,
    ))
}

fn monitor_rect(m: &tauri::Monitor) -> Rect {
    Rect::new(
        m.position().x,
        m.position().y,
        m.size().width as i32,
        m.size().height as i32,
    )
}

fn display_of(m: &tauri::Monitor) -> Display {
    Display {
        name: m.name().cloned(),
        bounds: monitor_rect(m),
        scale: m.scale_factor(),
    }
}

/// Move and resize to `to`, and tell the grip watcher, which also saves the
/// spot once the moves settle.
fn place(window: &tauri::WebviewWindow, from: Rect, to: Rect) -> Result<(), String> {
    if to == from {
        return Ok(());
    }
    if let Ok(mut r) = window.state::<Requested>().0.lock() {
        *r = Some((to, Instant::now()));
    }
    move_resize(window, to)?;
    window.state::<Moved>().0.store(true, Ordering::Relaxed);
    Ok(())
}

/// One SetWindowPos, so no frame shows the new size at the old spot, which
/// could cross onto another monitor and set off a DPI change mid-move.
#[cfg(windows)]
fn move_resize(window: &tauri::WebviewWindow, r: Rect) -> Result<(), String> {
    const SWP_NOZORDER: u32 = 0x0004;
    const SWP_NOACTIVATE: u32 = 0x0010;
    let hwnd = window.hwnd().map_err(|e| e.to_string())?;
    let flags = SWP_NOZORDER | SWP_NOACTIVATE;
    match unsafe { win32::SetWindowPos(hwnd.0 as isize, 0, r.x, r.y, r.w, r.h, flags) } {
        0 => Err("SetWindowPos failed".into()),
        _ => Ok(()),
    }
}

#[cfg(not(windows))]
fn move_resize(window: &tauri::WebviewWindow, r: Rect) -> Result<(), String> {
    window
        .set_position(PhysicalPosition::new(r.x, r.y))
        .map_err(|e| e.to_string())?;
    window
        .set_size(tauri::PhysicalSize::new(r.w as u32, r.h as u32))
        .map_err(|e| e.to_string())
}

/// The frontend reports the size its panel needs (CSS pixels): a row per
/// account window, times the zoom, and the fleet strip beside it, with the
/// grip's and the strip's new rectangles. `pin` marks a zoom: the content
/// under the pointer, read now rather than when the wheel event fired, stays
/// under it, so the grip does too. Otherwise the window grows away from the
/// screen edges it sits nearest. Either way it is kept wholly on its monitor.
#[tauri::command]
fn set_size(
    window: tauri::WebviewWindow,
    width: f64,
    height: f64,
    pin: bool,
    grip: Option<[f64; 4]>,
    strip: Option<[f64; 4]>,
) -> Result<(), String> {
    if let (Some(g), Ok(mut slot)) = (grip, window.state::<Grip>().0.lock()) {
        *slot = Some(g);
    }
    if let Ok(mut slot) = window.state::<fleet::Strip>().0.lock() {
        *slot = strip;
    }
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let from = current(&window).ok_or("window placement unavailable")?;
    let w = (width.max(1.0) * scale).round() as i32;
    let h = (height.max(1.0) * scale).round() as i32;
    let first = !window.state::<Sized>().0.swap(true, Ordering::Relaxed);
    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .map(|m| monitor_rect(&m));

    let cursor = if pin && !first {
        pointer(window.app_handle())
    } else {
        None
    };
    // The window-state plugin restores only the top-left corner. If it is
    // where the window last sat, restore that rect by its edges instead, so a
    // gauge docked on the taskbar stays docked whatever its rows are now.
    let last = if first {
        read_prefs(window.app_handle())
            .and_then(|p| json_rect(p.get("last")?))
            .filter(|r| (r.x, r.y) == (from.x, from.y))
    } else {
        None
    };
    let mut to = match (first, last, cursor, monitor) {
        (true, Some(last), _, Some(m)) => geometry::grow_from_edges(last, w, h, m),
        (true, ..) => Rect { w, h, ..from },
        (false, _, Some(p), _) => {
            // Everything scales with the width, so its ratio is the zoom's.
            let ratio = w as f64 / from.w.max(1) as f64;
            let (px, py) = (p.x.round() as i32, p.y.round() as i32);
            let zoomed = geometry::grow_from_point(from, w, h, px, py, ratio);
            monitor.map_or(zoomed, |m| geometry::keep_docked(from, zoomed, m))
        }
        (false, _, None, Some(m)) => geometry::grow_from_edges(from, w, h, m),
        (false, _, None, None) => Rect { w, h, ..from },
    };
    if let Some(m) = monitor {
        to = geometry::clamp_into(to, m);
    }
    place(&window, from, to)
}

#[tauri::command]
fn set_grip(
    grip: tauri::State<'_, Grip>,
    strip_state: tauri::State<'_, fleet::Strip>,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    strip: Option<[f64; 4]>,
) {
    if let Ok(mut g) = grip.0.lock() {
        *g = Some([x, y, w, h]);
    }
    if let Ok(mut s) = strip_state.0.lock() {
        *s = strip;
    }
}

/// Re-assert topmost above every other topmost window, the taskbar included.
///
/// The taskbar is itself WS_EX_TOPMOST, and within that band z-order goes to
/// whoever was raised last -- so clicking the taskbar buries a gauge sitting
/// over it, taking the drag handle out of reach with it. Tauri's
/// `set_always_on_top` diffs against the flag it already holds and does
/// nothing, so re-inserting at the top of the band means calling SetWindowPos
/// directly. NOMOVE/NOSIZE keep the user's position, NOACTIVATE keeps focus
/// where it was.
#[cfg(windows)]
fn raise_above_taskbar(window: &tauri::WebviewWindow) {
    const HWND_TOPMOST: isize = -1;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOACTIVATE: u32 = 0x0010;

    if let Ok(hwnd) = window.hwnd() {
        unsafe {
            win32::SetWindowPos(
                hwnd.0 as isize,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }
}

#[cfg(not(windows))]
fn raise_above_taskbar(_window: &tauri::WebviewWindow) {}

#[cfg(windows)]
mod win32 {
    #[link(name = "user32")]
    unsafe extern "system" {
        pub fn SetWindowPos(
            hwnd: isize,
            insert_after: isize,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
            flags: u32,
        ) -> i32;
    }
}

fn displays(window: &tauri::WebviewWindow) -> Vec<Display> {
    window
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .map(display_of)
        .collect()
}

/// Remember where the gauge sits now, at its size, and on which monitor.
fn set_home(window: &tauri::WebviewWindow) {
    let (Some(at), Ok(Some(monitor))) = (current(window), window.current_monitor()) else {
        return;
    };
    let d = display_of(&monitor);
    let home = serde_json::json!({
        "rect": rect_json(at),
        "monitor": { "name": d.name, "bounds": rect_json(d.bounds), "scale": d.scale },
    });
    write_pref(window.app_handle(), "home", home);
}

fn saved_home(app: &tauri::AppHandle) -> Option<Home> {
    let prefs = read_prefs(app)?;
    let home = prefs.get("home")?;
    let m = home.get("monitor")?;
    Some(Home {
        rect: json_rect(home.get("rect")?)?,
        display: Display {
            name: m.get("name").and_then(|n| n.as_str()).map(String::from),
            bounds: json_rect(m.get("bounds")?)?,
            scale: m.get("scale").and_then(|s| s.as_f64()).unwrap_or(1.0),
        },
    })
}

/// Save where the window is, for the next launch: the plugin keeps its
/// corner, and the full rect lets the first sizing keep the edge it sat on.
fn remember(app: &tauri::AppHandle, window: &tauri::WebviewWindow) {
    let _ = app.save_window_state(tauri_plugin_window_state::StateFlags::POSITION);
    if let Some(r) = current(window) {
        write_pref(app, "last", rect_json(r));
    }
}

/// Put the gauge back where "Set home here" saved it, adjusted to the monitors
/// attached now. With no home, the default spot: over the primary monitor's
/// taskbar, 220px in from the right. Either way, wholly on screen.
///
/// The spot is worked out for the size the gauge will have at the destination
/// monitor's scale. The move itself keeps the current size: Windows rescales
/// the window as it lands on a monitor with a different scale, and sizing it
/// ahead of that would scale it twice.
#[tauri::command]
fn reset_position(window: tauri::WebviewWindow) -> Result<(), String> {
    let from = current(&window).ok_or("window placement unavailable")?;
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let (w, h) = (from.w as f64 / scale, from.h as f64 / scale);
    let home = saved_home(window.app_handle())
        .and_then(|home| geometry::home_rect(&home, w, h, &displays(&window)));
    let to = match home {
        Some(to) => to,
        None => {
            let primary = window
                .primary_monitor()
                .map_err(|e| e.to_string())?
                .ok_or("no primary monitor")?;
            geometry::default_rect(&display_of(&primary), w, h)
        }
    };
    place(
        &window,
        from,
        Rect {
            x: to.x,
            y: to.y,
            ..from
        },
    )
}

/// Draw the tray icon as a miniature of the bar: a capsule track with the fill
/// running to `pct`, in the colour the frontend resolved from the CSS ramp.
///
/// 32px rather than 16px so Windows downscales rather than us guessing which
/// tray size is in use.
fn gauge_icon(pct: f64, rgb: (u8, u8, u8)) -> tauri::image::Image<'static> {
    const N: usize = 32;
    const H: usize = 14; // bar height
    const M: usize = 3; // side margin

    let mut buf = vec![0u8; N * N * 4];
    let y0 = (N - H) / 2;
    let w = N - 2 * M;
    let r = (H / 2) as i32;
    let pct = pct.clamp(0.0, 100.0);
    let fill_w = ((w as f64) * pct / 100.0).round() as usize;
    // A nonzero reading keeps at least a round dot, matching the overlay.
    let fill_w = if pct > 0.0 { fill_w.max(H) } else { 0 };

    for y in y0..y0 + H {
        for x in M..M + w {
            // Capsule: circular at the two ends, square through the middle.
            let cx = if x < M + H / 2 {
                (M + H / 2) as i32
            } else if x >= M + w - H / 2 {
                (M + w - H / 2) as i32
            } else {
                x as i32
            };
            let (dx, dy) = (x as i32 - cx, y as i32 - (y0 + H / 2) as i32);
            if dx * dx + dy * dy > r * r {
                continue;
            }
            let (cr, cg, cb) = if x < M + fill_w { rgb } else { (70, 70, 70) };
            let i = (y * N + x) * 4;
            buf[i] = cr;
            buf[i + 1] = cg;
            buf[i + 2] = cb;
            buf[i + 3] = 255;
        }
    }
    tauri::image::Image::new_owned(buf, N as u32, N as u32)
}

/// Mirror the primary reading onto the tray icon, so the level stays readable
/// when the overlay is covered or a fullscreen app is in front.
#[tauri::command]
fn set_tray_level(app: tauri::AppHandle, pct: f64, r: u8, g: u8, b: u8) {
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(gauge_icon(pct, (r, g, b))));
    }
}

/// The pointer in physical desktop pixels, and whether the left button is down.
///
/// Read from the OS rather than the webview: `data-tauri-drag-region` needs a
/// focused window, and this one is deliberately unfocused and click-through,
/// so webview drag never fires. Polling the button here sidesteps that.
struct Pointer {
    x: f64,
    y: f64,
    pressed: bool,
}

/// Windows: straight from user32 on this thread. `AppHandle::cursor_position`
/// answers the same GetCursorPos from the event loop, so off the main thread
/// each call is a round trip that wakes it, 60 times a second at idle. The
/// process is per-monitor DPI aware, so these are physical desktop pixels.
#[cfg(windows)]
fn pointer(_app: &tauri::AppHandle) -> Option<Pointer> {
    #[repr(C)]
    struct Point {
        x: i32,
        y: i32,
    }
    #[link(name = "user32")]
    unsafe extern "system" {
        fn GetAsyncKeyState(key: i32) -> i16;
        fn GetCursorPos(point: *mut Point) -> i32;
    }
    const VK_LBUTTON: i32 = 0x01;
    let mut cursor = Point { x: 0, y: 0 };
    if unsafe { GetCursorPos(&mut cursor) } == 0 {
        return None;
    }
    let pressed = unsafe { (GetAsyncKeyState(VK_LBUTTON) as u16 & 0x8000) != 0 };
    Some(Pointer {
        x: f64::from(cursor.x),
        y: f64::from(cursor.y),
        pressed,
    })
}

/// X11: one XQueryPointer on the root window answers both, over the watcher
/// thread's own connection, so polling queues nothing on the GTK main loop. A
/// failed or dropped connection is retried, so an X server that was not ready
/// at login costs dragging only until the next attempt.
///
/// Off X11 it answers nothing. A Wayland compositor shows clients no global
/// pointer, and XWayland sees only presses over X11 windows, so the handle
/// stays inert rather than reacting to another window's clicks.
#[cfg(target_os = "linux")]
fn pointer(_app: &tauri::AppHandle) -> Option<Pointer> {
    use std::cell::RefCell;
    use std::sync::OnceLock;
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, KeyButMask, Window};
    use x11rb::rust_connection::RustConnection;

    const RETRY: Duration = Duration::from_secs(2);
    type Link = Option<(RustConnection, Window)>;
    thread_local! {
        static X: RefCell<(Link, Option<Instant>)> = const { RefCell::new((None, None)) };
    }
    // GDK's choice: Wayland whenever a compositor is reachable, unless forced.
    static ON_X11: OnceLock<bool> = OnceLock::new();
    let on_x11 = *ON_X11.get_or_init(|| match std::env::var("GDK_BACKEND") {
        Ok(backend) if backend.starts_with("x11") => true,
        _ => std::env::var_os("WAYLAND_DISPLAY").is_none(),
    });
    if !on_x11 {
        return None;
    }

    X.with_borrow_mut(|(link, last_try)| {
        if link.is_none() {
            if last_try.is_some_and(|t| t.elapsed() < RETRY) {
                return None;
            }
            *last_try = Some(Instant::now());
            *link = x11rb::connect(None).ok().map(|(conn, screen)| {
                let root = conn.setup().roots[screen].root;
                (conn, root)
            });
        }
        let (conn, root) = link.as_ref()?;
        let reply = conn
            .query_pointer(*root)
            .ok()
            .and_then(|cookie| cookie.reply().ok());
        if reply.is_none() {
            *link = None;
        }
        reply.map(|r| Pointer {
            x: r.root_x as f64,
            y: r.root_y as f64,
            pressed: r.mask.contains(KeyButMask::BUTTON1),
        })
    })
}

#[cfg(not(any(windows, target_os = "linux")))]
fn pointer(app: &tauri::AppHandle) -> Option<Pointer> {
    let cursor = app.cursor_position().ok()?;
    Some(Pointer {
        x: cursor.x,
        y: cursor.y,
        pressed: false,
    })
}

/// The window's placement in physical desktop pixels, with its display scale,
/// as the pointer watcher caches it.
#[derive(Clone, Copy)]
struct Placed {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
}

fn placed(window: &tauri::WebviewWindow) -> Option<Placed> {
    let r = current(window)?;
    Some(Placed {
        x: r.x as f64,
        y: r.y as f64,
        w: r.w as f64,
        h: r.h as f64,
        scale: window.scale_factor().ok()?,
    })
}

/// An undecorated resizable window gets tao's edge-resize band on Linux: a press
/// within it starts a window-manager resize. Hit areas stop short of the band,
/// so a press there passes through instead. Windows is not resizable, so it
/// has no band.
fn resize_band(g: Placed) -> Option<f64> {
    cfg!(target_os = "linux").then(|| geometry::resize_inset(g.scale))
}

/// Neither Windows nor Tauri's X11 backend offers per-region hit testing for a
/// click-through window: ignoring cursor events is all-or-nothing. So we watch
/// the pointer and switch the whole window interactive only while it is over
/// the grab handle or the fleet strip. Everywhere else the gauge stays
/// click-through and never eats a click.
///
/// The same loop owns dragging, for the reason described on `Pointer`.
fn watch_grip(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut interactive = false;
        let mut ticks: u32 = 0;
        let mut was_pressed = false;
        // Cursor offset from the window origin, set when a drag begins.
        let mut drag_offset: Option<(f64, f64)> = None;
        // Every window getter is a round trip to the main thread, so the
        // placement is cached and refreshed twice a second. Only this loop's
        // drag moves the window quickly, and it updates the cache itself.
        let mut geo: Option<Placed> = None;
        // When to save the position after a resize or reset moved the window:
        // once the moves settle, not on every wheel notch.
        let mut save_at: Option<Instant> = None;
        loop {
            std::thread::sleep(Duration::from_millis(16));
            ticks = ticks.wrapping_add(1);
            let Some(window) = app.get_webview_window("main") else {
                continue;
            };
            let Some(rect) = app.state::<Grip>().0.lock().ok().and_then(|g| *g) else {
                continue;
            };
            let moved = app.state::<Moved>().0.swap(false, Ordering::Relaxed);
            if moved {
                save_at = Some(Instant::now() + Duration::from_millis(600));
            }
            if geo.is_none() || moved || (drag_offset.is_none() && ticks.is_multiple_of(30)) {
                geo = placed(&window);
            }
            if drag_offset.is_none() && save_at.is_some_and(|t| Instant::now() >= t) {
                save_at = None;
                remember(&app, &window);
            }
            let (Some(g), Some(cursor)) = (geo.as_mut(), pointer(&app)) else {
                continue;
            };

            // Hit areas in physical desktop coordinates. While already
            // interactive they are grown slightly, so a drag that outruns the
            // window by a pixel does not drop the mouse mid-move.
            let margin = if interactive { 8.0 } else { 0.0 };
            let band = resize_band(*g);
            let strip = app.state::<fleet::Strip>().0.lock().ok().and_then(|s| *s);
            let area = |css: [f64; 4]| {
                geometry::hit_area(css, (g.x, g.y), (g.w, g.h), g.scale, margin, band)
            };
            let on_grip = geometry::contains(area(rect), cursor.x, cursor.y);
            let on_strip = strip.is_some_and(|s| geometry::contains(area(s), cursor.x, cursor.y));
            let inside = on_grip || on_strip;

            // Only a press that *starts* on the handle begins a drag, so
            // dragging something else across the gauge cannot grab it.
            if cursor.pressed && !was_pressed && on_grip {
                drag_offset = Some((cursor.x - g.x, cursor.y - g.y));
                // The drag owns placement now; a pending request is stale.
                if let Ok(mut r) = app.state::<Requested>().0.lock() {
                    *r = None;
                }
            } else if !cursor.pressed && drag_offset.is_some() {
                drag_offset = None;
                remember(&app, &window);
            }
            was_pressed = cursor.pressed;

            if let Some((ox, oy)) = drag_offset {
                (g.x, g.y) = ((cursor.x - ox).round(), (cursor.y - oy).round());
                let _ = window.set_position(PhysicalPosition::new(g.x as i32, g.y as i32));
                continue; // hold interactivity and skip the re-assert mid-drag
            }

            if inside != interactive {
                interactive = inside;
                let _ = window.set_ignore_cursor_events(!inside);
            }

            // Twice a second. Measured: after the taskbar takes foreground the
            // gauge is buried until the next re-assert, so this interval is the
            // worst case it stays hidden.
            if ticks.is_multiple_of(30) {
                raise_above_taskbar(&window);
            }
        }
    });
}

/// The app's managed state. Tauri keys state by type and panics at startup on
/// a type managed twice, so each needs a type of its own; a test builds this.
fn with_state<R: tauri::Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    builder
        .manage(Grip::default())
        .manage(fleet::Strip::default())
        .manage(fleet::Fleet::default())
        .manage(fleet::QueueFeed::default())
        .manage(fleet::NeedsFeed::default())
        .manage(fleet::CiFeed::default())
        .manage(fleet::HealthFeed::default())
        .manage(Moved::default())
        .manage(Sized::default())
        .manage(Requested::default())
        .manage(Layouts::default())
        .manage(launch::InFlight::default())
        .manage(launch::AgyModels::default())
        .manage(launch::PaneFlight::default())
        .manage(launch::JumpFlight::default())
        .manage(phone::Phone::default())
        .manage(theme::Themes::default())
        .manage(voices::VoicesReader::default())
        .manage(split::Follow::default())
}

/// `KLEPSYDRA_NO_AUTOSTART` set to anything but empty: this copy leaves the
/// login entry alone. The entry is one per app name, so a test copy started
/// with its own `KLEPSYDRA_DIR` would otherwise point it at itself.
fn autostart_held() -> bool {
    std::env::var_os("KLEPSYDRA_NO_AUTOSTART").is_some_and(|v| !v.is_empty())
}

fn main() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_window_state::Builder::default()
                // Position only: the window sizes itself to its rows and zoom,
                // so a restored size would fight set_size on every launch.
                .with_state_flags(tauri_plugin_window_state::StateFlags::POSITION)
                .build(),
        );
    with_state(builder)
        .invoke_handler(tauri::generate_handler![
            read_usage,
            set_size,
            get_zoom,
            set_zoom,
            layout_subscribe,
            set_grip,
            reset_position,
            set_tray_level,
            fleet::fleet_subscribe,
            fleet::queue_subscribe,
            fleet::needs_subscribe,
            fleet::ci_subscribe,
            fleet::health_subscribe,
            fleet::open_wall,
            launch::open_folder,
            launch::open_github,
            split::get_split_mode,
            split::set_split_mode,
            split::split_subscribe,
            fleet::clear_session,
            fleet::ledger_today,
            fleet::reply_clip,
            launch::end_session,
            launch::interrupt_session,
            launch::start_wrapup,
            launch::cancel_wrapup,
            fleet::get_wall_density,
            fleet::set_wall_density,
            theme::theme_subscribe,
            theme::set_theme,
            voices::get_voices_mode,
            voices::set_voices_mode,
            fleet::open_settings,
            get_autostart,
            set_autostart,
            get_ping,
            set_ping,
            get_phone_wall,
            set_phone_wall,
            get_layout,
            set_layout_mode,
            reset_gauge_position,
            set_gauge_home,
            fleet::get_fleet_files,
            fleet::choose_queue_file,
            fleet::choose_needs_file,
            jump::jump_to_terminal,
            launch::launch_session,
            launch::agy_models,
            launch::engines_status,
            launch::new_session_prefs,
            launch::set_new_session_default,
            launch::get_launch_dir
        ])
        .setup(|app| {
            logging::start(app.handle());
            let window = app.get_webview_window("main").expect("main window");
            window.set_ignore_cursor_events(true)?;
            // GTK never sizes a non-resizable window below its content's
            // natural size, 200px for WebKit, so set_size could not shrink
            // it. Resizable arms tao's edge-resize band; watch_grip keeps the
            // grip out of it.
            #[cfg(target_os = "linux")]
            window.set_resizable(true)?;

            // Enable autostart once, on first run. Re-enabling unconditionally
            // would quietly undo the user turning it off in Settings. When it
            // is already on, re-register anyway so the recorded path follows the
            // executable if it moves.
            let autostart = app.autolaunch();
            let dir = klepsydra_dir(app.handle());
            let marker = dir.as_ref().map(|d| d.join("autostart-initialised"));
            let legacy = legacy_dir(app.handle()).map(|d| d.join("autostart-initialised"));
            let exists = |m: &Option<PathBuf>| m.as_ref().map(|m| m.exists()).unwrap_or(false);
            let first_run = marker.is_some() && !exists(&marker) && !exists(&legacy);
            if !autostart_held() && (first_run || autostart.is_enabled().unwrap_or(false)) {
                let _ = autostart.enable();
            }
            // Write the marker whenever it is missing, not only on a first run:
            // left unwritten, an upgraded install answers "have we been here
            // before?" out of the old directory forever, and tidying that
            // directory away silently re-enables autostart the user turned off.
            // A held copy decided nothing, so it leaves the first run unspent.
            if let Some(m) = marker.as_ref().filter(|m| !m.exists() && !autostart_held()) {
                if let Some(parent) = m.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = std::fs::write(m, "");
            }
            let layout = layout_of(app.handle());
            app.state::<Layouts>().0.publish(serde_json::json!(layout));
            #[cfg(windows)]
            ping::set(ping_saved(app.handle()));
            // Off unless saved on: the wall on loopback for Tailscale Serve (README).
            phone::set(app.handle(), phone::saved(app.handle()));
            // The saved theme to each window as it subscribes, and to the hook's cast.
            theme::publish(app.handle());

            let menu = build_tray_menu(app)?;
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().expect("bundled icon").clone())
                .tooltip("klepsydra")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| {
                    let settings = match event.id.as_ref() {
                        "open_wall" => false,
                        "settings" => true,
                        "quit" => return app.exit(0),
                        _ => return,
                    };
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move {
                        let opened = if settings {
                            fleet::open_settings(app).await
                        } else {
                            fleet::open_wall(app, String::new()).await
                        };
                        if let Err(e) = opened {
                            log::error!(settings = settings; "tray: the wall did not open: {e}");
                        }
                    });
                })
                .build(app)?;

            raise_above_taskbar(&window);
            watch_grip(app.handle().clone());
            fleet::start(app.handle(), klepsydra_dir(app.handle()));
            fleet::start_queue(app.handle());
            fleet::start_ci(app.handle(), klepsydra_dir(app.handle()));
            fleet::start_health(app.handle(), klepsydra_dir(app.handle()));
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building klepsydra")
        .run(|_, event| {
            // Before Tauri hides every window on its way out.
            if let tauri::RunEvent::Exit = event {
                // Logged, so the doctor's "phone wall: no answer" reads as a quit, not a mystery.
                log::info!("klepsydra quitting: the phone wall and the gauge stop with it");
                log::logger().flush();
                split::quitting();
            }
        });
}

#[cfg(test)]
mod tests {
    #[test]
    fn writers_of_different_keys_at_once_keep_every_key() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-prefs-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("prefs.json");
        let _ = std::fs::remove_file(&path);
        let writers: Vec<_> = (0..16)
            .map(|i| {
                let path = path.clone();
                std::thread::spawn(move || {
                    for n in 0..25 {
                        super::write_pref_at(&path, &format!("k{i}"), serde_json::json!(n));
                    }
                })
            })
            .collect();
        for w in writers {
            w.join().unwrap();
        }
        let prefs = super::read_prefs_at(&path).expect("prefs.json whole");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
        for i in 0..16 {
            assert_eq!(
                prefs.get(&format!("k{i}")),
                Some(&serde_json::json!(24)),
                "k{i}"
            );
        }
    }

    #[test]
    fn every_managed_state_has_a_type_of_its_own() {
        // Builder::manage asserts that no type is managed twice.
        let _ = super::with_state(tauri::Builder::<tauri::Wry>::default());
    }

    #[test]
    fn tray_menu_is_open_wall_settings_quit() {
        let app = tauri::test::mock_app();
        let menu = super::build_tray_menu(&app).expect("tray menu builds");
        let items: Vec<String> = menu
            .items()
            .expect("tray menu items")
            .iter()
            .map(|i| i.id().0.clone())
            .collect();
        assert_eq!(items, ["open_wall", "settings", "quit"]);
    }
}
