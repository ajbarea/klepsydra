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
    assert!(text.contains("1 lost exports"), "{text}");
    assert!(text.contains("1 sent no telemetry"), "{text}");
}

#[test]
fn a_ledger_that_is_only_higher_exits_0() {
    let out = run("ledger-ok", &[]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(0), "{text}");
    assert!(
        text.contains("0 lost exports") && text.contains("0 sent no telemetry"),
        "{text}"
    );
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

/// A ledger folder like `ledger-ok` without session 4, which then has
/// transcripts and no ledger entry, and with `state` as its state file.
fn without_session_4(name: &str, state: Option<&str>) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("klepsydra-verify-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let text = std::fs::read_to_string(fixtures().join("ledger-ok/2026-10-06.json")).unwrap();
    let mut day: serde_json::Value = serde_json::from_str(&text).unwrap();
    day["sessions"]
        .as_object_mut()
        .unwrap()
        .remove("00000000-0000-4000-8000-000000000004");
    std::fs::write(dir.join("2026-10-06.json"), day.to_string()).unwrap();
    if let Some(state) = state {
        std::fs::write(dir.join("state.json"), state).unwrap();
    }
    dir
}

/// Session 4's assistant messages run from 10:47:51Z to 10:47:55Z.
const GAP_OVER_SESSION_4: &str = r#"{"version":1,"gaps":[{"from":1791283660,"to":1791283680}]}"#;
const GAP_BEFORE_SESSION_4: &str = r#"{"version":1,"gaps":[{"from":1791280000,"to":1791281000}]}"#;

#[test]
fn a_session_with_no_telemetry_alone_exits_0() {
    for (name, state) in [("silent", None), ("silent-gap", Some(GAP_BEFORE_SESSION_4))] {
        let dir = without_session_4(name, state);
        let out = run(dir.to_str().unwrap(), &[]);
        std::fs::remove_dir_all(&dir).unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert_eq!(out.status.code(), Some(0), "{name}: {text}");
        assert!(
            text.contains("0 lost exports") && text.contains("1 sent no telemetry"),
            "{name}: {text}"
        );
    }
}

#[test]
fn a_session_with_no_ledger_entry_during_a_receiver_gap_exits_1() {
    let dir = without_session_4("gap", Some(GAP_OVER_SESSION_4));
    let out = run(dir.to_str().unwrap(), &[]);
    std::fs::remove_dir_all(&dir).unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("00000000-0000-4000-8000-000000000004 (receiver down)"),
        "{text}"
    );
    assert!(
        text.contains("1 lost exports") && text.contains("0 sent no telemetry"),
        "{text}"
    );
}

#[test]
fn a_state_file_it_cannot_read_exits_2_naming_it() {
    let dir = without_session_4("bad-state", Some("{not json"));
    let out = run(dir.to_str().unwrap(), &[]);
    let kept = std::fs::read_to_string(dir.join("state.json")).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{err}");
    assert!(err.contains("state.json"), "{err}");
    assert_eq!(kept, "{not json", "left where it was");
}
