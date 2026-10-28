//! The app's log: plain lines on stderr and JSON lines in `<data dir>/logs/
//! klepsydra.log`, which rotates. One file holds both sides: the Rust code
//! and the fleet crate log through the `log` crate, the webviews through
//! tauri-plugin-log's `log` command (src/log.js).

use std::path::PathBuf;

use klepsydra_fleet::logfmt::{self, DEFAULT_LEVEL, LEVEL_ENV};
use tauri::Manager;
use tauri_plugin_log::{Builder, RotationStrategy, Target, TargetKind, TimezoneStrategy};

/// Largest a log file grows before it rotates: about 5,000 lines.
pub const MAX_FILE_BYTES: u128 = 1024 * 1024;
/// Rotated files kept beside the active one, so the logs stay under 5 MiB.
pub const KEEP_ROTATED: usize = 4;
/// The log file's name, without `.log`.
const FILE_NAME: &str = "klepsydra";

/// Where the log file goes: `logs` in the data dir, which by default is the
/// same folder as Tauri's LogDir on Windows and Linux, and follows
/// `KLEPSYDRA_DIR`, so a test copy never writes into the installed app's log.
fn folder(app: &tauri::AppHandle) -> Option<PathBuf> {
    crate::klepsydra_dir(app)
        .map(|d| d.join("logs"))
        .or_else(|| app.path().app_log_dir().ok())
}

fn builder(level: log::LevelFilter, file: Option<PathBuf>) -> Builder {
    let stderr = Target::new(TargetKind::Stderr).format(|out, message, record| {
        out.finish(format_args!("{}", logfmt::plain_line(message, record)))
    });
    let b = Builder::new()
        .clear_targets()
        .clear_format()
        .level(level)
        .max_file_size(MAX_FILE_BYTES)
        .rotation_strategy(RotationStrategy::KeepSome(KEEP_ROTATED))
        .timezone_strategy(TimezoneStrategy::UseUtc)
        .target(stderr);
    match file {
        Some(path) => b.target(
            Target::new(TargetKind::Folder {
                path,
                file_name: Some(FILE_NAME.into()),
            })
            .format(|out, message, record| {
                out.finish(format_args!("{}", logfmt::json_line(message, record)))
            }),
        ),
        None => b,
    }
}

/// Start logging, first thing in setup. A log file that cannot be opened
/// leaves stderr alone and says why, rather than stopping the app.
pub fn start(app: &tauri::AppHandle) {
    let (level, bad_level) = match logfmt::level(std::env::var(LEVEL_ENV).ok().as_deref()) {
        Ok(l) => (l, None),
        Err(e) => (DEFAULT_LEVEL, Some(e)),
    };
    let dir = folder(app);
    let (split, file_error) = match builder(level, dir.clone()).split(app) {
        Ok(s) => (Ok(s), None),
        Err(e) => (builder(level, None).split(app), Some(e)),
    };
    let Ok((plugin, max, logger)) = split else {
        return;
    };
    let _ = tauri_plugin_log::attach_logger(max, logger);
    if let Err(e) = app.plugin(plugin) {
        log::error!("the webviews' log command is not registered, so their lines reach only their console: {e}");
    }
    let path = dir.map(|d| d.join(format!("{FILE_NAME}.log")));
    match (&file_error, &path) {
        (None, Some(p)) => log::info!(
            "klepsydra {} logging at {} to {}",
            app.package_info().version,
            level.as_str().to_lowercase(),
            p.display()
        ),
        (Some(e), Some(p)) => log::warn!(
            "no log file at {}, so lines go to stderr only: {e}",
            p.display()
        ),
        (_, None) => log::warn!("klepsydra has no data folder, so lines go to stderr only"),
    }
    if let Some(e) = bad_level {
        log::warn!("{e}");
    }
}
