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
    ledger: Option<Shared>,
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
            ledger: None,
        }
    }

    /// Attach each session's telemetry totals from `ledger` to its view.
    pub fn with_ledger(mut self, ledger: Shared) -> Self {
        self.ledger = Some(ledger);
        self
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
        let t = now();
        let mut snap = snapshot(&listing.entries, t);
        let started: HashMap<&str, Option<i64>> = listing
            .entries
            .iter()
            .map(|e| (e.file.session_id.as_str(), e.file.started_at))
            .collect();
        if let Some(ledger) = &self.ledger {
            let mut l = lock(ledger);
            for v in &mut snap.sessions {
                if let Some(voice) = &v.voice {
                    l.note_voice(&v.session_id, voice);
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
}
