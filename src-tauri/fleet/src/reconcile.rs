//! Checking a day's ledger against what Claude Code wrote to its own
//! transcripts: the transcripts hold the usage of every API call the session
//! made, so a session whose ledger counts fewer cache tokens than they do lost
//! exports, and so did one missing from the ledger that ran only while the
//! receiver was down. The ledger counts more, as it also sees calls that
//! never reach a transcript, so higher is only reported.

use std::collections::{BTreeMap, BTreeSet};
use std::io::BufRead;
use std::path::{Path, PathBuf};

use jiff::tz::TimeZone;
use jiff::Timestamp;
use serde::Deserialize;

use crate::ledger::{day_name, Day, Gap, Tokens, ALIVE_EVERY};

/// How far below the transcripts the ledger may be on cache tokens before the
/// session is flagged, in percent. Rounding and the odd message that never
/// finished streaming stay inside it.
pub const LOST_PERCENT: u64 = 2;

/// How far outside a receiver gap a message may lie and still have been
/// exported during it: a gap's ends are known to `ALIVE_EVERY`, and a
/// message's export follows it within one interval.
// The interval is OTEL_METRIC_EXPORT_INTERVAL=15000 ms; 60 s rounds it up with margin.
pub const GAP_SLACK: i64 = ALIVE_EVERY + 60;

#[derive(Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
}

impl Usage {
    fn tokens(&self) -> Tokens {
        Tokens {
            input: self.input_tokens.unwrap_or(0),
            output: self.output_tokens.unwrap_or(0),
            cache_read: self.cache_read_input_tokens.unwrap_or(0),
            cache_creation: self.cache_creation_input_tokens.unwrap_or(0),
        }
    }
}

/// Each field's larger value: a message streams as several lines whose usage
/// grows, so the largest is the finished one.
fn field_max(a: &Tokens, b: &Tokens) -> Tokens {
    Tokens {
        input: a.input.max(b.input),
        output: a.output.max(b.output),
        cache_read: a.cache_read.max(b.cache_read),
        cache_creation: a.cache_creation.max(b.cache_creation),
    }
}

fn add(a: &mut Tokens, b: &Tokens) {
    a.input = a.input.saturating_add(b.input);
    a.output = a.output.saturating_add(b.output);
    a.cache_read = a.cache_read.saturating_add(b.cache_read);
    a.cache_creation = a.cache_creation.saturating_add(b.cache_creation);
}

/// What the transcripts say one day's sessions used.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Transcripts {
    pub sessions: BTreeMap<String, Tokens>,
    /// Per session, the epoch seconds of each counted message line.
    pub times: BTreeMap<String, BTreeSet<i64>>,
    /// Files read.
    pub files: usize,
    /// Lines that were not JSON, such as one cut off mid-write.
    pub malformed: usize,
}

/// Every transcript file under `root` (`<project>/<session>.jsonl` and
/// `<project>/<session>/subagents/*.jsonl`) with the session it belongs to.
fn transcript_files(root: &Path) -> Vec<(PathBuf, String)> {
    let mut out = Vec::new();
    let Ok(projects) = std::fs::read_dir(root) else {
        return out;
    };
    for project in projects.flatten() {
        let Ok(entries) = std::fs::read_dir(project.path()) else {
            continue;
        };
        for e in entries.flatten() {
            let path = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if let Some(id) = name.strip_suffix(".jsonl") {
                out.push((path, id.to_string()));
            } else if path.is_dir() {
                let Ok(subs) = std::fs::read_dir(path.join("subagents")) else {
                    continue;
                };
                for s in subs.flatten() {
                    if s.file_name().to_string_lossy().ends_with(".jsonl") {
                        out.push((s.path(), name.clone()));
                    }
                }
            }
        }
    }
    out.sort();
    out
}

