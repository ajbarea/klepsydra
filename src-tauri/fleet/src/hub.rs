//! Who follows the fleet: one sink per webview window, the latest snapshot for
//! a window that subscribes late, and the card the wall should show next.

use std::sync::Mutex;

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

impl<S: Sink> Hub<S> {
    /// Send a new snapshot to every window, dropping the ones that are gone.
    pub fn publish(&self, snapshot: Value) {
        if let Ok(mut last) = self.last.lock() {
            *last = Some(snapshot.clone());
        }
        if let Ok(mut subs) = self.subs.lock() {
            subs.retain(|(_, s)| s.send(snapshot.clone()));
        }
    }

    /// Window `label` follows the fleet from now on, starting with the latest
    /// snapshot and any card waiting to be shown there. A window that
    /// subscribes again (a reload) replaces its old sink.
    pub fn subscribe(&self, label: &str, sink: S) {
        if let Some(snapshot) = self.last.lock().ok().and_then(|l| l.clone()) {
            sink.send(snapshot);
        }
        let card = self.pending.lock().ok().and_then(|mut p| {
            p.take_if(|(for_label, _)| for_label == label)
                .map(|(_, id)| id)
        });
        if let Some(id) = card {
            sink.send(json!({ "focus": id }));
        }
        if let Ok(mut subs) = self.subs.lock() {
            subs.retain(|(l, _)| l != label);
            subs.push((label.to_string(), sink));
        }
    }

    /// Show session `id`'s card in window `label`: now if it is following,
    /// else as soon as it subscribes.
    pub fn focus(&self, label: &str, id: &str) {
        let sent = self.subs.lock().is_ok_and(|subs| {
            subs.iter()
                .find(|(l, _)| l == label)
                .is_some_and(|(_, s)| s.send(json!({ "focus": id })))
        });
        if !sent {
            if let Ok(mut p) = self.pending.lock() {
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
}
