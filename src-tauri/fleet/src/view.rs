//! What the strip and the wall show for each session: its status with that
//! status's time, in the order AJ reads them.

use serde::Serialize;

use crate::session::{Place, Said, SessionFile, State, Touched};

/// No heartbeat and no event for this long, and a session is silent: three
/// missed 30 s statusline refreshes.
pub const SILENT_AFTER: i64 = 90;
/// How long an ended session stays on the strip and the wall.
pub const ENDED_FOR: i64 = 600;
/// Clocks closer than this are taken to agree; the hook stamps a file a
/// moment before it lands.
const SKEW_SLACK: i64 = 2;
/// A working turn with no hook event for this long is quiet: a user interrupt
/// leaves one behind, because Stop does not run on an interrupt.
pub const QUIET_AFTER: i64 = 600;

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    NeedsYou,
    Error,
    Working,
    Done,
    New,
    Silent,
    Ended,
}

impl Status {
    fn rank(self) -> u8 {
        self as u8
    }
}

/// One session file as found on disk.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub file: SessionFile,
    /// When the file last changed, by this machine's clock.
    pub modified: i64,
    /// The heartbeat: when it last changed, and the name it carries.
    pub beat: Option<(i64, Option<String>)>,
}

/// A session as the webview receives it. Every time is by this machine's
/// clock, in epoch seconds.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct View {
    pub session_id: String,
    pub name: Option<String>,
    pub launch_dir: Option<String>,
    pub voice: Option<String>,
    pub status: Status,
    pub reason: Option<String>,
    pub status_at: i64,
    #[serde(rename = "where")]
    pub place: Option<Place>,
    pub touched: Vec<Touched>,
    pub prompt: Option<Said>,
    pub reply: Option<Said>,
    pub error: Option<String>,
    pub updated_at: i64,
    /// Last hook activity, when the session is working and has had none for
    /// `QUIET_AFTER`.
    pub quiet_since: Option<i64>,
}

#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Snapshot {
    pub sessions: Vec<View>,
}

/// Seconds to add to the hook's times to put them on this machine's clock.
/// The hook stamps `written_at` just before it writes, and the filesystem
/// stamps the write by this machine's clock, so the difference is how far the
/// two clocks disagree (a Linux guest's drifts after the host sleeps).
fn skew(entry: &Entry) -> i64 {
    match entry.file.written_at {
        Some(w) if (entry.modified - w).abs() > SKEW_SLACK => entry.modified - w,
        _ => 0,
    }
}

/// What to show for one session at `now`, or None once it has ended long enough ago.
pub fn view(entry: &Entry, now: i64) -> Option<View> {
    let f = &entry.file;
    let shift = skew(entry);
    let at = |t: i64| t + shift;
    let state_at = at(f.state_at);
    if f.state == State::Ended {
        let ended = f.ended.as_ref().map_or(state_at, |e| at(e.at));
        if now - ended > ENDED_FOR {
            return None;
        }
    }
    // The last word of any kind: a heartbeat, or a change to the file.
    let last_word = entry
        .beat
        .as_ref()
        .map_or(entry.modified, |b| b.0.max(entry.modified));
    let silent = f.state != State::Ended && now - last_word > SILENT_AFTER;
    let (status, reason, status_at) = if silent {
        (Status::Silent, None, last_word)
    } else {
        let status = match f.state {
            State::New => Status::New,
            State::Working => Status::Working,
            State::NeedsYou => Status::NeedsYou,
            State::Done => Status::Done,
            State::Error => Status::Error,
            State::Ended => Status::Ended,
        };
        (status, f.reason.clone(), state_at)
    };
    let shift_said = |s: &Option<Said>| {
        s.as_ref().map(|s| Said {
            text: s.text.clone(),
            at: at(s.at),
        })
    };
    let place = f.place.as_ref().map(|p| Place {
        at: at(p.at),
        ..p.clone()
    });
    let prompt = shift_said(&f.prompt);
    let reply = shift_said(&f.reply);
    let updated_at = [
        Some(state_at),
        place.as_ref().map(|p| p.at),
        prompt.as_ref().map(|s| s.at),
        reply.as_ref().map(|s| s.at),
        f.ended.as_ref().map(|e| at(e.at)),
    ]
    .into_iter()
    .flatten()
    .max()
    .unwrap_or(state_at);
    let last_activity = f.written_at.map_or(entry.modified, at);
    let quiet_since =
        (status == Status::Working && now - last_activity > QUIET_AFTER).then_some(last_activity);
    let beat_name = entry.beat.as_ref().and_then(|b| b.1.clone());
    Some(View {
        session_id: f.session_id.clone(),
        name: beat_name.or_else(|| f.name.clone()),
        launch_dir: f.launch_dir.clone(),
        voice: f.voice.clone(),
        status,
        reason,
        status_at,
        place,
        touched: f
            .touched
            .iter()
            .map(|t| Touched {
                repo: t.repo.clone(),
                at: at(t.at),
            })
            .collect(),
        prompt,
        reply,
        error: f.error.clone(),
        updated_at,
        quiet_since,
    })
}

