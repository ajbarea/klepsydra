//! Following a fleet directory: a filesystem watcher for prompt updates, and a
//! re-read every `POLL` as a safety net and to let ages pass into silence.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::scan::{scan, Problem, Reporter};
use crate::view::{snapshot, Snapshot};

/// The safety-net re-read, matching the gauge's POLL_MS.
pub const POLL: Duration = Duration::from_secs(5);

/// Whether a change to `path` can change the fleet. Temp files are written
/// then renamed over a session file, and the rename is what counts.
fn counts(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("json" | "beat")
    )
}

pub struct Reader {
    fleet: PathBuf,
    tx: Sender<()>,
    rx: Receiver<()>,
    watcher: Option<RecommendedWatcher>,
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
            reporter: Reporter::default(),
            last: None,
        }
    }

    /// Watch the directory once it exists; drop the watch if it goes away, so
    /// a recreated directory is watched afresh.
    fn attach(&mut self) {
        if !self.fleet.is_dir() {
            self.watcher = None;
            return;
        }
        if self.watcher.is_some() {
            return;
        }
        let tx = self.tx.clone();
        let made = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok_and(|e| e.paths.iter().any(|p| counts(p))) {
                let _ = tx.send(());
            }
        });
        self.watcher = made.ok().and_then(|mut w| {
            w.watch(&self.fleet, RecursiveMode::NonRecursive).ok()?;
            Some(w)
        });
    }

    /// Wait up to `timeout` for a change, then re-read. Returns the snapshot
    /// when it differs from the last one returned, and the problems not
    /// reported before.
    pub fn step(
        &mut self,
        timeout: Duration,
        now: impl Fn() -> i64,
    ) -> (Option<Snapshot>, Vec<Problem>) {
        self.attach();
        if let Err(RecvTimeoutError::Disconnected) = self.rx.recv_timeout(timeout) {
            self.watcher = None;
        }
        while self.rx.try_recv().is_ok() {}
        let listing = scan(&self.fleet);
        let problems = self.reporter.fresh(&listing.problems);
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
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::{session, Scratch, A};
    use crate::view::Status;
    use std::time::Instant;

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
}
