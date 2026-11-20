//! What one tick of the app's file readers costs, as Windows counts it for
//! this process: read operations, other operations (opens, closes, queries,
//! directory listings) and bytes, per call, after one warm-up call.
//! `cargo run --release --example readcost -- <data folder> [calls]`
//! The data folder should be a copy: the fleet reader writes picks.json.

#![expect(
    clippy::print_stdout,
    reason = "a measurement tool: its report is its output"
)]

use std::path::PathBuf;
use std::time::{Duration, Instant};

#[cfg(windows)]
fn io() -> (u64, u64, u64) {
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, GetProcessIoCounters, IO_COUNTERS,
    };
    let mut c: IO_COUNTERS = unsafe { std::mem::zeroed() };
    unsafe { GetProcessIoCounters(GetCurrentProcess(), &mut c) };
    (
        c.ReadOperationCount,
        c.OtherOperationCount,
        c.ReadTransferCount,
    )
}
#[cfg(not(windows))]
fn io() -> (u64, u64, u64) {
    (0, 0, 0)
}

fn measure(name: &str, calls: usize, mut f: impl FnMut()) {
    f();
    let mut us = Vec::with_capacity(calls);
    let a = io();
    for _ in 0..calls {
        let t = Instant::now();
        f();
        us.push(t.elapsed().as_micros());
    }
    let b = io();
    us.sort_unstable();
    let n = calls as u64;
    println!(
        "{name}: reads/call={} other/call={} bytes/call={} median_us={} min_us={} max_us={}",
        (b.0 - a.0) / n,
        (b.1 - a.1) / n,
        (b.2 - a.2) / n,
        us[us.len() / 2],
        us[0],
        us[us.len() - 1]
    );
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("data folder"));
    let calls: usize = args.next().map_or(50, |s| s.parse().expect("calls"));
    let fleet = dir.join("fleet");
    let mut scanner = klepsydra_fleet::scan::Scanner::default();
    measure("scan", calls, || {
        std::hint::black_box(scanner.scan(&fleet));
    });
    let mut usage = readcost_usage(&dir);
    measure("usage", calls, || {
        std::hint::black_box(usage());
    });
    let mut reader = klepsydra_fleet::watch::Reader::new(&dir);
    measure("reader step", calls, || {
        std::hint::black_box(reader.step(Duration::ZERO, klepsydra_fleet::watch::unix_now));
    });
}

// One usage read as the app makes it: through the reader it keeps.
fn readcost_usage(dir: &std::path::Path) -> impl FnMut() -> Vec<serde_json::Value> + '_ {
    let mut reader = klepsydra_fleet::usage::Reader::default();
    move || reader.read([dir])
}
