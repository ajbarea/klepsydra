//! Settings' Voices row (#183, #273, #337, #384): who speaks through keryx.
//! A choice saves the mode to prefs.json and runs `fleet voices` at once, so
//! keryx follows it for running sessions too (the resume service applies a
//! change it missed). Each time the page reads the row, it shows what keryx
//! does now, read from keryx's own config, so a `keryx off` or a
//! `fleet voices heph` done elsewhere shows; a state no mode matches selects
//! nothing, and the row's note names it.

use std::time::Duration;

use klepsydra_fleet::voices::{self, Reader, Shown, VOICES};
use tauri::{AppHandle, Manager};

/// The longest the page waits on keryx's config (it may sit across the
/// distro's file share) before it shows "unknown"; the next open reads again.
const PAGE_WAIT: Duration = Duration::from_secs(2);

/// The one bounded reader of keryx's config: a read stuck on the file share
/// holds at most one thread, however often the page opens.
#[derive(Default)]
pub struct VoicesReader(Reader);

/// What the Voices row shows: the mode keryx's state matches (none when no
/// mode does) and a line naming what keryx does.
#[derive(serde::Serialize)]
pub struct VoicesShown {
    tick: Option<&'static str>,
    says: String,
}

impl From<Shown> for VoicesShown {
    fn from(s: Shown) -> Self {
        Self {
            tick: s.tick,
            says: s.says,
        }
    }
}

/// The saved mode, or the default.
pub fn saved(app: &AppHandle) -> &'static str {
    voices::of(crate::read_prefs(app).as_ref())
}

/// keryx's state now, read live (#337), within [`PAGE_WAIT`].
#[tauri::command]
pub async fn get_voices_mode(app: AppHandle) -> VoicesShown {
    let saved = saved(&app);
    let Some(dir) = crate::klepsydra_dir(&app) else {
        return voices::unknown("no data folder").into();
    };
    let reader = app.clone();
    let shown = tauri::async_runtime::spawn_blocking(move || {
        reader
            .state::<VoicesReader>()
            .0
            .read(&dir, saved, PAGE_WAIT)
    })
    .await
    .ok()
    .flatten()
    .unwrap_or_else(|| voices::unknown("reading keryx's config"));
    log::debug!(tick = shown.tick.unwrap_or("none"); "voices: {}", shown.says);
    shown.into()
}

/// Save mode `mode` and have keryx follow it now (`fleet voices`). Shows the
/// mode saved: the one asked for, or the one still saved when prefs.json
/// refused it, with a note saying so.
#[tauri::command]
pub fn set_voices_mode(app: AppHandle, mode: String) -> VoicesShown {
    match voices::value(&mode) {
        Ok(v) => {
            crate::write_pref(&app, voices::KEY, v);
        }
        Err(e) => log::warn!(voices = mode.as_str(); "voices: {e}"),
    }
    // write_pref logs its own failure; this says which mode holds now.
    let now = saved(&app);
    let says = if now == mode {
        log::info!(voices = now; "voices: saved; keryx follows it now (fleet voices)");
        crate::launch::apply_voices();
        String::new()
    } else {
        log::warn!(voices = mode.as_str(), saved = now; "voices: not saved; the mode is still the saved one");
        let label = VOICES
            .iter()
            .find(|(id, _)| *id == now)
            .map_or(now, |(_, l)| l);
        format!("Not saved: the mode is still {label}.")
    };
    VoicesShown {
        tick: Some(now),
        says,
    }
}
