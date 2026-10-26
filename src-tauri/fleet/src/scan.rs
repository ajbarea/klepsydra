//! Reading a fleet directory: every session file and heartbeat in it, and the
//! files that had to be skipped.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::time::UNIX_EPOCH;

use crate::session::{beat_name, is_session_id, parse};
use crate::speaking::FILE as SPEAKING;
use crate::view::Entry;

/// A file skipped, and why.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Problem {
    pub file: String,
    pub what: String,
}

#[derive(Debug, Default)]
pub struct Listing {
    pub entries: Vec<Entry>,
    pub problems: Vec<Problem>,
    /// The folder exists but could not be listed, so `entries` says nothing
    /// about which sessions run.
    pub unread: bool,
}

/// The text of an open file and its mtime in seconds, both from this one
/// handle, so a rename over the path mid-read cannot pair old time with new text.
fn stamped(mut file: File) -> std::io::Result<(String, i64)> {
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let t = file
        .metadata()?
        .modified()?
        .duration_since(UNIX_EPOCH)
        .map_err(std::io::Error::other)?;
    let secs = i64::try_from(t.as_secs()).map_err(std::io::Error::other)?;
    Ok((text, secs))
}

/// A regular file's text and mtime. The type is checked from the directory
/// entry before opening, so a FIFO named like a session file is never opened
/// (an open would block); symlinks are not followed. `None` is a file that is
/// not one or has vanished, passed over silently; an error is a real failure.
fn read_regular(item: &std::fs::DirEntry) -> Option<std::io::Result<(String, i64)>> {
    if !item.file_type().ok()?.is_file() {
        return None;
    }
    match File::open(item.path()).and_then(stamped) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        r => Some(r),
    }
}

/// Every `<uuid>.json` in `fleet` with its `<uuid>.beat`. Anything else there
/// (temp files mid-write, the hook's lock, stray files) is not a session and is
/// passed over without a word. A missing directory is an empty fleet; one
/// that cannot be listed is `unread`, with a problem saying why.
pub fn scan(fleet: &Path) -> Listing {
    let mut out = Listing::default();
    let dir = match std::fs::read_dir(fleet) {
        Ok(dir) => dir,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return out,
        Err(e) => {
            out.unread = true;
            out.problems.push(Problem {
                file: fleet.display().to_string(),
                what: format!("fleet folder not read: {e}"),
            });
            return out;
        }
    };
    let mut files = Vec::new();
    let mut beats: HashMap<String, (i64, Option<String>)> = HashMap::new();
    for item in dir.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        if name == SPEAKING {
            continue; // keryx's, read on its own by `speaking::read`
        }
        let Some((stem, ext)) = name.rsplit_once('.') else {
            continue;
        };
        if !is_session_id(stem) || !matches!(ext, "json" | "beat") {
            continue;
        }
        let (text, mtime) = match read_regular(&item) {
            None => continue,
            Some(Ok(read)) => read,
            Some(Err(e)) => {
                if ext == "json" {
                    out.problems.push(Problem {
                        file: name,
                        what: format!("unreadable: {e}"),
                    });
                }
                continue;
            }
        };
        if ext == "beat" {
            beats.insert(stem.to_string(), (mtime, beat_name(&text)));
        } else {
            files.push((stem.to_string(), name, mtime, text));
        }
    }
    for (stem, name, mtime, text) in files {
        match parse(&text, &stem, mtime) {
            Ok(file) => out.entries.push(Entry {
                file,
                modified: mtime,
                beat: beats.remove(&stem),
            }),
            Err(e) => out.problems.push(Problem {
                file: name,
                what: e.to_string(),
            }),
        }
    }
    out.entries
        .sort_by(|a, b| a.file.session_id.cmp(&b.file.session_id));
    out
}

/// Reports each skipped file once, not on every re-read; a file that recovers
/// and breaks again is reported again.
#[derive(Debug, Default)]
pub struct Reporter {
    seen: HashSet<Problem>,
}

