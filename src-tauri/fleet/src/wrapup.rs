//! The wall's wrap-up: the request the app made, and each session's answer,
//! from `<klepsydra_dir>/wrapup`. The app writes `request.json`;
//! `hooks/klepsydra-wrapup.sh` writes `<session>.json` when it asks a session
//! and when the session reports.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::ledger::write_atomic;
use crate::speaking::{read_small, Found};
use crate::view::Status;

/// The folder's name in the klepsydra dir, beside `fleet`.
pub const DIR: &str = "wrapup";
/// The request's file name in it.
pub const REQUEST: &str = "request.json";
/// How long sessions have to answer, in seconds; a card still unanswered
/// after it reads "no answer". The app writes `until` from this.
pub const WINDOW: i64 = 600;
/// How long after `until` the wall still shows the request and its answers.
pub const SHOWN_AFTER: i64 = 3600;
/// A reason longer than this is cut; the script caps it at 300 characters.
const REASON_CHARS: usize = 300;
/// More than this is no file klepsydra writes.
const MAX_BYTES: u64 = 4096;

/// A wrap-up the wall asked for.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Request {
    /// Milliseconds since the epoch when it was made, as text.
    pub id: String,
    pub at: i64,
    /// When sessions stop being asked and silence reads "no answer".
    pub until: i64,
}

/// A session's place in the wrap-up.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Handed the instructions; no answer yet.
    Asked,
    /// Nothing would be lost by stopping it.
    Ready,
    /// Something would be lost; `reason` says what.
    Blocked,
}

/// One session's answer to the current request.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Answer {
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub at: i64,
}

#[derive(Deserialize)]
struct File {
    request: String,
    state: State,
    #[serde(default)]
    reason: Option<String>,
    at: i64,
}

fn text(path: &Path) -> Option<String> {
    match read_small(path, MAX_BYTES) {
        Found::Text(t) => Some(t),
        _ => None,
    }
}

/// The request in `klepsydra_dir`, while the wall still shows it at `now`.
pub fn request(klepsydra_dir: &Path, now: i64) -> Option<Request> {
    let r: Request = serde_json::from_str(&text(&klepsydra_dir.join(DIR).join(REQUEST))?).ok()?;
    let sane = !r.id.is_empty()
        && r.id.len() <= 20
        && r.id.bytes().all(|b| b.is_ascii_digit())
        && r.at <= r.until;
    (sane && now <= r.until.saturating_add(SHOWN_AFTER)).then_some(r)
}

/// Session `id`'s answer to `request`, if it has one. An answer to an older
/// request is none. `id` must already be a session id the scan accepted.
pub fn answer(klepsydra_dir: &Path, request: &Request, id: &str) -> Option<Answer> {
    let f: File =
        serde_json::from_str(&text(&klepsydra_dir.join(DIR).join(format!("{id}.json")))?).ok()?;
    if f.request != request.id {
        return None;
    }
    let reason = f
        .reason
        .filter(|_| f.state == State::Blocked)
        .map(|r| r.chars().take(REASON_CHARS).collect());
    Some(Answer {
        state: f.state,
        reason,
        at: f.at,
    })
}

/// How a session gets the wrap-up, by its status when the wall asks.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Route {
    /// Idle in klepsydra's tmux: `/klepsydra-wrapup` is typed now.
    Type,
    /// Mid-turn: the Stop hook asks it when the turn ends.
    TurnEnd,
    /// Waiting on AJ: the Stop hook asks it once he answers and the turn ends.
    AfterAnswer,
    /// Idle outside klepsydra's tmux, or silent: AJ asks it himself.
    ByHand,
}

/// How a session with `status` gets the wrap-up; none once it has ended.
/// `in_fleet` is whether it runs in klepsydra's own tmux server.
pub fn route(status: Status, in_fleet: bool) -> Option<Route> {
    match status {
        Status::Working => Some(Route::TurnEnd),
        Status::NeedsYou => Some(Route::AfterAnswer),
        Status::Done | Status::New | Status::Error if in_fleet => Some(Route::Type),
        Status::Done | Status::New | Status::Error | Status::Silent => Some(Route::ByHand),
        Status::Ended => None,
    }
}

