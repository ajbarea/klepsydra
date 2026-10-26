//! The queue file: a markdown to-do list the fleet's agents keep, read for the
//! wall's Queue panel. The path is a pref, by default `claude-queue.md` on the
//! Desktop; the app only reads it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use serde_json::Value;

use crate::bounded::{read_text, Refused};
use crate::watch::incarnation;

/// The default file's name, in the Desktop folder.
pub const FILE_NAME: &str = "claude-queue.md";
/// The prefs.json key that overrides the default path.
pub const PREF: &str = "queue_path";
/// The app writes a few keys to prefs.json; more than this is not its file.
const PREFS_MAX_BYTES: u64 = 64 * 1024;
/// More than this is not a to-do list. At the cap, the slowest of 20
/// worst-case files (262,144 `[`) took the panel a median 471 ms to parse,
/// walk and count (node 24, 5 runs); a runaway file past it is refused rather
/// than parsed on every save.
pub const MAX_BYTES: u64 = 256 * 1024;
/// A burst of writes (an editor's save, an agent's rewrite) is one re-read
/// once the folder has been quiet this long...
const QUIET: Duration = Duration::from_millis(250);
/// ...or this long after the first event, should the writes never pause.
const SETTLE_CAP: Duration = Duration::from_secs(1);

/// What the panel shows: the file's text, or one line saying why there is none.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct QueueView {
    /// The path read, when there is one to name.
    pub path: Option<String>,
    pub text: Option<String>,
    pub problem: Option<String>,
}

/// The queue file's path: the `queue_path` pref when set, else
/// `claude-queue.md` in `desktop`, the Desktop known folder the app resolves.
pub fn resolve(pref: Option<&Value>, desktop: Option<PathBuf>) -> Result<PathBuf, String> {
    match pref {
        None | Some(Value::Null) => desktop
            .filter(|d| d.is_absolute())
            .map(|d| d.join(FILE_NAME))
            .ok_or_else(|| format!("No Desktop folder was found; set {PREF} in prefs.json.")),
        Some(Value::String(s)) if Path::new(s).is_absolute() => Ok(PathBuf::from(s)),
        Some(Value::String(s)) => Err(format!(
            "{PREF} in prefs.json is not an absolute path: {s:?}."
        )),
        Some(_) => Err(format!("{PREF} in prefs.json is not a path.")),
    }
}

/// The `queue_path` pref from the prefs.json at `prefs`, or None when there
/// is no such file or key. A prefs.json that will not read or parse is an
/// error: the panel says so rather than quietly reading the Desktop file.
pub fn pref(prefs: Option<&Path>) -> Result<Option<Value>, String> {
    let Some(prefs) = prefs else {
        return Ok(None);
    };
    let text = match read_text(prefs, PREFS_MAX_BYTES) {
        Ok(t) => t,
        Err(Refused::Missing) => return Ok(None),
        Err(why) => {
            let reason = match why {
                Refused::Unreadable(e) => e.to_string(),
                Refused::TooLarge => format!("over {} KB", PREFS_MAX_BYTES / 1024),
                Refused::NotUtf8 => "not UTF-8 text".into(),
                Refused::Missing | Refused::NotFile => "not a regular file".into(),
            };
            return Err(format!(
                "prefs.json could not be read ({reason}), so the queue path is unknown."
            ));
        }
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(map)) => Ok(map.get(PREF).cloned()),
        _ => Err("prefs.json could not be parsed, so the queue path is unknown.".into()),
    }
}

/// Read the queue file at `path`, or say why there is nothing to show.
pub fn view(path: &Result<PathBuf, String>) -> QueueView {
    let path = match path {
        Ok(p) => p,
        Err(why) => {
            return QueueView {
                path: None,
                text: None,
                problem: Some(why.clone()),
            }
        }
    };
    let (text, problem) = match read_text(path, MAX_BYTES) {
        // A BOM is an editor's, not the list's.
        Ok(t) => (
            Some(t.strip_prefix('\u{feff}').unwrap_or(&t).to_owned()),
            None,
        ),
        Err(why) => (None, Some(say(&why))),
    };
    QueueView {
        path: Some(path.display().to_string()),
        text,
        problem,
    }
}

