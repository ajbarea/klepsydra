//! What the strip and the wall show for each session: its status with that
//! status's time, in the order AJ reads them.

use std::collections::HashMap;

use serde::Serialize;

use crate::session::{Claude, Kind, Place, Said, SessionFile, State, Tmux, Touched};

/// No heartbeat and no event for this long, and a session is silent: three
/// missed 30 s statusline refreshes.
pub const SILENT_AFTER: i64 = 90;
/// How long an ended session stays on the strip and the wall.
pub const ENDED_FOR: i64 = 600;
/// A working turn with no hook event for this long is quiet: a user interrupt
/// leaves one behind, because Stop does not run on an interrupt.
pub const QUIET_AFTER: i64 = 600;
/// A session waiting on AJ shows no heartbeat while its prompt is open, so it
/// is not silent; with no word of any kind for this long it is in doubt.
pub const WAITING_DOUBT_AFTER: i64 = 1800;
/// A background entry the hook has not heard of for this long no longer
/// counts. A subagent's every tool call refreshes its entry, but a shell's
/// never does, so this bounds how long a forgotten shell (a dev server) keeps
/// a finished session working: twice the 30-minute deadline of the longest
/// bounded waits Claude runs in the background, so such a wait is still shown
/// when it ends.
pub const BACKGROUND_STALE_AFTER: i64 = 3600;
/// An entry stamped this far ahead of the reader's clock still counts: the
/// hook stamps a moment before the file lands.
const BACKGROUND_AHEAD: i64 = 60;

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
    /// When the file last changed: the last hook activity, which moves while
    /// the state stays working.
    pub active_at: i64,
    #[serde(rename = "where")]
    pub place: Option<Place>,
    pub touched: Vec<Touched>,
    pub prompt: Option<Said>,
    pub reply: Option<Said>,
    pub error: Option<String>,
    pub updated_at: i64,
    /// Last hook activity, when the session is working and has had none for
    /// `QUIET_AFTER`; the last word of any kind, when it needs AJ and has had
    /// none for `WAITING_DOUBT_AFTER`.
    pub quiet_since: Option<i64>,
    pub tmux: Option<Tmux>,
    pub distro: Option<String>,
    pub claude: Option<Claude>,
    /// The background work still counted: none once the session stopped
    /// working, and none for entries stale past `BACKGROUND_STALE_AFTER`.
    pub background: Crew,
}

/// How many subagents and background shells a session has out.
#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Crew {
    pub agents: u32,
    pub shells: u32,
}

#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Snapshot {
    pub sessions: Vec<View>,
}

