//! The tray's resume controls (#271): "Run resume pass now" with its last
//! result beneath it, and the "Heph's account" submenu: the fleet's order, or
//! one account by its id, each shown with its room now. A pick is saved to
//! prefs.json (`heph_account`), where the resume service reads it each pass,
//! and a pass runs at once so Heph moves at his next finished turn.

use std::sync::Mutex;
use std::time::Duration;

use klepsydra_fleet::heph_account::{self, Choice, AUTO, AUTO_LABEL};
use tauri::menu::{CheckMenuItem, MenuItem, Submenu};
use tauri::{AppHandle, Manager, Wry};

/// The tray's id for "Run resume pass now".
pub const RUN_ID: &str = "resume-now";
/// The prefix of each account item's id.
const PICK_PREFIX: &str = "heph-account:";
/// How often the accounts' rooms are read again.
const REFRESH: Duration = Duration::from_secs(60);
/// The longest status line the tray shows.
const STATUS_MAX: usize = 90;

struct Held {
    submenu: Submenu<Wry>,
    items: Vec<(String, CheckMenuItem<Wry>)>,
    run: MenuItem<Wry>,
    status: MenuItem<Wry>,
    running: bool,
}

/// The tray's resume items, kept to update them.
#[derive(Default)]
pub struct HephMenu(Mutex<Option<Held>>);

fn saved(app: &AppHandle) -> String {
    heph_account::of(crate::read_prefs(app).as_ref())
}

fn now_s() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// What the submenu offers: the fleet's order, each account with a reading,
/// and a saved pick no reading names (so the tick always has an item).
fn offered(app: &AppHandle, pick: &str) -> Vec<Choice> {
    let mut out = vec![Choice {
        id: AUTO.into(),
        label: AUTO_LABEL.into(),
    }];
    out.extend(heph_account::choices(
        &klepsydra_fleet::usage::read(crate::usage_dirs(app)),
        now_s(),
    ));
    if !out.iter().any(|c| c.id == pick) {
        out.push(Choice {
            id: pick.into(),
            label: format!("{pick} (no usage reading)"),
        });
    }
    out
}

/// The status line's text, cut to `STATUS_MAX` characters.
fn status_text(r: &Result<String, String>) -> String {
    let t = match r {
        Ok(s) if !s.trim().is_empty() => s.trim().to_string(),
        Ok(_) => "Resume pass done".to_string(),
        Err(e) => format!("Resume pass did not run: {}", e.trim()),
    };
    if t.chars().count() > STATUS_MAX {
        let cut: String = t.chars().take(STATUS_MAX - 1).collect();
        format!("{cut}…")
    } else {
        t
    }
}

/// "Run resume pass now", its status line and the "Heph's account" submenu.
pub fn items(app: &AppHandle) -> tauri::Result<(MenuItem<Wry>, MenuItem<Wry>, Submenu<Wry>)> {
    let run = MenuItem::with_id(app, RUN_ID, "Run resume pass now", true, None::<&str>)?;
    let status = MenuItem::with_id(
        app,
        "resume-now-status",
        "Last resume pass: none from here yet",
        false,
        None::<&str>,
    )?;
    let submenu = Submenu::with_id(app, "heph-account", "Heph's account", true)?;
    let mut held = Held {
        submenu: submenu.clone(),
        items: Vec::new(),
        run: run.clone(),
        status: status.clone(),
        running: false,
    };
    fill(app, &mut held)?;
    if let Ok(mut h) = app.state::<HephMenu>().0.lock() {
        *h = Some(held);
    }
    Ok((run, status, submenu))
}