/// The transcripts under each of `roots`, counting the messages stamped on
/// `day` (`YYYY-MM-DD`) in `tz`. A message is counted once per session, at
/// its largest usage; a subagent's belong to the session its file sits under,
/// unless a line names another.
pub fn read_transcripts(roots: &[PathBuf], day: &str, tz: &TimeZone) -> Transcripts {
    let mut out = Transcripts::default();
    let mut messages: BTreeMap<(String, String), Tokens> = BTreeMap::new();
    for root in roots {
        for (path, file_session) in transcript_files(root) {
            let Ok(file) = std::fs::File::open(&path) else {
                continue;
            };
            out.files += 1;
            for text in std::io::BufReader::new(file).lines() {
                let Ok(text) = text else {
                    out.malformed += 1;
                    continue;
                };
                if text.trim().is_empty() {
                    continue;
                }
                let line: Line = match serde_json::from_str(&text) {
                    Ok(l) => l,
                    Err(_) => {
                        // Valid JSON of another shape is not ours to count.
                        if serde_json::from_str::<serde::de::IgnoredAny>(&text).is_err() {
                            out.malformed += 1;
                        }
                        continue;
                    }
                };
                if line.kind.as_deref() != Some("assistant") {
                    continue;
                }
                let (
                    Some(at),
                    Some(Message {
                        id: Some(id),
                        usage: Some(usage),
                    }),
                ) = (line.timestamp.as_deref(), line.message)
                else {
                    continue;
                };
                let Ok(at) = at.parse::<Timestamp>() else {
                    out.malformed += 1;
                    continue;
                };
                let at = at.as_second();
                if day_name(at, tz) != day {
                    continue;
                }
                let session = line.session_id.unwrap_or_else(|| file_session.clone());
                let tokens = usage.tokens();
                // A synthetic line with zero usage says nothing about telemetry.
                if KINDS.iter().any(|(_, get)| get(&tokens) > 0) {
                    out.times.entry(session.clone()).or_default().insert(at);
                }
                messages
                    .entry((session, id))
                    .and_modify(|t| *t = field_max(t, &tokens))
                    .or_insert(tokens);
            }
        }
    }
    for ((session, _), tokens) in messages {
        add(out.sessions.entry(session).or_default(), &tokens);
    }
    out
}

/// One session on both sides; a side that has no entry for it is None.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub session: String,
    pub ledger: Option<Tokens>,
    pub transcript: Option<Tokens>,
    /// Missing from the ledger, every one of its transcript messages lies in
    /// a time the receiver was not listening, give or take `GAP_SLACK`.
    pub receiver_down: bool,
}

/// Reads one token kind out of `Tokens`.
pub type Field = fn(&Tokens) -> u64;

/// The four token kinds a row compares, with the field of each.
pub const KINDS: [(&str, Field); 4] = [
    ("input", |t| t.input),
    ("output", |t| t.output),
    ("cache_read", |t| t.cache_read),
    ("cache_creation", |t| t.cache_creation),
];

/// Whether `ledger` is more than `LOST_PERCENT` below `transcript`.
fn lower(ledger: u64, transcript: u64) -> bool {
    transcript > ledger
        && u128::from(transcript - ledger) * 100 > u128::from(transcript) * u128::from(LOST_PERCENT)
}

impl Row {
    /// The ledger's difference from the transcript, in percent; None when the
    /// transcript has none of this kind to compare to.
    pub fn percent(&self, get: Field) -> Option<f64> {
        let t = get(self.transcript.as_ref()?);
        let l = self.ledger.as_ref().map_or(0, get);
        (t > 0).then(|| (l as f64 - t as f64) / t as f64 * 100.0)
    }

    /// Why the ledger lost exports, if it did: it has the session and is
    /// more than `LOST_PERCENT` lower on cache read or cache creation
    /// ("ledger lower"), or it has none of a session that used tokens while
    /// the receiver was down ("receiver down").
    pub fn lost_reason(&self) -> Option<&'static str> {
        match (&self.ledger, &self.transcript) {
            (Some(l), Some(t)) => (lower(l.cache_read, t.cache_read)
                || lower(l.cache_creation, t.cache_creation))
            .then_some("ledger lower"),
            (None, Some(_)) => (self.receiver_down && self.used()).then_some("receiver down"),
            _ => None,
        }
    }

    /// Whether the ledger lost exports of this session.
    pub fn lost(&self) -> bool {
        self.lost_reason().is_some()
    }

    fn used(&self) -> bool {
        self.transcript
            .as_ref()
            .is_some_and(|t| KINDS.iter().any(|(_, get)| get(t) > 0))
    }

    /// Whether the session used tokens, is not in the ledger at all, and ran
    /// in no receiver gap: it never exported, as when it started without the
    /// telemetry settings.
    pub fn no_telemetry(&self) -> bool {
        self.ledger.is_none() && !self.receiver_down && self.used()
    }
}

