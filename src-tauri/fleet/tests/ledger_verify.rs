//! `ledger-verify` run as a program on the recorded transcripts.

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/transcripts")
}

fn run(ledger: &str, extra: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ledger-verify"))
        .args(["--ledger"])
        .arg(fixtures().join(ledger))
        .args([
            "--day",
            "2026-10-06",
            "--tz",
            "America/New_York",
            "--projects",
        ])
        .arg(fixtures().join("projects"))
        .args(extra)
        .output()
        .unwrap()
}

#[test]
fn lost_exports_exit_1_and_name_the_session() {
    let out = run("ledger", &[]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("00000000-0000-4000-8000-000000000002"),
        "{text}"
    );
    assert!(text.contains("2 of 5 sessions lost exports"), "{text}");
}

#[test]
fn a_ledger_that_is_only_higher_exits_0() {
    let out = run("ledger-ok", &[]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(0), "{text}");
    assert!(text.contains("0 of 5 sessions lost exports"), "{text}");
}

#[test]
fn bad_arguments_and_a_missing_day_exit_2_with_a_reason() {
    for (args, reason) in [
        (vec!["--day", "yesterday", "--ledger", "x"], "YYYY-MM-DD"),
        (vec!["--ledger", "x"], "--day is required"),
        (vec!["--bogus"], "unknown argument"),
        (
            vec![
                "--day",
                "2001-01-01",
                "--ledger",
                "/nonexistent",
                "--projects",
                "/tmp",
            ],
            "2001-01-01.json",
        ),
    ] {
        let out = Command::new(env!("CARGO_BIN_EXE_ledger-verify"))
            .args(&args)
            .output()
            .unwrap();
        let err = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(2), "{args:?}: {err}");
        assert!(err.contains(reason), "{args:?}: {err}");
    }
}