/// Every session to show, needing AJ first, the longest wait leading; then
/// errors, work in progress, finished work newest first, not started,
/// silent and ended.
pub fn snapshot(entries: &[Entry], now: i64) -> Snapshot {
    let mut sessions: Vec<View> = entries.iter().filter_map(|e| view(e, now)).collect();
    sessions.sort_by(|a, b| {
        a.status
            .rank()
            .cmp(&b.status.rank())
            .then_with(|| match a.status {
                Status::NeedsYou => a.status_at.cmp(&b.status_at),
                _ => b.status_at.cmp(&a.status_at),
            })
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    Snapshot { sessions }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_792_353_000;

    fn file(id: &str, state: State, state_at: i64) -> SessionFile {
        SessionFile {
            session_id: id.into(),
            name: None,
            launch_dir: Some("/home/aj/ajsoftworks".into()),
            voice: Some("am_michael".into()),
            state,
            reason: None,
            state_at,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            ended: None,
            written_at: Some(state_at),
        }
    }

    /// A session whose file last changed at `state_at` and which beat at `beat`.
    fn entry(id: &str, state: State, state_at: i64, beat: i64) -> Entry {
        Entry {
            file: file(id, state, state_at),
            modified: state_at,
            beat: Some((beat, Some(format!("tab {id}")))),
        }
    }

    fn ids(s: &Snapshot) -> Vec<&str> {
        s.sessions.iter().map(|v| v.session_id.as_str()).collect()
    }

    #[test]
    fn a_session_whose_heartbeat_stopped_is_silent_never_working() {
        let e = entry("a", State::Working, NOW - 600, NOW - 91);
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status, Status::Silent);
        assert_eq!(v.status_at, NOW - 91, "silent since the last word");
        assert_eq!(v.reason, None);
    }

    #[test]
    fn a_live_heartbeat_keeps_the_state() {
        let e = entry("a", State::Working, NOW - 600, NOW - 30);
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.status_at), (Status::Working, NOW - 600));
    }

    #[test]
    fn a_recent_event_keeps_a_session_from_silence_even_without_a_beat() {
        let mut e = entry("a", State::NeedsYou, NOW - 20, 0);
        e.beat = None;
        assert_eq!(view(&e, NOW).unwrap().status, Status::NeedsYou);
        e.file.state_at = NOW - 200;
        e.modified = NOW - 200;
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
    }

    #[test]
    fn an_event_after_the_last_beat_still_falls_silent() {
        let e = entry("a", State::Working, NOW - 95, NOW - 120);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
    }

    #[test]
    fn an_ended_session_stays_ten_minutes_and_is_never_silent() {
        let mut e = entry("a", State::Ended, NOW - 300, NOW - 300);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Ended);
        e.file.state_at = NOW - 601;
        e.modified = NOW - 601;
        assert_eq!(view(&e, NOW), None);
    }

    #[test]
    fn not_started_is_its_own_status() {
        let e = entry("a", State::New, NOW - 10, NOW - 5);
        assert_eq!(view(&e, NOW).unwrap().status, Status::New);
    }

    #[test]
    fn the_beat_names_the_session_over_the_file() {
        let mut e = entry("a", State::Done, NOW - 10, NOW - 5);
        e.file.name = Some("custom".into());
        assert_eq!(view(&e, NOW).unwrap().name.as_deref(), Some("tab a"));
        e.beat = Some((NOW - 5, None));
        assert_eq!(view(&e, NOW).unwrap().name.as_deref(), Some("custom"));
    }

    #[test]
    fn a_writer_clock_ten_minutes_ahead_is_put_back() {
        // The hook's clock ahead of this one: every stored time reads 600 s late.
        let mut e = entry("a", State::NeedsYou, NOW - 120 + 600, NOW - 10);
        e.modified = NOW - 120;
        e.file.prompt = Some(Said {
            text: "go".into(),
            at: NOW - 130 + 600,
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status_at, NOW - 120);
        assert_eq!(v.prompt.unwrap().at, NOW - 130);
    }

    #[test]
    fn a_writer_clock_behind_is_put_forward_and_cannot_hide_silence() {
        let mut e = entry("a", State::Working, NOW - 900 - 3600, NOW - 900);
        e.modified = NOW - 900;
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status, Status::Silent);
        assert_eq!(v.status_at, NOW - 900);
    }

    #[test]
    fn a_two_second_disagreement_is_not_skew() {
        let mut e = entry("a", State::Done, NOW - 100, NOW - 5);
        e.modified = NOW - 98;
        assert_eq!(view(&e, NOW).unwrap().status_at, NOW - 100);
    }

    #[test]
    fn updated_is_the_newest_field() {
        let mut e = entry("a", State::Working, NOW - 400, NOW - 5);
        e.file.reply = Some(Said {
            text: "r".into(),
            at: NOW - 350,
        });
        e.file.prompt = Some(Said {
            text: "p".into(),
            at: NOW - 300,
        });
        assert_eq!(view(&e, NOW).unwrap().updated_at, NOW - 300);
    }

    #[test]
    fn order_needs_you_longest_wait_first_then_by_status() {
        let entries = vec![
            entry("ended", State::Ended, NOW - 60, NOW - 60),
            entry("done-old", State::Done, NOW - 500, NOW - 5),
            entry("needs-new", State::NeedsYou, NOW - 10, NOW - 5),
            entry("silent", State::Working, NOW - 300, NOW - 200),
            entry("new", State::New, NOW - 20, NOW - 5),
            entry("working", State::Working, NOW - 40, NOW - 5),
            entry("done-new", State::Done, NOW - 50, NOW - 5),
            entry("error", State::Error, NOW - 70, NOW - 5),
            entry("needs-old", State::NeedsYou, NOW - 80, NOW - 5),
        ];
        assert_eq!(
            ids(&snapshot(&entries, NOW)),
            vec![
                "needs-old",
                "needs-new",
                "error",
                "working",
                "done-new",
                "done-old",
                "new",
                "silent",
                "ended"
            ]
        );
    }

    #[test]
    fn a_session_that_starts_needing_aj_moves_to_the_front() {
        let mut entries = vec![
            entry("a", State::Working, NOW - 40, NOW - 5),
            entry("b", State::Done, NOW - 50, NOW - 5),
        ];
        assert_eq!(ids(&snapshot(&entries, NOW)), vec!["a", "b"]);
        entries[1] = entry("b", State::NeedsYou, NOW - 1, NOW - 1);
        assert_eq!(ids(&snapshot(&entries, NOW)), vec!["b", "a"]);
    }

    #[test]
    fn the_snapshot_serialises_as_the_webview_reads_it() {
        let mut e = entry("a", State::NeedsYou, NOW - 120, NOW - 5);
        e.file.reason = Some("approve Bash".into());
        let json = serde_json::to_value(snapshot(&[e], NOW)).unwrap();
        let s = &json["sessions"][0];
        assert_eq!(s["status"], "needs_you");
        assert_eq!(s["reason"], "approve Bash");
        assert_eq!(s["status_at"], NOW - 120);
        assert_eq!(s["where"], serde_json::Value::Null);
        assert_eq!(s["name"], "tab a");
    }

    fn quiet(state: State, written_at: i64, modified: i64) -> Option<i64> {
        let mut e = entry("a", state, NOW - 5, NOW - 5);
        e.file.written_at = Some(written_at);
        e.modified = modified;
        view(&e, NOW).unwrap().quiet_since
    }

    #[test]
    fn a_working_turn_with_no_event_for_ten_minutes_is_quiet() {
        let mut e = entry("a", State::Working, NOW - 601, NOW - 5);
        e.modified = NOW - 601;
        assert_eq!(view(&e, NOW).unwrap().quiet_since, Some(NOW - 601));
        assert_eq!(quiet(State::Working, NOW - 599, NOW - 599), None);
    }

    #[test]
    fn only_a_working_session_is_ever_quiet() {
        for state in [State::Done, State::NeedsYou, State::New, State::Error] {
            assert_eq!(quiet(state, NOW - 700, NOW - 700), None, "{state:?}");
        }
        let silent = entry("a", State::Working, NOW - 700, NOW - 700);
        let v = view(&silent, NOW).unwrap();
        assert_eq!((v.status, v.quiet_since), (Status::Silent, None));
    }

    #[test]
    fn quiet_is_judged_after_the_skew_is_corrected() {
        // Writer clock 3600 s ahead: written_at reads fresh, the file is 700 s old.
        let mut e = entry("a", State::Working, NOW + 3000, NOW - 5);
        e.modified = NOW - 700;
        e.file.written_at = Some(NOW + 2900);
        e.beat = Some((NOW - 5, None));
        assert_eq!(view(&e, NOW).unwrap().quiet_since, Some(NOW - 700));
    }

    #[test]
    fn quiet_falls_back_to_the_file_time_without_written_at() {
        let mut e = entry("a", State::Working, NOW - 650, NOW - 5);
        e.file.written_at = None;
        e.modified = NOW - 650;
        assert_eq!(view(&e, NOW).unwrap().quiet_since, Some(NOW - 650));
    }
}