/// A day's ledger set against its transcripts.
#[derive(Debug, PartialEq, Eq)]
pub struct Report {
    pub day: String,
    pub rows: Vec<Row>,
    pub files: usize,
    pub malformed: usize,
}

/// Pair each session of `day`'s ledger with its transcripts', by session id,
/// given the `gaps` in which the receiver was not listening.
pub fn compare(day: &Day, transcripts: Transcripts, gaps: &[Gap]) -> Report {
    let mut rows: BTreeMap<String, Row> = BTreeMap::new();
    for (id, t) in &day.sessions {
        rows.insert(
            id.clone(),
            Row {
                session: id.clone(),
                ledger: Some(t.tokens.clone()),
                transcript: None,
                receiver_down: false,
            },
        );
    }
    let in_gap = |at: i64| {
        gaps.iter()
            .any(|g| g.overlaps(at - GAP_SLACK, at + GAP_SLACK))
    };
    for (id, t) in transcripts.sessions {
        let times = transcripts.times.get(&id);
        let row = rows.entry(id.clone()).or_insert_with(|| Row {
            session: id,
            ledger: None,
            transcript: None,
            receiver_down: false,
        });
        row.transcript = Some(t);
        row.receiver_down = row.ledger.is_none()
            && times.is_some_and(|ts| !ts.is_empty() && ts.iter().all(|&at| in_gap(at)));
    }
    Report {
        day: day.day.clone(),
        rows: rows.into_values().collect(),
        files: transcripts.files,
        malformed: transcripts.malformed,
    }
}

impl Report {
    /// The sessions whose ledger lost exports.
    pub fn lost(&self) -> Vec<&Row> {
        self.rows.iter().filter(|r| r.lost()).collect()
    }

    /// The sessions with transcript usage and no ledger entry.
    pub fn no_telemetry(&self) -> Vec<&Row> {
        self.rows.iter().filter(|r| r.no_telemetry()).collect()
    }

    /// The table `ledger-verify` prints.
    pub fn render(&self) -> String {
        let mut out = format!(
            "ledger vs transcripts, {} ({} sessions, {} transcript files, {} malformed lines skipped)\n",
            self.day,
            self.rows.len(),
            self.files,
            self.malformed
        );
        for row in &self.rows {
            let state = match (&row.ledger, &row.transcript) {
                (None, _) if row.lost() => "  LOST (receiver down)",
                (_, _) if row.lost() => "  LEDGER LOWER",
                (Some(_), None) => "  ledger only",
                (None, Some(_)) => "  sent no telemetry",
                _ => "",
            };
            out.push_str(&format!("\n{}{state}\n", row.session));
            out.push_str(&format!(
                "  {:<15}{:>14}{:>14}{:>10}\n",
                "", "ledger", "transcripts", "diff"
            ));
            for (name, get) in KINDS {
                let cell =
                    |t: &Option<Tokens>| t.as_ref().map_or("-".to_string(), |t| get(t).to_string());
                let diff = row
                    .percent(get)
                    .map_or("-".to_string(), |p| format!("{p:+.1}%"));
                out.push_str(&format!(
                    "  {:<15}{:>14}{:>14}{:>10}\n",
                    name,
                    cell(&row.ledger),
                    cell(&row.transcript),
                    diff
                ));
            }
        }
        let lost = self.lost();
        if !lost.is_empty() {
            out.push_str("\nlost exports:\n");
            for r in &lost {
                let reason = r.lost_reason().unwrap_or_default();
                out.push_str(&format!("  {} ({reason})\n", r.session));
            }
        }
        let silent = self.no_telemetry();
        if !silent.is_empty() {
            out.push_str("\nsent no telemetry (started without the telemetry settings):\n");
            for r in &silent {
                out.push_str(&format!("  {}\n", r.session));
            }
        }
        out.push_str(&format!(
            "\n{} lost exports (ledger more than {LOST_PERCENT}% lower on cache_read or cache_creation, or missing while the receiver was down); {} sent no telemetry (started without the telemetry settings); {} sessions\n",
            lost.len(),
            silent.len(),
            self.rows.len()
        ));
        out
    }
}

