//! One session file, as the fleet hook writes it, and its heartbeat.

use serde::{Deserialize, Serialize};

/// No Claude Code session predates 2020-01-01Z or outlives 2100-01-01Z, so a
/// time outside these bounds, once the writer's clock is put right, is a
/// corrupt file.
pub const MIN_TIME: i64 = 1_577_836_800;
pub const MAX_TIME: i64 = 4_102_444_800;
/// Clocks closer than this are taken to agree; the hook stamps a file a
/// moment before it lands.
const SKEW_SLACK: i64 = 2;

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
    /// The folder the session works in: its repo's top, or its worktree's
    /// (#149). Left out when the hook did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<String>,
    /// The repo's GitHub page, from its origin. Left out for another host or none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github: Option<String>,
}

/// Whether `url` is a GitHub repo page as the hook writes one
/// (`https://github.com/OWNER/REPO`), so the walls may link it.
pub fn is_github(url: &str) -> bool {
    let plain = |s: &str| {
        !s.is_empty()
            && s.len() <= 100
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
            && s != "."
            && s != ".."
    };
    match url
        .strip_prefix("https://github.com/")
        .map(|r| r.split('/').collect::<Vec<_>>())
    {
        Some(parts) => parts.len() == 2 && parts.iter().all(|p| plain(p)),
        None => false,
    }
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
    pub at: i64,
}

/// The tmux pane a session runs in.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Tmux {
    pub socket: String,
    pub pane: String,
}

/// The Claude process a session runs as: its pid and start time (clock ticks
/// since boot, `/proc/<pid>/stat` field 22).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Claude {
    pub pid: u32,
    pub start: u64,
}

/// What a piece of background work is: a subagent, a background shell, or
/// another kind of background task (a monitor, a workflow).
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Agent,
    Shell,
    Task,
}

/// One subagent or background shell still running, and when the hook last
/// heard of it (a shell: when it started; a subagent: its last event).
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Background {
    pub id: String,
    pub kind: Kind,
    pub at: i64,
}

/// The well-formed entries of `background`: a file from before the field, or
/// an entry a newer hook shaped differently, costs only that entry.
fn lenient_background<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<Background>, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    Ok(match value {
        serde_json::Value::Array(items) => items
            .into_iter()
            .filter_map(|v| serde_json::from_value::<Background>(v).ok())
            .filter(|b| !b.id.is_empty())
            .collect(),
        _ => Vec::new(),
    })
}

/// `turns`, present in every file a counting hook wrote; a value of the wrong
/// shape counts as none ended rather than costing the file.
fn lenient_turns<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    Ok(Some(
        serde_json::Value::deserialize(d)?.as_u64().unwrap_or(0),
    ))
}

/// A live shell count, or none for a value that is not one (the file still reads).
fn lenient_shells<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    Ok(serde_json::Value::deserialize(d)?
        .as_u64()
        .and_then(|n| u32::try_from(n).ok()))
}

/// What a session waiting on AJ needs. Only whether the ask came after its
/// turn had ended (a background subagent's) is read.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct Needs {
    #[serde(default)]
    pub turn_over: Option<bool>,
}

/// `needs` when it reads as one; any other shape costs only the field.
fn lenient_needs<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Needs>, D::Error> {
    Ok(serde_json::from_value(serde_json::Value::deserialize(d)?).ok())
}

/// Where a Remote Control session can be opened: claude.ai's Claude Code
/// sessions, by an id of letters, digits, `_` and `-`. Nothing else is a
/// link the phone may follow.
pub const REMOTE_PREFIX: &str = "https://claude.ai/code/";

