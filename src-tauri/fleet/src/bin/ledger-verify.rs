//! `ledger-verify --ledger DIR --day YYYY-MM-DD [--projects DIR]... [--tz ZONE]`
//!
//! Sets a day's ledger against the transcripts Claude Code wrote, and exits 1
//! when exports were lost: a session's ledger is more than 2% lower on
//! cache_read or cache_creation, or a session missing from it ran only while
//! the receiver was down. See `reconcile`.

use std::path::PathBuf;
use std::process::ExitCode;

use jiff::tz::TimeZone;
use klepsydra_fleet::ledger::read_gaps;
use klepsydra_fleet::reconcile::{compare, read_day, read_transcripts};

const USAGE: &str =
    "usage: ledger-verify --ledger DIR --day YYYY-MM-DD [--projects DIR]... [--tz ZONE]";

struct Args {
    ledger: PathBuf,
    day: String,
    projects: Vec<PathBuf>,
    tz: TimeZone,
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Args, String> {
    let (mut ledger, mut day, mut tz) = (None, None, None);
    let mut projects = Vec::new();
    while let Some(flag) = args.next() {
        let mut value = || args.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--ledger" => ledger = Some(PathBuf::from(value()?)),
            "--day" => day = Some(value()?),
            "--projects" => projects.push(PathBuf::from(value()?)),
            "--tz" => {
                let name = value()?;
                tz = Some(TimeZone::get(&name).map_err(|e| format!("--tz {name}: {e}"))?);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let day = day.ok_or("--day is required")?;
    let bytes = day.as_bytes();
    let shaped = bytes.len() == 10
        && bytes.iter().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                *b == b'-'
            } else {
                b.is_ascii_digit()
            }
        });
    if !shaped {
        return Err(format!("--day {day}: expected YYYY-MM-DD"));
    }
    Ok(Args {
        ledger: ledger.ok_or("--ledger is required")?,
        day,
        projects: if projects.is_empty() {
            default_projects()
        } else {
            projects
        },
        tz: tz.unwrap_or_else(TimeZone::system),
    })
}

/// `projects` under every `~/.claude*` folder.
fn default_projects() -> Vec<PathBuf> {
    let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = std::fs::read_dir(home)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(".claude"))
        .map(|e| e.path().join("projects"))
        .filter(|p| p.is_dir())
        .collect();
    found.sort();
    found
}

fn main() -> ExitCode {
    let args = match parse(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ledger-verify: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    if args.projects.is_empty() {
        eprintln!("ledger-verify: no ~/.claude*/projects folder found; pass --projects DIR");
        return ExitCode::from(2);
    }
    let day = match read_day(&args.ledger, &args.day) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("ledger-verify: {e}");
            return ExitCode::from(2);
        }
    };
    let gaps = match read_gaps(&args.ledger) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("ledger-verify: {e}");
            return ExitCode::from(2);
        }
    };
    let report = compare(
        &day,
        read_transcripts(&args.projects, &args.day, &args.tz),
        &gaps,
    );
    print!("{}", report.render());
    ExitCode::from(u8::from(!report.lost().is_empty()))
}