/// Make the submenu's items what `offered` says now: labels change in place,
/// a changed set of accounts rebuilds them.
fn fill(app: &AppHandle, held: &mut Held) -> tauri::Result<()> {
    let pick = saved(app);
    let want = offered(app, &pick);
    let same = want.len() == held.items.len()
        && want.iter().zip(&held.items).all(|(c, (id, _))| c.id == *id);
    if same {
        for (c, (_, item)) in want.iter().zip(&held.items) {
            item.set_text(&c.label)?;
            item.set_checked(c.id == pick)?;
        }
        return Ok(());
    }
    for (_, item) in held.items.drain(..) {
        held.submenu.remove(&item)?;
    }
    for c in want {
        let item = CheckMenuItem::with_id(
            app,
            format!("{PICK_PREFIX}{}", c.id),
            &c.label,
            true,
            c.id == pick,
            None::<&str>,
        )?;
        held.submenu.append(&item)?;
        held.items.push((c.id, item));
    }
    Ok(())
}

fn refresh(app: &AppHandle) {
    if let Ok(mut h) = app.state::<HephMenu>().0.lock() {
        if let Some(held) = h.as_mut() {
            if let Err(e) = fill(app, held) {
                let error = e.to_string();
                log::warn!(error = error.as_str(); "heph account: the tray's accounts could not be updated");
            }
        }
    }
}

/// Read the accounts' rooms again every `REFRESH`, off the tray's thread.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(REFRESH);
        refresh(&app);
    });
}

/// One resume pass now, unless one from here is still running; the status
/// line says it runs, then what it did.
fn run_pass(app: &AppHandle, why: &'static str) {
    let state = app.state::<HephMenu>();
    {
        let Ok(mut h) = state.0.lock() else { return };
        let Some(held) = h.as_mut() else { return };
        if held.running {
            log::info!(why = why; "resume pass: one from the tray is still running");
            return;
        }
        held.running = true;
        let _ = held.run.set_enabled(false);
        let _ = held.status.set_text("Resume pass running…");
    }
    log::info!(why = why; "resume pass: asked from the tray");
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let r = crate::launch::resume_now();
        let text = status_text(&r);
        if let Ok(mut h) = app.state::<HephMenu>().0.lock() {
            if let Some(held) = h.as_mut() {
                held.running = false;
                let _ = held.run.set_enabled(true);
                let _ = held.status.set_text(&text);
            }
        }
        refresh(&app);
    });
}

/// A tray click on one of these items: run a pass, or save the pick (a click
/// on the ticked item keeps it) and run a pass so Heph moves. False for any
/// other item.
pub fn on_menu(app: &AppHandle, menu_id: &str) -> bool {
    if menu_id == RUN_ID {
        run_pass(app, "run resume pass now");
        return true;
    }
    let Some(id) = menu_id.strip_prefix(PICK_PREFIX) else {
        return false;
    };
    match heph_account::value(id) {
        Ok(v) => crate::write_pref(app, heph_account::KEY, v),
        Err(e) => log::warn!(error = e.as_str(); "heph account: not saved"),
    }
    let now = saved(app);
    if now == id {
        log::info!(heph_account = id; "heph account: saved; the resume service moves him at a finished turn");
        run_pass(app, "heph account picked");
    } else {
        log::warn!(heph_account = id, saved = now.as_str(); "heph account: not saved; the pick is still the saved one");
    }
    refresh(app);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_status_line_says_what_happened_and_stays_short() {
        assert_eq!(
            status_text(&Ok("Resume pass done at 10:41: nothing to do\n".into())),
            "Resume pass done at 10:41: nothing to do"
        );
        assert_eq!(status_text(&Ok(String::new())), "Resume pass done");
        assert_eq!(
            status_text(&Err("The resume pass did not run; see fleet log.".into())),
            "Resume pass did not run: The resume pass did not run; see fleet log."
        );
        let long = status_text(&Err("x".repeat(200)));
        assert_eq!(long.chars().count(), STATUS_MAX);
        assert!(long.ends_with('…'));
    }

    #[test]
    fn the_status_line_reads_fleet_resume_nows_last_line() {
        let script = include_str!("../../fleet/resume-now.sh");
        assert!(script.contains("echo \"Resume pass done at $(date +%H:%M): nothing to do\""));
    }
}