fn folder(klepsydra_dir: &Path) -> std::io::Result<std::path::PathBuf> {
    let dir = klepsydra_dir.join(DIR);
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn save_request(klepsydra_dir: &Path, r: &Request) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(r).map_err(std::io::Error::other)?;
    write_atomic(&folder(klepsydra_dir)?.join(REQUEST), &bytes)
}

/// Start a wrap-up at `now_ms`: sessions are asked until `WINDOW` passes.
/// A new one replaces any before it, so every answer is asked for again.
pub fn start(klepsydra_dir: &Path, now_ms: i64) -> std::io::Result<Request> {
    let at = now_ms.div_euclid(1000);
    let r = Request {
        id: now_ms.to_string(),
        at,
        until: at + WINDOW,
    };
    save_request(klepsydra_dir, &r)?;
    Ok(r)
}

/// Stop asking at `now`; the answers so far stay on the wall.
pub fn cancel(klepsydra_dir: &Path, now: i64) -> std::io::Result<()> {
    let Some(mut r) = request(klepsydra_dir, now) else {
        return Ok(());
    };
    r.until = r.until.min(now.max(r.at));
    save_request(klepsydra_dir, &r)
}

/// Record that session `id` was asked, before `/klepsydra-wrapup` is typed,
/// so the Stop hook at the end of that turn does not ask again.
pub fn mark_asked(klepsydra_dir: &Path, r: &Request, id: &str, now: i64) -> std::io::Result<()> {
    let text = serde_json::json!({"request": r.id, "state": State::Asked, "at": now});
    write_atomic(
        &folder(klepsydra_dir)?.join(format!("{id}.json")),
        text.to_string().as_bytes(),
    )
}

