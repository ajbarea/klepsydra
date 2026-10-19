//! Following a fleet directory: a filesystem watcher for prompt updates, and a
//! re-read every `POLL` as a safety net and to let ages pass into silence.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::scan::{scan, Problem, Reporter};
use crate::view::{snapshot, Snapshot};

/// The safety-net re-read, matching the gauge's POLL_MS.
pub const POLL: Duration = Duration::from_secs(5);

/// How long to keep gathering events after the first, so one burst of writes
/// is one re-read.
const COALESCE: Duration = Duration::from_millis(75);

/// What a watcher event asks of the reader.
enum Wake {
    /// A session or beat file may have changed.
    Change,
    /// The fleet directory itself changed; the watch may be dead.
    Rewatch,
}

/// Temp files are written then renamed over a session file, and the rename is
/// what counts. Opens and closes are the reader's own reads, so they never do.
fn wake(fleet: &Path, res: notify::Result<notify::Event>) -> Option<Wake> {
    let Ok(event) = res else {
        return Some(Wake::Change);
    };
    if matches!(event.kind, EventKind::Access(_)) {
        return None;
    }
    if event.paths.iter().any(|p| p == fleet) {
        return Some(Wake::Rewatch);
    }
    let session = |p: &PathBuf| {
        matches!(
            p.extension().and_then(|e| e.to_str()),
            Some("json" | "beat")
        )
    };
    event.paths.iter().any(session).then_some(Wake::Change)
}

/// Identifies one incarnation of the directory where the platform's watcher
/// does not report its removal (Windows); elsewhere the removal event does.
fn incarnation(dir: &Path) -> Option<u64> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        std::fs::metadata(dir).ok().map(|m| m.creation_time())
    }
    #[cfg(not(windows))]
    {
        let _ = dir;
        None
    }
}

pub struct Reader {
    fleet: PathBuf,
    tx: Sender<Wake>,
    rx: Receiver<Wake>,
    watcher: Option<RecommendedWatcher>,
    watched: Option<u64>,
    reporter: Reporter,
    last: Option<Snapshot>,
}

impl Reader {
    /// A reader for `<klepsydra_dir>/fleet`, which may not exist yet.
    pub fn new(klepsydra_dir: &Path) -> Self {
        let (tx, rx) = channel();
        Reader {
            fleet: klepsydra_dir.join("fleet"),
            tx,
            rx,
            watcher: None,
            watched: None,
            reporter: Reporter::default(),
            last: None,
        }
    }

    /// Watch the directory once it exists; drop the watch if it goes away, so
    /// a recreated directory is watched afresh. A watcher that cannot start is
    /// a problem; the re-read every `POLL` still covers it.
    fn attach(&mut self) -> Option<Problem> {
        if !self.fleet.is_dir() {
            self.watcher = None;
            return None;
        }
        if self.watcher.is_some() && self.watched == incarnation(&self.fleet) {
            return None;
        }
        self.watched = incarnation(&self.fleet);
        let tx = self.tx.clone();
        let fleet = self.fleet.clone();
        let started = notify::recommended_watcher(move |res| {
            if let Some(w) = wake(&fleet, res) {
                let _ = tx.send(w);
            }
        })
        .and_then(|mut w| {
            w.watch(&self.fleet, RecursiveMode::NonRecursive)?;
            Ok(w)
        });
        match started {
            Ok(w) => {
                self.watcher = Some(w);
                None
            }
            Err(e) => Some(Problem {
                file: "fleet".into(),
                what: format!("watcher unavailable: {e}"),
            }),
        }
    }

    /// Wait up to `timeout` for a change, then re-read. Returns the snapshot
    /// when it differs from the last one returned, and the problems not
    /// reported before.
    pub fn step(
        &mut self,
        timeout: Duration,
        now: impl Fn() -> i64,
    ) -> (Option<Snapshot>, Vec<Problem>) {
        let mut broken = Vec::new();
        broken.extend(self.attach());
        if let Ok(first) = self.rx.recv_timeout(timeout) {
            let mut rewatch = matches!(first, Wake::Rewatch);
            let deadline = Instant::now() + COALESCE;
            while let Some(left) = deadline.checked_duration_since(Instant::now()) {
                match self.rx.recv_timeout(left) {
                    Ok(w) => rewatch |= matches!(w, Wake::Rewatch),
                    Err(_) => break,
                }
            }
            if rewatch {
                self.watcher = None;
                broken.extend(self.attach());
            }
        }
        let listing = scan(&self.fleet);
        broken.extend(listing.problems);
        let problems = self.reporter.fresh(&broken);
        let snap = snapshot(&listing.entries, now());
        if self.last.as_ref() == Some(&snap) {
            return (None, problems);
        }
        self.last = Some(snap.clone());
        (Some(snap), problems)
    }
}

