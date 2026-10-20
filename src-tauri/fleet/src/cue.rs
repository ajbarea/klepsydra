//! Which sound a new snapshot asks for: a session that now needs AJ, or one
//! whose turn just ended. The shell plays it; this decides it.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::view::{Snapshot, Status};

/// A cue this soon after the last one is dropped, so a burst of sessions
/// changing over a few reads makes one sound.
pub const GAP: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cue {
    /// A session entered needs-you or error.
    NeedsYou,
    /// A working or silent session's turn ended.
    Done,
}

impl Cue {
    pub fn name(self) -> &'static str {
        match self {
            Cue::NeedsYou => "needs-you",
            Cue::Done => "done",
        }
    }
}

/// What one session's move from `before` (None: not shown before) to `now`
/// asks for.
fn cue_for(before: Option<Status>, now: Status) -> Option<Cue> {
    let wants_you = |s: Status| matches!(s, Status::NeedsYou | Status::Error);
    match now {
        s if wants_you(s) && !before.is_some_and(wants_you) => Some(Cue::NeedsYou),
        Status::Done if matches!(before, Some(Status::Working | Status::Silent)) => Some(Cue::Done),
        _ => None,
    }
}

/// Follows the statuses from one snapshot to the next.
#[derive(Default)]
pub struct Cues {
    /// None until the first snapshot, which is the baseline and asks for nothing.
    last: Option<HashMap<String, Status>>,
    played_at: Option<Instant>,
}

impl Cues {
    /// The cue `snap` asks for at `now`: needs-you outranks done, and at most
    /// one per `GAP`.
    pub fn next(&mut self, snap: &Snapshot, now: Instant) -> Option<Cue> {
        let statuses: HashMap<String, Status> = snap
            .sessions
            .iter()
            .map(|v| (v.session_id.clone(), v.status))
            .collect();
        let cue = self.last.as_ref().and_then(|last| {
            snap.sessions
                .iter()
                .filter_map(|v| cue_for(last.get(&v.session_id).copied(), v.status))
                .min_by_key(|c| *c as u8)
        });
        self.last = Some(statuses);
        let cue = cue.filter(|_| {
            self.played_at
                .is_none_or(|t| now.saturating_duration_since(t) >= GAP)
        })?;
        self.played_at = Some(now);
        Some(cue)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::view::View;

    fn view(id: &str, status: Status) -> View {
        View {
            session_id: id.into(),
            name: None,
            launch_dir: None,
            voice: None,
            status,
            reason: None,
            status_at: 0,
            active_at: 0,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            updated_at: 0,
            quiet_since: None,
            tmux: None,
            distro: None,
            claude: None,
            background: Default::default(),
        }
    }

    fn snap(sessions: &[(&str, Status)]) -> Snapshot {
        Snapshot {
            sessions: sessions.iter().map(|(id, s)| view(id, *s)).collect(),
        }
    }

    /// Cues for each snapshot in turn, read `GAP` apart so the gap never drops one.
    fn run(snaps: &[Snapshot]) -> Vec<Option<Cue>> {
        let mut cues = Cues::default();
        let t0 = Instant::now();
        snaps
            .iter()
            .enumerate()
            .map(|(i, s)| cues.next(s, t0 + GAP * i as u32))
            .collect()
    }

    #[test]
    fn the_first_snapshot_is_the_baseline() {
        let got = run(&[snap(&[("a", Status::NeedsYou), ("b", Status::Done)])]);
        assert_eq!(got, vec![None]);
    }

    #[test]
    fn each_status_move_asks_for_its_cue() {
        use Status::*;
        let all = [NeedsYou, Error, Working, Done, New, Silent, Ended];
        for before in all.iter().map(|s| Some(*s)).chain([None]) {
            for now in all {
                let want = match (before, now) {
                    (Some(NeedsYou | Error), NeedsYou | Error) => None,
                    (_, NeedsYou | Error) => Some(Cue::NeedsYou),
                    (Some(Working | Silent), Done) => Some(Cue::Done),
                    _ => None,
                };
                assert_eq!(cue_for(before, now), want, "{before:?} -> {now:?}");
            }
        }
    }

    #[test]
    fn a_new_session_that_needs_you_asks_for_a_cue() {
        let got = run(&[
            snap(&[("a", Status::Working)]),
            snap(&[("a", Status::Working), ("b", Status::NeedsYou)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_turn_ending_asks_for_done_once() {
        let got = run(&[
            snap(&[("a", Status::Working)]),
            snap(&[("a", Status::Done)]),
            snap(&[("a", Status::Done)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::Done), None]);
    }

    #[test]
    fn needs_you_outranks_done_in_one_read() {
        let got = run(&[
            snap(&[("a", Status::Working), ("b", Status::Working)]),
            snap(&[("a", Status::Done), ("b", Status::NeedsYou)]),
        ]);
        assert_eq!(got, vec![None, Some(Cue::NeedsYou)]);
    }

    #[test]
    fn a_cue_within_the_gap_is_dropped_and_the_next_after_it_plays() {
        let mut cues = Cues::default();
        let t0 = Instant::now();
        let working = snap(&[("a", Status::Working), ("b", Status::Working)]);
        assert_eq!(cues.next(&working, t0), None);
        let a_done = snap(&[("a", Status::Done), ("b", Status::Working)]);
        assert_eq!(cues.next(&a_done, t0), Some(Cue::Done));
        let b_done = snap(&[("a", Status::Done), ("b", Status::Done)]);
        let soon = t0 + GAP - Duration::from_millis(1);
        assert_eq!(cues.next(&b_done, soon), None);
        let a_needs = snap(&[("a", Status::NeedsYou), ("b", Status::Done)]);
        assert_eq!(cues.next(&a_needs, t0 + GAP), Some(Cue::NeedsYou));
    }

    #[test]
    fn a_dropped_cue_is_not_replayed_later() {
        let mut cues = Cues::default();
        let t0 = Instant::now();
        cues.next(&snap(&[("a", Status::Working), ("b", Status::Working)]), t0);
        cues.next(&snap(&[("a", Status::Done), ("b", Status::Working)]), t0);
        let both = snap(&[("a", Status::Done), ("b", Status::Done)]);
        assert_eq!(cues.next(&both, t0), None);
        assert_eq!(cues.next(&both, t0 + GAP * 2), None);
    }

    #[test]
    fn a_session_leaving_and_coming_back_needing_you_cues_again() {
        let got = run(&[
            snap(&[("a", Status::NeedsYou)]),
            snap(&[]),
            snap(&[("a", Status::NeedsYou)]),
        ]);
        assert_eq!(got, vec![None, None, Some(Cue::NeedsYou)]);
    }
}
