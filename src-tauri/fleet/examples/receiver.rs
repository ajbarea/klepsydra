//! Run the OTLP receiver alone, without the overlay, for a live check:
//! `cargo run -p klepsydra-fleet --example receiver -- <ledger-dir> [port]`.
//! Port 0, the default, picks a free one. Prints the bound address, then
//! today's ledger each time it changes; logs to stderr at `KLEPSYDRA_LOG`'s
//! level (info by default).

use std::net::{Ipv4Addr, SocketAddrV4};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use klepsydra_fleet::ledger::{lock, Ledger, Shared};
use klepsydra_fleet::receiver;
use klepsydra_fleet::watch::unix_now;

#[expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a command's usage text, and the address and ledger it reports"
)]
fn main() {
    klepsydra_fleet::logfmt::to_stderr();
    let mut args = std::env::args().skip(1);
    let Some(dir) = args.next() else {
        eprintln!("usage: receiver <ledger-dir> [port]");
        return;
    };
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    let (ledger, problems) = Ledger::open_local(dir.into(), unix_now());
    for p in problems {
        log::error!("ledger: {p}");
    }
    let ledger: Shared = Arc::new(Mutex::new(ledger));
    let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    match receiver::spawn(addr, ledger.clone()) {
        Ok(bound) => println!("listening on {bound}"),
        Err(e) => {
            log::error!("no receiver on {addr}: {e}");
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
