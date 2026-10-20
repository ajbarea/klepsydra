//! Run the OTLP receiver alone, without the overlay, for a live check:
//! `cargo run -p klepsydra-fleet --example receiver -- <ledger-dir> [port]`.
//! Port 0, the default, picks a free one. Prints the bound address, then
//! today's ledger each time it changes.

use std::net::{Ipv4Addr, SocketAddrV4};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use klepsydra_fleet::ledger::{lock, Ledger, Shared};
use klepsydra_fleet::receiver::{self, Log};
use klepsydra_fleet::watch::unix_now;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(dir) = args.next() else {
        eprintln!("usage: receiver <ledger-dir> [port]");
        return;
    };
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    let (ledger, problems) = Ledger::open(dir.into(), unix_now());
    for p in problems {
        eprintln!("ledger: {p}");
    }
    let ledger: Shared = Arc::new(Mutex::new(ledger));
    let log: Log = Arc::new(|l| eprintln!("{l}"));
    let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    match receiver::spawn(addr, ledger.clone(), log) {
        Ok(bound) => println!("listening on {bound}"),
        Err(e) => {
            eprintln!("no receiver on {addr}: {e}");
            return;
        }
    }
    let mut last = String::new();
    loop {
        std::thread::sleep(Duration::from_secs(2));
        let now = serde_json::to_string_pretty(lock(&ledger).day()).unwrap_or_default();
        if now != last {
            println!("{now}");
            last = now;
        }
    }
}
