//! A small append-only log file that cannot grow without bound.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

/// Largest the log may be before the next append starts it over.
pub const CAP: u64 = 64 * 1024;

/// Append `line` to `path`, emptying the file first when it is over `cap`
/// bytes. Failures are ignored: logging must never disturb the reader.
pub fn append_capped(path: &Path, line: &str, cap: u64) {
    if std::fs::metadata(path).is_ok_and(|m| m.len() > cap) {
        let _ = std::fs::write(path, b"");
    }
    let open = OpenOptions::new().create(true).append(true).open(path);
    if let Ok(mut f) = open {
        // One write, so lines appended at once from two threads stay whole.
        let _ = f.write_all(format!("{line}\n").as_bytes());
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

    #[test]
    fn exactly_the_cap_is_kept_and_one_over_is_emptied() {
        let dir = Scratch::new("log-boundary");
        let path = dir.0.join("fleet.log");
        std::fs::write(&path, "x".repeat(CAP as usize)).unwrap();
        append_capped(&path, "a", CAP);
        assert_eq!(std::fs::metadata(&path).unwrap().len(), CAP + 2);
        append_capped(&path, "b", CAP);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "b\n");
    }
}
