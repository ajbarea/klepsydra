//! What the phone feed's per-update work costs on a real data folder:
//! the clone and serialisation `Feed::update` does on each usage poll, and
//! the snapshot parse `offers_clip` does on each audio range request.
//! `cargo run --release --example phonecost -- <data folder copy> [calls]`

#![expect(
    clippy::print_stdout,
    reason = "a measurement tool: its report is its output"
)]

use std::path::PathBuf;
use std::time::{Duration, Instant};

fn median(name: &str, calls: usize, mut f: impl FnMut() -> usize) {
    let mut size = f();
    let mut us = Vec::with_capacity(calls);
    for _ in 0..calls {
        let t = Instant::now();
        size = std::hint::black_box(f());
        us.push(t.elapsed().as_nanos() as u64);
    }
    us.sort_unstable();
    println!(
        "{name}: bytes={size} median_us={:.1} min_us={:.1} max_us={:.1}",
        us[us.len() / 2] as f64 / 1e3,
        us[0] as f64 / 1e3,
        us[us.len() - 1] as f64 / 1e3
    );
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("data folder"));
    let calls: usize = args.next().map_or(200, |s| s.parse().expect("calls"));
    let mut reader = klepsydra_fleet::watch::Reader::new(&dir);
    let (snap, _) = reader.step(Duration::ZERO, klepsydra_fleet::watch::unix_now);
    let snap = serde_json::to_value(snap.expect("a first snapshot")).expect("json");
    let fleet = klepsydra_fleet::phone::phone_view(&snap);
    let readings = klepsydra_fleet::usage::Reader::default().read([dir.as_path()]);
    let usage = klepsydra_fleet::usage::phone_view(&readings);
    println!(
        "sessions={} readings={}",
        snap["sessions"].as_array().map_or(0, Vec::len),
        readings.len()
    );
    // Feed::update: clone the fleet part, insert usage, serialise.
    median("update (clone+insert+to_vec)", calls, || {
        let mut view = fleet.clone();
        if let Some(m) = view.as_object_mut() {
            m.insert("usage".into(), usage.clone());
        }
        serde_json::to_vec(&view).map_or(0, |v| v.len())
    });
    let mut whole = fleet.clone();
    if let Some(m) = whole.as_object_mut() {
        m.insert("usage".into(), usage.clone());
    }
    let json = serde_json::to_vec(&whole).expect("json");
    // offers_clip: parse the whole snapshot for one range request.
    median("offers_clip parse", calls, || {
        serde_json::from_slice::<serde_json::Value>(&json).map_or(0, |_| json.len())
    });
    // The fleet snapshot the app serialises on every change (to_value + phone_view).
    median("fleet phone_view", calls, || {
        let v = klepsydra_fleet::phone::phone_view(&snap);
        v.as_object().map_or(0, |m| m.len())
    });
}