fn say(why: &Refused) -> String {
    match why {
        Refused::Missing => "No queue file at this path.".into(),
        Refused::NotFile => {
            "The queue path is not a regular file (a folder, link or pipe), so it is not read."
                .into()
        }
        Refused::TooLarge => format!(
            "The queue file is over {} KB, so it is not read.",
            MAX_BYTES / 1024
        ),
        Refused::Unreadable(e) => format!("The queue file could not be read: {e}."),
        Refused::NotUtf8 => "The queue file is not UTF-8 text, so it is not read.".into(),
    }
}

/// Whether `event` may have changed the file named `name` in the watched
/// folder. Opens and closes are reads, the reader's own among them.
fn touches(name: &str, res: &notify::Result<notify::Event>) -> bool {
    let Ok(event) = res else {
        return true;
    };
    if matches!(event.kind, EventKind::Access(_)) {
        return false;
    }
    // A write lands as a rename over the name, or straight into it; NTFS
    // matches names without case.
    event.paths.iter().any(|p| {
        p.file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.eq_ignore_ascii_case(name))
    })
}

/// Follows the queue file: a watch on its folder for prompt updates, and a
/// re-read every time `step` times out, for a folder the watcher cannot see.
pub struct Follower {
    tx: Sender<()>,
    rx: Receiver<()>,
    watcher: Option<RecommendedWatcher>,
    /// The file the watch is for, and its folder's incarnation.
    watched: Option<(PathBuf, Option<u64>)>,
    /// The path the last step read, so a changed one is read at once.
    followed: Option<Result<PathBuf, String>>,
    last: Option<QueueView>,
}

impl Default for Follower {
    fn default() -> Self {
        let (tx, rx) = channel();
        Follower {
            tx,
            rx,
            watcher: None,
            watched: None,
            followed: None,
            last: None,
        }
    }
}

impl Follower {
    /// Watch `path`'s folder, once it exists and anew when the path or the
    /// folder changes. A watcher that cannot start leaves the re-read.
    fn attach(&mut self, path: Option<&Path>) {
        let target = path.and_then(|p| Some((p, p.parent()?, p.file_name()?.to_str()?)));
        let Some((file, dir, name)) = target.filter(|(_, d, _)| d.is_dir()) else {
            self.watcher = None;
            self.watched = None;
            return;
        };
        let now = (file.to_path_buf(), incarnation(dir));
        if self.watcher.is_some() && self.watched.as_ref() == Some(&now) {
            return;
        }
        let tx = self.tx.clone();
        let name = name.to_owned();
        self.watcher = notify::recommended_watcher(move |res| {
            if touches(&name, &res) {
                let _ = tx.send(());
            }
        })
        .and_then(|mut w| {
            w.watch(dir, RecursiveMode::NonRecursive)?;
            Ok(w)
        })
        .ok();
        self.watched = Some(now);
    }

