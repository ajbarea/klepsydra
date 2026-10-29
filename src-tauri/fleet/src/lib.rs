//! The fleet strip's reader: session files in, an ordered list of sessions
//! out. Kept free of Tauri so its tests run on any machine.

pub mod bounded;
pub mod ci;
pub mod clear;
pub mod cue;
pub mod hub;
pub mod ledger;
pub mod logfmt;
pub mod lookup;
pub mod otel;
pub mod phone;
pub mod picks;
pub mod queue;
pub mod receiver;
pub mod reconcile;
pub mod reply;
pub mod scan;
pub mod session;
pub mod speaking;
pub mod tabs;
pub mod theme;
pub mod usage;
pub mod view;
pub mod watch;
pub mod wrapup;