/// What to show for one session at `now`, or None once it has ended long enough ago.
pub fn view(entry: &Entry, now: i64) -> Option<View> {
    let f = &entry.file;
    let shift = f.skew(entry.modified);
    let at = |t: i64| t.saturating_add(shift);
    let state_at = at(f.state_at);
    // An ended session's time is when it ended, for its status and its expiry.
    let ended_at = f.ended.as_ref().map_or(state_at, |e| at(e.at));
    if f.state == State::Ended && now.saturating_sub(ended_at) > ENDED_FOR {
        return None;
    }
    // The last word of any kind: a heartbeat, or a change to the file.
    let last_word = entry
        .beat
        .as_ref()
        .map_or(entry.modified, |b| b.0.max(entry.modified));
    // A prompt hides the status line, so a waiting session sends no beats.
    let silent = !matches!(f.state, State::Ended | State::NeedsYou)
        && now.saturating_sub(last_word) > SILENT_AFTER;
    let mut crew = Crew::default();
    if matches!(f.state, State::Working | State::NeedsYou) {
        for b in &f.background {
            if (-BACKGROUND_AHEAD..=BACKGROUND_STALE_AFTER).contains(&now.saturating_sub(at(b.at)))
            {
                match b.kind {
                    Kind::Agent => crew.agents += 1,
                    Kind::Shell => crew.shells += 1,
                }
            }
        }
    }
    // A turn that ended with work out: once all of it is stale, it is done.
    let after_turn = f.state == State::Working && f.reason.as_deref() == Some("background");
    let crew_out = crew.agents + crew.shells > 0;
    let (status, reason, status_at) = if silent {
        (Status::Silent, None, last_word)
    } else {
        let status = match f.state {
            State::New => Status::New,
            State::Working if after_turn && !crew_out => Status::Done,
            State::Working => Status::Working,
            State::NeedsYou => Status::NeedsYou,
            State::Done => Status::Done,
            State::Error => Status::Error,
            State::Ended => Status::Ended,
        };
        let status_at = if status == Status::Ended {
            ended_at
        } else {
            state_at
        };
        let reason = if status == Status::Done {
            None
        } else {
            f.reason.clone()
        };
        (status, reason, status_at)
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
    // The file's own time: its skew-corrected written_at equals it within 2 s.
    let active_at = entry.modified;
    let quiet_since = match status {
        // A shell sends no events while it runs, so a turn that ended with
        // work out is never quiet; its staleness is the entries' own.
        Status::Working if after_turn => None,
        Status::Working => Some(active_at).filter(|m| now.saturating_sub(*m) > QUIET_AFTER),
        Status::NeedsYou => {
            Some(last_word).filter(|w| now.saturating_sub(*w) > WAITING_DOUBT_AFTER)
        }
        _ => None,
    };
    let beat_name = entry.beat.as_ref().and_then(|b| b.1.clone());
    Some(View {
        session_id: f.session_id.clone(),
        name: beat_name.or_else(|| f.name.clone()),
        launch_dir: f.launch_dir.clone(),
        voice: f.voice.clone(),
        status,
        reason,
        status_at,
        active_at,
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
        tmux: f.tmux.clone(),
        distro: f.host.as_ref().and_then(|h| h.distro.clone()),
        claude: f.claude.clone(),
        background: if matches!(status, Status::Working | Status::NeedsYou) {
            crew
        } else {
            Crew::default()
        },
    })
}

/// A face follows a voice, so sessions sharing one keep it by claim: a session
/// that has not ended before one that has, then a hold before a repo's home
/// voice, then the earlier start, then the lower session id. The keeper shows
/// the face; the others show a medallion, except a hold that has not
/// ended, since two holds of one voice are keryx's own choice once every voice
/// is in use. Only ending counts, never silence, so a face changes with its
/// session's status at most once and never flips back.
fn keep_faces_distinct(shown: &mut [(&SessionFile, View)]) {
    let live = |v: &View| v.status != Status::Ended;
    let held = |f: &SessionFile| f.voice_from.as_deref() != Some("home");
    let claim = |f: &SessionFile, v: &View| {
        (
            !live(v),
            !held(f),
            f.started_at.unwrap_or(i64::MAX),
            f.session_id.clone(),
        )
    };
    let mut keeper: HashMap<String, (bool, bool, i64, String)> = HashMap::new();
    for (f, v) in shown.iter() {
        if let Some(voice) = &v.voice {
            let c = claim(f, v);
            keeper
                .entry(voice.clone())
                .and_modify(|k| {
                    if c < *k {
                        *k = c.clone();
                    }
                })
                .or_insert(c);
        }
    }
    for (f, v) in shown.iter_mut() {
        let keeps = match &v.voice {
            Some(voice) => keeper[voice].3 == f.session_id || (live(v) && held(f)),
            None => true,
        };
        if !keeps {
            v.voice = None;
        }
    }
}

/// Every session to show, needing AJ first, the longest wait leading; then
/// errors, work in progress, finished work newest first, not started,
/// silent and ended.
pub fn snapshot(entries: &[Entry], now: i64) -> Snapshot {
    let mut shown: Vec<(&SessionFile, View)> = entries
        .iter()
        .filter_map(|e| view(e, now).map(|v| (&e.file, v)))
        .collect();
    keep_faces_distinct(&mut shown);
    let mut sessions: Vec<View> = shown.into_iter().map(|(_, v)| v).collect();
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
    use crate::session::{Background, Ended, Host};

    const NOW: i64 = 1_792_353_000;

    fn file(id: &str, state: State, state_at: i64) -> SessionFile {
        SessionFile {
            session_id: id.into(),
            name: None,
            launch_dir: Some("/home/aj/ajsoftworks".into()),
            started_at: Some(state_at),
            voice: Some("am_michael".into()),
            voice_from: None,
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
            tmux: None,
            host: None,
            claude: None,
            background: vec![],
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
    fn a_view_carries_its_tmux_pane_and_distro() {
        let mut e = entry("a", State::Working, NOW - 5, NOW - 5);
        e.file.tmux = Some(Tmux {
            socket: "/tmp/tmux-1001/klepsydra".into(),
            pane: "%3".into(),
        });
        e.file.host = Some(Host {
            boot: "b".into(),
            distro: Some("Ubuntu".into()),
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.tmux.as_ref().map(|t| t.pane.as_str()), Some("%3"));
        assert_eq!(v.distro.as_deref(), Some("Ubuntu"));
        assert_eq!(v.claude, None);
        e.file.claude = Some(Claude {
            pid: 2231,
            start: 8_717_628,
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.claude.map(|c| (c.pid, c.start)), Some((2231, 8_717_628)));
    }

    fn crew_entry(id: &str, kind: Kind, at: i64) -> Background {
        Background {
            id: id.into(),
            kind,
            at,
        }
    }

    /// A session whose turn ended at `NOW - 30` with two agents and a shell out.
    fn after_turn(at: i64) -> Entry {
        let mut e = entry("a", State::Working, NOW - 30, NOW - 5);
        e.file.reason = Some("background".into());
        e.file.background = vec![
            crew_entry("a1", Kind::Agent, at),
            crew_entry("a2", Kind::Agent, at),
            crew_entry("s1", Kind::Shell, at),
        ];
        e
    }

    #[test]
    fn a_turn_that_ended_with_work_out_stays_working_with_its_crew() {
        let v = view(&after_turn(NOW - 60), NOW).unwrap();
        assert_eq!(
            (v.status, v.reason.as_deref()),
            (Status::Working, Some("background"))
        );
        assert_eq!(
            v.background,
            Crew {
                agents: 2,
                shells: 1
            }
        );
    }

    #[test]
    fn work_out_is_never_quiet_however_long_a_shell_runs() {
        let mut e = after_turn(NOW - 3000);
        e.modified = NOW - 3000;
        e.file.state_at = NOW - 3000;
        e.file.written_at = Some(NOW - 3000);
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.quiet_since), (Status::Working, None));
    }

    #[test]
    fn stale_work_falls_back_to_done() {
        let v = view(&after_turn(NOW - BACKGROUND_STALE_AFTER), NOW).unwrap();
        assert_eq!(
            v.background.agents + v.background.shells,
            3,
            "exactly the bound still counts"
        );
        let v = view(&after_turn(NOW - BACKGROUND_STALE_AFTER - 1), NOW).unwrap();
        assert_eq!(
            (v.status, v.reason, v.background),
            (Status::Done, None, Crew::default())
        );
        assert_eq!(v.status_at, NOW - 30, "done since the turn ended");
    }

    #[test]
    fn only_the_stale_entries_drop() {
        let mut e = after_turn(NOW - 60);
        e.file.background[2].at = NOW - BACKGROUND_STALE_AFTER - 1;
        assert_eq!(
            view(&e, NOW).unwrap().background,
            Crew {
                agents: 2,
                shells: 0
            }
        );
    }

    #[test]
    fn an_entry_from_the_future_does_not_count() {
        let mut e = after_turn(NOW - 60);
        e.file.background[0].at = NOW + BACKGROUND_AHEAD;
        e.file.background[1].at = NOW + BACKGROUND_AHEAD + 1;
        assert_eq!(
            view(&e, NOW).unwrap().background,
            Crew {
                agents: 1,
                shells: 1
            }
        );
    }

    #[test]
    fn entry_times_follow_the_writer_clock_correction() {
        // The hook's clock runs 600 s ahead: its fresh entries read 600 s late.
        let mut e = after_turn(NOW - 60 + 600);
        e.file.written_at = Some(NOW - 5 + 600);
        e.modified = NOW - 5;
        assert_eq!(
            view(&e, NOW).unwrap().background,
            Crew {
                agents: 2,
                shells: 1
            }
        );
    }

    #[test]
    fn a_working_turn_counts_its_crew_and_still_goes_quiet() {
        let mut e = after_turn(NOW - 60);
        e.file.reason = None;
        let v = view(&e, NOW).unwrap();
        assert_eq!(
            (v.status, v.background),
            (
                Status::Working,
                Crew {
                    agents: 2,
                    shells: 1
                }
            )
        );
        e.modified = NOW - QUIET_AFTER - 1;
        assert_eq!(
            view(&e, NOW).unwrap().quiet_since,
            Some(NOW - QUIET_AFTER - 1)
        );
        // With all of it stale, a turn still in progress stays working.
        let mut e = after_turn(NOW - BACKGROUND_STALE_AFTER - 1);
        e.file.reason = None;
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.background), (Status::Working, Crew::default()));
    }

    #[test]
    fn needs_you_keeps_its_crew_and_outranks_it() {
        let mut e = after_turn(NOW - 60);
        e.file.state = State::NeedsYou;
        e.file.reason = Some("approve Bash".into());
        let v = view(&e, NOW).unwrap();
        assert_eq!(
            (v.status, v.background),
            (
                Status::NeedsYou,
                Crew {
                    agents: 2,
                    shells: 1
                }
            )
        );
    }

    #[test]
    fn a_finished_or_silent_session_shows_no_crew() {
        let mut e = after_turn(NOW - 60);
        e.file.state = State::Done;
        e.file.reason = None;
        assert_eq!(view(&e, NOW).unwrap().background, Crew::default());
        let mut e = after_turn(NOW - 60);
        e.beat = Some((NOW - SILENT_AFTER - 1, None));
        e.modified = NOW - SILENT_AFTER - 1;
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.background), (Status::Silent, Crew::default()));
    }

    #[test]
    fn an_old_file_reads_as_before_and_the_crew_is_always_sent() {
        let text = format!(
            r#"{{"v":1,"session_id":"cb9fa591-1514-44d1-a31c-eba4a7cb41ed","state":"working","state_at":{},"written_at":{}}}"#,
            NOW - 10,
            NOW - 10
        );
        let file =
            crate::session::parse(&text, "cb9fa591-1514-44d1-a31c-eba4a7cb41ed", NOW - 10).unwrap();
        let v = view(
            &Entry {
                file,
                modified: NOW - 10,
                beat: None,
            },
            NOW,
        )
        .unwrap();
        assert_eq!((v.status, v.background), (Status::Working, Crew::default()));
        let json = serde_json::to_value(&v).unwrap();
        assert_eq!(
            json["background"],
            serde_json::json!({"agents": 0, "shells": 0})
        );
    }

    #[test]
    fn a_view_without_tmux_has_none() {
        let v = view(&entry("a", State::Working, NOW - 5, NOW - 5), NOW).unwrap();
        assert_eq!((v.tmux, v.distro), (None, None));
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
        let mut e = entry("a", State::Done, NOW - 20, 0);
        e.beat = None;
        assert_eq!(view(&e, NOW).unwrap().status, Status::Done);
        e.file.state_at = NOW - 200;
        e.modified = NOW - 200;
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
    }

    #[test]
    fn a_session_waiting_on_a_prompt_stays_needs_you_while_its_status_line_is_hidden() {
        // The prompt hides the status line, so no beat comes while it waits.
        let mut e = entry("a", State::NeedsYou, NOW - 91, NOW - 91);
        e.file.reason = Some("approve Bash".into());
        let v = view(&e, NOW).unwrap();
        assert_eq!(
            (v.status, v.status_at, v.quiet_since),
            (Status::NeedsYou, NOW - 91, None)
        );
        assert_eq!(v.reason.as_deref(), Some("approve Bash"));
        let v = view(&entry("a", State::NeedsYou, NOW - 1800, NOW - 1800), NOW).unwrap();
        assert_eq!(v.quiet_since, None, "30 minutes exactly is not yet quiet");
        let v = view(
            &entry("a", State::NeedsYou, NOW - 31 * 60, NOW - 31 * 60),
            NOW,
        )
        .unwrap();
        assert_eq!((v.status, v.status_at), (Status::NeedsYou, NOW - 31 * 60));
        assert_eq!(v.quiet_since, Some(NOW - 31 * 60));
    }

    #[test]
    fn needs_you_order_is_unchanged_by_silence() {
        let entries = vec![
            entry("done", State::Done, NOW - 10, NOW - 5),
            entry("needs-new", State::NeedsYou, NOW - 100, NOW - 100),
            entry("needs-old", State::NeedsYou, NOW - 31 * 60, NOW - 31 * 60),
        ];
        assert_eq!(
            ids(&snapshot(&entries, NOW)),
            vec!["needs-old", "needs-new", "done"]
        );
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

    /// `quiet_since` of a session whose file last changed at `modified`, the
    /// writer's clock agreeing with ours.
    fn quiet_for(state: State, modified: i64) -> Option<i64> {
        let mut e = entry("a", state, NOW - 5, NOW - 5);
        e.file.written_at = Some(modified);
        e.modified = modified;
        view(&e, NOW).unwrap().quiet_since
    }

    #[test]
    fn active_at_is_the_files_own_time_and_is_sent() {
        // Writer clock an hour ahead and the state unchanged for 20 minutes:
        // the last activity is the file's own time, by this machine's clock.
        let mut e = entry("a", State::Working, NOW + 3600 - 1200, NOW - 5);
        e.file.written_at = Some(NOW + 3600 - 30);
        e.modified = NOW - 30;
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.active_at, NOW - 30);
        assert_eq!(
            v.status_at,
            NOW - 1200,
            "status_at stays when the state began"
        );
        let json = serde_json::to_value(snapshot(&[e], NOW)).unwrap();
        assert_eq!(json["sessions"][0]["active_at"], NOW - 30);
    }

    #[test]
    fn a_working_turn_with_no_event_for_ten_minutes_is_quiet() {
        let mut e = entry("a", State::Working, NOW - 601, NOW - 5);
        e.modified = NOW - 601;
        assert_eq!(view(&e, NOW).unwrap().quiet_since, Some(NOW - 601));
        assert_eq!(quiet_for(State::Working, NOW - 599), None);
    }

    #[test]
    fn only_a_working_or_waiting_session_is_ever_quiet() {
        for state in [State::Done, State::New, State::Error] {
            assert_eq!(quiet_for(state, NOW - 700), None, "{state:?}");
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
    fn quiet_is_judged_by_the_file_time_when_there_is_no_written_at() {
        let mut e = entry("a", State::Working, NOW - 650, NOW - 5);
        e.file.written_at = None;
        e.modified = NOW - 650;
        assert_eq!(view(&e, NOW).unwrap().quiet_since, Some(NOW - 650));
    }

    #[test]
    fn exact_boundaries_are_pinned() {
        // Silent: more than 90 s since the last word.
        let e = entry("a", State::Working, NOW - 90, NOW - 90);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Working);
        let e = entry("a", State::Working, NOW - 91, NOW - 91);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
        // Ended: shown through 600 s after ended.at, gone after.
        let ended = |age: i64| {
            let mut e = entry("a", State::Ended, NOW - 5, NOW - 5);
            e.file.ended = Some(Ended { at: NOW - age });
            view(&e, NOW)
        };
        assert!(ended(600).is_some());
        assert_eq!(ended(601), None);
        // Quiet: more than 600 s since the file changed.
        assert_eq!(quiet_for(State::Working, NOW - 600), None);
        assert_eq!(quiet_for(State::Working, NOW - 601), Some(NOW - 601));
    }

    #[test]
    fn an_ended_session_shows_and_expires_by_ended_at() {
        let mut e = entry("a", State::Ended, NOW - 900, NOW - 5);
        e.modified = NOW - 5;
        e.file.written_at = Some(NOW - 5);
        e.file.ended = Some(Ended { at: NOW - 100 });
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.status_at), (Status::Ended, NOW - 100));
        assert_eq!(v.updated_at, NOW - 100);
    }

    #[test]
    fn every_shifted_field_is_put_back_and_counts_toward_updated() {
        // Writer clock 600 s ahead.
        let mut e = entry("a", State::Done, NOW - 400 + 600, NOW - 5);
        e.modified = NOW - 5;
        e.file.written_at = Some(NOW - 5 + 600);
        e.file.place = Some(Place {
            repo: "r".into(),
            worktree: None,
            branch: None,
            at: NOW - 300 + 600,
        });
        e.file.touched = vec![Touched {
            repo: "t".into(),
            at: NOW - 350 + 600,
        }];
        e.file.reply = Some(Said {
            text: "r".into(),
            at: NOW - 360 + 600,
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status_at, NOW - 400);
        assert_eq!(v.place.as_ref().unwrap().at, NOW - 300);
        assert_eq!(v.touched[0].at, NOW - 350);
        assert_eq!(v.reply.as_ref().unwrap().at, NOW - 360);
        assert_eq!(v.updated_at, NOW - 300, "place is the newest");
        e.file.state = State::Ended;
        e.file.ended = Some(Ended {
            at: NOW - 200 + 600,
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status_at, v.updated_at), (NOW - 200, NOW - 200));
    }

    #[test]
    fn extreme_times_never_panic() {
        for t in [i64::MIN, i64::MAX, 0] {
            for state in [State::Working, State::Ended, State::Done] {
                let mut e = entry("a", state, t, t);
                e.modified = t;
                e.file.written_at = Some(t);
                e.file.ended = Some(Ended { at: t });
                e.file.place = Some(Place {
                    repo: "r".into(),
                    worktree: None,
                    branch: None,
                    at: t,
                });
                e.beat = Some((t, None));
                let _ = view(&e, NOW);
                let _ = view(&e, i64::MIN);
                let _ = view(&e, i64::MAX);
                e.modified = NOW;
                let _ = view(&e, NOW);
                e.modified = t;
                e.file.written_at = Some(NOW);
                let _ = view(&e, NOW);
            }
        }
    }
    /// A session started at `started` with `voice`, held or from a home.
    fn voiced(id: &str, started: i64, voice: &str, from: &str) -> Entry {
        let mut e = entry(id, State::Working, NOW - 10, NOW - 5);
        e.file.started_at = Some(started);
        e.file.voice = Some(voice.into());
        e.file.voice_from = Some(from.into());
        e
    }

    fn voice_of<'a>(s: &'a Snapshot, id: &str) -> Option<&'a str> {
        let v = s.sessions.iter().find(|v| v.session_id == id).unwrap();
        v.voice.as_deref()
    }

    #[test]
    fn two_homes_of_one_voice_the_first_started_keeps_it() {
        let s = snapshot(
            &[
                voiced("b", NOW - 100, "bf_emma", "home"),
                voiced("a", NOW - 200, "bf_emma", "home"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "a"), Some("bf_emma"));
        assert_eq!(voice_of(&s, "b"), None, "the later one shows a medallion");
    }

    #[test]
    fn a_hold_beats_a_home_however_late_it_started() {
        let s = snapshot(
            &[
                voiced("home", NOW - 900, "bf_emma", "home"),
                voiced("held", NOW - 100, "bf_emma", "hold"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "held"), Some("bf_emma"));
        assert_eq!(voice_of(&s, "home"), None);
    }

    /// `voiced`, ended or gone silent: a file and a beat both long past.
    fn gone(id: &str, started: i64, voice: &str, from: &str, ended: bool) -> Entry {
        let mut e = voiced(id, started, voice, from);
        if ended {
            e.file.state = State::Ended;
            e.file.ended = Some(Ended { at: NOW - 60 });
        } else {
            e.modified = NOW - 3600;
            e.file.state_at = NOW - 3600;
            e.file.written_at = Some(NOW - 3600);
            e.beat = Some((NOW - 3600, None));
        }
        e
    }

    #[test]
    fn after_clear_the_live_session_keeps_the_face_not_the_ended_one() {
        let s = snapshot(
            &[
                gone("old", NOW - 900, "bf_emma", "home", true),
                voiced("new", NOW - 30, "bf_emma", "home"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "new"), Some("bf_emma"));
        assert_eq!(voice_of(&s, "old"), None);
    }

    #[test]
    fn silence_never_moves_a_face() {
        // The first started keeps the face whether it is live or silent, so a
        // session missing beats does not swap faces back and forth.
        for quiet in [false, true] {
            let first = if quiet {
                gone("a", NOW - 900, "bf_emma", "home", false)
            } else {
                voiced("a", NOW - 900, "bf_emma", "home")
            };
            let s = snapshot(&[first, voiced("b", NOW - 30, "bf_emma", "home")], NOW);
            let a = s.sessions.iter().find(|v| v.session_id == "a").unwrap();
            assert_eq!(
                a.status,
                if quiet {
                    Status::Silent
                } else {
                    Status::Working
                }
            );
            assert_eq!(voice_of(&s, "a"), Some("bf_emma"), "silent: {quiet}");
            assert_eq!(voice_of(&s, "b"), None, "silent: {quiet}");
        }
    }

    #[test]
    fn a_silent_hold_keeps_its_face_beside_a_live_hold() {
        let s = snapshot(
            &[
                gone("quiet", NOW - 900, "am_michael", "hold", false),
                voiced("busy", NOW - 30, "am_michael", "hold"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "quiet"), Some("am_michael"));
        assert_eq!(voice_of(&s, "busy"), Some("am_michael"));
    }

    #[test]
    fn an_ended_hold_gives_way_to_the_live_hold_of_its_terminal() {
        let s = snapshot(
            &[
                gone("old", NOW - 900, "am_michael", "hold", true),
                voiced("new", NOW - 30, "am_michael", "hold"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "new"), Some("am_michael"));
        assert_eq!(voice_of(&s, "old"), None);
    }

    #[test]
    fn two_holds_of_one_voice_both_stay() {
        let s = snapshot(
            &[
                voiced("a", NOW - 200, "am_michael", "hold"),
                voiced("b", NOW - 100, "am_michael", "hold"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "a"), Some("am_michael"));
        assert_eq!(
            voice_of(&s, "b"),
            Some("am_michael"),
            "keryx repeats a voice once all are in use"
        );
    }

    #[test]
    fn homes_of_different_voices_both_stay() {
        let s = snapshot(
            &[
                voiced("a", NOW - 200, "bf_emma", "home"),
                voiced("b", NOW - 100, "am_adam", "home"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "a"), Some("bf_emma"));
        assert_eq!(voice_of(&s, "b"), Some("am_adam"));
    }

    #[test]
    fn a_tie_on_start_goes_to_the_lower_session_id() {
        let s = snapshot(
            &[
                voiced("b", NOW - 100, "bf_emma", "home"),
                voiced("a", NOW - 100, "bf_emma", "home"),
            ],
            NOW,
        );
        assert_eq!(voice_of(&s, "a"), Some("bf_emma"));
        assert_eq!(voice_of(&s, "b"), None);
    }
}
