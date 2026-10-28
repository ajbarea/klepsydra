//! How a log record reads: one JSON object per line for the log file, a plain
//! line for a terminal, and the level `KLEPSYDRA_LOG` asks for. The crate
//! logs through the `log` facade; the app (or an example) decides where the
//! records go.

use std::fmt::{Arguments, Write as _};
use std::io::Write as _;

use log::kv::{Key, Value, VisitSource};
use log::{LevelFilter, Log, Metadata, Record};

/// The environment variable that sets the level.
pub const LEVEL_ENV: &str = "KLEPSYDRA_LOG";
/// The level when `LEVEL_ENV` is unset or empty.
pub const DEFAULT_LEVEL: LevelFilter = LevelFilter::Info;
const LEVELS: [LevelFilter; 5] = [
    LevelFilter::Error,
    LevelFilter::Warn,
    LevelFilter::Info,
    LevelFilter::Debug,
    LevelFilter::Trace,
];
/// The JSON line's own fields; a key-value of the same name is left out.
const FIXED: [&str; 4] = ["ts", "level", "target", "message"];

/// The level `value`, `LEVEL_ENV`'s value, names: the default when unset or
/// empty, else one of error, warn, info, debug or trace in any case. Anything
/// else is an error naming the value and the choices.
pub fn level(value: Option<&str>) -> Result<LevelFilter, String> {
    let Some(v) = value.map(str::trim).filter(|v| !v.is_empty()) else {
        return Ok(DEFAULT_LEVEL);
    };
    LEVELS
        .into_iter()
        .find(|l| l.as_str().eq_ignore_ascii_case(v))
        .ok_or_else(|| {
            format!(
                "{LEVEL_ENV}={v:?} is not a level; expected one of error, warn, info, debug, \
                 trace, so the level is {}",
                DEFAULT_LEVEL.as_str().to_lowercase()
            )
        })
}

/// A record's key-values in the order given, the first of each key only.
fn fields(record: &Record) -> Vec<(String, String)> {
    struct Collect(Vec<(String, String)>);
    impl<'kvs> VisitSource<'kvs> for Collect {
        fn visit_pair(&mut self, key: Key<'kvs>, value: Value<'kvs>) -> Result<(), log::kv::Error> {
            if !self.0.iter().any(|(k, _)| k == key.as_str()) {
                self.0.push((key.as_str().to_owned(), value.to_string()));
            }
            Ok(())
        }
    }
    let mut c = Collect(Vec::new());
    let _ = record.key_values().visit(&mut c);
    c.0
}

/// `s` as a JSON string, quotes, escapes and all.
fn quoted(s: &str) -> String {
    serde_json::Value::from(s).to_string()
}

/// One JSON object for the log file: `ts` (UTC, RFC 3339 to the
/// millisecond), `level`, `target` (the module that logged), `message`, then
/// the record's key-values, such as `session_id`.
pub fn json_line_at(ts: jiff::Timestamp, message: &Arguments, record: &Record) -> String {
    let mut line = format!(
        "{{\"ts\":{},\"level\":{},\"target\":{},\"message\":{}",
        quoted(&format!("{ts:.3}")),
        quoted(record.level().as_str()),
        quoted(record.target()),
        quoted(&message.to_string()),
    );
    for (k, v) in fields(record) {
        if !FIXED.contains(&k.as_str()) {
            let _ = write!(line, ",{}:{}", quoted(&k), quoted(&v));
        }
    }
    line.push('}');
    line
}

/// `json_line_at` now.
pub fn json_line(message: &Arguments, record: &Record) -> String {
    json_line_at(jiff::Timestamp::now(), message, record)
}

/// The same event for a terminal: `LEVEL target: message key=value ...`.
pub fn plain_line(message: &Arguments, record: &Record) -> String {
    let mut line = format!("{:<5} {}: {message}", record.level(), record.target());
    for (k, v) in fields(record) {
        let _ = write!(line, " {k}={v}");
    }
    line
}

/// Plain lines on stderr: the logger of the crate's examples.
pub struct Stderr(pub LevelFilter);

impl Log for Stderr {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= self.0
    }

    fn log(&self, record: &Record) {
        if self.enabled(record.metadata()) {
            let line = plain_line(record.args(), record);
            let _ = writeln!(std::io::stderr().lock(), "{line}");
        }
    }

    fn flush(&self) {}
}

/// Send this process's records to stderr at `LEVEL_ENV`'s level; a bad
/// value is logged and the default used.
pub fn to_stderr() {
    let (level, bad) = match level(std::env::var(LEVEL_ENV).ok().as_deref()) {
        Ok(l) => (l, None),
        Err(e) => (DEFAULT_LEVEL, Some(e)),
    };
    if log::set_boxed_logger(Box::new(Stderr(level))).is_ok() {
        log::set_max_level(level);
    }
    if let Some(e) = bad {
        log::warn!("{e}");
    }
}

/// Records kept in memory for the crate's tests, from every test thread.
#[cfg(test)]
pub(crate) mod captured {
    use std::sync::{Mutex, Once};

    static LINES: Mutex<Vec<(log::Level, String, String)>> = Mutex::new(Vec::new());

