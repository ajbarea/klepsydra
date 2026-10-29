//! Which sound a new snapshot asks for: a session that now needs AJ, or one
//! whose turn just ended. The shell plays it; this decides it.
//!
//! A cue answers a hook event, never the clock or a rewrite. Needs-you takes a
//! state time the session has not shown before, and done takes a turn count it
//! has not shown before, both as the hook wrote them. Going silent and back,
//! a stale background crew, a missed read or a resume moves neither.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::view::{Marks, Snapshot, Status};

/// After a cue, one of the same or lower rank this soon is dropped, so a
/// burst of sessions changing over a few reads makes one sound.
pub const GAP: Duration = Duration::from_secs(2);

/// A session absent from the strip and unseen this long is forgotten.
const FORGET_AFTER: i64 = 86_400;

/// In rank order: needs-you outranks done.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Cue {
    /// A session entered needs-you or error.
    NeedsYou,
    /// A session's turn ended.
    Done,
}

/// The last view of a session, silent only if it was never seen otherwise,
/// and when it was read.
#[derive(Clone, Copy)]
struct Seen {
    status: Status,
    marks: Marks,
    read_at: i64,
}

fn wants_you(s: Status) -> bool {
    matches!(s, Status::NeedsYou | Status::Error)
}

/// Whether a turn ended between `b` and `now`. A hook that never counted
/// turns (an older install) falls back to working becoming done at a new
/// state time.
fn turn_ended(b: Seen, now: Marks) -> bool {
    match (b.marks.turns, now.turns) {
        (Some(was), Some(is)) => is != was,
        (None, Some(is)) => is > 0 && b.status == Status::Working,
        (_, None) => b.status == Status::Working && now.state_at != b.marks.state_at,
    }
}

/// What a session now showing `now` with `marks` asks for, given what was
/// last seen of it. `since` is the app's start, by the reader's clock, and
/// `at` is the view's status time by the same clock.
fn cue_for(before: Option<Seen>, since: i64, now: Status, marks: Marks, at: i64) -> Option<Cue> {
    if wants_you(now) {
        let new = match before {
            // Silent at first sight: only a new state time is news.
            Some(b) if b.status == Status::Silent => marks.state_at != b.marks.state_at,
            Some(b) => !wants_you(b.status) || marks.state_at != b.marks.state_at,
            None => at > since,
        };
        return new.then_some(Cue::NeedsYou);
    }
    let ended = before.is_some_and(|b| turn_ended(b, marks));
    (now == Status::Done && ended).then_some(Cue::Done)
}

/// Follows each session from one snapshot to the next.
pub struct Cues {
    since: i64,
    /// The first snapshot is what was on the strip at start: it asks for nothing.
    started: bool,
    seen: HashMap<String, Seen>,
    played: Option<(Cue, Instant)>,
}

impl Cues {
    /// `since` is the app's start, by the reader's clock.
    pub fn new(since: i64) -> Self {
        Cues {
            since,
            started: false,
            seen: HashMap::new(),
            played: None,
        }
    }

