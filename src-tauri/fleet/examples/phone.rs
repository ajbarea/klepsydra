//! Run the phone wall server alone, without the overlay, for a live check
//! or the browser suite: `cargo run -p klepsydra-fleet --example phone --
//! <frontend-dir> <snapshot.json> [port]`. Serves the frontend from disk, as
//! the app serves its bundle, and the snapshot with its times moved up to now
//! (by its `at`, as the wall's ?demo does), again each time the file changes.
//! Port 0, the default, picks a free one. Prints the bound address, and logs
//! to stderr at `KLEPSYDRA_LOG`'s level (info by default). With
//! `KLEPSYDRA_DIR` set, reply clips come from its `replies/`, the usage
//! gauges from its `accounts/`, the character theme from its `prefs.json`
//! and the CI watch from its `ci.json`, read again each time they change, as
//! the app reads them.

use std::net::{Ipv4Addr, SocketAddrV4};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use klepsydra_fleet::phone::{asset_type, Assets, Clips, Server, Usage};
use klepsydra_fleet::theme;
use klepsydra_fleet::watch::unix_now;
use serde_json::Value;

/// The snapshot's times, as the wall's ?demo shifts them (feed.js TIMES).
const TIMES: [&str; 10] = [
    "status_at",
    "active_at",
    "updated_at",
    "quiet_since",
    "at",
    "started_at",
    "ends_at",
    "until",
    "settled_at",
    "turn_at",
];

fn shifted(v: &mut Value, by: i64) {
    match v {
        Value::Object(m) => {
            for (k, x) in m.iter_mut() {
                match x.as_i64() {
                    Some(t) if TIMES.contains(&k.as_str()) => *x = Value::from(t + by),
                    _ => shifted(x, by),
                }
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| shifted(x, by)),
        _ => {}
    }
}

fn load(path: &PathBuf) -> Option<Value> {
    let mut v: Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    if let Some(at) = v.get("at").and_then(Value::as_i64) {
        if let Some(m) = v.as_object_mut() {
            m.remove("at");
        }
        shifted(&mut v, unix_now() - at);
    }
    Some(v)
}

#[expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a command's usage text and the bound address the browser suite reads"
)]
fn main() {
    klepsydra_fleet::logfmt::to_stderr();
    let mut args = std::env::args().skip(1);
    let (Some(root), Some(snapshot)) = (args.next(), args.next()) else {
        eprintln!("usage: phone <frontend-dir> <snapshot.json> [port]");
        return;
    };
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    let root = PathBuf::from(root);
    let assets: Assets = Arc::new(move |path: &str| {
        asset_type(path)?;
        std::fs::read(root.join(path)).ok()
    });
    let dir = std::env::var_os("KLEPSYDRA_DIR").map(PathBuf::from);
    let clips: Clips = match dir.clone() {
        Some(dir) => Arc::new(move |id: &str| klepsydra_fleet::reply::read(&dir, id)),
        None => Arc::new(|_| None),
    };
    let prefs = dir.as_ref().map(|d| d.join("prefs.json"));
    let ci_dir = dir.clone();
    let mut ci = klepsydra_fleet::ci::Follower::default();
    let usage: Option<Usage> = dir.map(|dir| {
        let read: Usage = Arc::new(move || klepsydra_fleet::usage::read([&dir]));
        read
    });
    let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let server = match Server::spawn(addr, assets, clips, usage) {
        Ok(s) => s,
        Err(e) => {
            log::error!("no phone wall on {addr}: {e}");
            return;
        }
    };
    println!("listening on {}", server.addr());
    let snapshot = PathBuf::from(snapshot);
    let mut seen: Option<SystemTime> = None;
    let mut theme_seen: Option<SystemTime> = None;
    loop {
        if let Some(prefs) = &prefs {
            let changed = std::fs::metadata(prefs).and_then(|m| m.modified()).ok();
            if changed != theme_seen {
                theme_seen = changed;
                let saved = std::fs::read_to_string(prefs)
                    .ok()
                    .and_then(|t| serde_json::from_str::<Value>(&t).ok());
                server.set_theme(theme::of(saved.as_ref().and_then(Value::as_object)));
            }
        }
        if let Some(view) = ci_dir.as_ref().and_then(|d| ci.step(d, unix_now())) {
            server.set_ci(&view);
        }
        let changed = std::fs::metadata(&snapshot).and_then(|m| m.modified()).ok();
        if changed != seen {
            seen = changed;
            if let Some(v) = load(&snapshot) {
                server.publish(&v);
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
