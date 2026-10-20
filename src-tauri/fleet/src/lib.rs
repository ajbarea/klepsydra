//! The fleet strip's reader: session files in, an ordered list of sessions
//! out. Kept free of Tauri so its tests run on any machine.

pub mod hub;
pub mod lookup;
pub mod problem_log;
pub mod scan;
pub mod session;
pub mod tabs;
pub mod view;
pub mod watch;