    struct Keep;
    impl log::Log for Keep {
        fn enabled(&self, _: &log::Metadata) -> bool {
            true
        }
        fn log(&self, r: &log::Record) {
            let line = (r.level(), r.target().to_owned(), r.args().to_string());
            LINES.lock().unwrap_or_else(|e| e.into_inner()).push(line);
        }
        fn flush(&self) {}
    }

    /// Start keeping records; once per process, whichever test asks first.
    pub fn start() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            log::set_logger(&Keep).expect("no other logger in the tests");
            log::set_max_level(log::LevelFilter::Trace);
        });
    }

    /// The records kept so far whose message contains `needle`.
    pub fn with(needle: &str) -> Vec<(log::Level, String, String)> {
        LINES
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|(_, _, m)| m.contains(needle))
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use log::Level;

    fn at(ms: i64) -> jiff::Timestamp {
        jiff::Timestamp::from_millisecond(ms).unwrap()
    }

    #[test]
    fn a_line_is_one_json_object_with_when_where_and_what() {
        let kv: &[(&str, &str)] = &[("session_id", "0b1e5b4e-6f0e-4bbd-9d3c-2a7a1c0f9e11")];
        let msg = format_args!("skipped fleet/{}.json: not JSON", "x");
        let record = Record::builder()
            .level(Level::Warn)
            .target("klepsydra::fleet")
            .key_values(&kv)
            .args(msg)
            .build();
        let line = json_line_at(at(1_761_652_800_123), &msg, &record);
        assert!(!line.contains('\n'), "{line}");
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            v,
            serde_json::json!({
                "ts": "2025-10-28T12:00:00.123Z",
                "level": "WARN",
                "target": "klepsydra::fleet",
                "message": "skipped fleet/x.json: not JSON",
                "session_id": "0b1e5b4e-6f0e-4bbd-9d3c-2a7a1c0f9e11",
            })
        );
        assert!(
            line.starts_with("{\"ts\":"),
            "when comes first, for a reader: {line}"
        );
    }

    #[test]
    fn a_whole_second_still_has_its_milliseconds_and_newlines_are_escaped() {
        let msg = format_args!("line one\r\nline \"two\"");
        let record = Record::builder().level(Level::Error).args(msg).build();
        let line = json_line_at(at(1_761_652_800_000), &msg, &record);
        assert!(!line.contains('\n') && !line.contains('\r'), "{line}");
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["ts"], "2025-10-28T12:00:00.000Z");
        assert_eq!(v["message"], "line one\r\nline \"two\"");
        assert_eq!(v["level"], "ERROR");
    }

    #[test]
    fn a_key_value_cannot_overwrite_a_fixed_field_or_repeat() {
        let kv: &[(&str, &str)] = &[("level", "INFO"), ("n", "1"), ("n", "2")];
        let msg = format_args!("m");
        let record = Record::builder()
            .level(Level::Error)
            .key_values(&kv)
            .args(msg)
            .build();
        let line = json_line_at(at(0), &msg, &record);
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["level"], "ERROR");
        assert_eq!(v["n"], "1");
        assert_eq!(line.matches("\"level\"").count(), 1, "{line}");
    }

    #[test]
    fn a_terminal_line_is_plain() {
        let kv: &[(&str, &str)] = &[("session_id", "abc")];
        let msg = format_args!("phone: wall serving on 127.0.0.1:8318");
        let record = Record::builder()
            .level(Level::Info)
            .target("klepsydra::phone")
            .key_values(&kv)
            .args(msg)
            .build();
        assert_eq!(
            plain_line(&msg, &record),
            "INFO  klepsydra::phone: phone: wall serving on 127.0.0.1:8318 session_id=abc"
        );
    }

    #[test]
    fn the_level_is_info_unless_the_variable_names_another() {
        assert_eq!(level(None), Ok(LevelFilter::Info));
        assert_eq!(level(Some("")), Ok(LevelFilter::Info));
        assert_eq!(level(Some("  ")), Ok(LevelFilter::Info));
        for (v, l) in [
            ("debug", LevelFilter::Debug),
            ("DEBUG", LevelFilter::Debug),
            (" warn ", LevelFilter::Warn),
            ("error", LevelFilter::Error),
            ("trace", LevelFilter::Trace),
            ("info", LevelFilter::Info),
        ] {
            assert_eq!(level(Some(v)), Ok(l), "{v}");
        }
    }

    #[test]
    fn an_unknown_level_is_refused_by_name() {
        for bad in ["verbose", "off", "warning", "2"] {
            let e = level(Some(bad)).unwrap_err();
            assert!(e.contains(&format!("{bad:?}")), "{e}");
            assert!(
                e.contains("error, warn, info, debug, trace") && e.ends_with("info"),
                "{e}"
            );
        }
    }

    #[test]
    fn stderr_lets_through_only_its_level_and_above() {
        let s = Stderr(LevelFilter::Warn);
        let m = |l| Metadata::builder().level(l).build();
        assert!(s.enabled(&m(Level::Error)) && s.enabled(&m(Level::Warn)));
        assert!(!s.enabled(&m(Level::Info)) && !s.enabled(&m(Level::Debug)));
    }
}
