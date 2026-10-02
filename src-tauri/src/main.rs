#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    LogicalSize, Manager, PhysicalPosition,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_window_state::AppHandleExt;

/// The grab handle, in CSS pixels relative to the window's top-left. The
/// frontend owns the layout and reports it, so restyling cannot desync this.
#[derive(Default)]
struct Grip(Mutex<Option<[f64; 4]>>);

/// `%LOCALAPPDATA%\dev.ajsoftworks.klepsydra` -- where the statusLine hook
/// publishes. Tauri's app-local-data dir rather than the install dir: a
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

/// Every published reading, one per Claude Code session.
///
/// A file per session (under a directory per account) means neither separate
/// logins nor several terminals on one login ever contend for a file. Sessions
/// of the same account disagree routinely -- each holds whatever the last API
/// response it saw reported -- so reconciling them is the frontend's job.
#[tauri::command]
fn read_usage(app: tauri::AppHandle) -> serde_json::Value {
    let mut out: Vec<serde_json::Value> = Vec::new();
    // The old location too: the hook is a copy in the user's ~/.claude, so an
    // upgraded overlay meets a hook still publishing where it always did. A
    // session appearing in both is what the frontend already reconciles.
    for dir in [klepsydra_dir(&app), legacy_dir(&app)]
        .into_iter()
        .flatten()
    {
        collect_readings(&dir, &mut out);
    }
    serde_json::Value::Array(out)
}

fn collect_readings(dir: &std::path::Path, out: &mut Vec<serde_json::Value>) {
    let Ok(accounts) = std::fs::read_dir(dir.join("accounts")) else {
        return;
    };
    for account in accounts.flatten() {
        let Ok(sessions) = std::fs::read_dir(account.path()) else {
            continue; // a stale pre-per-session file, not a directory
        };
        for session in sessions.flatten() {
            let path = session.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                continue;
            };
            out.push(value);
        }
    }
}

