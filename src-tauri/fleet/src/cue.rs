//! Which sound a new snapshot asks for: a session that now needs AJ, or one
//! whose turn just ended. The shell plays it; this decides it.
//!
//! A cue answers a hook event, never the clock: only a status time that moved
//! past the last one seen can ask for one. A session going silent and coming
//! back, or a stale background crew turning a session done, moves no status
//! time, so neither sounds.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::view::{Snapshot, Status};

/// After a cue, one of the same or lower rank this soon is dropped, so a
/// burst of sessions changing over a few reads makes one sound.
pub const GAP: Duration = Duration::from_secs(2);

/// A session's last word older than this, and absent from the strip, is forgotten.
const FORGET_AFTER: i64 = 86_400;

/// In rank order: needs-you outranks done.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Cue {
    /// A session entered needs-you or error.
    NeedsYou,
    /// A session's turn ended.
    Done,
}

/// What the last non-silent view of a session said.
#[derive(Clone, Copy)]
struct Seen {
    status: Status,
    at: i64,
}

fn wants_you(s: Status) -> bool {
    matches!(s, Status::NeedsYou | Status::Error)
}

/// What one session's move from `before` to `now`, at a later status time,
/// asks for. A turn ends after work, or after an earlier turn whose start
/// fell between two reads; done after anything else is a start or a resume.
fn cue_for(before: Option<Status>, now: Status) -> Option<Cue> {
    match now {
        s if wants_you(s) => Some(Cue::NeedsYou),
        Status::Done if matches!(before, Some(Status::Working | Status::Done)) => Some(Cue::Done),
        _ => None,
    }
}

/// Whether `now`, at `at`, is a hook event `before` has not seen. Times are
/// whole seconds, so a prompt in the second its turn began is one too; done
/// never is, since a stale crew reads done at the turn's own time.
fn is_new(before: Option<Seen>, since: i64, now: Status, at: i64) -> bool {
    let last = before.map_or(since, |s| s.at.max(since));
    at > last
        || (at == last
            && at > since
            && wants_you(now)
            && before.is_some_and(|s| !wants_you(s.status)))
}

/// Follows each session's status time from one snapshot to the next.
pub struct Cues {
    /// Status times up to this are older than the app: what was on the strip
    /// when it started.
    since: i64,
    seen: HashMap<String, Seen>,
    played: Option<(Cue, Instant)>,
}

impl Cues {
    /// `since` is the app's start, by the same clock as the views' times.
    pub fn new(since: i64) -> Self {
        Cues {
            since,
            seen: HashMap::new(),
            played: None,
        }
    }

