//! Who follows the fleet: one sink per webview window, the latest snapshot for
//! a window that subscribes late, and the card the wall should show next.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};

use serde_json::{json, Value};

/// Somewhere a message can go; false once it is gone (a closed webview).
pub trait Sink: Send {
    fn send(&self, message: Value) -> bool;
}

pub struct Hub<S> {
    subs: Mutex<Vec<(String, S)>>,
    last: Mutex<Option<Value>>,
    /// A card waiting for its window to subscribe: (window label, session id).
    pending: Mutex<Option<(String, String)>>,
}

impl<S> Default for Hub<S> {
    fn default() -> Self {
        Hub {
            subs: Mutex::new(Vec::new()),
            last: Mutex::new(None),
            pending: Mutex::new(None),
        }
    }
}

/// Lock `m`; a poisoned lock disables the hub, so say so once.
fn lock<T>(m: &Mutex<T>) -> Option<MutexGuard<'_, T>> {
    static SAID: AtomicBool = AtomicBool::new(false);
    let guard = m.lock().ok();
    if guard.is_none() && !SAID.swap(true, Ordering::Relaxed) {
        eprintln!("klepsydra: a hub lock was poisoned; its windows will stop updating");
    }
    guard
}

// Lock order: `subs`, then `last` or `pending`. Publish and subscribe each
// hold `subs` throughout, so a new window sees every snapshot exactly once
// and in order.
impl<S: Sink> Hub<S> {
    /// Send a new snapshot to every window, dropping the ones that are gone.
    pub fn publish(&self, snapshot: Value) {
        let Some(mut subs) = lock(&self.subs) else {
            return;
        };
        if let Some(mut last) = lock(&self.last) {
            *last = Some(snapshot.clone());
        }
        subs.retain(|(_, s)| s.send(snapshot.clone()));
    }

    /// `f` of the last snapshot published, if any, read in place under the
    /// lock, so a click clones only what it needs.
    pub fn with_latest<R>(&self, f: impl FnOnce(&Value) -> R) -> Option<R> {
        lock(&self.last).and_then(|l| l.as_ref().map(f))
    }

    /// Window `label` follows the fleet from now on, starting with the latest
    /// snapshot and any card waiting to be shown there. A window that
    /// subscribes again (a reload) replaces its old sink.
    pub fn subscribe(&self, label: &str, sink: S) {
        let Some(mut subs) = lock(&self.subs) else {
            return;
        };
        if let Some(snapshot) = lock(&self.last).and_then(|l| l.clone()) {
            sink.send(snapshot);
        }
        let card = lock(&self.pending).and_then(|mut p| {
            p.take_if(|(for_label, _)| for_label == label)
                .map(|(_, id)| id)
        });
        if let Some(id) = card {
            sink.send(json!({ "focus": id }));
        }
        subs.retain(|(l, _)| l != label);
        subs.push((label.to_string(), sink));
    }