/// The panel grows a row per account window, so the frontend reports the height
/// it needs rather than the window guessing.
#[tauri::command]
fn set_height(window: tauri::Window, height: f64) -> Result<(), String> {
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let width = window.outer_size().map_err(|e| e.to_string())?.width as f64 / scale;
    window
        .set_size(LogicalSize::new(width, height.max(1.0)))
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn set_grip(grip: tauri::State<'_, Grip>, x: f64, y: f64, w: f64, h: f64) {
    if let Ok(mut g) = grip.0.lock() {
        *g = Some([x, y, w, h]);
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

    #[link(name = "user32")]
    unsafe extern "system" {
        fn SetWindowPos(
            hwnd: isize,
            insert_after: isize,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
            flags: u32,
        ) -> i32;
    }

    if let Ok(hwnd) = window.hwnd() {
        unsafe {
            SetWindowPos(
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

/// Put the gauge back somewhere reachable, for when it has been dragged
/// off-screen or onto a monitor that is no longer attached.
#[tauri::command]
fn reset_position(window: tauri::WebviewWindow) -> Result<(), String> {
    let monitor = window
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or("no primary monitor")?;
    let scale = monitor.scale_factor();
    let screen = monitor.size();
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let x = (screen.width as f64 - size.width as f64) / scale - 220.0;
    let y = (screen.height as f64 - size.height as f64) / scale;
    window
        .set_position(tauri::LogicalPosition::new(x.max(0.0), y.max(0.0)))
        .map_err(|e| e.to_string())
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

#[cfg(windows)]
fn pointer(app: &tauri::AppHandle) -> Option<Pointer> {
    #[link(name = "user32")]
    unsafe extern "system" {
        fn GetAsyncKeyState(key: i32) -> i16;
    }
    const VK_LBUTTON: i32 = 0x01;
    let cursor = app.cursor_position().ok()?;
    let pressed = unsafe { (GetAsyncKeyState(VK_LBUTTON) as u16 & 0x8000) != 0 };
    Some(Pointer {
        x: cursor.x,
        y: cursor.y,
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
    use std::time::Instant;
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

/// The window's placement in physical desktop pixels.
#[derive(Clone, Copy)]
struct Geometry {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
}

fn geometry(window: &tauri::WebviewWindow) -> Option<Geometry> {
    let (Ok(origin), Ok(size), Ok(scale)) = (
        window.outer_position(),
        window.outer_size(),
        window.scale_factor(),
    ) else {
        return None;
    };
    Some(Geometry {
        x: origin.x as f64,
        y: origin.y as f64,
        w: size.width as f64,
        h: size.height as f64,
        scale,
    })
}

/// An undecorated resizable window gets tao's edge-resize band on Linux: a press
/// within it starts a window-manager resize. Stop the grip short of the band, so
/// a press there passes through instead. Windows is not resizable, so it has
/// no band.
fn clear_of_resize_band(
    g: Geometry,
    (left, top, right, bottom): (f64, f64, f64, f64),
) -> (f64, f64, f64, f64) {
    const TAO_RESIZE_BORDER: f64 = 5.0; // tao's linux/event_loop.rs
    if !cfg!(target_os = "linux") {
        return (left, top, right, bottom);
    }
    let inset = (TAO_RESIZE_BORDER + 1.0) * g.scale;
    (
        left.max(g.x + inset),
        top.max(g.y + inset),
        right.min(g.x + g.w - inset),
        bottom.min(g.y + g.h - inset),
    )
}

/// Neither Windows nor Tauri's X11 backend offers per-region hit testing for a
/// click-through window: ignoring cursor events is all-or-nothing. So we watch
/// the pointer and switch the whole window interactive only while it is over
/// the grab handle. Everywhere else the gauge stays click-through and never
/// eats a click.
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
        let mut geo: Option<Geometry> = None;
        loop {
            std::thread::sleep(Duration::from_millis(16));
            ticks = ticks.wrapping_add(1);
            let Some(window) = app.get_webview_window("main") else {
                continue;
            };
            let Some(rect) = app.state::<Grip>().0.lock().ok().and_then(|g| *g) else {
                continue;
            };
            if geo.is_none() || (drag_offset.is_none() && ticks.is_multiple_of(30)) {
                geo = geometry(&window);
            }
            let (Some(g), Some(cursor)) = (geo.as_mut(), pointer(&app)) else {
                continue;
            };

            // Grip rect in physical desktop coordinates. While already
            // interactive the region is grown slightly, so a drag that outruns
            // the window by a pixel does not drop the mouse mid-move.
            let margin = if interactive { 8.0 } else { 0.0 };
            let left = g.x + rect[0] * g.scale - margin;
            let top = g.y + rect[1] * g.scale - margin;
            let (left, top, right, bottom) = clear_of_resize_band(
                *g,
                (
                    left,
                    top,
                    left + rect[2] * g.scale + margin * 2.0,
                    top + rect[3] * g.scale + margin * 2.0,
                ),
            );

            let inside =
                cursor.x >= left && cursor.x <= right && cursor.y >= top && cursor.y <= bottom;

            // Only a press that *starts* on the handle begins a drag, so
            // dragging something else across the gauge cannot grab it.
            if cursor.pressed && !was_pressed && inside {
                drag_offset = Some((cursor.x - g.x, cursor.y - g.y));
            } else if !cursor.pressed && drag_offset.is_some() {
                drag_offset = None;
                let _ = app.save_window_state(tauri_plugin_window_state::StateFlags::POSITION);
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

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_window_state::Builder::default()
                // Position only: the window sizes itself to its rows, so a
                // restored height would fight set_height on every launch.
                .with_state_flags(tauri_plugin_window_state::StateFlags::POSITION)
                .build(),
        )
        .manage(Grip::default())
        .invoke_handler(tauri::generate_handler![
            read_usage,
            set_height,
            set_grip,
            reset_position,
            set_tray_level
        ])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");
            window.set_ignore_cursor_events(true)?;
            // GTK never sizes a non-resizable window below its content's
            // natural size, 200px for WebKit, so set_height could not shrink
            // it. Resizable arms tao's edge-resize band; watch_grip keeps the
            // grip out of it.
            #[cfg(target_os = "linux")]
            window.set_resizable(true)?;

            // Enable autostart once, on first run. Re-enabling unconditionally
            // would quietly undo the user turning it off from the tray. When it
            // is already on, re-register anyway so the recorded path follows the
            // executable if it moves.
            let autostart = app.autolaunch();
            let dir = klepsydra_dir(app.handle());
            let marker = dir.as_ref().map(|d| d.join("autostart-initialised"));
            let legacy = legacy_dir(app.handle()).map(|d| d.join("autostart-initialised"));
            let exists = |m: &Option<PathBuf>| m.as_ref().map(|m| m.exists()).unwrap_or(false);
            let first_run = marker.is_some() && !exists(&marker) && !exists(&legacy);
            if first_run || autostart.is_enabled().unwrap_or(false) {
                let _ = autostart.enable();
            }
            // Write the marker whenever it is missing, not only on a first run:
            // left unwritten, an upgraded install answers "have we been here
            // before?" out of the old directory forever, and tidying that
            // directory away silently re-enables autostart the user turned off.
            if let Some(m) = marker.as_ref().filter(|m| !m.exists()) {
                if let Some(parent) = m.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = std::fs::write(m, "");
            }
            let start_item = CheckMenuItem::with_id(
                app,
                "autostart",
                if cfg!(windows) {
                    "Start with Windows"
                } else {
                    "Start at login"
                },
                true,
                autostart.is_enabled().unwrap_or(false),
                None::<&str>,
            )?;
            let reset = MenuItem::with_id(app, "reset", "Reset position", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[
                    &reset,
                    &PredefinedMenuItem::separator(app)?,
                    &start_item,
                    &PredefinedMenuItem::separator(app)?,
                    &quit,
                ],
            )?;

            let toggle = start_item.clone();
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().expect("bundled icon").clone())
                .tooltip("klepsydra")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "autostart" => {
                        // The checkbox has already flipped; mirror it onto the system.
                        let want = toggle.is_checked().unwrap_or(false);
                        let mgr = app.autolaunch();
                        let _ = if want { mgr.enable() } else { mgr.disable() };
                        let _ = toggle.set_checked(mgr.is_enabled().unwrap_or(want));
                    }
                    "reset" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = reset_position(w.clone());
                            raise_above_taskbar(&w);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            raise_above_taskbar(&window);
            watch_grip(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running klepsydra");
}