/// Undo `mark_asked` when the typing failed, so the Stop hook asks instead.
pub fn unmark(klepsydra_dir: &Path, id: &str) {
    let _ = std::fs::remove_file(klepsydra_dir.join(DIR).join(format!("{id}.json")));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    const A: &str = "4ce1be96-f12f-4c66-87eb-4ab36e451dc5";
    const NOW: i64 = 1_792_600_000;

    fn dir() -> Scratch {
        let d = Scratch::new("wrapup");
        std::fs::create_dir(d.0.join(DIR)).unwrap();
        d
    }

    fn put(d: &Scratch, name: &str, text: &str) {
        d.write(&format!("{DIR}/{name}"), text);
    }

    #[test]
    fn a_request_shows_until_an_hour_after_its_window() {
        let d = dir();
        assert_eq!(request(&d.0, NOW), None);
        let until = NOW + WINDOW;
        put(
            &d,
            REQUEST,
            &format!(r#"{{"id":"1792600000000","at":{NOW},"until":{until}}}"#),
        );
        let r = request(&d.0, NOW).unwrap();
        assert_eq!((r.id.as_str(), r.until), ("1792600000000", until));
        assert!(request(&d.0, until + SHOWN_AFTER).is_some());
        assert_eq!(request(&d.0, until + SHOWN_AFTER + 1), None);
    }

    #[test]
    fn a_malformed_request_is_none() {
        let d = dir();
        for bad in [
            "not json",
            r#"{"id":"","at":1,"until":2}"#,
            r#"{"id":"12a","at":1,"until":2}"#,
            r#"{"id":"123456789012345678901","at":1,"until":2}"#,
            r#"{"id":"1","at":3,"until":2}"#,
            r#"{"id":"1","at":1}"#,
        ] {
            put(&d, REQUEST, bad);
            assert_eq!(request(&d.0, 0), None, "{bad}");
        }
    }

    #[test]
    fn answers_count_only_for_the_current_request() {
        let d = dir();
        let r = Request {
            id: "7".into(),
            at: NOW,
            until: NOW + WINDOW,
        };
        assert_eq!(answer(&d.0, &r, A), None);
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"6","state":"ready","at":1}"#,
        );
        assert_eq!(answer(&d.0, &r, A), None);
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"7","state":"asked","at":1}"#,
        );
        assert_eq!(answer(&d.0, &r, A).unwrap().state, State::Asked);
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"7","state":"blocked","reason":"a 2 h build","at":2}"#,
        );
        assert_eq!(
            answer(&d.0, &r, A),
            Some(Answer {
                state: State::Blocked,
                reason: Some("a 2 h build".into()),
                at: 2
            })
        );
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"7","state":"ready","reason":"x","at":3}"#,
        );
        assert_eq!(
            answer(&d.0, &r, A).unwrap().reason,
            None,
            "only blocked has a reason"
        );
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"7","state":"safe","at":3}"#,
        );
        assert_eq!(answer(&d.0, &r, A), None, "an unknown state is no answer");
    }

    #[test]
    fn a_long_reason_is_cut_and_a_symlink_is_not_followed() {
        let d = dir();
        let r = Request {
            id: "7".into(),
            at: NOW,
            until: NOW + WINDOW,
        };
        let long = "é".repeat(500);
        put(
            &d,
            &format!("{A}.json"),
            &format!(r#"{{"request":"7","state":"blocked","reason":"{long}","at":1}}"#),
        );
        assert_eq!(
            answer(&d.0, &r, A).unwrap().reason.unwrap().chars().count(),
            300
        );
        #[cfg(unix)]
        {
            put(&d, "real.json", r#"{"request":"7","state":"ready","at":1}"#);
            let link = d.0.join(DIR).join(format!("{A}.json"));
            std::fs::remove_file(&link).unwrap();
            std::os::unix::fs::symlink(d.0.join(DIR).join("real.json"), &link).unwrap();
            assert_eq!(answer(&d.0, &r, A), None);
        }
    }

    #[test]
    fn each_status_has_its_route() {
        use Route::*;
        for (status, fleet, want) in [
            (Status::Working, false, Some(TurnEnd)),
            (Status::Working, true, Some(TurnEnd)),
            (Status::NeedsYou, true, Some(AfterAnswer)),
            (Status::Done, true, Some(Type)),
            (Status::New, true, Some(Type)),
            (Status::Error, true, Some(Type)),
            (Status::Done, false, Some(ByHand)),
            (Status::Silent, true, Some(ByHand)),
            (Status::Ended, true, None),
        ] {
            assert_eq!(route(status, fleet), want, "{status:?} in_fleet={fleet}");
        }
    }

    #[test]
    fn start_cancel_and_marks_round_trip() {
        let d = Scratch::new("wrapup-start");
        let r = start(&d.0, NOW * 1000 + 250).unwrap();
        assert_eq!(
            r,
            Request {
                id: format!("{}", NOW * 1000 + 250),
                at: NOW,
                until: NOW + WINDOW
            }
        );
        assert_eq!(request(&d.0, NOW), Some(r.clone()));
        mark_asked(&d.0, &r, A, NOW + 1).unwrap();
        assert_eq!(answer(&d.0, &r, A).unwrap().state, State::Asked);
        unmark(&d.0, A);
        assert_eq!(answer(&d.0, &r, A), None);
        cancel(&d.0, NOW + 30).unwrap();
        assert_eq!(request(&d.0, NOW + 30).unwrap().until, NOW + 30);
        // Cancelling twice, or with none, changes nothing.
        cancel(&d.0, NOW + 60).unwrap();
        assert_eq!(request(&d.0, NOW + 60).unwrap().until, NOW + 30);
        cancel(&Scratch::new("wrapup-none").0, NOW).unwrap();
    }

    #[test]
    fn the_script_reads_the_request_the_app_writes() {
        // klepsydra-wrapup.sh reads .id as text and .until as a number.
        let d = Scratch::new("wrapup-shape");
        start(&d.0, 1_792_600_000_123).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(d.0.join(DIR).join(REQUEST)).unwrap())
                .unwrap();
        assert!(v["id"].is_string() && v["until"].is_i64(), "{v}");
    }
}