/// Seconds since the epoch by this machine's clock.
pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::{session, Scratch, A};
    use crate::view::Status;

    fn reader(name: &str) -> (Scratch, Reader) {
        let root = Scratch::new(name);
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        let r = Reader::new(&root.0);
        (root, r)
    }

    #[test]
    fn the_first_read_reports_even_an_empty_fleet() {
        let (_root, mut r) = reader("first");
        let (snap, problems) = r.step(Duration::ZERO, unix_now);
        assert_eq!(snap, Some(Snapshot::default()));
        assert!(problems.is_empty());
    }

    #[test]
    fn a_new_session_arrives_well_before_the_poll() {
        let (root, mut r) = reader("arrive");
        r.step(Duration::ZERO, unix_now);
        let fleet = root.0.join("fleet");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            let tmp = fleet.join(format!("{A}.json.77.tmp"));
            std::fs::write(&tmp, session(A, "working")).unwrap();
            std::fs::rename(&tmp, fleet.join(format!("{A}.json"))).unwrap();
        });
        let started = Instant::now();
        let (snap, _) = r.step(POLL, unix_now);
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher, not the poll"
        );
        assert_eq!(snap.unwrap().sessions.len(), 1);
    }

    #[test]
    fn nothing_changed_returns_nothing() {
        let (root, mut r) = reader("same");
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        assert!(r.step(Duration::ZERO, unix_now).0.is_some());
        root.write(&format!("fleet/{A}.json.5.tmp"), "{half");
        assert_eq!(r.step(Duration::from_millis(300), unix_now).0, None);
    }

    #[test]
    fn time_alone_can_change_the_snapshot() {
        let (root, mut r) = reader("time");
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        let t = unix_now();
        let first = r.step(Duration::ZERO, || t).0.unwrap();
        assert_eq!(first.sessions[0].status, Status::Working);
        let later = r.step(Duration::ZERO, || t + 120).0.unwrap();
        assert_eq!(later.sessions[0].status, Status::Silent);
    }

    #[test]
    fn a_fleet_dir_made_later_is_picked_up() {
        let root = Scratch::new("later");
        let mut r = Reader::new(&root.0);
        assert_eq!(
            r.step(Duration::ZERO, unix_now).0,
            Some(Snapshot::default())
        );
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "new"));
        assert_eq!(
            r.step(Duration::ZERO, unix_now).0.unwrap().sessions.len(),
            1
        );
    }

    #[test]
    fn a_bad_file_is_reported_once_across_reads() {
        let (root, mut r) = reader("once");
        root.write(&format!("fleet/{A}.json"), r#"{"v":3}"#);
        assert_eq!(r.step(Duration::ZERO, unix_now).1.len(), 1);
        assert_eq!(r.step(Duration::ZERO, unix_now).1.len(), 0);
    }

    #[test]
    fn an_idle_reader_does_not_spin_on_its_own_reads() {
        let (root, mut r) = reader("idle");
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        r.step(Duration::ZERO, unix_now);
        let started = Instant::now();
        let (mut steps, mut early) = (0, 0);
        while started.elapsed() < Duration::from_millis(1500) {
            let began = Instant::now();
            r.step(Duration::from_millis(300), unix_now);
            // A step cut short was woken by something: its own read, if it spins.
            early += usize::from(began.elapsed() < Duration::from_millis(250));
            steps += 1;
        }
        assert_eq!(
            early, 0,
            "{early} of {steps} waits cut short with nothing changing"
        );
        assert!(steps <= 6, "{steps} re-reads in 1.5 s of nothing changing");
    }

    #[test]
    fn a_fleet_dir_recreated_within_one_wait_is_watched_afresh() {
        let (root, mut r) = reader("recreate");
        r.step(Duration::ZERO, unix_now);
        let fleet = root.0.join("fleet");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            std::fs::remove_dir_all(&fleet).unwrap();
            std::fs::create_dir_all(&fleet).unwrap();
            std::thread::sleep(Duration::from_millis(300));
        });
        r.step(Duration::from_secs(2), unix_now);
        writer.join().unwrap();
        let fleet = root.0.join("fleet");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            std::fs::write(fleet.join(format!("{A}.json")), session(A, "new")).unwrap();
        });
        let started = Instant::now();
        let (snap, _) = r.step(POLL, unix_now);
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher"
        );
        assert_eq!(snap.unwrap().sessions.len(), 1);
    }
}