impl Reporter {
    pub fn fresh(&mut self, problems: &[Problem]) -> Vec<Problem> {
        let now: HashSet<Problem> = problems.iter().cloned().collect();
        let mut new: Vec<Problem> = now.difference(&self.seen).cloned().collect();
        new.sort_by(|a, b| a.file.cmp(&b.file));
        self.seen = now;
        new
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    pub const A: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
    pub const B: &str = "0f8e2c1d-9a3b-4c5d-8e7f-a1b2c3d4e5f6";

    /// A scratch directory removed on drop.
    pub struct Scratch(pub PathBuf);

    impl Scratch {
        pub fn new(name: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            let dir = std::env::temp_dir().join(format!("klepsydra-fleet-{name}-{nanos}"));
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }
        pub fn write(&self, name: &str, text: &str) {
            std::fs::write(self.0.join(name), text).unwrap();
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    pub fn session(id: &str, state: &str) -> String {
        format!(r#"{{"v":1,"session_id":"{id}","state":"{state}","state_at":1700000000}}"#)
    }

    #[test]
    fn a_session_from_a_wildly_wrong_clock_still_shows() {
        let dir = Scratch::new("wrong-clock");
        dir.write(
            &format!("{A}.json"),
            &format!(
                r#"{{"v":1,"session_id":"{A}","state":"working","state_at":1000,"written_at":1000}}"#
            ),
        );
        let l = scan(&dir.0);
        assert_eq!(l.entries.len(), 1);
        assert!(l.problems.is_empty());
    }

    #[test]
    fn sessions_and_their_beats_are_read() {
        let dir = Scratch::new("read");
        dir.write(&format!("{A}.json"), &session(A, "working"));
        dir.write(&format!("{A}.beat"), "Plan the fleet\t179235300\n");
        dir.write(&format!("{B}.json"), &session(B, "done"));
        let l = scan(&dir.0);
        assert!(l.problems.is_empty());
        assert_eq!(l.entries.len(), 2);
        let a = l.entries.iter().find(|e| e.file.session_id == A).unwrap();
        assert_eq!(
            a.beat.as_ref().unwrap().1.as_deref(),
            Some("Plan the fleet")
        );
        assert!(a.modified > 1_700_000_000);
        let b = l.entries.iter().find(|e| e.file.session_id == B).unwrap();
        assert_eq!(b.beat, None);
    }

    #[test]
    fn files_that_are_not_sessions_are_passed_over_silently() {
        let dir = Scratch::new("strays");
        dir.write(&format!("{A}.json.4242.tmp"), "{half");
        dir.write("notes.json", "not a session");
        dir.write("klepsydra-fleet.lock", "");
        dir.write(&format!("{A}.beat.9.tmp"), "x");
        std::fs::create_dir(dir.0.join(format!("{B}.json"))).unwrap();
        let l = scan(&dir.0);
        assert!(l.entries.is_empty());
        assert!(l.problems.is_empty());
    }

    #[test]
    fn keryx_speaking_file_is_never_read_as_a_session() {
        let dir = Scratch::new("speaking");
        dir.write(
            SPEAKING,
            r#"{"v":1,"voice":"af_heart","started_at":1792520221.2,"ends_at":1792520223.7,"envelope":[1.0]}"#,
        );
        dir.write(&format!("{A}.json"), &session(A, "working"));
        let l = scan(&dir.0);
        assert_eq!(l.entries.len(), 1);
        assert!(l.problems.is_empty(), "{:?}", l.problems);
        // Even a session-shaped body under that name is keryx's, not a session.
        dir.write(SPEAKING, &session(A, "done"));
        dir.write(&format!("{A}.json"), &session(A, "working"));
        let l = scan(&dir.0);
        assert_eq!(l.entries.len(), 1);
        assert_eq!(l.entries[0].file.state, crate::session::State::Working);
        assert!(l.problems.is_empty());
    }

    #[test]
    fn a_bad_file_is_skipped_and_the_rest_still_read() {
        let dir = Scratch::new("bad");
        dir.write(&format!("{A}.json"), r#"{"v":2,"session_id":"x"}"#);
        dir.write(&format!("{B}.json"), &session(B, "done"));
        let l = scan(&dir.0);
        assert_eq!(l.entries.len(), 1);
        assert_eq!(
            l.problems,
            vec![Problem {
                file: format!("{A}.json"),
                what: "unknown version 2".into()
            }]
        );
    }

    #[test]
    fn a_fleet_path_that_cannot_be_listed_is_unread_not_empty() {
        let dir = Scratch::new("unread");
        dir.write("fleet", "not a folder");
        let l = scan(&dir.0.join("fleet"));
        assert!(l.unread);
        assert!(l.entries.is_empty());
        assert_eq!(l.problems.len(), 1, "{:?}", l.problems);
        assert!(!scan(&dir.0.join("missing")).unread);
    }

    #[test]
    fn a_missing_directory_is_an_empty_fleet() {
        let l = scan(Path::new("/nonexistent/klepsydra/fleet"));
        assert!(l.entries.is_empty() && l.problems.is_empty());
    }

    #[test]
    fn each_problem_is_reported_once() {
        let p = Problem {
            file: "x.json".into(),
            what: "unknown version 2".into(),
        };
        let broken = vec![p.clone()];
        let mut r = Reporter::default();
        assert_eq!(r.fresh(&broken), broken);
        assert_eq!(r.fresh(&broken), vec![]);
        assert_eq!(r.fresh(&broken), vec![]);
        assert_eq!(r.fresh(&[]), vec![]);
        assert_eq!(r.fresh(&broken), broken, "broken again after a fix");
    }

    #[test]
    fn modified_is_the_mtime_of_the_handle_the_text_came_from() {
        let dir = Scratch::new("handle");
        let path = dir.0.join(format!("{A}.json"));
        std::fs::write(&path, "old").unwrap();
        let old = UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        let new = UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000);
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(old)
            .unwrap();
        let handle = File::open(&path).unwrap();
        // The hook's replace: a new file renamed over the path.
        let tmp = dir.0.join(format!("{A}.json.1.tmp"));
        std::fs::write(&tmp, "new").unwrap();
        File::options()
            .write(true)
            .open(&tmp)
            .unwrap()
            .set_modified(new)
            .unwrap();
        std::fs::rename(&tmp, &path).unwrap();
        assert_eq!(stamped(handle).ok(), Some(("old".into(), 1_700_000_000)));
        assert_eq!(
            stamped(File::open(&path).unwrap()).ok(),
            Some(("new".into(), 1_800_000_000))
        );
    }

    #[test]
    fn scan_pairs_the_file_mtime_with_its_text() {
        let dir = Scratch::new("pair");
        dir.write(&format!("{A}.json"), &session(A, "done"));
        let t = UNIX_EPOCH + std::time::Duration::from_secs(1_750_000_000);
        File::options()
            .write(true)
            .open(dir.0.join(format!("{A}.json")))
            .unwrap()
            .set_modified(t)
            .unwrap();
        assert_eq!(scan(&dir.0).entries[0].modified, 1_750_000_000);
    }

    #[cfg(unix)]
    #[test]
    fn a_fifo_named_like_a_session_never_blocks_the_scan() {
        let dir = Scratch::new("fifo");
        let fifo = dir.0.join(format!("{A}.json"));
        let path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: `path` is a valid NUL-terminated string that outlives the call.
        let made = unsafe { libc::mkfifo(path.as_ptr(), 0o600) };
        assert_eq!(made, 0);
        dir.write(&format!("{B}.json"), &session(B, "done"));
        let (tx, rx) = std::sync::mpsc::channel();
        let path = dir.0.clone();
        std::thread::spawn(move || {
            let _ = tx.send(scan(&path));
        });
        let l = rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("scan returned");
        assert_eq!(l.entries.len(), 1);
        assert!(l.problems.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_named_like_a_session_is_passed_over() {
        let dir = Scratch::new("link");
        dir.write("target", &session(A, "done"));
        std::os::unix::fs::symlink(dir.0.join("target"), dir.0.join(format!("{A}.json"))).unwrap();
        let l = scan(&dir.0);
        assert!(l.entries.is_empty() && l.problems.is_empty());
    }

    #[test]
    fn a_file_that_is_not_text_is_a_problem_not_silence() {
        let dir = Scratch::new("utf8");
        std::fs::write(dir.0.join(format!("{A}.json")), [0xff, 0xfe, 0x00]).unwrap();
        let l = scan(&dir.0);
        assert!(l.entries.is_empty());
        assert_eq!(l.problems.len(), 1);
        assert_eq!(l.problems[0].file, format!("{A}.json"));
        assert!(l.problems[0].what.starts_with("unreadable: "));
    }
}
