//! The wall's wrap-up: the request the app made, and each session's answer,
//! from `<klepsydra_dir>/wrapup`. The app writes `request.json`;
//! `hooks/klepsydra-wrapup.sh` writes `<session>.json` when it asks a session
//! and when the session reports.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::speaking::{read_small, Found};

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
}
