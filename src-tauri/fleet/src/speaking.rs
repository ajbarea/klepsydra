//! keryx's `speaking.json`: the line it is playing, matched to the card whose
//! session is speaking. keryx writes it; the reader only reads it.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::session::{MAX_TIME, MIN_TIME};
use crate::view::{Status, View};

/// The file's name in the fleet folder. Not a session id, so the scan passes
/// it over.
pub const FILE: &str = "speaking.json";
/// The only version this reader understands.
pub const VERSION: u64 = 1;
/// Envelope samples a second.
pub const RATE: f64 = 20.0;
/// A clip longer than this is a corrupt file; keryx renders a sentence at a time.
const MAX_CLIP_SECS: f64 = 600.0;
/// More than this is no `speaking.json` keryx would write.
const MAX_BYTES: u64 = 256 * 1024;
/// A line starting more than this after the reader's clock is a skewed clock
/// or a leftover file, not a line being played.
pub const START_AHEAD_SECS: f64 = 5.0;
/// How long after its end a line survives a read that failed: the wall's
/// sentence-gap hold (`SPEAK_HOLD_MS` in `src/fleet/speaking.js`).
pub const HOLD_SECS: f64 = 0.6;

/// The file as keryx writes it (`docs/speaking-signal.md` in keryx).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Signal {
    pub v: u64,
    #[serde(default)]
    pub voice: Option<String>,
    #[serde(default)]
    pub claude_pid: Option<u32>,
    #[serde(default)]
    pub claude_start: Option<u64>,
    #[serde(default)]
    pub session_id: Option<String>,
    pub started_at: f64,
    pub ends_at: f64,
    pub envelope: Vec<f64>,
}

/// The line being spoken, as the webview receives it: whose card, and the
/// loudness to pace the waves by.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Speaking {
    pub session_id: String,
    pub envelope: Vec<f64>,
    pub started_at: f64,
    pub ends_at: f64,
}

/// What is at `speaking.json` in the fleet folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Found {
    /// No file: keryx removed it (a cut-off or the end of a line), or what is
    /// there is not a regular file keryx would write (a symlink, a FIFO, a
    /// folder, one too big).
    Absent,
    /// A file that would not read: keryx's replace is best effort on Windows,
    /// and the next change re-reads it.
    Failed,
    Text(String),
}

/// `speaking.json` in `fleet`. The type is checked before opening, so a FIFO
/// is never opened and a symlink never followed.
pub fn read(fleet: &Path) -> Found {
    let path = fleet.join(FILE);
    let gone = |e: &std::io::Error| e.kind() == std::io::ErrorKind::NotFound;
    let meta = match std::fs::symlink_metadata(&path) {
        Ok(m) => m,
        Err(e) if gone(&e) => return Found::Absent,
        Err(_) => return Found::Failed,
    };
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return Found::Absent;
    }
    let mut text = String::new();
    match File::open(&path).and_then(|f| f.take(MAX_BYTES).read_to_string(&mut text)) {
        Ok(_) => Found::Text(text),
        Err(e) if gone(&e) => Found::Absent,
        Err(_) => Found::Failed,
    }
}

/// What a `speaking.json` text holds.
#[derive(Clone, Debug, PartialEq)]
pub enum Parsed {
    Line(Signal),
    /// Not JSON, or cut short: a read that caught half a write.
    Partial,
    /// Whole JSON but not a line this reader can use: another version, a
    /// missing or mistyped field, or times and levels no clip has.
    Invalid,
}

pub fn parse(text: &str) -> Parsed {
    let value: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Parsed::Partial,
    };
    let Ok(s) = serde_json::from_value::<Signal>(value) else {
        return Parsed::Invalid;
    };
    let span = s.ends_at - s.started_at;
    let sane = s.v == VERSION
        && (MIN_TIME as f64..=MAX_TIME as f64).contains(&s.started_at)
        && (0.0..=MAX_CLIP_SECS).contains(&span)
        && s.envelope.len() as f64 <= (MAX_CLIP_SECS * RATE).ceil()
        && s.envelope.iter().all(|x| x.is_finite() && *x >= 0.0);
    if sane {
        Parsed::Line(s)
    } else {
        Parsed::Invalid
    }
}