/// Whether `url` is a Remote Control session link.
pub fn remote_url_ok(url: &str) -> bool {
    url.strip_prefix(REMOTE_PREFIX).is_some_and(|id| {
        (1..=128).contains(&id.len())
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

/// `remote_url` when it is a Remote Control session link; anything else,
/// including a value of the wrong type, is none rather than costing the file.
fn lenient_remote_url<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(match serde_json::Value::deserialize(d)? {
        serde_json::Value::String(url) if remote_url_ok(&url) => Some(url),
        _ => None,
    })
}

/// The account a session runs on, as the hook read it from the config folder
/// Claude Code was started with: the account id and the gauge's name for it.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Account {
    pub id: String,
    pub label: String,
}

/// `account` when its id is a plain id and its label a short name; anything
/// else is none rather than costing the file.
fn lenient_account<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Account>, D::Error> {
    let a = serde_json::from_value::<Account>(serde_json::Value::deserialize(d)?).ok();
    Ok(a.filter(|a| {
        (1..=64).contains(&a.id.len())
            && a.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && (1..=80).contains(&a.label.chars().count())
            && !a.label.chars().any(char::is_control)
    }))
}

/// The kernel boot and distro a session runs on.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Host {
    pub boot: String,
    #[serde(default)]
    pub distro: Option<String>,
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
    pub started_at: Option<i64>,
    #[serde(default)]
    pub voice: Option<String>,
    /// "hold" when keryx held the voice for the session's terminal, "home"
    /// when it is the voice keryx remembers for the repo (keryx was muted).
    #[serde(default)]
    pub voice_from: Option<String>,
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
    #[serde(default)]
    pub tmux: Option<Tmux>,
    #[serde(default)]
    pub host: Option<Host>,
    #[serde(default)]
    pub claude: Option<Claude>,
    /// Subagents and background shells still running; none when absent.
    #[serde(default, deserialize_with = "lenient_background")]
    pub background: Vec<Background>,
    /// The shells Claude Code ran at the hook's last event, its Bash calls
    /// foreground and background (#167); none when /proc could not say.
    #[serde(default, deserialize_with = "lenient_shells")]
    pub shells_live: Option<u32>,
    /// How many turns have ended (Stops); None from a hook that never counted.
    #[serde(default, deserialize_with = "lenient_turns")]
    pub turns: Option<u64>,
    /// The `written_at` of the write that kept `turns`. An older hook carries
    /// both along unchanged while it moves `written_at`.
    #[serde(default)]
    pub turns_at: Option<i64>,
    /// When its latest turn began: every prompt, a background task's
    /// notification included. None from a hook that never stamped it.
    #[serde(default)]
    pub turn_at: Option<i64>,
    #[serde(default, deserialize_with = "lenient_needs")]
    pub needs: Option<Needs>,
    /// The Remote Control link the hook last read from the transcript; none
    /// while Remote Control is off.
    #[serde(default, deserialize_with = "lenient_remote_url")]
    pub remote_url: Option<String>,
    /// The account it runs on; none from a hook that never read it.
    #[serde(default, deserialize_with = "lenient_account")]
    pub account: Option<Account>,
    /// The fleet agent launch.sh started it as (its registry name), the same
    /// across the agent's relaunches; none outside the fleet.
    #[serde(default)]
    pub fleet_name: Option<String>,
    /// It runs in the orchestrator's pane on the fleet's tmux server: Heph,
    /// the only session that wears Heph's face (#172).
    #[serde(default)]
    pub orchestrator: bool,
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

/// Parse `<stem>.json`, last changed at `modified` by this machine's clock.
/// Any `v` but 1 is rejected before the fields are read, so a newer hook's
/// file never half-renders.
pub fn parse(text: &str, stem: &str, modified: i64) -> Result<SessionFile, Rejected> {
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
    file.check_times(modified)?;
    Ok(file)
}

/// Seconds to add to a time a writer stamped as `written` to put it on this
/// machine's clock, given that the file it wrote last changed at `modified`
/// by this clock. Every file a hook writes and the reader times goes through it.
pub fn skew(written: i64, modified: i64) -> i64 {
    let d = modified.saturating_sub(written);
    if d.saturating_abs() > SKEW_SLACK {
        d
    } else {
        0
    }
}

impl SessionFile {
    /// Seconds to add to the hook's times to put them on this machine's clock.
    /// The hook stamps `written_at` just before it writes, and the filesystem
    /// stamps the write by this machine's clock, so the difference is how far
    /// the two clocks disagree (a Linux guest's drifts after the host sleeps).
    pub fn skew(&self, modified: i64) -> i64 {
        self.written_at.map_or(0, |w| skew(w, modified))
    }

    /// `turns`, if the last write kept it: a counting hook stamps it with the
    /// write's time; an older hook's write leaves the stamp behind.
    pub fn counted_turns(&self) -> Option<u64> {
        self.turns
            .filter(|_| self.turns_at.is_some() && self.turns_at == self.written_at)
    }

    /// A consistently wrong writer clock is what the skew corrects; only a
    /// time still out of range once corrected marks the file as corrupt.
    fn check_times(&self, modified: i64) -> Result<(), Rejected> {
        let shift = self.skew(modified);
        let times = [
            ("state_at", Some(self.state_at)),
            ("written_at", self.written_at),
            ("where.at", self.place.as_ref().map(|p| p.at)),
            ("prompt.at", self.prompt.as_ref().map(|s| s.at)),
            ("reply.at", self.reply.as_ref().map(|s| s.at)),
            ("ended.at", self.ended.as_ref().map(|e| e.at)),
            ("turn_at", self.turn_at),
        ]
        .into_iter()
        .chain(self.touched.iter().map(|t| ("touched.at", Some(t.at))));
        for (field, t) in times {
            if let Some(t) = t.filter(|t| !(MIN_TIME..=MAX_TIME).contains(&t.saturating_add(shift)))
            {
                return Err(Rejected::Malformed(format!("{field} {t} is out of range")));
            }
        }
        Ok(())
    }
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

    #[test]
    fn a_github_page_is_a_plain_owner_and_repo() {
        let long = format!("https://github.com/a/{}", "b".repeat(101));
        let longest = format!("https://github.com/a/{}", "b".repeat(100));
        for (url, ok) in [
            ("https://github.com/ajbarea/klepsydra", true),
            ("https://github.com/a.b/c_d-e", true),
            (longest.as_str(), true),
            (long.as_str(), false),
            ("https://github.com/a/b/c", false),
            ("https://github.com/a", false),
            ("https://github.com/../b", false),
            ("https://github.com/a/.", false),
            ("https://github.com/a/b c", false),
            ("https://github.com/a/b%20c", false),
            ("https://github.com//b", false),
            ("http://github.com/a/b", false),
            ("https://github.com.evil/a/b", false),
        ] {
            assert_eq!(is_github(url), ok, "{url}");
        }
    }

    const ID: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
    /// When the test files last changed, by the reader's clock.
    const MODIFIED: i64 = 1_800_000_110;

    fn parse(text: &str, stem: &str) -> Result<SessionFile, Rejected> {
        super::parse(text, stem, MODIFIED)
    }

    fn file(extra: &str) -> String {
        format!(r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":1800000100{extra}}}"#)
    }

    #[test]
    fn tmux_and_host_parse_and_are_optional() {
        let with = r#"{"v":1,"session_id":"11111111-2222-4333-8444-555555555555","state":"working","state_at":1800000000,
            "tmux":{"socket":"/tmp/s","pane":"%3"},"host":{"boot":"b","distro":null}}"#;
        let f: SessionFile = serde_json::from_str(with).unwrap();
        assert_eq!(f.tmux.unwrap().pane, "%3");
        assert_eq!(f.host.unwrap().distro, None);
        let without = r#"{"v":1,"session_id":"11111111-2222-4333-8444-555555555555","state":"working","state_at":1800000000}"#;
        let f: SessionFile = serde_json::from_str(without).unwrap();
        assert_eq!((f.tmux, f.host), (None, None));
    }

    #[test]
    fn claude_parses_and_null_or_missing_is_none() {
        let base = |extra: &str| {
            format!(
                r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":1800000100{extra}}}"#
            )
        };
        let f = parse(&base(r#","claude":{"pid":2231,"start":8717628}"#), ID).unwrap();
        assert_eq!(
            f.claude,
            Some(Claude {
                pid: 2231,
                start: 8_717_628
            })
        );
        assert_eq!(parse(&base(r#","claude":null"#), ID).unwrap().claude, None);
        assert_eq!(parse(&base(""), ID).unwrap().claude, None);
    }

    #[test]
    fn turns_is_none_only_from_a_hook_that_never_counted() {
        let with = |extra: &str| {
            let text = format!(
                r#"{{"v":1,"session_id":"{ID}","state":"done","state_at":1800000100{extra}}}"#
            );
            parse(&text, ID).unwrap().turns
        };
        assert_eq!(with(""), None);
        assert_eq!(with(r#","turns":3"#), Some(3));
        for odd in [
            r#","turns":null"#,
            r#","turns":1.5"#,
            r#","turns":"x""#,
            r#","turns":-1"#,
        ] {
            assert_eq!(with(odd), Some(0), "{odd}");
        }
    }

    #[test]
    fn a_count_an_older_hook_carried_along_is_not_trusted() {
        let with = |extra: &str| {
            let text = format!(
                r#"{{"v":1,"session_id":"{ID}","state":"done","state_at":1800000100,"written_at":1800000100{extra}}}"#
            );
            parse(&text, ID).unwrap().counted_turns()
        };
        assert_eq!(with(r#","turns":3,"turns_at":1800000100"#), Some(3));
        assert_eq!(with(r#","turns":3,"turns_at":1800000050"#), None);
        assert_eq!(with(r#","turns":3"#), None);
        assert_eq!(with(""), None);
    }

    #[test]
    fn a_file_the_hook_writes_parses() {
        let text = r#"{"v":1,"session_id":"cb9fa591-1514-44d1-a31c-eba4a7cb41ed","name":null,
          "started_at":1800000090,"launch_dir":"/home/aj/ajsoftworks","claude":{"pid":2231,"start":8717628},
          "voice":"am_michael","voice_from":"home","state":"needs_you","reason":"approve Bash",
          "needs":{"by":"","tool":"Bash"},"state_at":1800000106,
          "where":{"repo":"klepsydra","worktree":"fleet","branch":"feat/fleet-visualizer","by":"edit","at":1800000105},
          "touched":[{"repo":"ideas","at":1800000095}],"prompt":{"text":"viz them","at":1800000100},
          "reply":{"text":"That works","at":1800000099},"error":null,"ended":null,"written_at":1800000106}"#;
        let f = parse(text, ID).unwrap();
        assert_eq!(f.state, State::NeedsYou);
        assert_eq!(f.started_at, Some(1_800_000_090));
        assert_eq!(f.voice_from.as_deref(), Some("home"));
        assert_eq!(f.reason.as_deref(), Some("approve Bash"));
        assert_eq!(f.place.unwrap().worktree.as_deref(), Some("fleet"));
        assert_eq!(
            f.touched,
            vec![Touched {
                repo: "ideas".into(),
                at: 1_800_000_095
            }]
        );
        assert_eq!(f.written_at, Some(1_800_000_106));
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
    fn impossible_times_are_rejected() {
        for bad in [i64::MIN, i64::MAX, 0, MIN_TIME - 1, MAX_TIME + 1] {
            for field in [
                format!(r#","where":{{"repo":"r","at":{bad}}}"#),
                format!(r#","touched":[{{"repo":"r","at":{bad}}}]"#),
                format!(r#","prompt":{{"text":"p","at":{bad}}}"#),
                format!(r#","reply":{{"text":"p","at":{bad}}}"#),
                format!(r#","ended":{{"at":{bad}}}"#),
            ] {
                assert!(
                    matches!(parse(&file(&field), ID), Err(Rejected::Malformed(_))),
                    "{field}"
                );
            }
            let text =
                format!(r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":{bad}}}"#);
            assert!(matches!(parse(&text, ID), Err(Rejected::Malformed(_))));
        }
        let ok = file(&format!(r#","prompt":{{"text":"p","at":{MIN_TIME}}}"#));
        assert!(parse(&ok, ID).is_ok());
        let ok = file(&format!(r#","prompt":{{"text":"p","at":{MAX_TIME}}}"#));
        assert!(parse(&ok, ID).is_ok());
    }

    #[test]
    fn a_wrong_writer_clock_is_corrected_not_rejected() {
        // The writer's clock reads 1000 s into 1970; the reader's is right.
        let text = format!(
            r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":1000,"written_at":1000,"prompt":{{"text":"p","at":990}}}}"#
        );
        assert!(super::parse(&text, ID, MODIFIED).is_ok());
        // Wrong by years the other way.
        let text = text
            .replace("1000", "4000000000")
            .replace("990", "3999999990");
        assert!(super::parse(&text, ID, MODIFIED).is_ok());
    }

    #[test]
    fn a_time_still_impossible_once_corrected_is_rejected() {
        for w in [i64::MIN, i64::MAX] {
            let text = file(&format!(r#","written_at":{w}"#));
            assert!(
                matches!(parse(&text, ID), Err(Rejected::Malformed(_))),
                "{w}"
            );
        }
        // A field far from written_at is far from now, whatever the clock.
        let text = format!(
            r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":1000,"written_at":1000,"reply":{{"text":"r","at":-3000000000}}}}"#
        );
        assert!(matches!(
            super::parse(&text, ID, MODIFIED),
            Err(Rejected::Malformed(_))
        ));
    }

    #[test]
    fn background_parses_and_an_old_file_has_none() {
        let f = parse(
            &file(r#","background":[{"id":"abd38d40cac785715","kind":"agent","at":1800000101},{"id":"biwpk3ab6","kind":"shell","at":1800000102}]"#),
            ID,
        )
        .unwrap();
        assert_eq!(
            f.background,
            vec![
                Background {
                    id: "abd38d40cac785715".into(),
                    kind: Kind::Agent,
                    at: 1_800_000_101
                },
                Background {
                    id: "biwpk3ab6".into(),
                    kind: Kind::Shell,
                    at: 1_800_000_102
                },
            ]
        );
        assert_eq!(parse(&file(""), ID).unwrap().background, vec![]);
    }

    #[test]
    fn a_task_of_another_type_is_kept_as_a_task() {
        let f = parse(
            &file(r#","background":[{"id":"m1","kind":"task","at":1800000101}]"#),
            ID,
        )
        .unwrap();
        assert_eq!(
            f.background.iter().map(|b| b.kind).collect::<Vec<_>>(),
            vec![Kind::Task]
        );
    }

    #[test]
    fn the_account_is_kept_only_when_it_is_a_plain_id_and_short_name() {
        let account = |extra: &str| parse(&file(extra), ID).unwrap().account;
        assert_eq!(
            account(
                r#","account":{"id":"96130a18-106b-49a2-9b8e-a0b4d52aa214","label":"RIT-CS-DQL"}"#
            ),
            Some(Account {
                id: "96130a18-106b-49a2-9b8e-a0b4d52aa214".into(),
                label: "RIT-CS-DQL".into()
            })
        );
        assert_eq!(account(""), None);
        for bad in [
            r#","account":null"#,
            r#","account":"Personal""#,
            r#","account":{"id":"../x","label":"P"}"#,
            r#","account":{"id":"a","label":""}"#,
            r#","account":{"id":"a","label":"a\nb"}"#,
            r#","account":{"id":"a"}"#,
            r#","account":{"id":7,"label":"P"}"#,
        ] {
            assert_eq!(account(bad), None, "{bad}");
        }
        let long = format!(r#","account":{{"id":"a","label":"{}"}}"#, "x".repeat(81));
        assert_eq!(account(&long), None);
    }

    #[test]
    fn a_malformed_background_entry_costs_only_itself() {
        let f = parse(
            &file(r#","background":[{"id":"ok","kind":"shell","at":1800000101},"junk",null,
                {"id":"","kind":"agent","at":1800000101},{"id":"x","kind":"cron","at":1800000101},
                {"id":"y","kind":"agent","at":"soon"},{"id":7,"kind":"agent","at":1800000101},{"kind":"agent","at":1}]"#),
            ID,
        )
        .unwrap();
        assert_eq!(
            f.background
                .iter()
                .map(|b| b.id.as_str())
                .collect::<Vec<_>>(),
            vec!["ok"]
        );
        for other in [
            r#","background":null"#,
            r#","background":"none""#,
            r#","background":{"id":"a"}"#,
        ] {
            assert_eq!(
                parse(&file(other), ID).unwrap().background,
                vec![],
                "{other}"
            );
        }
    }

    #[test]
    fn only_a_remote_control_link_is_kept() {
        let url = |extra: &str| parse(&file(extra), ID).unwrap().remote_url;
        assert_eq!(url(""), None, "a file from before the field");
        assert_eq!(url(r#","remote_url":null"#), None);
        assert_eq!(
            url(r#","remote_url":"https://claude.ai/code/session_01AbC-x_9""#),
            Some("https://claude.ai/code/session_01AbC-x_9".into())
        );
        for bad in [
            r#"1"#,
            r#"{"url":"https://claude.ai/code/session_01"}"#,
            r#""""#,
            r#""https://claude.ai/code/""#,
            r#""http://claude.ai/code/session_01""#,
            r#""https://claude.ai.evil.example/code/session_01""#,
            r#""https://evil.example/https://claude.ai/code/session_01""#,
            r#""https://claude.ai/code/session_01?next=https://evil.example""#,
            r#""https://claude.ai/code/session_01/../../settings""#,
            r#""https://claude.ai/code/session_01#x""#,
            r#""javascript:alert(1)//https://claude.ai/code/x""#,
            r#""HTTPS://CLAUDE.AI/code/session_01""#,
        ] {
            let f = parse(&file(&format!(r#","remote_url":{bad}"#)), ID);
            assert_eq!(f.map(|f| f.remote_url), Ok(None), "{bad}");
        }
        let long = format!(
            r#","remote_url":"https://claude.ai/code/{}""#,
            "a".repeat(129)
        );
        assert_eq!(url(&long), None);
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
