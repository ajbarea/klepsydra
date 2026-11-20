//! One run at a time of a job that reads its input when it runs (`fleet
//! voices` reads the saved mode): asks that come while it runs fold into one
//! more run, so a burst of asks costs at most two runs and the last ask is
//! always served.

use std::sync::atomic::{AtomicBool, Ordering::SeqCst};

#[derive(Default)]
pub struct Coalesce {
    running: AtomicBool,
    again: AtomicBool,
}

impl Coalesce {
    /// A gate with nothing running, usable in a `static`.
    pub const fn new() -> Self {
        Self {
            running: AtomicBool::new(false),
            again: AtomicBool::new(false),
        }
    }

    /// Ask for a run. True when the caller must start the worker; false when
    /// one runs already and will run once more for this ask.
    pub fn ask(&self) -> bool {
        self.again.store(true, SeqCst);
        !self.running.swap(true, SeqCst)
    }

    /// The worker is about to run: what it reads now covers every ask so far.
    pub fn starting(&self) {
        self.again.store(false, SeqCst);
    }

    /// The worker finished a run. True when it must run again (an ask came
    /// meanwhile); false when it may stop, the gate open for the next ask.
    pub fn finished(&self) -> bool {
        if self.again.load(SeqCst) {
            return true;
        }
        self.running.store(false, SeqCst);
        // An ask between the check and the store saw it running and left the
        // run to it: take the gate back for it, unless a new worker has.
        self.again.load(SeqCst) && !self.running.swap(true, SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    #[test]
    fn asks_during_a_run_fold_into_one_more() {
        let c = Coalesce::default();
        assert!(c.ask(), "the first ask starts the worker");
        c.starting();
        for _ in 0..30 {
            assert!(!c.ask(), "a held key adds no worker");
        }
        assert!(c.finished(), "one more run for the asks that came");
        c.starting();
        assert!(!c.finished(), "then it stops");
        assert!(c.ask(), "and the next ask starts a worker again");
    }

    #[test]
    fn a_burst_from_many_threads_never_overlaps_runs_and_serves_the_last_ask() {
        let c = Coalesce::default();
        let asked = AtomicUsize::new(0);
        let served = AtomicUsize::new(0); // the newest ask a run has read
        let live = AtomicUsize::new(0); // runs going at once
        let (runs, starts) = (AtomicUsize::new(0), AtomicUsize::new(0));
        std::thread::scope(|s| {
            for _ in 0..8 {
                s.spawn(|| {
                    for _ in 0..25 {
                        asked.fetch_add(1, SeqCst);
                        if !c.ask() {
                            continue;
                        }
                        starts.fetch_add(1, SeqCst);
                        s.spawn(|| loop {
                            c.starting();
                            assert_eq!(live.fetch_add(1, SeqCst), 0, "two runs at once");
                            served.fetch_max(asked.load(SeqCst), SeqCst);
                            runs.fetch_add(1, SeqCst);
                            std::thread::sleep(Duration::from_millis(2));
                            live.fetch_sub(1, SeqCst);
                            if !c.finished() {
                                break;
                            }
                        });
                    }
                });
            }
        });
        assert_eq!(served.load(SeqCst), 200, "a run read the last ask");
        assert!(
            runs.load(SeqCst) < 200,
            "asks folded: {} runs",
            runs.load(SeqCst)
        );
        assert!(c.ask(), "the gate is open again");
        assert!(starts.load(SeqCst) >= 1);
    }
}
