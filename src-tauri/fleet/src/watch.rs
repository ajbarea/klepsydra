//! Following a fleet directory: a filesystem watcher for prompt updates, and a
//! re-read every `POLL` as a safety net and to let ages pass into silence.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::ledger::{lock, Shared};
use crate::scan::{scan, Problem, Reporter};
use crate::speaking::{read as read_speaking, speaking};
use crate::view::{snapshot, Snapshot, Status};

/// The safety-net re-read, matching the gauge's POLL_MS.
pub const POLL: Duration = Duration::from_secs(5);

/// How long to keep gathering events after the first, so one burst of writes
/// is one re-read.
const COALESCE: Duration = Duration::from_millis(75);

/// What a watcher event asks of the reader.
enum Wake {
    /// A session or beat file may have changed.
    Change,
    /// A watched directory itself changed; the watch may be dead.
    Rewatch,
}

/// Temp files are written then renamed over a session file, and the rename is
/// what counts. Opens and closes are the reader's own reads, so they never do.
/// `dirs` are the watched directories: the fleet's and the wrap-up's.
fn wake(dirs: &[PathBuf], res: notify::Result<notify::Event>) -> Option<Wake> {
    let Ok(event) = res else {
        return Some(Wake::Change);
    };
    if matches!(event.kind, EventKind::Access(_)) {
        return None;
    }
    if event.paths.iter().any(|p| dirs.contains(p)) {
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
pub(crate) fn incarnation(dir: &Path) -> Option<u64> {
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
    dir: PathBuf,
    fleet: PathBuf,
    /// The wrap-up's folder, watched too once it exists.
    wrapup: PathBuf,
    /// Its incarnation while the watcher covers it.
    wrap_watched: Option<Option<u64>>,
    tx: Sender<Wake>,
    rx: Receiver<Wake>,
    watcher: Option<RecommendedWatcher>,
    watched: Option<u64>,
    reporter: Reporter,
    last: Option<Snapshot>,
    ledger: Option<Shared>,
    picks: crate::picks::Picks,
}

impl Reader {
    /// A reader for `<klepsydra_dir>/fleet`, which may not exist yet.
    pub fn new(klepsydra_dir: &Path) -> Self {
        let (tx, rx) = channel();
        // The wrap-up's folder is watched from the start, so the first request is not a poll late.
        let _ = std::fs::create_dir_all(klepsydra_dir.join(crate::wrapup::DIR));
        Reader {
            dir: klepsydra_dir.to_path_buf(),
            fleet: klepsydra_dir.join("fleet"),
            wrapup: klepsydra_dir.join(crate::wrapup::DIR),
            wrap_watched: None,
            tx,
            rx,
            watcher: None,
            watched: None,
            reporter: Reporter::default(),
            last: None,
            ledger: None,
            picks: crate::picks::Picks::load(klepsydra_dir),
        }
    }

    /// Attach each session's telemetry totals from `ledger` to its view.
    pub fn with_ledger(mut self, ledger: Shared) -> Self {
        self.ledger = Some(ledger);
        self
    }

    /// Watch the fleet directory once it exists, and the wrap-up's once it
    /// does; drop the watch if either goes away, so a recreated directory is
    /// watched afresh. A watcher that cannot start is a problem; the re-read
    /// every `POLL` still covers it.
    fn attach(&mut self) -> Option<Problem> {
        if !self.fleet.is_dir() {
            self.watcher = None;
            return None;
        }
        let wrap_now = self.wrapup.is_dir().then(|| incarnation(&self.wrapup));
        if self.watcher.is_some() && self.watched == incarnation(&self.fleet) {
            match (self.wrap_watched, wrap_now) {
                (was, now) if was == now => return None,
                (None, Some(now)) => {
                    if let Some(w) = &mut self.watcher {
                        if w.watch(&self.wrapup, RecursiveMode::NonRecursive).is_ok() {
                            self.wrap_watched = Some(now);
                        }
                    }
                    return None;
                }
                _ => {} // gone or remade: start over
            }
        }
        self.watched = incarnation(&self.fleet);
        self.wrap_watched = None;
        let tx = self.tx.clone();
        let dirs = vec![self.fleet.clone(), self.wrapup.clone()];
        let started = notify::recommended_watcher(move |res| {
            if let Some(w) = wake(&dirs, res) {
                let _ = tx.send(w);
            }
        })
        .and_then(|mut w| {
            w.watch(&self.fleet, RecursiveMode::NonRecursive)?;
            Ok(w)
        });
        match started {
            Ok(mut w) => {
                if let Some(now) = wrap_now {
                    if w.watch(&self.wrapup, RecursiveMode::NonRecursive).is_ok() {
                        self.wrap_watched = Some(now);
                    }
                }
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
        if listing.unread {
            // No word on the sessions: the wall keeps what it shows, so an
            // empty read never reads as every session ended (Safe to restart).
            return (None, self.reporter.fresh(&broken));
        }
        let t = now();
        let mut snap = snapshot(&listing.entries, t);
        if self.picks.assign(&mut snap.sessions) {
            if let Err(e) = self.picks.save() {
                broken.push(Problem {
                    file: crate::picks::FILE.into(),
                    what: format!("picks not saved: {e}"),
                });
            }
        }
        let started: HashMap<&str, Option<i64>> = listing
            .entries
            .iter()
            .map(|e| (e.file.session_id.as_str(), e.file.started_at))
            .collect();
        // The session's own voice: the view drops a shared one to keep faces distinct.
        let voices: HashMap<&str, (&str, bool)> = listing
            .entries
            .iter()
            .filter_map(|e| {
                let home = e.file.voice_from.as_deref() == Some("home");
                Some((e.file.session_id.as_str(), (e.file.voice.as_deref()?, home)))
            })
            .collect();
        if let Some(ledger) = &self.ledger {
            let mut l = lock(ledger);
            let mut noted = false;
            for v in &mut snap.sessions {
                if let Some(&(voice, home)) = voices.get(v.session_id.as_str()) {
                    noted |= l.note_voice(&v.session_id, voice, home, t);
                }
                noted |= match &v.pick {
                    Some(pick) => l.note_pick(&v.session_id, pick, t),
                    None => l.forget_pick(&v.session_id),
                };
                // The wall's label for the card (drawer.js `who`).
                let label = v.name.as_deref().filter(|n| !n.is_empty());
                if let Some(label) = label.or(v.place.as_ref().map(|p| p.repo.as_str())) {
                    noted |= l.note_label(&v.session_id, label, t);
                }
                v.ledger = l.session(&v.session_id).cloned();
                // Alive from its start to its end, or to now while it runs.
                let started = started.get(v.session_id.as_str()).copied().flatten();
                let end = if v.status == Status::Ended {
                    v.status_at
                } else {
                    t
                };
                v.ledger_partial =
                    l.lost_in_gap(&v.session_id, started.unwrap_or(v.status_at), end);
            }
            snap.receiver = l.receiver().cloned();
            if noted {
                if let Err(e) = l.save() {
                    broken.push(Problem {
                        file: "ledger".into(),
                        what: format!("voice or label not saved: {e}"),
                    });
                }
            }
        }
        let problems = self.reporter.fresh(&broken);
        for v in &mut snap.sessions {
            v.reply_at = crate::reply::written_at(&self.dir, &v.session_id);
        }
        crate::wrapup::forget_expired(&self.dir, t);
        snap.wrapup = crate::wrapup::request(&self.dir, t);
        if let Some(r) = &snap.wrapup {
            for v in &mut snap.sessions {
                v.wrapup = crate::wrapup::answer(&self.dir, r, &v.session_id);
            }
        }
        let shown = self.last.as_ref().and_then(|s| s.speaking.as_ref());
        snap.speaking = speaking(&read_speaking(&self.fleet), shown, &snap.sessions, t);
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
    use crate::scan::tests::{session, Scratch, A, B};
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
    fn the_wrap_up_request_and_each_answer_reach_the_snapshot() {
        let (root, mut r) = reader("wrapup");
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        let t = 1_700_000_100;
        let snap = r.step(Duration::ZERO, || t).0.unwrap();
        assert_eq!((snap.wrapup, snap.sessions[0].wrapup.clone()), (None, None));
        root.write(
            "wrapup/request.json",
            &format!(r#"{{"id":"9","at":{t},"until":{}}}"#, t + 600),
        );
        root.write(
            &format!("wrapup/{A}.json"),
            r#"{"request":"9","state":"ready","at":1700000101}"#,
        );
        let snap = r.step(Duration::ZERO, || t).0.unwrap();
        assert_eq!(snap.wrapup.unwrap().id, "9");
        let answer = snap.sessions[0].wrapup.clone().unwrap();
        assert_eq!(answer.state, crate::wrapup::State::Ready);
        let json = serde_json::to_value(&snap.sessions[0]).unwrap();
        assert_eq!(json["wrapup"]["state"], "ready");
    }

    fn set_mtime(path: &std::path::Path, t: i64) {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(t as u64))
            .unwrap();
    }

    #[test]
    fn an_answer_and_its_session_share_one_clock_whatever_the_writers_skew() {
        // Prompted at T+5, answered ready at T+185, by a writer clock `ahead`
        // of this one; both files land by this clock. The answer must still
        // follow the prompt, and a later prompt must still overtake it.
        let t = 1_792_800_000;
        for ahead in [-300, 0, 120, 700] {
            let (root, mut r) = reader("wrapup-skew");
            let w = |x: i64| x + ahead;
            let session = format!(
                r#"{{"v":1,"session_id":"{A}","state":"done","state_at":{},"written_at":{},"prompt":{{"text":"/klepsydra-wrapup","at":{}}}}}"#,
                w(t + 190),
                w(t + 190),
                w(t + 5)
            );
            root.write(&format!("fleet/{A}.json"), &session);
            set_mtime(&root.0.join(format!("fleet/{A}.json")), t + 190);
            std::fs::create_dir_all(root.0.join("wrapup")).unwrap();
            root.write(
                "wrapup/request.json",
                &format!(r#"{{"id":"9","at":{t},"until":{},"ids":["{A}"]}}"#, t + 600),
            );
            root.write(
                &format!("wrapup/{A}.json"),
                &format!(r#"{{"request":"9","state":"ready","at":{}}}"#, w(t + 185)),
            );
            set_mtime(&root.0.join(format!("wrapup/{A}.json")), t + 185);
            let snap = r.step(Duration::ZERO, || t + 200).0.unwrap();
            let v = &snap.sessions[0];
            let (prompt, answer) = (v.prompt.as_ref().unwrap().at, v.wrapup.as_ref().unwrap().at);
            assert_eq!(
                (prompt, answer),
                (t + 5, t + 185),
                "writer clock {ahead:+} s"
            );
        }
    }

    #[test]
    fn a_wrap_up_answer_arrives_well_before_the_poll() {
        let (root, mut r) = reader("wrapup-watch");
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        std::fs::create_dir_all(root.0.join("wrapup")).unwrap();
        let t = unix_now();
        root.write(
            "wrapup/request.json",
            &format!(r#"{{"id":"9","at":{t},"until":{},"ids":["{A}"]}}"#, t + 600),
        );
        r.step(Duration::ZERO, unix_now);
        let wrap = root.0.join("wrapup");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            let tmp = wrap.join(format!("{A}.json.77.tmp"));
            std::fs::write(
                &tmp,
                format!(r#"{{"request":"9","state":"ready","at":{t}}}"#),
            )
            .unwrap();
            std::fs::rename(&tmp, wrap.join(format!("{A}.json"))).unwrap();
        });
        let started = Instant::now();
        let (snap, _) = r.step(POLL, unix_now);
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher, not the poll"
        );
        assert_eq!(
            snap.unwrap().sessions[0].wrapup.as_ref().map(|a| a.state),
            Some(crate::wrapup::State::Ready)
        );
    }

    #[test]
    fn the_first_wrap_up_ever_arrives_well_before_the_poll() {
        let (root, mut r) = reader("wrapup-first");
        assert!(
            root.0.join("wrapup").is_dir(),
            "the reader makes the folder it watches"
        );
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        r.step(Duration::ZERO, unix_now);
        let dir = root.0.clone();
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            crate::wrapup::start(&dir, unix_now() * 1000, &[A.to_owned()]).unwrap();
        });
        let started = Instant::now();
        let (snap, _) = r.step(POLL, unix_now);
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher, not the poll"
        );
        assert!(snap.unwrap().wrapup.is_some());
    }

    #[test]
    fn a_request_past_its_hour_is_removed_by_the_reader() {
        let (root, mut r) = reader("wrapup-forget");
        let t = 1_700_000_100;
        root.write(
            "wrapup/request.json",
            &format!(r#"{{"id":"9","at":{t},"until":{}}}"#, t + 600),
        );
        r.step(Duration::ZERO, || t + 600 + crate::wrapup::SHOWN_AFTER + 1);
        assert!(!root.0.join("wrapup/request.json").exists());
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

    fn claude_session(id: &str, pid: u32, start: u64) -> String {
        format!(
            r#"{{"v":1,"session_id":"{id}","state":"working","state_at":1700000000,"claude":{{"pid":{pid},"start":{start}}}}}"#
        )
    }

    fn line(pid: u32, start: u64, from: f64, to: f64) -> String {
        format!(
            r#"{{"v":1,"voice":"af_heart","terminal":"{pid}:{start}","claude_pid":{pid},"claude_start":{start},"started_at":{from},"ends_at":{to},"envelope":[0.2,1.0,0.4]}}"#
        )
    }

    #[test]
    fn a_line_being_spoken_rides_on_the_snapshot_and_goes_with_its_file() {
        let (root, mut r) = reader("speak");
        root.write(&format!("fleet/{A}.json"), &claude_session(A, 4242, 99));
        let t = unix_now();
        let now = t as f64;
        root.write("fleet/speaking.json", &line(4242, 99, now, now + 3.0));
        let snap = r.step(Duration::ZERO, || t).0.unwrap();
        assert_eq!(snap.sessions.len(), 1, "speaking.json is not a session");
        let s = snap.speaking.unwrap();
        assert_eq!((s.session_id.as_str(), s.envelope.len()), (A, 3));
        // The next sentence replaces the file: a new snapshot, at once.
        let fleet = root.0.join("fleet");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            let tmp = fleet.join("speaking.json.7.tmp");
            std::fs::write(&tmp, line(4242, 99, now + 3.2, now + 5.0)).unwrap();
            std::fs::rename(&tmp, fleet.join("speaking.json")).unwrap();
        });
        let started = Instant::now();
        let snap = r.step(POLL, || t).0.unwrap();
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher"
        );
        assert_eq!(snap.speaking.unwrap().started_at, now + 3.2);
        // A cut-off removes the file.
        std::fs::remove_file(root.0.join("fleet/speaking.json")).unwrap();
        assert_eq!(r.step(Duration::ZERO, || t).0.unwrap().speaking, None);
    }

    #[test]
    fn a_line_left_behind_by_a_crash_goes_once_it_has_ended() {
        let (root, mut r) = reader("speak-stale");
        root.write(&format!("fleet/{A}.json"), &claude_session(A, 4242, 99));
        let t = unix_now();
        let now = t as f64;
        root.write("fleet/speaking.json", &line(4242, 99, now, now + 2.0));
        assert!(r.step(Duration::ZERO, || t).0.unwrap().speaking.is_some());
        let later = r.step(Duration::ZERO, || t + 3).0.unwrap();
        assert_eq!(later.speaking, None);
        assert_eq!(later.sessions.len(), 1);
    }

    #[test]
    fn a_line_starting_well_after_now_is_not_speaking() {
        let (root, mut r) = reader("speak-ahead");
        root.write(&format!("fleet/{A}.json"), &claude_session(A, 4242, 99));
        let t = unix_now();
        let now = t as f64;
        root.write(
            "fleet/speaking.json",
            &line(4242, 99, now + 10.0, now + 12.0),
        );
        assert_eq!(r.step(Duration::ZERO, || t).0.unwrap().speaking, None);
        root.write("fleet/speaking.json", &line(4242, 99, now + 4.0, now + 6.0));
        assert!(
            r.step(Duration::ZERO, || t).0.unwrap().speaking.is_some(),
            "a little ahead is clock slack"
        );
    }

    #[test]
    fn a_half_written_file_keeps_the_line_but_a_removed_one_ends_it() {
        let (root, mut r) = reader("speak-partial");
        root.write(&format!("fleet/{A}.json"), &claude_session(A, 4242, 99));
        let t = unix_now();
        let now = t as f64;
        let whole = line(4242, 99, now, now + 3.0);
        root.write("fleet/speaking.json", &whole);
        let first = r.step(Duration::ZERO, || t).0.unwrap().speaking;
        assert!(first.is_some());
        // Windows' replace is best effort: a read can catch half a file.
        root.write("fleet/speaking.json", &whole[..whole.len() / 2]);
        assert_eq!(
            r.step(Duration::ZERO, || t).0,
            None,
            "nothing changed: the line goes on"
        );
        // Past its end and the hold, a kept line goes.
        assert_eq!(r.step(Duration::ZERO, || t + 4).0.unwrap().speaking, None);
        root.write("fleet/speaking.json", &whole);
        assert!(r.step(Duration::ZERO, || t).0.unwrap().speaking.is_some());
        std::fs::remove_file(root.0.join("fleet/speaking.json")).unwrap();
        assert_eq!(r.step(Duration::ZERO, || t).0.unwrap().speaking, None);
    }

    #[test]
    fn a_broken_speaking_file_is_silence_not_a_problem() {
        let (root, mut r) = reader("speak-bad");
        root.write(&format!("fleet/{A}.json"), &claude_session(A, 4242, 99));
        root.write("fleet/speaking.json", "{half");
        let (snap, problems) = r.step(Duration::ZERO, unix_now);
        let snap = snap.unwrap();
        assert_eq!((snap.speaking, snap.sessions.len()), (None, 1));
        assert!(problems.is_empty());
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
    #[test]
    fn an_unreadable_fleet_folder_keeps_the_last_snapshot() {
        let root = Scratch::new("unread-fleet");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        let t = unix_now();
        let mut r = Reader::new(&root.0);
        assert_eq!(r.step(Duration::ZERO, || t).0.unwrap().sessions.len(), 1);
        std::fs::remove_dir_all(root.0.join("fleet")).unwrap();
        root.write("fleet", "not a folder");
        let (snap, problems) = r.step(Duration::ZERO, || t);
        assert!(
            snap.is_none(),
            "an unreadable folder is no news, not an empty fleet"
        );
        assert!(
            problems
                .iter()
                .any(|p| p.what.starts_with("fleet folder not read")),
            "{problems:?}"
        );
    }

    #[test]
    fn a_session_with_a_reply_clip_says_when_keryx_kept_it() {
        let root = Scratch::new("reply-at");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        std::fs::create_dir_all(root.0.join("replies")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        root.write(&format!("fleet/{B}.json"), &session(B, "done"));
        let mut wav = b"RIFF\x24\x00\x00\x00WAVEfmt ".to_vec();
        wav.resize(100, 0);
        std::fs::write(root.0.join("replies").join(format!("{A}.wav")), wav).unwrap();
        let t = unix_now();
        let snap = Reader::new(&root.0).step(Duration::ZERO, || t).0.unwrap();
        let at = |id: &str| {
            snap.sessions
                .iter()
                .find(|v| v.session_id == id)
                .unwrap()
                .reply_at
        };
        assert!(at(A).is_some_and(|s| s > 1_700_000_000));
        assert_eq!(at(B), None);
    }

    #[test]
    fn a_session_gets_its_telemetry_totals_and_a_change_republishes() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-view");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        let t = unix_now();
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        let first = r.step(Duration::ZERO, || t).0.unwrap();
        // No telemetry yet: the field is absent, as the wall has always seen it.
        assert_eq!(first.sessions[0].ledger, None);
        let json = serde_json::to_value(&first).unwrap();
        assert!(json["sessions"][0].get("ledger").is_none());
        let ns = (t as u64 * 1_000_000_000).to_string();
        let export = serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":A}}],"timeUnixNano":ns,"asDouble":2}]}}]}]}]});
        ledger
            .lock()
            .unwrap()
            .record_metrics(&crate::otel::metrics(&export), t);
        let next = r.step(Duration::ZERO, || t).0.expect("a new snapshot");
        assert_eq!(next.sessions[0].ledger.as_ref().unwrap().commits, 2);
        let json = serde_json::to_value(&next).unwrap();
        assert_eq!(json["sessions"][0]["ledger"]["commits"], 2);
    }

    #[test]
    fn the_ledger_keeps_each_cards_label_its_name_else_its_repo() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-labels");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        root.write(
            &format!("fleet/{A}.beat"),
            "Techne PR queue resume\t179235300\n",
        );
        root.write(
            &format!("fleet/{B}.json"),
            &format!(
                r#"{{"v":1,"session_id":"{B}","state":"done","state_at":1700000000,"where":{{"repo":"pharos","branch":"main","by":"edit","at":1700000000}}}}"#
            ),
        );
        let t = unix_now();
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        let ns = (t as u64 * 1_000_000_000).to_string();
        for id in [A, B] {
            let export = serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":id}}],"timeUnixNano":ns,"asDouble":1}]}}]}]}]});
            ledger
                .lock()
                .unwrap()
                .record_metrics(&crate::otel::metrics(&export), t);
        }
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        r.step(Duration::ZERO, || t).0.unwrap();
        let l = ledger.lock().unwrap();
        assert_eq!(l.day().labels[A], "Techne PR queue resume");
        assert_eq!(l.day().labels[B], "pharos");
    }

    #[test]
    fn a_taken_port_reaches_the_snapshot() {
        use crate::ledger::{Ledger, Receiver};
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-receiver");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        let t = unix_now();
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        let first = r.step(Duration::ZERO, || t).0.unwrap();
        assert!(serde_json::to_value(&first)
            .unwrap()
            .get("receiver")
            .is_none());
        ledger.lock().unwrap().set_receiver(Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: false,
            error: Some("address in use".into()),
        });
        let next = r.step(Duration::ZERO, || t).0.expect("a new snapshot");
        let json = serde_json::to_value(&next).unwrap();
        assert_eq!(json["receiver"]["listening"], false);
        assert_eq!(json["receiver"]["error"], "address in use");
    }

    fn spanned(id: &str, state: &str, start: i64, ended: Option<i64>) -> String {
        let (at, end) = (
            ended.unwrap_or(start),
            ended.map_or(String::new(), |e| format!(r#","ended":{{"at":{e}}}"#)),
        );
        format!(
            r#"{{"v":1,"session_id":"{id}","state":"{state}","state_at":{at},"started_at":{start}{end}}}"#
        )
    }

    #[test]
    fn a_session_alive_while_the_receiver_was_down_reads_partial() {
        use crate::ledger::{Ledger, Receiver};
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-partial");
        let fleet = root.0.join("fleet");
        std::fs::create_dir_all(&fleet).unwrap();
        const T0: i64 = 1_800_000_000;
        let ids = [
            "11111111-2222-4333-8444-555555555551",
            "11111111-2222-4333-8444-555555555552",
            "11111111-2222-4333-8444-555555555553",
            "11111111-2222-4333-8444-555555555554",
        ];
        // Running through the second gap, ended inside it, ended between the
        // gaps, started after the last one.
        let files = [
            spanned(ids[0], "working", T0 + 1100, None),
            spanned(ids[1], "ended", T0 + 1065, Some(T0 + 1070)),
            spanned(ids[2], "ended", T0 + 1010, Some(T0 + 1050)),
            spanned(ids[3], "working", T0 + 1250, None),
        ];
        for (id, text) in ids.iter().zip(&files) {
            root.write(&format!("fleet/{id}.json"), text);
        }
        let (mut l, _) = Ledger::open(root.0.join("ledger"), T0 + 1000, jiff::tz::TimeZone::UTC);
        l.note_listening(T0 + 1000).unwrap(); // gap 0..T0 + 1000
        l.set_receiver(Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: true,
            error: None,
        });
        assert!(l.stamp_alive(T0 + 1060));
        l.note_listening(T0 + 1200).unwrap(); // gap T0 + 1060..T0 + 1200
        let ledger = Arc::new(Mutex::new(l));
        let mut r = Reader::new(&root.0).with_ledger(ledger);
        let snap = r.step(Duration::ZERO, || T0 + 1300).0.unwrap();
        let seen: Vec<_> = snap
            .sessions
            .iter()
            .map(|v| (&v.session_id, v.status))
            .collect();
        let partial = |id: &str| {
            let v = snap.sessions.iter().find(|v| v.session_id == id);
            v.unwrap_or_else(|| panic!("{id} not shown: {seen:?}"))
                .ledger_partial
        };
        assert_eq!(
            ids.map(partial),
            [true, true, false, false],
            "{:?}",
            snap.sessions
                .iter()
                .map(|v| (&v.session_id, v.status))
                .collect::<Vec<_>>()
        );
        let json = serde_json::to_value(&snap).unwrap();
        for v in json["sessions"].as_array().unwrap() {
            let id = v["session_id"].as_str().unwrap();
            assert_eq!(v.get("ledger_partial").is_some(), partial(id), "{id}");
        }
    }

    #[test]
    fn a_cumulative_export_after_the_gap_clears_the_partial_mark() {
        use crate::ledger::{Ledger, Receiver};
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-partial-cumulative");
        let fleet = root.0.join("fleet");
        std::fs::create_dir_all(&fleet).unwrap();
        const T0: i64 = 1_800_000_000;
        let ids = [
            "11111111-2222-4333-8444-555555555561",
            "11111111-2222-4333-8444-555555555562",
            "11111111-2222-4333-8444-555555555563",
        ];
        for id in ids {
            root.write(
                &format!("fleet/{id}.json"),
                &spanned(id, "working", T0 + 1000, None),
            );
        }
        let (mut l, _) = Ledger::open(root.0.join("ledger"), T0 + 900, jiff::tz::TimeZone::UTC);
        l.note_listening(T0 + 900).unwrap();
        l.set_receiver(Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: true,
            error: None,
        });
        assert!(l.stamp_alive(T0 + 1060));
        l.note_listening(T0 + 1200).unwrap(); // gap T0 + 1060..T0 + 1200
        let point = |id: &str, temporality: u8, at: i64| {
            let ns = (at as u64 * 1_000_000_000).to_string();
            crate::otel::metrics(
                &serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":temporality,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":id}},{"key":"type","value":{"stringValue":"input"}}],"startTimeUnixNano":(T0 as u64 * 1_000_000_000).to_string(),"timeUnixNano":ns,"asDouble":3}]}}]}]}]}),
            )
        };
        // Cumulative after the gap, delta after the gap, cumulative before its end.
        l.record_metrics(&point(ids[0], 2, T0 + 1250), T0 + 1250);
        l.record_metrics(&point(ids[1], 1, T0 + 1250), T0 + 1250);
        l.record_metrics(&point(ids[2], 2, T0 + 1100), T0 + 1100);
        let mut r = Reader::new(&root.0).with_ledger(Arc::new(Mutex::new(l)));
        let snap = r.step(Duration::ZERO, || T0 + 1300).0.unwrap();
        let partial = |id: &str| {
            snap.sessions
                .iter()
                .find(|v| v.session_id == id)
                .unwrap()
                .ledger_partial
        };
        assert_eq!(ids.map(partial), [false, true, true]);
    }

    #[test]
    fn a_reader_without_a_ledger_marks_nothing_partial() {
        let (root, mut r) = reader("no-partial");
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        let snap = r.step(Duration::ZERO, unix_now).0.unwrap();
        assert!(!snap.sessions[0].ledger_partial);
    }

    #[test]
    fn a_session_in_todays_ledger_has_its_voice_recorded_once() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-voice");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        let t = unix_now();
        for (id, voice) in [(A, "af_heart"), (B, "bf_emma")] {
            let text = claude_session(id, 4242, 99).replace(
                r#""state":"working""#,
                &format!(r#""state":"working","voice":"{voice}""#),
            );
            root.write(&format!("fleet/{id}.json"), &text);
        }
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        let ns = (t as u64 * 1_000_000_000).to_string();
        let export = serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":A}}],"timeUnixNano":ns,"asDouble":1}]}}]}]}]});
        ledger
            .lock()
            .unwrap()
            .record_metrics(&crate::otel::metrics(&export), t);
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        r.step(Duration::ZERO, || t);
        let l = ledger.lock().unwrap();
        // A is in today's file; B has no telemetry yet, so no voice.
        assert_eq!(l.day().voices.get(A).map(String::as_str), Some("af_heart"));
        assert!(!l.day().voices.contains_key(B));
    }

    /// A session file for `id` with `voice` from a repo's home, so two of them
    /// share one face on the wall.
    fn homed(id: &str, voice: &str) -> String {
        claude_session(id, 4242, 99).replace(
            r#""state":"working""#,
            &format!(r#""state":"working","voice":"{voice}","voice_from":"home""#),
        )
    }

    fn commit_export(id: &str, at: i64) -> Vec<crate::otel::Point> {
        let ns = (at as u64 * 1_000_000_000).to_string();
        crate::otel::metrics(
            &serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":id}}],"timeUnixNano":ns,"asDouble":1}]}}]}]}]}),
        )
    }

    fn day_voices(dir: &Path, day: &str) -> serde_json::Value {
        let bytes = std::fs::read(dir.join(format!("{day}.json"))).unwrap();
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["voices"].clone()
    }

    #[test]
    fn a_pick_leaves_todays_ledger_once_its_session_wears_its_own_voice_again() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-pick-back");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        let t = unix_now();
        for id in [A, B] {
            root.write(&format!("fleet/{id}.json"), &homed(id, "bf_emma"));
        }
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        for id in [A, B] {
            ledger
                .lock()
                .unwrap()
                .record_metrics(&commit_export(id, t), t);
        }
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        r.step(Duration::ZERO, || t);
        let picked: Vec<String> = ledger.lock().unwrap().day().picks.keys().cloned().collect();
        assert_eq!(
            picked.len(),
            1,
            "one of the two shares-a-voice cards wears a pick"
        );
        let keeper = if picked[0] == A { B } else { A };
        std::fs::remove_file(root.0.join(format!("fleet/{keeper}.json"))).unwrap();
        r.step(Duration::ZERO, || t + 1);
        assert!(
            ledger.lock().unwrap().day().picks.is_empty(),
            "its own voice is back, so its tokens follow that character"
        );
    }

    #[test]
    fn a_recorded_voice_is_on_disk_before_the_next_export() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-voice-saved");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &homed(A, "af_heart"));
        let dir = root.0.join("ledger");
        let t = unix_now();
        // A zone where t is midday: the restart a minute on is the same day
        // at any hour the test runs.
        let midday = i32::try_from(43_200 - t.rem_euclid(86_400)).unwrap();
        let tz = jiff::tz::TimeZone::fixed(jiff::tz::Offset::from_seconds(midday).unwrap());
        let (mut l, _) = Ledger::open(dir.clone(), t, tz.clone());
        l.record_metrics(&commit_export(A, t), t);
        l.save().unwrap(); // as the receiver does after a counted export
        let mut r = Reader::new(&root.0).with_ledger(Arc::new(Mutex::new(l)));
        let (_, problems) = r.step(Duration::ZERO, || t);
        assert!(problems.is_empty(), "{problems:?}");
        // A restart before any later export keeps the voice.
        let (again, _) = Ledger::open(dir, t + 60, tz);
        assert_eq!(
            again.day().voices.get(A).map(String::as_str),
            Some("af_heart")
        );
    }

    #[test]
    fn a_voice_first_seen_after_midnight_lands_in_the_new_days_file() {
        use crate::ledger::{day_name, Ledger};
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-voice-midnight");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &homed(A, "af_heart"));
        let dir = root.0.join("ledger");
        let utc = jiff::tz::TimeZone::UTC;
        let t = unix_now();
        let next = (t / 86_400 + 1) * 86_400 + 10;
        let (yesterday, today) = (day_name(t, &utc), day_name(next, &utc));
        let (mut l, _) = Ledger::open(dir.clone(), t, utc);
        l.record_metrics(&commit_export(A, t), t);
        l.save().unwrap();
        let ledger = Arc::new(Mutex::new(l));
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        // Past midnight with no export yet: yesterday's day is still in memory.
        r.step(Duration::ZERO, || next);
        assert_eq!(
            ledger.lock().unwrap().day().day,
            today,
            "the reader rolled the day"
        );
        assert!(day_voices(&dir, &yesterday).get(A).is_none());
        let mut l = ledger.lock().unwrap();
        l.record_metrics(&commit_export(A, next), next);
        l.save().unwrap();
        drop(l);
        r.step(Duration::ZERO, || next + 1);
        assert_eq!(day_voices(&dir, &today)[A], "af_heart");
        assert!(
            day_voices(&dir, &yesterday).get(A).is_none(),
            "yesterday's file never took the voice"
        );
    }

    #[test]
    fn two_sessions_sharing_a_voice_both_have_it_recorded() {
        use crate::ledger::Ledger;
        use std::sync::{Arc, Mutex};
        let root = Scratch::new("ledger-voice-shared");
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        for id in [A, B] {
            root.write(&format!("fleet/{id}.json"), &homed(id, "af_heart"));
        }
        let t = unix_now();
        let ledger = Arc::new(Mutex::new(Ledger::in_memory(t)));
        for id in [A, B] {
            ledger
                .lock()
                .unwrap()
                .record_metrics(&commit_export(id, t), t);
        }
        let mut r = Reader::new(&root.0).with_ledger(ledger.clone());
        let snap = r.step(Duration::ZERO, || t).0.unwrap();
        // The wall still shows one face for the voice.
        let faces = snap.sessions.iter().filter(|v| v.voice.is_some()).count();
        assert_eq!(faces, 1, "{:?}", snap.sessions);
        let l = ledger.lock().unwrap();
        for id in [A, B] {
            assert_eq!(
                l.day().voices.get(id).map(String::as_str),
                Some("af_heart"),
                "{id}"
            );
        }
    }
}