    /// The cue `snap`, read at `now` (`now_s` by the reader's clock), asks
    /// for: the highest rank among its sessions, and within `GAP` of the
    /// last cue only one that outranks it.
    pub fn next(&mut self, snap: &Snapshot, now: Instant, now_s: i64) -> Option<Cue> {
        let mut cue: Option<Cue> = None;
        for v in &snap.sessions {
            let seen = Seen {
                status: v.status,
                marks: v.marks,
                read_at: now_s,
            };
            // A silent view's time is its last word, not a hook event: it
            // asks for nothing, and replaces only a record of nothing.
            if v.status == Status::Silent {
                let s = self.seen.entry(v.session_id.clone()).or_insert(seen);
                s.read_at = now_s;
                continue;
            }
            let before = self.seen.get(&v.session_id).copied();
            if self.started {
                let c = cue_for(before, self.since, v.status, v.marks, v.status_at);
                cue = match (cue, c) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
            }
            self.seen.insert(v.session_id.clone(), seen);
        }
        self.started = true;
        let shown: Vec<&str> = snap
            .sessions
            .iter()
            .map(|v| v.session_id.as_str())
            .collect();
        self.seen
            .retain(|id, s| shown.contains(&id.as_str()) || now_s - s.read_at < FORGET_AFTER);
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

    /// A view at `at` seconds after START, written at that time by the hook,
    /// with `turns` turns ended. `shift` is the skew correction the reader
    /// added, so the display time moves while what the hook wrote does not.
    fn view(id: &str, status: Status, at: i64, turns: Option<u64>, shift: i64) -> View {
        View {
            session_id: id.into(),
            name: None,
            launch_dir: None,
            voice: None,
            status,
            reason: None,
            status_at: START + at + shift,
            active_at: START + at + shift,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            updated_at: START + at + shift,
            quiet_since: None,
            tmux: None,
            distro: None,
            claude: None,
            background: Default::default(),
            ledger: None,
            ledger_partial: false,
            wrapup: None,
            turn_at: None,
            asked_after_turn: false,
            remote_url: None,
            started_at: None,
            account: None,
            reply_at: None,
            marks: Marks {
                state_at: START + at,
                turns,
            },
        }
    }

    type S = (&'static str, Status, i64, Option<u64>);

    fn snap(sessions: &[S]) -> Snapshot {
        shifted(sessions, 0)
    }

    fn shifted(sessions: &[S], shift: i64) -> Snapshot {
        Snapshot {
            sessions: sessions
                .iter()
                .map(|(id, s, t, e)| view(id, *s, *t, *e, shift))
                .collect(),
            speaking: None,
            receiver: None,
            wrapup: None,
        }
    }

    /// Cues for each snapshot in turn, read `GAP` apart so the gap never drops one.
    fn run(snaps: &[Snapshot]) -> Vec<Option<Cue>> {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        snaps
            .iter()
            .enumerate()
            .map(|(i, s)| cues.next(s, t0 + GAP * i as u32, START + 2 * i as i64))
            .collect()
    }

    #[test]
    fn the_first_read_asks_for_nothing() {
        let first = snap(&[
            ("a", NeedsYou, 5, Some(0)),
            ("b", Done, 5, Some(1)),
            ("c", Error, 5, Some(0)),
        ]);
        assert_eq!(run(&[first.clone(), first]), vec![None, None]);
    }

    #[test]
    fn an_empty_first_read_then_old_sessions_asks_for_nothing() {
        let old = snap(&[("a", NeedsYou, -600, Some(0)), ("b", Done, -60, Some(4))]);
        assert_eq!(run(&[snap(&[]), old]), vec![None, None]);
    }

    #[test]
    fn a_session_started_after_the_app_that_needs_you_asks() {
        let got = run(&[snap(&[]), snap(&[("a", NeedsYou, 20, Some(0))])]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_turn_ending_asks_for_done_once() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", Done, 20, Some(1))]),
            snap(&[("a", Done, 20, Some(1))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done), None]);
    }

    #[test]
    fn a_whole_turn_between_two_reads_still_asks_for_done() {
        let got = run(&[
            snap(&[("a", Done, 10, Some(1))]),
            snap(&[("a", Done, 30, Some(2))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done)]);
    }

    #[test]
    fn done_without_a_new_turn_asks_for_nothing() {
        // A resume after a kill mid-turn, the idle prompt after Esc, an answer
        // after the turn ended, or a stale crew: done, with no new Stop.
        for before in [Working, NeedsYou, Error, New, Ended, Done] {
            let got = run(&[
                snap(&[("a", before, 10, Some(1))]),
                snap(&[("a", Done, 20, Some(1))]),
            ]);
            assert_eq!(got[1], None, "{before:?} -> done");
        }
        let unseen = run(&[snap(&[]), snap(&[("a", Done, 20, Some(1))])]);
        assert_eq!(unseen[1], None);
    }

    #[test]
    fn two_turns_ending_in_one_second_still_count() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(1))]),
            snap(&[("a", Working, 10, Some(2))]),
            snap(&[("a", Done, 10, Some(3))]),
        ]);
        assert_eq!(got, vec![None, None, Some(Cue::Done)]);
    }

    #[test]
    fn an_older_hook_that_never_counted_still_chimes_done_after_work() {
        let got = run(&[
            snap(&[("a", Working, 10, None)]),
            snap(&[("a", Done, 20, None)]),
            snap(&[("a", Done, 20, None)]),
            snap(&[("a", NeedsYou, 30, None)]),
            snap(&[("a", Done, 40, None)]),
        ]);
        assert_eq!(
            got,
            vec![None, Some(Cue::Done), None, Some(Cue::NeedsYou), None]
        );
    }

    #[test]
    fn an_upgrade_mid_session_counts_from_the_first_stop() {
        // The old hook wrote the file; the new one's first write adds the count.
        let stop = run(&[
            snap(&[("a", Working, 10, None)]),
            snap(&[("a", Done, 20, Some(1))]),
        ]);
        assert_eq!(stop[1], Some(Cue::Done));
        let idle = run(&[
            snap(&[("a", Working, 10, None)]),
            snap(&[("a", Done, 20, Some(0))]),
        ]);
        assert_eq!(idle[1], None, "the idle prompt after Esc ends no turn");
    }

    #[test]
    fn a_session_first_seen_silent_chimes_when_its_turn_ends() {
        let got = run(&[
            snap(&[("a", Silent, 10, Some(3)), ("b", Silent, -10, Some(1))]),
            snap(&[("a", Done, 300, Some(4)), ("b", Silent, -10, Some(1))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done)]);
    }

    #[test]
    fn an_error_first_seen_silent_does_not_chime_when_its_beats_return() {
        let got = run(&[
            snap(&[("b", Silent, -10, Some(1))]),
            snap(&[("b", Error, -10, Some(1))]),
            snap(&[("b", Error, 50, Some(1))]),
        ]);
        assert_eq!(got, vec![None, None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_turn_that_ended_with_work_out_does_not_chime_when_the_work_goes_stale() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", Working, 20, Some(1))]),
            snap(&[("a", Done, 20, Some(1))]),
        ]);
        assert_eq!(got, vec![None, None, None]);
    }

    #[test]
    fn a_new_prompt_asks_each_time_even_from_needs_you() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", NeedsYou, 20, Some(0))]),
            snap(&[("a", NeedsYou, 30, Some(0))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou), Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_prompt_in_the_second_its_turn_began_asks() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", NeedsYou, 10, Some(0))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_rewrite_whose_skew_correction_moved_asks_for_nothing() {
        // The writer's clock drifts, or the hook waited on the lock: the
        // reader's correction moves the display time between two writes.
        let after = [("a", Done, 20, Some(1)), ("b", NeedsYou, 20, Some(0))];
        let got = run(&[
            snap(&[("a", Working, 10, Some(0)), ("b", Working, 10, Some(0))]),
            snap(&after),
            shifted(&after, 3),
            shifted(&after, -3),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou), None, None]);
    }

    #[test]
    fn coming_back_from_silence_asks_for_nothing() {
        // The PC slept: idle sessions read silent, then their beats came back.
        let got = run(&[
            snap(&[("a", Working, 10, Some(0)), ("b", Error, -10, Some(0))]),
            snap(&[("a", Done, 20, Some(1)), ("b", Error, -10, Some(0))]),
            snap(&[("a", Silent, 400, Some(1)), ("b", Silent, 400, Some(0))]),
            snap(&[("a", Done, 20, Some(1)), ("b", Error, -10, Some(0))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done), None, None]);
    }

    #[test]
    fn a_long_tool_call_read_silent_still_ends_in_done() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", Silent, 200, Some(0))]),
            snap(&[("a", Done, 300, Some(1))]),
        ]);
        assert_eq!(got, vec![None, None, Some(Cue::Done)]);
    }

    #[test]
    fn a_session_missing_from_one_read_does_not_ask_again() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0))]),
            snap(&[("a", NeedsYou, 20, Some(0))]),
            snap(&[]),
            snap(&[("a", NeedsYou, 20, Some(0))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou), None, None]);
    }

    #[test]
    fn needs_you_outranks_done_in_one_read() {
        let got = run(&[
            snap(&[("a", Working, 10, Some(0)), ("b", Working, 10, Some(0))]),
            snap(&[("a", Done, 20, Some(1)), ("b", NeedsYou, 20, Some(0))]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn within_the_gap_only_a_higher_rank_plays() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        let soon = t0 + GAP - Duration::from_millis(1);
        let w = |id| (id, Working, 10, Some(0));
        let a_done = ("a", Done, 20, Some(1));
        let b_done = ("b", Done, 21, Some(1));
        let c_needs = ("c", NeedsYou, 21, Some(0));
        cues.next(&snap(&[w("a"), w("b"), w("c")]), t0, START);
        assert_eq!(
            cues.next(&snap(&[a_done, w("b"), w("c")]), t0, START),
            Some(Cue::Done)
        );
        assert_eq!(
            cues.next(&snap(&[a_done, b_done, w("c")]), soon, START),
            None
        );
        let c_asks = snap(&[a_done, b_done, c_needs]);
        assert_eq!(cues.next(&c_asks, soon, START), Some(Cue::NeedsYou));
        let a_asks = snap(&[("a", NeedsYou, 22, Some(1)), b_done, c_needs]);
        assert_eq!(cues.next(&a_asks, soon, START), None);
        let b_asks = snap(&[
            ("a", NeedsYou, 22, Some(1)),
            ("b", NeedsYou, 23, Some(1)),
            c_needs,
        ]);
        assert_eq!(cues.next(&b_asks, soon + GAP, START), Some(Cue::NeedsYou));
    }

    #[test]
    fn a_dropped_cue_is_not_replayed_later() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        let w = |id| (id, Working, 10, Some(0));
        cues.next(&snap(&[w("a"), w("b")]), t0, START);
        cues.next(&snap(&[("a", Done, 20, Some(1)), w("b")]), t0, START);
        let both = snap(&[("a", Done, 20, Some(1)), ("b", Done, 21, Some(1))]);
        assert_eq!(cues.next(&both, t0, START), None);
        assert_eq!(cues.next(&both, t0 + GAP * 2, START), None);
    }

    #[test]
    fn an_absent_session_is_forgotten_after_a_day_by_the_reader_clock() {
        let mut cues = Cues::new(START);
        let t0 = Instant::now();
        let here = ("here", Done, 10, Some(1));
        cues.next(&snap(&[("gone", Done, 10, Some(1)), here]), t0, START);
        let far = snap(&[here, ("new", Working, 999_999, Some(0))]);
        cues.next(&far, t0, START + 60);
        assert!(
            cues.seen.contains_key("gone"),
            "a far-future view time forgets nothing"
        );
        cues.next(&snap(&[here]), t0, START + FORGET_AFTER);
        assert!(!cues.seen.contains_key("gone"));
        assert!(cues.seen.contains_key("here"));
    }
}