/// Read `<ledger_dir>/<day>.json`.
pub fn read_day(ledger_dir: &Path, day: &str) -> Result<Day, String> {
    let path = ledger_dir.join(format!("{day}.json"));
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ledger::{Gap, Totals};
    use crate::scan::tests::Scratch;

    const DAY: &str = "2026-10-06";

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/transcripts")
    }

    fn id(n: u32) -> String {
        format!("00000000-0000-4000-8000-{n:012}")
    }

    fn new_york() -> TimeZone {
        TimeZone::get("America/New_York").unwrap()
    }

    fn tokens(input: u64, output: u64, cache_read: u64, cache_creation: u64) -> Tokens {
        Tokens {
            input,
            output,
            cache_read,
            cache_creation,
        }
    }

    fn recorded() -> Transcripts {
        read_transcripts(&[fixtures().join("projects")], DAY, &new_york())
    }

    fn line(session: &str, msg: &str, at: &str, usage: [u64; 4]) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{at}","sessionId":"{session}","message":{{"id":"{msg}","model":"m","usage":{{"input_tokens":{},"output_tokens":{},"cache_read_input_tokens":{},"cache_creation_input_tokens":{}}}}}}}"#,
            usage[0], usage[1], usage[2], usage[3]
        )
    }

    /// A transcript root with `files` as (path under the project, lines).
    fn root(name: &str, files: &[(&str, Vec<String>)]) -> (Scratch, PathBuf) {
        let s = Scratch::new(name);
        for (path, lines) in files {
            let p = s.0.join("projects/p").join(path);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        }
        let r = s.0.join("projects");
        (s, r)
    }

    #[test]
    fn the_recorded_transcripts_count_the_largest_usage_per_message() {
        let t = recorded();
        // Session 1: a message streamed as four lines, and a subagent's whose
        // output grew from 3 to 198 tokens.
        assert_eq!(t.sessions[&id(1)], tokens(45, 1627, 107_721, 44_796));
        assert_eq!(t.sessions[&id(2)], tokens(17, 720, 50_207, 17_659));
        assert_eq!(t.sessions[&id(4)], tokens(17, 523, 50_217, 17_689));
        assert_eq!(t.files, 5);
    }

    #[test]
    fn each_session_keeps_its_message_times() {
        let at = |s: &str| s.parse::<Timestamp>().unwrap().as_second();
        let t = recorded();
        // Its assistant messages, not the user's first line at 10:47:49Z.
        let four = &t.times[&id(4)];
        assert_eq!(four.first(), Some(&at("2026-10-06T10:47:51Z")));
        assert_eq!(four.last(), Some(&at("2026-10-06T10:47:55Z")));
        // Only the messages counted on the day: session 3's 03:59:59Z line
        // falls on Oct 5 in New York.
        assert_eq!(t.times[&id(3)].first(), Some(&at("2026-10-06T04:00:00Z")));
    }

    #[test]
    fn a_message_with_no_usage_has_no_time() {
        // Claude Code writes synthetic assistant lines with an id and zero usage.
        let (_s, r) = root(
            "reconcile-zero-usage",
            &[(
                "s.jsonl",
                vec![
                    line("s", "a", "2026-10-06T12:00:00Z", [0, 5, 0, 0]),
                    line("s", "b", "2026-10-06T13:00:00Z", [0, 0, 0, 0]),
                ],
            )],
        );
        let t = read_transcripts(&[r], DAY, &new_york());
        let at = |s: &str| s.parse::<Timestamp>().unwrap().as_second();
        assert_eq!(
            t.times["s"].iter().copied().collect::<Vec<_>>(),
            vec![at("2026-10-06T12:00:00Z")]
        );
    }

    #[test]
    fn a_cut_off_line_is_skipped_and_counted() {
        assert_eq!(recorded().malformed, 1);
    }

    #[test]
    fn the_day_is_the_local_day_of_each_timestamp() {
        // Session 3 has a message at 03:59:59.9Z and one at 04:00:00Z on Oct 6:
        // New York's midnight is 04:00Z.
        let ny = recorded().sessions[&id(3)].clone();
        assert_eq!(ny, tokens(34, 594, 92_647, 43_148));
        let utc = read_transcripts(&[fixtures().join("projects")], DAY, &TimeZone::UTC);
        assert!(
            utc.sessions[&id(3)].input > ny.input,
            "in UTC both lines fall on Oct 6"
        );
        let before = read_transcripts(&[fixtures().join("projects")], "2026-10-05", &new_york());
        assert_eq!(before.sessions.len(), 1, "only the 03:59:59Z line");
        assert_eq!(before.sessions[&id(3)].input, 9);
    }

    #[test]
    fn a_subagent_counts_for_its_parent_and_a_named_session_wins() {
        let at = "2026-10-06T12:00:00Z";
        let (_s, r) = root(
            "recon-sub",
            &[
                ("main.jsonl", vec![line("main", "m1", at, [1, 2, 3, 4])]),
                (
                    "main/subagents/agent-1.jsonl",
                    vec![
                        // No sessionId: the file's parent. The same id again, bigger.
                        line("main", "s1", at, [1, 1, 1, 1]),
                        line("main", "s1", at, [1, 5, 1, 1]),
                    ],
                ),
                (
                    "main/subagents/agent-2.jsonl",
                    vec![line("other", "o1", at, [7, 7, 7, 7])],
                ),
            ],
        );
        let t = read_transcripts(&[r], DAY, &TimeZone::UTC);
        assert_eq!(t.sessions["main"], tokens(2, 7, 4, 5));
        assert_eq!(t.sessions["other"], tokens(7, 7, 7, 7));
    }

    #[test]
    fn the_largest_value_is_taken_per_field_not_per_line() {
        let at = "2026-10-06T12:00:00Z";
        let (_s, r) = root(
            "recon-max",
            &[(
                "s.jsonl",
                vec![
                    line("s", "m", at, [1, 100, 5, 0]),
                    line("s", "m", at, [1, 3, 9, 0]),
                    // The same id in another session is another message.
                    line("t", "m", at, [4, 4, 4, 4]),
                ],
            )],
        );
        let t = read_transcripts(&[r], DAY, &TimeZone::UTC);
        assert_eq!(t.sessions["s"], tokens(1, 100, 9, 0));
        assert_eq!(t.sessions["t"], tokens(4, 4, 4, 4));
    }

    #[test]
    fn lines_that_are_not_assistant_usage_are_ignored_not_malformed() {
        let at = "2026-10-06T12:00:00Z";
        let (_s, r) = root(
            "recon-other",
            &[(
                "s.jsonl",
                vec![
                    r#"{"type":"user","message":"hello","timestamp":"2026-10-06T12:00:00Z"}"#.into(),
                    r#"[1,2]"#.into(),
                    r#"{"type":"assistant","timestamp":"2026-10-06T12:00:00Z","sessionId":"s","message":{"id":"x"}}"#.into(),
                    String::new(),
                    line("s", "m", at, [1, 1, 1, 1]),
                ],
            )],
        );
        let t = read_transcripts(&[r], DAY, &TimeZone::UTC);
        assert_eq!((t.malformed, t.sessions.len()), (0, 1));
    }

    fn day_of(sessions: &[(&str, Tokens)]) -> Day {
        Day {
            day: DAY.into(),
            sessions: sessions
                .iter()
                .map(|(id, t)| {
                    (
                        (*id).to_string(),
                        Totals {
                            tokens: t.clone(),
                            ..Totals::default()
                        },
                    )
                })
                .collect(),
            ..Day::default()
        }
    }

    fn one(ledger: Tokens, transcript: Tokens) -> Row {
        Row {
            session: "s".into(),
            ledger: Some(ledger),
            transcript: Some(transcript),
            receiver_down: false,
        }
    }

    #[test]
    fn two_percent_lower_is_the_edge_and_only_cache_counts() {
        let t = tokens(100, 100, 1000, 1000);
        // Exactly 2% lower passes, a hair more fails, on either cache kind.
        assert!(!one(tokens(100, 100, 980, 1000), t.clone()).lost());
        assert!(one(tokens(100, 100, 979, 1000), t.clone()).lost());
        assert!(!one(tokens(100, 100, 1000, 980), t.clone()).lost());
        assert!(one(tokens(100, 100, 1000, 979), t.clone()).lost());
        // Input and output may be as low as they like.
        assert!(!one(tokens(0, 0, 1000, 1000), t.clone()).lost());
    }

    #[test]
    fn a_higher_ledger_is_reported_not_flagged() {
        let t = tokens(5, 100, 1000, 1000);
        let row = one(tokens(5000, 130, 1080, 1000), t);
        assert!(!row.lost());
        assert_eq!(row.percent(|t| t.output), Some(30.0));
        assert_eq!(row.percent(|t| t.cache_read), Some(8.0));
    }

    #[test]
    fn nothing_to_compare_is_neither_a_difference_nor_a_loss() {
        let row = one(tokens(1, 1, 5, 5), tokens(0, 0, 0, 0));
        assert_eq!(row.percent(|t| t.cache_read), None);
        assert!(!row.lost());
    }

    #[test]
    fn a_session_missing_from_either_side() {
        let report = compare(
            &day_of(&[
                ("both", tokens(1, 1, 100, 100)),
                ("ledger-only", tokens(1, 1, 9, 9)),
            ]),
            Transcripts {
                sessions: BTreeMap::from([
                    ("both".into(), tokens(1, 1, 100, 100)),
                    ("transcript-only".into(), tokens(1, 1, 50, 0)),
                    ("silent".into(), tokens(1, 1, 0, 0)),
                    ("empty".into(), tokens(0, 0, 0, 0)),
                ]),
                files: 3,
                ..Transcripts::default()
            },
            &[],
        );
        let names: Vec<_> = report.rows.iter().map(|r| r.session.as_str()).collect();
        assert_eq!(
            names,
            ["both", "empty", "ledger-only", "silent", "transcript-only"]
        );
        // Ledger-only: higher, so reported only. A session the ledger never
        // heard of sent no telemetry: its own section, never lost exports.
        // One with no usage at all ("empty") is neither.
        assert!(report.lost().is_empty());
        let silent: Vec<_> = report
            .no_telemetry()
            .iter()
            .map(|r| r.session.as_str())
            .collect();
        assert_eq!(silent, ["silent", "transcript-only"]);
        let table = report.render();
        assert!(table.contains("ledger only"), "{table}");
        assert!(
            table.contains("sent no telemetry (started without the telemetry settings)"),
            "{table}"
        );
        assert!(
            table.contains("0 lost exports") && table.contains("2 sent no telemetry"),
            "{table}"
        );
    }

    #[test]
    fn the_recorded_day_flags_exactly_the_sessions_that_lost_exports() {
        let lost = |dir: &str| {
            let day = read_day(&fixtures().join(dir), DAY).unwrap();
            let report = compare(&day, recorded(), &[]);
            let mut names: Vec<String> = report.lost().iter().map(|r| r.session.clone()).collect();
            names.sort();
            names
        };
        // Session 2's ledger is 10% low on cache_read; session 1's is higher,
        // 3's is 1% low on cache_creation, and 5 has no transcript. Session 4
        // has no ledger entry: it sent no telemetry, which is not a loss.
        assert_eq!(lost("ledger"), [id(2)]);
        assert!(lost("ledger-ok").is_empty());
        let day = read_day(&fixtures().join("ledger"), DAY).unwrap();
        let report = compare(&day, recorded(), &[]);
        let silent: Vec<_> = report
            .no_telemetry()
            .iter()
            .map(|r| r.session.clone())
            .collect();
        assert_eq!(silent, [id(4)]);
        let ok = compare(
            &read_day(&fixtures().join("ledger-ok"), DAY).unwrap(),
            recorded(),
            &[],
        );
        assert!(ok.no_telemetry().is_empty());
    }

    #[test]
    fn the_table_shows_both_sides_and_the_difference() {
        let day = read_day(&fixtures().join("ledger"), DAY).unwrap();
        let table = compare(&day, recorded(), &[]).render();
        assert!(
            table.contains(&id(2)) && table.contains("LEDGER LOWER"),
            "{table}"
        );
        assert!(table.contains("-10.0%"), "{table}");
        assert!(table.contains("+"), "{table}");
        assert!(
            table.contains("1 lost exports") && table.contains("1 sent no telemetry"),
            "{table}"
        );
        assert!(table.contains("1 malformed lines skipped"), "{table}");
    }

    #[test]
    fn a_missing_day_file_is_an_error_naming_it() {
        let err = read_day(&fixtures().join("ledger"), "2001-01-01").unwrap_err();
        assert!(err.contains("2001-01-01.json"), "{err}");
    }

    #[test]
    fn a_session_missing_from_the_ledger_during_a_gap_lost_its_exports() {
        let day = day_of(&[("ok", tokens(1, 1, 100, 100))]);
        let times = |ts: &[i64]| ts.iter().copied().collect::<BTreeSet<_>>();
        let transcripts = || Transcripts {
            sessions: BTreeMap::from([
                ("ok".to_string(), tokens(1, 1, 100, 100)),
                ("down".to_string(), tokens(1, 1, 50_000, 9_000)),
                ("before".to_string(), tokens(1, 1, 7, 0)),
                ("across".to_string(), tokens(1, 1, 7, 0)),
            ]),
            times: BTreeMap::from([
                ("ok".to_string(), times(&[100, 9_000])),
                ("down".to_string(), times(&[5_000, 6_000])),
                ("before".to_string(), times(&[100, 1_000])),
                ("across".to_string(), times(&[1_000, 5_000])),
            ]),
            files: 4,
            malformed: 0,
        };
        // The receiver was down from 4000 to 7000: all of "down" ran in it,
        // only part of "across".
        let gaps = [Gap {
            from: 4_000,
            to: 7_000,
        }];
        let report = compare(&day, transcripts(), &gaps);
        let names = |rows: Vec<&Row>| rows.iter().map(|r| r.session.clone()).collect::<Vec<_>>();
        assert_eq!(names(report.lost()), ["down"]);
        assert_eq!(names(report.no_telemetry()), ["across", "before"]);
        let table = report.render();
        assert!(table.contains("down  LOST (receiver down)"), "{table}");
        assert!(table.contains("  down (receiver down)"), "{table}");
        assert!(
            table.contains("1 lost exports") && table.contains("2 sent no telemetry"),
            "{table}"
        );
        // With no gap, it is a session that never exported.
        let none = compare(&day, transcripts(), &[]);
        assert!(none.lost().is_empty());
        assert_eq!(names(none.no_telemetry()), ["across", "before", "down"]);
    }

    /// One session missing from the ledger, its messages at `at`.
    fn missing(at: &[i64]) -> Transcripts {
        Transcripts {
            sessions: BTreeMap::from([("s".to_string(), tokens(0, 0, 1000, 0))]),
            times: BTreeMap::from([("s".to_string(), at.iter().copied().collect())]),
            ..Transcripts::default()
        }
    }

    #[test]
    fn a_short_gap_in_a_long_session_is_not_a_lost_session() {
        let day = day_of(&[]);
        // 09:00 to 17:00 hourly; the receiver restarted at noon.
        let nine = 1_000_000;
        let hourly: Vec<i64> = (0..=8).map(|h| nine + h * 3600).collect();
        let noon = nine + 3 * 3600;
        let gaps = [Gap {
            from: noon,
            to: noon + 60,
        }];
        let r = compare(&day, missing(&hourly), &gaps);
        assert!(r.lost().is_empty(), "exit 0");
        assert!(r.rows[0].no_telemetry());
        // A session that ran only inside the gap lost every export.
        let r = compare(&day, missing(&[noon + 10, noon + 50]), &gaps);
        assert_eq!(r.rows[0].lost_reason(), Some("receiver down"), "exit 1");
    }

    #[test]
    fn a_message_within_the_slack_of_a_gap_counts_as_in_it() {
        let day = day_of(&[]);
        let gaps = [Gap {
            from: 10_000,
            to: 10_060,
        }];
        let lost = |at: i64| !compare(&day, missing(&[at]), &gaps).lost().is_empty();
        assert!(lost(10_060 + GAP_SLACK));
        assert!(!lost(10_060 + GAP_SLACK + 1));
        assert!(lost(10_000 - GAP_SLACK));
        assert!(!lost(10_000 - GAP_SLACK - 1));
        assert_eq!(GAP_SLACK, 120);
    }
}