    /// The cue `snap` asks for: the highest rank among its sessions, and
    /// within `GAP` of the last cue only one that outranks it.
    pub fn next(&mut self, snap: &Snapshot, now: Instant) -> Option<Cue> {
        let mut cue: Option<Cue> = None;
        let mut newest = self.since;
        for v in &snap.sessions {
            // A silent view's time is its last word, not a hook event.
            if v.status == Status::Silent {
                continue;
            }
            newest = newest.max(v.status_at);
            let before = self.seen.get(&v.session_id).copied();
            if is_new(before, self.since, v.status, v.status_at) {
                let c = cue_for(before.map(|s| s.status), v.status);
                cue = match (cue, c) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
            }
            self.seen.insert(
                v.session_id.clone(),
                Seen {
                    status: v.status,
                    at: v.status_at,
                },
            );
        }
        let shown: Vec<&str> = snap
            .sessions
            .iter()
            .map(|v| v.session_id.as_str())
            .collect();
        self.seen
            .retain(|id, s| shown.contains(&id.as_str()) || newest - s.at < FORGET_AFTER);
        let cue = cue.filter(|c| match self.played {
            Some((last, at)) if now.saturating_duration_since(at) < GAP => *c < last,
            _ => true,
        })?;
        self.played = Some((cue, now));
        Some(cue)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::view::View;
    use Status::*;

    const START: i64 = 1_792_500_000;

    fn view(id: &str, status: Status, at: i64) -> View {
        View {
            session_id: id.into(),
            name: None,
            launch_dir: None,
            voice: None,
            status,
            reason: None,
            status_at: at,
            active_at: at,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            updated_at: at,
            quiet_since: None,
            tmux: None,
            distro: None,
            claude: None,
            background: Default::default(),
        }
    }

    /// A snapshot of `(id, status, seconds after START)`.
    fn snap(sessions: &[(&str, Status, i64)]) -> Snapshot {
        Snapshot {
            sessions: sessions
                .iter()
                .map(|(id, s, t)| view(id, *s, START + t))
                .collect(),
        }
    }

    /// Cues for each snapshot in turn, read `GAP` apart so the gap never drops one.
    fn run(snaps: &[Snapshot]) -> Vec<Option<Cue>> {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        snaps
            .iter()
            .enumerate()
            .map(|(i, s)| cues.next(s, t0 + GAP * i as u32))
            .collect()
    }

    #[test]
    fn what_was_on_the_strip_at_start_asks_for_nothing() {
        let before_start = snap(&[("a", NeedsYou, -60), ("b", Done, -5), ("c", Error, 0)]);
        assert_eq!(run(&[before_start.clone(), before_start]), vec![None, None]);
    }

    #[test]
    fn an_empty_first_read_then_old_sessions_asks_for_nothing() {
        let got = run(&[snap(&[]), snap(&[("a", NeedsYou, -600), ("b", Done, -60)])]);
        assert_eq!(got, vec![None, None]);
    }

    #[test]
    fn each_move_asks_for_its_cue() {
        let all = [NeedsYou, Error, Working, Done, New, Silent, Ended];
        for before in all.iter().map(|s| Some(*s)).chain([None]) {
            for now in all {
                let want = match (before, now) {
                    (_, NeedsYou | Error) => Some(Cue::NeedsYou),
                    (Some(Working | Done), Done) => Some(Cue::Done),
                    _ => None,
                };
                assert_eq!(cue_for(before, now), want, "{before:?} -> {now:?}");
            }
        }
    }

    #[test]
    fn a_session_started_after_the_app_that_needs_you_asks() {
        let got = run(&[snap(&[]), snap(&[("a", NeedsYou, 20)])]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_turn_ending_asks_for_done_once() {
        let got = run(&[
            snap(&[("a", Working, 10)]),
            snap(&[("a", Done, 20)]),
            snap(&[("a", Done, 20)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done), None]);
    }

    #[test]
    fn a_whole_turn_between_two_reads_still_asks_for_done() {
        let got = run(&[snap(&[("a", Done, 10)]), snap(&[("a", Done, 30)])]);
        assert_eq!(got, vec![None, Some(Cue::Done)]);
    }

    #[test]
    fn a_resume_or_a_start_is_not_a_turn_ending() {
        for before in [New, Ended, NeedsYou, Error] {
            let got = run(&[snap(&[("a", before, 10)]), snap(&[("a", Done, 20)])]);
            assert_eq!(got[1], None, "{before:?} -> done");
        }
        assert_eq!(run(&[snap(&[]), snap(&[("a", Done, 20)])])[1], None);
    }

    #[test]
    fn a_new_prompt_asks_each_time_even_from_needs_you() {
        let got = run(&[
            snap(&[("a", Working, 10)]),
            snap(&[("a", NeedsYou, 20)]),
            snap(&[("a", NeedsYou, 30)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou), Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_prompt_in_the_second_its_turn_began_asks() {
        let got = run(&[snap(&[("a", Working, 10)]), snap(&[("a", NeedsYou, 10)])]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn coming_back_from_silence_asks_for_nothing() {
        // The PC slept: an idle session read silent, then its beats came back.
        let got = run(&[
            snap(&[("a", Working, 10), ("b", Error, -10)]),
            snap(&[("a", Done, 20), ("b", Error, -10)]),
            snap(&[("a", Silent, 400), ("b", Silent, 400)]),
            snap(&[("a", Done, 20), ("b", Error, -10)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done), None, None]);
    }

    #[test]
    fn a_long_tool_call_read_silent_still_ends_in_done() {
        let got = run(&[
            snap(&[("a", Working, 10)]),
            snap(&[("a", Silent, 200)]),
            snap(&[("a", Done, 300)]),
        ]);
        assert_eq!(got, vec![None, None, Some(Cue::Done)]);
    }

    #[test]
    fn a_stale_crew_turning_a_session_done_asks_for_nothing() {
        // Stop with a shell out keeps the status time; staleness alone reads done.
        let got = run(&[snap(&[("a", Working, 10)]), snap(&[("a", Done, 10)])]);
        assert_eq!(got, vec![None, None]);
    }

    #[test]
    fn a_session_missing_from_one_read_does_not_ask_again() {
        let got = run(&[
            snap(&[("a", Working, 10)]),
            snap(&[("a", NeedsYou, 20)]),
            snap(&[]),
            snap(&[("a", NeedsYou, 20)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou), None, None]);
    }

    #[test]
    fn needs_you_outranks_done_in_one_read() {
        let got = run(&[
            snap(&[("a", Working, 10), ("b", Working, 10)]),
            snap(&[("a", Done, 20), ("b", NeedsYou, 20)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn within_the_gap_only_a_higher_rank_plays() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        let soon = t0 + GAP - Duration::from_millis(1);
        let w = |id| (id, Working, 10);
        cues.next(&snap(&[w("a"), w("b"), w("c")]), t0);
        let a_done = snap(&[("a", Done, 20), w("b"), w("c")]);
        assert_eq!(cues.next(&a_done, t0), Some(Cue::Done));
        let b_done = snap(&[("a", Done, 20), ("b", Done, 21), w("c")]);
        assert_eq!(cues.next(&b_done, soon), None);
        let c_needs = snap(&[("a", Done, 20), ("b", Done, 21), ("c", NeedsYou, 21)]);
        assert_eq!(cues.next(&c_needs, soon), Some(Cue::NeedsYou));
        let a_needs = snap(&[("a", NeedsYou, 22), ("b", Done, 21), ("c", NeedsYou, 21)]);
        assert_eq!(cues.next(&a_needs, soon), None);
        let b_needs = snap(&[
            ("a", NeedsYou, 22),
            ("b", NeedsYou, 23),
            ("c", NeedsYou, 21),
        ]);
        assert_eq!(cues.next(&b_needs, soon + GAP), Some(Cue::NeedsYou));
    }

    #[test]
    fn a_dropped_cue_is_not_replayed_later() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        cues.next(&snap(&[("a", Working, 10), ("b", Working, 10)]), t0);
        cues.next(&snap(&[("a", Done, 20), ("b", Working, 10)]), t0);
        let both = snap(&[("a", Done, 20), ("b", Done, 21)]);
        assert_eq!(cues.next(&both, t0), None);
        assert_eq!(cues.next(&both, t0 + GAP * 2), None);
    }

    #[test]
    fn a_long_gone_session_is_forgotten_and_a_present_one_kept() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        cues.next(&snap(&[("old", Done, 10), ("here", Done, 10)]), t0);
        let later = FORGET_AFTER + 20;
        cues.next(
            &snap(&[("here", Done, 10), ("new", Working, later)]),
            t0 + GAP,
        );
        assert!(!cues.seen.contains_key("old"));
        assert!(cues.seen.contains_key("here"));
    }
}