    /// Show session `id`'s card in window `label`: now if it is following,
    /// else as soon as it subscribes.
    pub fn focus(&self, label: &str, id: &str) {
        let Some(mut subs) = lock(&self.subs) else {
            return;
        };
        let message = json!({ "focus": id });
        let sent = match subs.iter().position(|(l, _)| l == label) {
            Some(i) if subs[i].1.send(message) => true,
            Some(i) => {
                subs.remove(i);
                false
            }
            None => false,
        };
        if !sent {
            if let Some(mut p) = lock(&self.pending) {
                *p = Some((label.to_string(), id.to_string()));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A sink that records what it got, and can be closed.
    #[derive(Clone, Default)]
    struct Probe {
        got: Arc<Mutex<Vec<Value>>>,
        closed: Arc<Mutex<bool>>,
    }

    impl Sink for Probe {
        fn send(&self, message: Value) -> bool {
            if *self.closed.lock().unwrap() {
                return false;
            }
            self.got.lock().unwrap().push(message);
            true
        }
    }

    impl Probe {
        fn got(&self) -> Vec<Value> {
            self.got.lock().unwrap().clone()
        }
    }

    fn snap(n: u64) -> Value {
        json!({ "sessions": [], "n": n })
    }

    #[test]
    fn with_latest_reads_the_last_published_snapshot() {
        let hub: Hub<Probe> = Hub::default();
        assert_eq!(hub.with_latest(|v| v["n"].as_u64()), None);
        hub.publish(snap(1));
        hub.publish(snap(2));
        assert_eq!(hub.with_latest(|v| v["n"].as_u64()), Some(Some(2)));
        assert_eq!(hub.with_latest(|v| v.clone()), Some(snap(2)));
    }

    #[test]
    fn every_window_gets_each_snapshot() {
        let hub: Hub<Probe> = Hub::default();
        let (main, wall) = (Probe::default(), Probe::default());
        hub.subscribe("main", main.clone());
        hub.subscribe("wall", wall.clone());
        hub.publish(snap(1));
        assert_eq!(main.got(), vec![snap(1)]);
        assert_eq!(wall.got(), vec![snap(1)]);
    }

    #[test]
    fn a_late_window_starts_with_the_latest_snapshot() {
        let hub: Hub<Probe> = Hub::default();
        hub.publish(snap(1));
        hub.publish(snap(2));
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        assert_eq!(wall.got(), vec![snap(2)]);
    }

    #[test]
    fn a_reload_replaces_the_window_sink() {
        let hub: Hub<Probe> = Hub::default();
        let (old, new) = (Probe::default(), Probe::default());
        hub.subscribe("main", old.clone());
        hub.subscribe("main", new.clone());
        hub.publish(snap(1));
        assert!(old.got().is_empty());
        assert_eq!(new.got(), vec![snap(1)]);
    }

    #[test]
    fn a_closed_window_is_dropped() {
        let hub: Hub<Probe> = Hub::default();
        let gone = Probe::default();
        hub.subscribe("wall", gone.clone());
        *gone.closed.lock().unwrap() = true;
        hub.publish(snap(1));
        *gone.closed.lock().unwrap() = false;
        hub.publish(snap(2));
        assert!(gone.got().is_empty());
    }

    #[test]
    fn a_card_waits_for_the_wall_to_subscribe() {
        let hub: Hub<Probe> = Hub::default();
        hub.publish(snap(1));
        hub.focus("wall", "abc");
        let main = Probe::default();
        hub.subscribe("main", main.clone());
        assert_eq!(main.got(), vec![snap(1)], "the card is the wall's alone");
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        assert_eq!(wall.got(), vec![snap(1), json!({ "focus": "abc" })]);
    }

    #[test]
    fn a_card_goes_straight_to_a_following_wall() {
        let hub: Hub<Probe> = Hub::default();
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        hub.focus("wall", "abc");
        assert_eq!(wall.got(), vec![json!({ "focus": "abc" })]);
    }

    #[test]
    fn a_window_subscribing_mid_publish_sees_snapshots_in_order() {
        const N: u64 = 2000;
        let hub: Arc<Hub<Probe>> = Arc::new(Hub::default());
        let publisher = {
            let hub = Arc::clone(&hub);
            std::thread::spawn(move || (1..=N).for_each(|n| hub.publish(snap(n))))
        };
        let probes: Vec<Probe> = (0..20).map(|_| Probe::default()).collect();
        for (i, p) in probes.iter().enumerate() {
            hub.subscribe(&format!("w{i}"), p.clone());
            std::thread::yield_now();
        }
        publisher.join().unwrap();
        for p in probes {
            let ns: Vec<u64> = p.got().iter().map(|v| v["n"].as_u64().unwrap()).collect();
            assert!(ns.windows(2).all(|w| w[0] < w[1]), "out of order: {ns:?}");
            assert_eq!(ns.last(), Some(&N), "missed the newest snapshot");
        }
    }

    #[test]
    fn a_failed_focus_drops_the_closed_window() {
        let hub: Hub<Probe> = Hub::default();
        let gone = Probe::default();
        hub.subscribe("wall", gone.clone());
        *gone.closed.lock().unwrap() = true;
        hub.focus("wall", "abc");
        *gone.closed.lock().unwrap() = false;
        hub.publish(snap(1));
        assert!(gone.got().is_empty());
    }
}
