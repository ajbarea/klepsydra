//! The app's log: plain lines on stderr and JSON lines in `<data dir>/logs/
//! klepsydra.log`, which rotates. One file holds both sides: the Rust code
//! and the fleet crate log through the `log` crate, the webviews through
//! tauri-plugin-log's `log` command (src/log.js).

use std::path::PathBuf;

use klepsydra_fleet::logfmt::{self, Stderr, DEFAULT_LEVEL, LEVEL_ENV};
use log::{Log, Metadata, Record};
use tauri::Manager;
use tauri_plugin_log::{Builder, RotationStrategy, Target, TargetKind};

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

/// The plugin's rotating file alone. Its format is the dispatch's own, the
/// first formatter a record meets: fern rebuilds the record for the next
/// one without its key-values, which would drop `session_id`. The UTC
/// timezone, the default, names rotated files; setting it would replace
/// this format.
fn file_builder(level: log::LevelFilter, path: PathBuf) -> Builder {
    Builder::new()
        .clear_targets()
        .level(level)
        .max_file_size(MAX_FILE_BYTES)
        .rotation_strategy(RotationStrategy::KeepSome(KEEP_ROTATED))
        .format(|out, message, record| {
            out.finish(format_args!("{}", logfmt::json_line(message, record)))
        })
        .target(Target::new(TargetKind::Folder {
            path,
            file_name: Some(FILE_NAME.into()),
        }))
}

/// Every record to the log file and, as a plain line, to stderr.
struct Tee {
    file: Box<dyn Log>,
    stderr: Stderr,
}

impl Log for Tee {
    fn enabled(&self, metadata: &Metadata) -> bool {
        self.file.enabled(metadata) || self.stderr.enabled(metadata)
    }

    fn log(&self, record: &Record) {
        self.file.log(record);
        self.stderr.log(record);
    }

    fn flush(&self) {
        self.file.flush();
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
    let split = dir
        .clone()
        .ok_or_else(|| "klepsydra has no data folder".to_owned())
        .and_then(|d| file_builder(level, d).split(app).map_err(|e| e.to_string()));
    let (plugin, logger, file_error): (_, Box<dyn Log>, _) = match split {
        Ok((plugin, _, file)) => (
            plugin,
            Box::new(Tee {
                file,
                stderr: Stderr(level),
            }),
            None,
        ),
        // The plugin still serves the webviews' `log` command, into stderr.
        Err(e) => (
            Builder::new().skip_logger().build(),
            Box::new(Stderr(level)),
            Some(e),
        ),
    };
    if log::set_boxed_logger(logger).is_ok() {
        log::set_max_level(level);
    }
    if let Err(e) = app.plugin(plugin) {
        log::error!("the webviews' log command is not registered, so their lines reach only their console: {e}");
    }
    let path = dir.map(|d| d.join(format!("{FILE_NAME}.log")));
    match (&file_error, &path) {
        (None, Some(p)) => log::info!(
            "klepsydra {} logging at {} to {}; data folder {}",
            app.package_info().version,
            level.as_str().to_lowercase(),
            p.display(),
            crate::klepsydra_dir(app).map_or("none".into(), |d| d.display().to_string())
        ),
        (Some(e), Some(p)) => log::warn!(
            "no log file at {}, so lines go to stderr only: {e}",
            p.display()
        ),
        (Some(e), None) => log::warn!("no log file, so lines go to stderr only: {e}"),
        (None, None) => {}
    }
    if let Some(e) = bad_level {
        log::warn!("{e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The plugin's own logger, given a record with a session id, writes one
    /// JSON line with that id and the message as logged.
    #[test]
    fn the_log_file_keeps_the_message_as_logged_and_its_session_id() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-log-{nanos}"));
        let app = tauri::test::mock_app();
        let (_, _, file) = file_builder(log::LevelFilter::Info, dir.clone())
            .split(app.handle())
            .unwrap();
        let kv: &[(&str, &str)] = &[("session_id", "0b1e5b4e-6f0e-4bbd-9d3c-2a7a1c0f9e11")];
        file.log(
            &Record::builder()
                .level(log::Level::Warn)
                .target("klepsydra::fleet")
                .key_values(&kv)
                .args(format_args!("skipped x.json: malformed"))
                .build(),
        );
        file.log(
            &Record::builder()
                .level(log::Level::Debug)
                .args(format_args!("below the level"))
                .build(),
        );
        file.flush();
        let text = std::fs::read_to_string(dir.join("klepsydra.log")).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        let lines: Vec<serde_json::Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 1, "{text}");
        assert_eq!(lines[0]["message"], "skipped x.json: malformed", "{text}");
        assert_eq!(lines[0]["level"], "WARN");
        assert_eq!(lines[0]["target"], "klepsydra::fleet");
        assert_eq!(
            lines[0]["session_id"], "0b1e5b4e-6f0e-4bbd-9d3c-2a7a1c0f9e11",
            "{text}"
        );
    }
}