/// The card `s` belongs to: the one whose Claude process is keryx's (pid and
/// start time both), else the one with keryx's session id, else the one live
/// card wearing its voice. A voice two live cards wear names neither.
pub fn owner<'a>(s: &Signal, sessions: &'a [View]) -> Option<&'a View> {
    // One process can hold an ended session and the one `/clear` started after
    // it: keryx's session id, then a live card, settles which.
    let by_process = s.claude_pid.zip(s.claude_start).and_then(|(pid, start)| {
        let ours = |v: &&View| {
            v.claude
                .as_ref()
                .is_some_and(|c| c.pid == pid && c.start == start)
        };
        let id = s.session_id.as_deref();
        sessions
            .iter()
            .filter(ours)
            .min_by_key(|v| (Some(v.session_id.as_str()) != id, v.status == Status::Ended))
    });
    let by_id = || {
        let id = s.session_id.as_deref().filter(|id| !id.is_empty())?;
        sessions.iter().find(|v| v.session_id == id)
    };
    let by_voice = || {
        let voice = s.voice.as_deref().filter(|v| !v.is_empty())?;
        let mut wearing = sessions
            .iter()
            .filter(|v| v.status != Status::Ended && v.voice.as_deref() == Some(voice));
        let one = wearing.next()?;
        wearing.next().is_none().then_some(one)
    };
    by_process.or_else(by_id).or_else(by_voice)
}

