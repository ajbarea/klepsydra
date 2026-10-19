//! One session file, as the fleet hook writes it, and its heartbeat.

use serde::{Deserialize, Serialize};

/// The only session-file version this reader understands.
pub const VERSION: u64 = 1;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    New,
    Working,
    NeedsYou,
    Done,
    Error,
    Ended,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Place {
    pub repo: String,
    #[serde(default)]
    pub worktree: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    pub at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Touched {
    pub repo: String,
    pub at: i64,
}

/// A prompt or a reply, with when it was stored.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Said {
    pub text: String,
    pub at: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Ended {
    pub reason: String,
    pub at: i64,
}

/// `<session_id>.json`. Times are the writer's clock, in epoch seconds.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SessionFile {
    pub session_id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub launch_dir: Option<String>,
    #[serde(default)]
    pub voice: Option<String>,
    pub state: State,
    #[serde(default)]
    pub reason: Option<String>,
    pub state_at: i64,
    #[serde(default, rename = "where")]
    pub place: Option<Place>,
    #[serde(default)]
    pub touched: Vec<Touched>,
    #[serde(default)]
    pub prompt: Option<Said>,
    #[serde(default)]
    pub reply: Option<Said>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub ended: Option<Ended>,
    #[serde(default)]
    pub written_at: Option<i64>,
}

/// Why a session file was skipped.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Rejected {
    Version(String),
    Malformed(String),
    WrongId,
}

impl std::fmt::Display for Rejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Rejected::Version(v) => write!(f, "unknown version {v}"),
            Rejected::Malformed(e) => write!(f, "malformed: {e}"),
            Rejected::WrongId => write!(f, "session_id does not match the file name"),
        }
    }
}

/// Parse `<stem>.json`. Any `v` but 1 is rejected before the fields are read,
/// so a newer hook's file never half-renders.
pub fn parse(text: &str, stem: &str) -> Result<SessionFile, Rejected> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| Rejected::Malformed(e.to_string()))?;
    match value.get("v") {
        Some(v) if v.as_u64() == Some(VERSION) => {}
        Some(v) => return Err(Rejected::Version(v.to_string())),
        None => return Err(Rejected::Version("missing".into())),
    }
    let file: SessionFile =
        serde_json::from_value(value).map_err(|e| Rejected::Malformed(e.to_string()))?;
    if file.session_id != stem {
        return Err(Rejected::WrongId);
    }
    Ok(file)
}

/// The name in a `<session_id>.beat` line: the terminal tab's title, which the
/// statusline writes before a tab and the 10 s bucket. None while it has none.
pub fn beat_name(text: &str) -> Option<String> {
    let line = text.lines().next()?;
    let name = line.split('\t').next()?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// Whether `stem` is a Claude Code session id: a UUID, as the hook requires.
pub fn is_session_id(stem: &str) -> bool {
    stem.len() == 36
        && stem.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";

    fn file(extra: &str) -> String {
        format!(r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":100{extra}}}"#)
    }

    #[test]
    fn a_file_the_hook_writes_parses() {
        let text = r#"{"v":1,"session_id":"cb9fa591-1514-44d1-a31c-eba4a7cb41ed","name":null,
          "started_at":90,"launch_dir":"/home/aj/ajsoftworks","claude":{"pid":2231,"start":8717628},
          "voice":"am_michael","state":"needs_you","reason":"approve Bash",
          "needs":{"by":"","tool":"Bash"},"state_at":106,
          "where":{"repo":"klepsydra","worktree":"fleet","branch":"feat/fleet-visualizer","by":"edit","at":105},
          "touched":[{"repo":"ideas","at":95}],"prompt":{"text":"viz them","at":100},
          "reply":{"text":"That works","at":99},"error":null,"ended":null,"written_at":106}"#;
        let f = parse(text, ID).unwrap();
        assert_eq!(f.state, State::NeedsYou);
        assert_eq!(f.reason.as_deref(), Some("approve Bash"));
        assert_eq!(f.place.unwrap().worktree.as_deref(), Some("fleet"));
        assert_eq!(
            f.touched,
            vec![Touched {
                repo: "ideas".into(),
                at: 95
            }]
        );
        assert_eq!(f.written_at, Some(106));
    }

    #[test]
    fn an_unknown_version_is_rejected_whatever_else_it_holds() {
        let text = format!(r#"{{"v":2,"session_id":"{ID}","state":"teleporting"}}"#);
        assert_eq!(parse(&text, ID), Err(Rejected::Version("2".into())));
        let text = format!(r#"{{"session_id":"{ID}","state":"working","state_at":1}}"#);
        assert_eq!(parse(&text, ID), Err(Rejected::Version("missing".into())));
    }

    #[test]
    fn malformed_files_are_rejected() {
        assert!(matches!(
            parse("{\"v\":1,", ID),
            Err(Rejected::Malformed(_))
        ));
        assert!(matches!(
            parse(&file(r#","state":"x""#), ID),
            Err(Rejected::Malformed(_))
        ));
        assert!(matches!(
            parse(
                &format!(r#"{{"v":1,"session_id":"{ID}","state":"done"}}"#),
                ID
            ),
            Err(Rejected::Malformed(_))
        ));
    }

    #[test]
    fn a_file_must_be_named_for_its_session() {
        let other = "00000000-0000-4000-8000-000000000000";
        assert_eq!(parse(&file(""), other), Err(Rejected::WrongId));
    }

    #[test]
    fn beat_names() {
        assert_eq!(
            beat_name("Plan the fleet\t179235300\n").as_deref(),
            Some("Plan the fleet")
        );
        assert_eq!(beat_name("\t179235300\n"), None);
        assert_eq!(beat_name(""), None);
    }

    #[test]
    fn session_ids_are_uuids() {
        assert!(is_session_id(ID));
        assert!(is_session_id("CB9FA591-1514-44D1-A31C-EBA4A7CB41ED"));
        assert!(!is_session_id("abc-123"));
        assert!(!is_session_id("cb9fa591-1514-44d1-a31c-eba4a7cb41ed.json"));
        assert!(!is_session_id("cb9fa591x1514-44d1-a31c-eba4a7cb41ed"));
        assert!(!is_session_id("../../../../../../../../../../../etc"));
    }
}