    /// Wait up to `timeout` for a change to `path`, let a burst of writes
    /// settle, then read it; a path other than the last step's is read at
    /// once. Returns the view when it differs from the last one returned.
    pub fn step(&mut self, path: &Result<PathBuf, String>, timeout: Duration) -> Option<QueueView> {
        self.attach(path.as_deref().ok());
        let moved = self.followed.as_ref() != Some(path);
        self.followed = Some(path.clone());
        if !moved && self.rx.recv_timeout(timeout).is_ok() {
            let cap = Instant::now() + SETTLE_CAP;
            while let Some(left) = cap.checked_duration_since(Instant::now()) {
                if self.rx.recv_timeout(left.min(QUIET)).is_err() {
                    break;
                }
            }
        }
        let next = view(path);
        if self.last.as_ref() == Some(&next) {
            return None;
        }
        self.last = Some(next.clone());
        Some(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;
    use serde_json::json;

    const QUEUE: &str = "# Claude queue\n\n## Needs you\n\n1. **One.**\n";

    #[test]
    fn the_default_is_the_desktop_file() {
        let desktop = Scratch::new("queue-desktop");
        assert_eq!(
            resolve(None, Some(desktop.0.clone())),
            Ok(desktop.0.join("claude-queue.md"))
        );
        assert_eq!(
            resolve(Some(&Value::Null), Some(desktop.0.clone())),
            Ok(desktop.0.join("claude-queue.md")),
            "a null pref is no pref"
        );
        let none = resolve(None, None).unwrap_err();
        assert!(none.contains("No Desktop folder"), "{none}");
        assert!(
            resolve(None, Some(PathBuf::from("Desktop"))).is_err(),
            "a relative Desktop would read from the working folder"
        );
    }

    #[test]
    fn the_pref_overrides_the_default() {
        let elsewhere = Scratch::new("queue-pref");
        let file = elsewhere.0.join("todo.md");
        let pref = json!(file.to_str().unwrap());
        assert_eq!(resolve(Some(&pref), Some(PathBuf::from("/desk"))), Ok(file));
        for (bad, says) in [
            (json!("todo.md"), "not an absolute path"),
            (json!(""), "not an absolute path"),
            (json!(7), "not a path"),
            (json!(["/a.md"]), "not a path"),
        ] {
            let err = resolve(Some(&bad), Some(PathBuf::from("/desk"))).unwrap_err();
            assert!(err.contains(says), "{bad}: {err}");
        }
    }

    fn problem(path: &Path) -> String {
        let v = view(&Ok(path.to_path_buf()));
        assert_eq!(v.text, None);
        assert_eq!(v.path.as_deref(), path.to_str());
        v.problem.expect("a problem")
    }

    #[test]
    fn the_pref_is_read_from_prefs_json_and_a_broken_one_says_so() {
        let dir = Scratch::new("queue-prefs");
        let prefs = dir.0.join("prefs.json");
        assert_eq!(pref(None), Ok(None), "no data folder");
        assert_eq!(pref(Some(&prefs)), Ok(None), "no prefs.json yet");
        dir.write("prefs.json", r#"{"zoom":2}"#);
        assert_eq!(pref(Some(&prefs)), Ok(None), "no queue_path");
        dir.write("prefs.json", r#"{"zoom":2,"queue_path":"/q/todo.md"}"#);
        assert_eq!(pref(Some(&prefs)), Ok(Some(json!("/q/todo.md"))));
        for (text, says) in [
            (r#"{"queue_path":"/q/todo.md""#, "could not be parsed"),
            ("[1]", "could not be parsed"),
            ("", "could not be parsed"),
        ] {
            dir.write("prefs.json", text);
            let err = pref(Some(&prefs)).unwrap_err();
            assert!(
                err.contains("prefs.json") && err.contains(says),
                "{text}: {err}"
            );
        }
        std::fs::remove_file(&prefs).unwrap();
        std::fs::create_dir(&prefs).unwrap();
        let err = pref(Some(&prefs)).unwrap_err();
        assert!(err.contains("prefs.json could not be read"), "{err}");
    }

    #[test]
    fn the_file_reads_whole_without_a_bom() {
        let dir = Scratch::new("queue-read");
        dir.write("q.md", &format!("\u{feff}{QUEUE}"));
        let v = view(&Ok(dir.0.join("q.md")));
        assert_eq!(v.text.as_deref(), Some(QUEUE));
        assert_eq!(v.problem, None);
    }

    #[test]
    fn missing_oversized_folder_and_not_utf8_each_say_which() {
        let dir = Scratch::new("queue-problems");
        assert!(problem(&dir.0.join("none.md")).contains("No queue file"));
        dir.write("big.md", &"x".repeat(MAX_BYTES as usize + 1));
        assert!(problem(&dir.0.join("big.md")).contains("over 256 KB"));
        dir.write("edge.md", &"x".repeat(MAX_BYTES as usize));
        assert!(
            view(&Ok(dir.0.join("edge.md"))).text.is_some(),
            "the cap itself reads"
        );
        std::fs::create_dir(dir.0.join("folder.md")).unwrap();
        assert!(problem(&dir.0.join("folder.md")).contains("not a regular file"));
        std::fs::write(dir.0.join("cp1252.md"), b"caf\xe9\n").unwrap();
        assert!(problem(&dir.0.join("cp1252.md")).contains("not UTF-8"));
        let bad = view(&Err("queue_path in prefs.json is not a path.".into()));
        assert_eq!((bad.path, bad.text), (None, None));
        assert!(bad.problem.unwrap().contains("not a path"));
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_or_fifo_is_not_read() {
        let dir = Scratch::new("queue-special");
        dir.write("real.md", QUEUE);
        std::os::unix::fs::symlink(dir.0.join("real.md"), dir.0.join("link.md")).unwrap();
        assert!(problem(&dir.0.join("link.md")).contains("not a regular file"));
        let fifo = dir.0.join("fifo.md");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: `c` is a valid NUL-terminated string that outlives the call.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert!(problem(&fifo).contains("not a regular file"));
    }

    #[test]
    fn an_unchanged_file_is_sent_once() {
        let dir = Scratch::new("queue-once");
        dir.write("q.md", QUEUE);
        let path = Ok(dir.0.join("q.md"));
        let mut f = Follower::default();
        assert!(f.step(&path, Duration::ZERO).is_some(), "the first read");
        assert_eq!(f.step(&path, Duration::from_millis(50)), None);
    }

    #[test]
    fn an_edit_arrives_well_before_the_poll() {
        let dir = Scratch::new("queue-edit");
        dir.write("q.md", QUEUE);
        let path = Ok(dir.0.join("q.md"));
        let mut f = Follower::default();
        f.step(&path, Duration::ZERO);
        let writer = dir.0.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            // Write then rename over the name, as an atomic save does.
            std::fs::write(writer.join("q.md.tmp"), "# Edited\n").unwrap();
            std::fs::rename(writer.join("q.md.tmp"), writer.join("q.md")).unwrap();
        });
        let started = Instant::now();
        let got = f.step(&path, Duration::from_secs(30));
        assert_eq!(got.and_then(|v| v.text).as_deref(), Some("# Edited\n"));
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn other_files_in_the_folder_do_not_wake_it() {
        let dir = Scratch::new("queue-other");
        dir.write("q.md", QUEUE);
        let path = Ok(dir.0.join("q.md"));
        let mut f = Follower::default();
        f.step(&path, Duration::ZERO);
        let writer = dir.0.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            std::fs::write(writer.join("notes.txt"), "x").unwrap();
        });
        let started = Instant::now();
        assert_eq!(f.step(&path, Duration::from_millis(600)), None);
        assert!(
            started.elapsed() >= Duration::from_millis(550),
            "waited out the timeout"
        );
    }

    #[test]
    fn a_file_made_later_and_a_new_path_are_followed() {
        let dir = Scratch::new("queue-later");
        let path = Ok(dir.0.join("q.md"));
        let mut f = Follower::default();
        let first = f.step(&path, Duration::ZERO).unwrap();
        assert!(first.problem.unwrap().contains("No queue file"));
        let writer = dir.0.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            std::fs::write(writer.join("q.md"), QUEUE).unwrap();
        });
        let got = f.step(&path, Duration::from_secs(30)).unwrap();
        assert_eq!(got.text.as_deref(), Some(QUEUE));

        let other = Scratch::new("queue-moved");
        other.write("todo.md", "# Moved\n");
        let moved = Ok(other.0.join("todo.md"));
        let started = Instant::now();
        let got = f.step(&moved, Duration::from_secs(30)).unwrap();
        assert_eq!(
            got.text.as_deref(),
            Some("# Moved\n"),
            "a changed pref reads the new file"
        );
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "a new path is read at once, not after a poll: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn only_changes_to_the_named_file_count() {
        let event = |kind, p: &str| Ok(notify::Event::new(kind).add_path(PathBuf::from(p)));
        let modify = EventKind::Modify(notify::event::ModifyKind::Any);
        let access = EventKind::Access(notify::event::AccessKind::Any);
        assert!(touches(
            "claude-queue.md",
            &event(modify, "/d/claude-queue.md")
        ));
        assert!(touches(
            "claude-queue.md",
            &event(modify, "/d/Claude-Queue.MD")
        ));
        assert!(!touches("claude-queue.md", &event(modify, "/d/notes.md")));
        assert!(!touches(
            "claude-queue.md",
            &event(access, "/d/claude-queue.md")
        ));
        assert!(touches(
            "claude-queue.md",
            &Err(notify::Error::generic("lost"))
        ));
    }
}