/// What the wall shows as speaking at `now` (seconds, this machine's clock),
/// from what was `found` and the `last` line shown: nothing once the clip has
/// ended, when it starts more than `START_AHEAD_SECS` ahead, or when no card
/// owns it. A file that failed to read, or read half-written, keeps the last
/// line through its end and `HOLD_SECS`; only an absent file is a cut-off.
pub fn speaking(
    found: &Found,
    last: Option<&Speaking>,
    sessions: &[View],
    now: i64,
) -> Option<Speaking> {
    let now = now as f64;
    let keep = || {
        last.filter(|l| {
            l.ends_at + HOLD_SECS >= now && sessions.iter().any(|v| v.session_id == l.session_id)
        })
        .cloned()
    };
    let s = match found {
        Found::Absent => return None,
        Found::Failed => return keep(),
        Found::Text(text) => match parse(text) {
            Parsed::Line(s) => s,
            Parsed::Partial => return keep(),
            Parsed::Invalid => return None,
        },
    };
    if s.ends_at < now || s.started_at > now + START_AHEAD_SECS {
        return None;
    }
    let card = owner(&s, sessions)?;
    Some(Speaking {
        session_id: card.session_id.clone(),
        envelope: s.envelope.iter().map(|x| x.min(1.0)).collect(),
        started_at: s.started_at,
        ends_at: s.ends_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;
    use crate::session::Claude;
    use crate::view::Crew;

    const NOW: i64 = 1_792_520_222;

    fn card(id: &str, voice: Option<&str>, claude: Option<(u32, u64)>) -> View {
        View {
            session_id: id.into(),
            name: None,
            launch_dir: None,
            voice: voice.map(Into::into),
            status: Status::Working,
            reason: None,
            status_at: NOW,
            active_at: NOW,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            updated_at: NOW,
            quiet_since: None,
            tmux: None,
            distro: None,
            claude: claude.map(|(pid, start)| Claude { pid, start }),
            background: Crew::default(),
            marks: Default::default(),
        }
    }

    /// The contract's example, as of `NOW`.
    fn example() -> String {
        r#"{"v":1,"voice":"af_heart","terminal":"48213:9120441","claude_pid":48213,"claude_start":9120441,"session_id":"3f1c0a52-7b1e-4c0e-9a55-2f6f0d1d7a10","started_at":1792520221.2,"ends_at":1792520223.7,"envelope":[0.12,0.55,1.0,0.8,0.31]}"#.into()
    }

    fn with(edit: impl FnOnce(&mut serde_json::Value)) -> String {
        let mut v: serde_json::Value = serde_json::from_str(&example()).unwrap();
        edit(&mut v);
        v.to_string()
    }

    fn fleet() -> Vec<View> {
        vec![
            card("by-voice", Some("af_heart"), None),
            card("by-id", None, None),
            card(
                "3f1c0a52-7b1e-4c0e-9a55-2f6f0d1d7a10",
                Some("am_adam"),
                Some((1, 1)),
            ),
            card("by-process", Some("am_puck"), Some((48213, 9120441))),
        ]
    }

    fn who(text: &str, sessions: &[View]) -> Option<String> {
        speaking(&Found::Text(text.into()), None, sessions, NOW).map(|s| s.session_id)
    }

    #[test]
    fn the_contract_example_reads_whole() {
        let s = speaking(&Found::Text(example()), None, &fleet(), NOW).unwrap();
        assert_eq!(
            s,
            Speaking {
                session_id: "by-process".into(),
                envelope: vec![0.12, 0.55, 1.0, 0.8, 0.31],
                started_at: 1_792_520_221.2,
                ends_at: 1_792_520_223.7,
            }
        );
    }

    #[test]
    fn the_claude_process_wins_over_session_id_and_voice() {
        assert_eq!(who(&example(), &fleet()).as_deref(), Some("by-process"));
    }

    #[test]
    fn pid_and_start_must_both_match() {
        let mut sessions = fleet();
        sessions[3].claude = Some(Claude {
            pid: 48213,
            start: 1,
        });
        // A reused pid is another process: the session id decides.
        assert_eq!(
            who(&example(), &sessions).as_deref(),
            Some("3f1c0a52-7b1e-4c0e-9a55-2f6f0d1d7a10")
        );
    }

    #[test]
    fn a_process_that_cleared_speaks_for_its_live_session() {
        // `/clear` ended one session and started another in the same process.
        let mut old = card("old", None, Some((48213, 9120441)));
        old.status = Status::Ended;
        let new = card("new", None, Some((48213, 9120441)));
        let text = with(|v| {
            v.as_object_mut().unwrap().remove("session_id");
        });
        assert_eq!(
            who(&text, &[old.clone(), new.clone()]).as_deref(),
            Some("new")
        );
        let text = with(|v| v["session_id"] = "new".into());
        assert_eq!(
            who(&text, &[old.clone(), new.clone()]).as_deref(),
            Some("new")
        );
        let text = with(|v| v["session_id"] = "old".into());
        assert_eq!(
            who(&text, &[new, old]).as_deref(),
            Some("old"),
            "keryx's session id settles it"
        );
    }

    #[test]
    fn with_no_process_the_session_id_decides() {
        let text = with(|v| {
            v.as_object_mut().unwrap().remove("claude_pid");
            v.as_object_mut().unwrap().remove("claude_start");
        });
        assert_eq!(
            who(&text, &fleet()).as_deref(),
            Some("3f1c0a52-7b1e-4c0e-9a55-2f6f0d1d7a10")
        );
    }

    #[test]
    fn with_neither_the_voice_decides() {
        let text = with(|v| {
            let o = v.as_object_mut().unwrap();
            o.remove("claude_pid");
            o.remove("claude_start");
            o.remove("session_id");
        });
        assert_eq!(who(&text, &fleet()).as_deref(), Some("by-voice"));
        let text = with(|v| {
            v["claude_pid"] = 7.into();
            v["session_id"] = "nobody".into();
        });
        assert_eq!(
            who(&text, &fleet()).as_deref(),
            Some("by-voice"),
            "unmatched ids fall through"
        );
    }

    #[test]
    fn a_voice_two_live_cards_wear_names_neither() {
        let text = with(|v| {
            v["claude_pid"] = 7.into();
            v["session_id"] = "".into();
        });
        let mut sessions = fleet();
        sessions.push(card("twin", Some("af_heart"), None));
        assert_eq!(who(&text, &sessions), None);
        sessions[4].status = Status::Ended;
        assert_eq!(who(&text, &sessions).as_deref(), Some("by-voice"));
    }

    #[test]
    fn no_card_no_speaker() {
        let text = with(|v| {
            v["claude_pid"] = 7.into();
            v["session_id"] = "nobody".into();
            v["voice"] = "bm_george".into();
        });
        assert_eq!(who(&text, &fleet()), None);
        assert_eq!(who(&example(), &[]), None);
    }

    #[test]
    fn a_line_that_has_ended_is_not_speaking() {
        let ended = with(|v| v["ends_at"] = (NOW as f64 - 0.5).into());
        assert_eq!(who(&ended, &fleet()), None);
        let at_now = with(|v| v["ends_at"] = (NOW as f64).into());
        assert!(
            who(&at_now, &fleet()).is_some(),
            "ends at the reader's second"
        );
    }

    #[test]
    fn another_version_is_ignored() {
        for v in [0, 2] {
            assert_eq!(who(&with(|x| x["v"] = v.into()), &fleet()), None, "v {v}");
        }
        let missing = with(|x| {
            x.as_object_mut().unwrap().remove("v");
        });
        assert_eq!(who(&missing, &fleet()), None);
    }

    #[test]
    fn a_malformed_file_is_ignored() {
        let cases = [
            String::new(),
            "{half".into(),
            "[]".into(),
            with(|v| v["envelope"] = "loud".into()),
            with(|v| v["envelope"] = serde_json::json!([0.1, -0.2])),
            with(|v| v["started_at"] = "soon".into()),
            with(|v| {
                v.as_object_mut().unwrap().remove("ends_at");
            }),
            with(|v| v["ends_at"] = (1_792_520_221.0).into()),
            with(|v| v["started_at"] = 12.into()),
            with(|v| v["ends_at"] = (1_792_520_221.2 + 3600.0).into()),
            with(|v| v["claude_pid"] = (-1).into()),
        ];
        for text in cases {
            assert_eq!(
                speaking(&Found::Text(text.clone()), None, &fleet(), NOW),
                None,
                "{text}"
            );
        }
    }

    #[test]
    fn a_line_starting_more_than_five_seconds_ahead_is_ignored() {
        let at = |ahead: f64| {
            with(|v| {
                v["started_at"] = (NOW as f64 + ahead).into();
                v["ends_at"] = (NOW as f64 + ahead + 2.0).into();
            })
        };
        assert!(
            who(&at(START_AHEAD_SECS), &fleet()).is_some(),
            "exactly the slack"
        );
        assert_eq!(who(&at(START_AHEAD_SECS + 0.1), &fleet()), None);
        assert_eq!(who(&at(3600.0), &fleet()), None);
    }

    fn shown() -> Speaking {
        speaking(&Found::Text(example()), None, &fleet(), NOW).unwrap()
    }

    #[test]
    fn a_failed_or_half_read_keeps_the_last_line_through_the_hold() {
        let last = shown();
        let end = last.ends_at.ceil() as i64; // the reader's whole seconds
        for found in [Found::Failed, Found::Text(example()[..40].into())] {
            assert_eq!(
                speaking(&found, Some(&last), &fleet(), NOW),
                Some(last.clone()),
                "{found:?}"
            );
            assert_eq!(
                speaking(&found, None, &fleet(), NOW),
                None,
                "nothing to keep"
            );
            let held = (last.ends_at + HOLD_SECS).floor() as i64;
            assert!(
                speaking(&found, Some(&last), &fleet(), held).is_some(),
                "within the hold"
            );
            assert_eq!(
                speaking(&found, Some(&last), &fleet(), end + 1),
                None,
                "past the hold"
            );
            let gone: Vec<View> = fleet()
                .into_iter()
                .filter(|v| v.session_id != last.session_id)
                .collect();
            assert_eq!(
                speaking(&found, Some(&last), &gone, NOW),
                None,
                "its card is gone"
            );
        }
    }

    #[test]
    fn an_absent_or_invalid_file_ends_the_line_at_once() {
        let last = shown();
        assert_eq!(speaking(&Found::Absent, Some(&last), &fleet(), NOW), None);
        let v2 = with(|v| v["v"] = 2.into());
        assert_eq!(speaking(&Found::Text(v2), Some(&last), &fleet(), NOW), None);
    }

    #[test]
    fn half_a_file_is_partial_and_a_wrong_shape_invalid() {
        let whole = example();
        for cut in [0, 1, 20, whole.len() - 1] {
            assert_eq!(parse(&whole[..cut]), Parsed::Partial, "cut at {cut}");
        }
        assert!(matches!(parse(&whole), Parsed::Line(_)));
        for text in ["[]", r#"{"v":1}"#, &with(|v| v["v"] = 2.into())] {
            assert_eq!(parse(text), Parsed::Invalid, "{text}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_file_that_will_not_open_is_a_failed_read() {
        use std::os::unix::fs::PermissionsExt;
        let dir = Scratch::new("speaking-locked");
        dir.write(FILE, &example());
        let path = dir.0.join(FILE);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
        if File::open(&path).is_ok() {
            return; // root reads it anyway
        }
        assert_eq!(read(&dir.0), Found::Failed);
    }

    #[test]
    fn levels_above_the_loudest_are_held_to_it() {
        let text = with(|v| v["envelope"] = serde_json::json!([0.5, 1.2]));
        let s = speaking(&Found::Text(text.clone()), None, &fleet(), NOW).unwrap();
        assert_eq!(s.envelope, vec![0.5, 1.0]);
    }

    #[test]
    fn no_file_is_no_speaker() {
        assert_eq!(speaking(&Found::Absent, None, &fleet(), NOW), None);
        let dir = Scratch::new("speaking-absent");
        assert_eq!(read(&dir.0), Found::Absent);
        assert_eq!(
            read(Path::new("/nonexistent/klepsydra/fleet")),
            Found::Absent
        );
    }

    #[test]
    fn the_file_reads_from_the_fleet_folder() {
        let dir = Scratch::new("speaking-read");
        dir.write(FILE, &example());
        assert_eq!(read(&dir.0), Found::Text(example()));
        dir.write(FILE, &" ".repeat(MAX_BYTES as usize + 1));
        assert_eq!(read(&dir.0), Found::Absent, "too big to be keryx's");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_or_a_folder_is_no_file() {
        let dir = Scratch::new("speaking-link");
        dir.write("elsewhere", &example());
        std::os::unix::fs::symlink(dir.0.join("elsewhere"), dir.0.join(FILE)).unwrap();
        assert_eq!(read(&dir.0), Found::Absent);
        let dir = Scratch::new("speaking-dir");
        std::fs::create_dir(dir.0.join(FILE)).unwrap();
        assert_eq!(read(&dir.0), Found::Absent);
    }
}
