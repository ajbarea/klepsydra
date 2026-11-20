//! Reading a fleet directory: every session file and heartbeat in it, and the
//! files that had to be skipped.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::memo::{Memo, Stamp};
use crate::session::{beat_name, is_session_id, parse, SessionFile};
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

/// The text of an open file, its mtime in seconds and its stamp, all from
/// this one handle, so a rename over the path mid-read cannot pair old time
/// with new text.
fn stamped(mut file: File) -> std::io::Result<(String, i64, Option<Stamp>)> {
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let meta = file.metadata()?;
    let t = meta
        .modified()?
        .duration_since(UNIX_EPOCH)
        .map_err(std::io::Error::other)?;
    let secs = i64::try_from(t.as_secs()).map_err(std::io::Error::other)?;
    Ok((text, secs, Stamp::of(&meta)))
}

/// What a session file read as: its mtime and the parsed file, or why not.
type Parsed = (i64, Result<SessionFile, String>);
/// What a heartbeat read as: its mtime and the name it carries.
type Beat = (i64, Option<String>);

/// Every `<uuid>.json` in `fleet` with its `<uuid>.beat`, read afresh. A
/// reader that lists the folder again and again keeps a `Scanner` instead.
pub fn scan(fleet: &Path) -> Listing {
    Scanner::default().scan(fleet)
}

/// Reads a fleet folder pass after pass, opening only the files written
/// since the last pass (`memo`).
#[derive(Debug, Default)]
pub struct Scanner {
    sessions: Memo<Parsed>,
    beats: Memo<Beat>,
}

impl Scanner {
    /// Files opened since this scanner was made.
    pub fn reads(&self) -> u64 {
        self.sessions.reads() + self.beats.reads()
    }

