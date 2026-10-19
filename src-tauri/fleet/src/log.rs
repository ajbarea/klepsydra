//! A small append-only log file that cannot grow without bound.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

/// Largest the log may be before the next append starts it over.
pub const CAP: u64 = 64 * 1024;

/// Append `line` to `path`, emptying the file first when it is over `cap`
/// bytes. Failures are ignored: logging must never disturb the reader.
pub fn append_capped(path: &Path, line: &str, cap: u64) {
    let over = std::fs::metadata(path).is_ok_and(|m| m.len() > cap);
    let mut open = OpenOptions::new();
    open.create(true).append(true);
    if over {
        let _ = std::fs::write(path, b"");
    }
    if let Ok(mut f) = open.open(path) {
        let _ = writeln!(f, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    #[test]
    fn lines_accumulate_under_the_cap() {
        let dir = Scratch::new("log-append");
        let path = dir.0.join("fleet.log");
        append_capped(&path, "one", 100);
        append_capped(&path, "two", 100);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\ntwo\n");
    }

    #[test]
    fn a_log_over_the_cap_starts_over() {
        let dir = Scratch::new("log-cap");
        let path = dir.0.join("fleet.log");
        append_capped(&path, &"x".repeat(60), 50);
        append_capped(&path, "fresh", 50);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "fresh\n");
    }

    #[test]
    fn an_unwritable_path_is_ignored() {
        let dir = Scratch::new("log-missing");
        append_capped(&dir.0.join("no/such/dir/fleet.log"), "x", 50);
    }
}