    /// Every `<uuid>.json` in `fleet` with its `<uuid>.beat`. Anything else
    /// there (temp files mid-write, the hook's lock, stray files) is not a
    /// session and is passed over without a word. A missing directory is an
    /// empty fleet; one that cannot be listed is `unread`, with a problem
    /// saying why. The type is checked from the directory entry before
    /// opening, so a FIFO named like a session file is never opened (an open
    /// would block); symlinks are not followed.
    pub fn scan(&mut self, fleet: &Path) -> Listing {
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
        let now = SystemTime::now();
        let mut sessions = self.sessions.pass();
        let mut beat_pass = self.beats.pass();
        let mut files = Vec::new();
        let mut beats: HashMap<String, Beat> = HashMap::new();
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
            if !item.file_type().is_ok_and(|t| t.is_file()) {
                continue;
            }
            let path = item.path();
            let listed = Stamp::of_entry(&item);
            // `None`: the file went between the listing and the open.
            let open = || match File::open(&path).and_then(stamped) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(None),
                r => r.map_err(Some),
            };
            let read = if ext == "beat" {
                beat_pass
                    .get(&path, listed, now, || {
                        open().map(|(text, mtime, held)| ((mtime, beat_name(&text)), held))
                    })
                    .map(|beat| {
                        beats.insert(stem.to_string(), beat);
                    })
            } else {
                sessions
                    .get(&path, listed, now, || {
                        open().map(|(text, mtime, held)| {
                            (
                                (mtime, parse(&text, stem, mtime).map_err(|e| e.to_string())),
                                held,
                            )
                        })
                    })
                    .map(|parsed| files.push((name.clone(), parsed)))
            };
            match read {
                Ok(()) | Err(None) => {}
                Err(Some(e)) => {
                    if ext == "json" {
                        out.problems.push(Problem {
                            file: name,
                            what: format!("unreadable: {e}"),
                        });
                    }
                }
            }
        }
        for (name, (mtime, parsed)) in files {
            match parsed {
                Ok(file) => {
                    let beat = beats.remove(&file.session_id);
                    out.entries.push(Entry {
                        file,
                        modified: mtime,
                        beat,
                    });
                }
                Err(what) => out.problems.push(Problem { file: name, what }),
            }
        }
        out.entries
            .sort_by(|a, b| a.file.session_id.cmp(&b.file.session_id));
        out
    }
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

    /// Date `name` in `dir` to `secs` past the epoch.
    pub fn age(dir: &Scratch, name: &str, secs: u64) {
        File::options()
            .write(true)
            .open(dir.0.join(name))
            .unwrap()
            .set_modified(UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .unwrap();
    }

    /// A fleet of `n` sessions with beats, all last written long ago.
    fn still_fleet(dir: &Scratch, n: usize) -> Vec<String> {
        (0..n)
            .map(|i| {
                let id = format!("{i:08x}-1514-44d1-a31c-eba4a7cb41ed");
                dir.write(&format!("{id}.json"), &session(&id, "working"));
                dir.write(&format!("{id}.beat"), "Plan\t179235300\n");
                age(dir, &format!("{id}.json"), 1_700_000_000);
                age(dir, &format!("{id}.beat"), 1_700_000_000);
                id
            })
            .collect()
    }

    #[test]
    fn a_pass_over_an_unchanged_fleet_opens_no_file() {
        let dir = Scratch::new("still");
        let ids = still_fleet(&dir, 30);
        let mut s = Scanner::default();
        let first = s.scan(&dir.0);
        assert_eq!((first.entries.len(), s.reads()), (30, 60));
        let again = s.scan(&dir.0);
        assert_eq!(s.reads(), 60, "an unchanged file was opened again");
        assert_eq!(again.entries, first.entries);
        // One session written: that file alone is opened, and its new text read.
        let id = &ids[7];
        dir.write(&format!("{id}.json"), &session(id, "done"));
        age(&dir, &format!("{id}.json"), 1_700_000_100);
        let third = s.scan(&dir.0);
        assert_eq!(s.reads(), 61);
        assert_eq!(third.entries[7].file.state, crate::session::State::Done);
        // A beat removed, and a session: gone from the listing, nothing opened.
        std::fs::remove_file(dir.0.join(format!("{}.beat", ids[3]))).unwrap();
        std::fs::remove_file(dir.0.join(format!("{}.json", ids[4]))).unwrap();
        let fourth = s.scan(&dir.0);
        assert_eq!((fourth.entries.len(), s.reads()), (29, 61));
        assert_eq!(fourth.entries[3].beat, None);
    }

    #[test]
    fn a_replace_with_the_same_length_is_read() {
        let dir = Scratch::new("same-len");
        let name = format!("{A}.json");
        dir.write(&name, &session(A, "error"));
        age(&dir, &name, 1_700_000_000);
        let mut s = Scanner::default();
        assert_eq!(
            s.scan(&dir.0).entries[0].file.state,
            crate::session::State::Error
        );
        // The hook's write: a temp file renamed over the path.
        let tmp = format!("{A}.json.9.tmp");
        dir.write(&tmp, &session(A, "ended"));
        age(&dir, &tmp, 1_700_000_001);
        std::fs::rename(dir.0.join(&tmp), dir.0.join(&name)).unwrap();
        assert_eq!(
            s.scan(&dir.0).entries[0].file.state,
            crate::session::State::Ended
        );
    }

    #[test]
    fn a_file_written_just_now_is_read_on_every_pass() {
        let dir = Scratch::new("racy");
        let name = format!("{A}.json");
        dir.write(&name, &session(A, "error"));
        let mut s = Scanner::default();
        s.scan(&dir.0);
        // Rewritten within the same timestamp tick: same length, maybe same time.
        dir.write(&name, &session(A, "ended"));
        assert_eq!(
            s.scan(&dir.0).entries[0].file.state,
            crate::session::State::Ended
        );
        assert_eq!(s.reads(), 2);
    }

    #[test]
    fn a_bad_file_is_reported_on_every_pass_though_read_once() {
        let dir = Scratch::new("bad-kept");
        dir.write(&format!("{A}.json"), "{not json");
        age(&dir, &format!("{A}.json"), 1_700_000_000);
        let mut s = Scanner::default();
        assert_eq!(s.scan(&dir.0).problems, s.scan(&dir.0).problems);
        assert_eq!(s.scan(&dir.0).problems.len(), 1);
        assert_eq!(s.reads(), 1);
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
        let text_time = |r: std::io::Result<(String, i64, Option<Stamp>)>| {
            r.ok()
                .map(|(text, secs, held)| (text, secs, held.map(|h| h.modified)))
        };
        assert_eq!(
            text_time(stamped(handle)),
            Some(("old".into(), 1_700_000_000, Some(old)))
        );
        assert_eq!(
            text_time(stamped(File::open(&path).unwrap())),
            Some(("new".into(), 1_800_000_000, Some(new)))
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
