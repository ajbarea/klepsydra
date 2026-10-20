//! What Claude Code's telemetry adds up to, per session: tokens, the
//! API-equivalent cost estimate, lines, commits and PRs, active time, edit
//! decisions, tool results, API errors and refusals, and the tool calls a
//! hook or a config rule turned down. Kept in memory for the fleet view and
//! on disk as one ledger file per local calendar day.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use jiff::tz::TimeZone;
use jiff::Timestamp;
use serde::{Deserialize, Serialize};

use crate::otel::{Event, Point, Temporality};

/// Day files older than this many days are deleted.
pub const RETENTION_DAYS: i64 = 30;
/// How long a counted point's key is remembered after it was counted, so a
/// retried export is not counted twice. A point whose window ended longer ago
/// than this can no longer be told from one already counted, so it is dropped
/// as stale.
pub const DEDUPE_WINDOW: i64 = 3600;
/// How far ahead of this machine's clock a point or event may be dated. The
/// exporter runs on the same machine, so anything further is nonsense.
pub const MAX_AHEAD: i64 = 300;
/// Most sessions one map keeps; past it the least recently updated goes.
pub const MAX_SESSIONS: usize = 512;
/// Most guardrail entries one day file keeps.
pub const GUARDRAIL_CAP: usize = 10_000;
/// The file format's version.
pub const VERSION: u32 = 1;
/// Holds what spans days: lifetime totals, dedupe keys, cumulative baselines.
pub const STATE_FILE: &str = "state.json";

const DAY: i64 = 86_400;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Tokens {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Active {
    pub user_ms: u64,
    pub cli_ms: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Decisions {
    pub accept: u64,
    pub reject: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ToolResults {
    pub count: u64,
    pub failures: u64,
}

/// One session's totals. Every field defaults, so a file written before a
/// field existed still loads.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Totals {
    pub tokens: Tokens,
    /// Claude Code's `cost.usage`, in millionths of a US dollar: what the
    /// tokens would cost at API prices, not money spent on a subscription.
    pub cost_usd_estimate_micros: u64,
    pub lines_added: u64,
    pub lines_removed: u64,
    pub commits: u64,
    pub pull_requests: u64,
    pub active: Active,
    /// Edit, Write and NotebookEdit decisions (`code_edit_tool.decision`).
    pub edit_decisions: Decisions,
    pub tool_results: ToolResults,
    pub api_errors: u64,
    pub api_refusals: u64,
    /// Tool calls a config rule or a hook rejected.
    pub guardrail_rejects: u64,
    /// Tool calls the user rejected or dismissed.
    pub user_rejects: u64,
    /// When this session's totals last changed, in epoch seconds.
    pub updated_at: i64,
}

/// A tool call a config rule or a hook turned down.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Guardrail {
    /// When it happened, in epoch seconds.
    pub at: i64,
    pub session_id: String,
    pub tool_name: String,
    /// `config` or `hook`.
    pub source: String,
}

/// One local day's file.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Day {
    pub version: u32,
    /// `YYYY-MM-DD`, in the machine's time zone.
    pub day: String,
    pub sessions: BTreeMap<String, Totals>,
    pub guardrails: Vec<Guardrail>,
    /// Counted metric points that carried no `session.id`, and so no total.
    pub no_session: u64,
}

/// A cumulative series' last point, to take the next one's difference from.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
struct Baseline {
    start_ns: u64,
    end_ns: u64,
    value: f64,
    at: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
struct State {
    version: u32,
    /// Since the session's first export, across days, for the fleet view.
    sessions: BTreeMap<String, Totals>,
    /// Counted keys and when they were counted, in epoch seconds.
    seen: HashMap<u64, i64>,
    series: HashMap<u64, Baseline>,
}

/// What one export added.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tally {
    pub counted: usize,
    pub duplicate: usize,
    pub stale: usize,
    /// Dated more than `MAX_AHEAD` ahead of the clock.
    pub future: usize,
    /// Points the ledger would count but for a missing `session.id`.
    pub no_session: usize,
    /// Names the ledger does not count, and values that are not numbers.
    pub ignored: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Field {
    Input,
    Output,
    CacheRead,
    CacheCreation,
    Cost,
    LinesAdded,
    LinesRemoved,
    Commits,
    PullRequests,
    ActiveUser,
    ActiveCli,
    EditAccept,
    EditReject,
}

/// Which total a metric point adds to, and the unit scale that makes it an
/// integer: micro-dollars for cost, milliseconds for active time.
fn classify(p: &Point) -> Option<(Field, f64)> {
    let ty = p.attrs.get("type").map(String::as_str);
    let one = |f| Some((f, 1.0));
    match p.metric.as_str() {
        "claude_code.token.usage" => match ty? {
            "input" => one(Field::Input),
            "output" => one(Field::Output),
            "cacheRead" => one(Field::CacheRead),
            "cacheCreation" => one(Field::CacheCreation),
            _ => None,
        },
        "claude_code.cost.usage" => Some((Field::Cost, 1e6)),
        "claude_code.lines_of_code.count" => match ty? {
            "added" => one(Field::LinesAdded),
            "removed" => one(Field::LinesRemoved),
            _ => None,
        },
        "claude_code.commit.count" => one(Field::Commits),
        "claude_code.pull_request.count" => one(Field::PullRequests),
        "claude_code.active_time.total" => match ty? {
            "user" => Some((Field::ActiveUser, 1e3)),
            "cli" => Some((Field::ActiveCli, 1e3)),
            _ => None,
        },
        "claude_code.code_edit_tool.decision" => match p.attrs.get("decision")?.as_str() {
            "accept" => one(Field::EditAccept),
            "reject" => one(Field::EditReject),
            _ => None,
        },
        _ => None,
    }
}

impl Totals {
    fn slot(&mut self, f: Field) -> &mut u64 {
        match f {
            Field::Input => &mut self.tokens.input,
            Field::Output => &mut self.tokens.output,
            Field::CacheRead => &mut self.tokens.cache_read,
            Field::CacheCreation => &mut self.tokens.cache_creation,
            Field::Cost => &mut self.cost_usd_estimate_micros,
            Field::LinesAdded => &mut self.lines_added,
            Field::LinesRemoved => &mut self.lines_removed,
            Field::Commits => &mut self.commits,
            Field::PullRequests => &mut self.pull_requests,
            Field::ActiveUser => &mut self.active.user_ms,
            Field::ActiveCli => &mut self.active.cli_ms,
            Field::EditAccept => &mut self.edit_decisions.accept,
            Field::EditReject => &mut self.edit_decisions.reject,
        }
    }
}

/// `v` in whole units of `scale`; None for a value that is not a number.
fn scaled(v: f64, scale: f64) -> Option<i64> {
    let s = v * scale;
    // `as` saturates, so a huge value cannot wrap.
    s.is_finite().then(|| s.round() as i64)
}

fn secs(ns: u64) -> i64 {
    i64::try_from(ns / 1_000_000_000).unwrap_or(i64::MAX)
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Hinnant's
/// `civil_from_days`).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// The inverse of `civil` (Hinnant's `days_from_civil`).
fn days_from(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let m = i64::from(m);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The calendar date of `now` in `tz`; the UTC date for an instant jiff
/// cannot represent.
fn local_date(now: i64, tz: &TimeZone) -> (i64, u32, u32) {
    match Timestamp::from_second(now) {
        Ok(t) => {
            let d = t.to_zoned(tz.clone()).date();
            (
                i64::from(d.year()),
                u32::try_from(d.month()).unwrap_or(1),
                u32::try_from(d.day()).unwrap_or(1),
            )
        }
        Err(_) => civil(now.div_euclid(DAY)),
    }
}

/// The day of `now` in `tz` as `YYYY-MM-DD`.
pub fn day_name(now: i64, tz: &TimeZone) -> String {
    let (y, m, d) = local_date(now, tz);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The day a ledger file belongs to, in days since the epoch, when its name
/// is exactly `YYYY-MM-DD.json` (or `.json.bad`, one set aside unreadable).
/// Nothing else in the folder is ever a candidate for deletion.
fn file_day(name: &str) -> Option<i64> {
    let stem = name
        .strip_suffix(".json")
        .or_else(|| name.strip_suffix(".json.bad"))?;
    let b = stem.as_bytes();
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' || !digits(0..4) || !digits(5..7) {
        return None;
    }
    if !digits(8..10) {
        return None;
    }
    let y: i64 = stem[0..4].parse().ok()?;
    let m: u32 = stem[5..7].parse().ok()?;
    let d: u32 = stem[8..10].parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let days = days_from(y, m, d);
    (civil(days) == (y, m, d)).then_some(days)
}

/// Delete day files more than `RETENTION_DAYS` days before `now`'s day in
/// `tz`. Returns the names removed.
pub fn prune(dir: &Path, now: i64, tz: &TimeZone) -> Vec<String> {
    let (y, m, d) = local_date(now, tz);
    let today = days_from(y, m, d);
    let mut removed = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return removed;
    };
    for e in entries.flatten() {
        if !e.file_type().is_ok_and(|t| t.is_file()) {
            continue;
        }
        let name = e.file_name().to_string_lossy().into_owned();
        let Some(day) = file_day(&name) else {
            continue;
        };
        if today - day > RETENTION_DAYS && std::fs::remove_file(e.path()).is_ok() {
            removed.push(name);
        }
    }
    removed.sort();
    removed
}

/// Write `bytes` to `path` through a temporary file and a rename, so a reader
/// never sees half a file. Only the receiver's thread writes, under the
/// ledger's lock, so one temporary name per file is enough.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = path.with_file_name(format!("{name}.tmp"));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// Read `path` as `T`: the default when there is no file, and the default
/// after setting an unreadable file aside as `<name>.bad`, so a write never
/// replaces data it could not read without keeping a copy.
fn load<T: Default + for<'de> Deserialize<'de>>(path: &Path, problems: &mut Vec<String>) -> T {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return T::default(),
        Err(e) => {
            problems.push(format!("{}: {e}", path.display()));
            return T::default();
        }
    };
    match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            let mut aside = path.as_os_str().to_owned();
            aside.push(".bad");
            let _ = std::fs::rename(path, &aside);
            problems.push(format!("{} set aside: {e}", path.display()));
            T::default()
        }
    }
}

/// The ledger: today's file, lifetime totals, and what stops a retried
/// export from counting twice.
pub struct Ledger {
    dir: Option<PathBuf>,
    tz: TimeZone,
    day: Day,
    state: State,
    receiver: Option<Receiver>,
}

/// Whether the OTLP receiver is listening, for the wall to show.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Receiver {
    pub addr: String,
    pub listening: bool,
    /// Why it is not listening, such as the port being taken.
    pub error: Option<String>,
}

/// Drop the least recently updated sessions past `MAX_SESSIONS`, never
/// `keep`, the one just updated.
fn cap_sessions(map: &mut BTreeMap<String, Totals>, keep: &str) {
    while map.len() > MAX_SESSIONS {
        let oldest = map
            .iter()
            .filter(|(id, _)| id.as_str() != keep)
            .min_by_key(|(id, t)| (t.updated_at, id.as_str()))
            .map(|(id, _)| id.clone());
        match oldest {
            Some(id) => map.remove(&id),
            None => break,
        };
    }
}

/// The ledger as the receiver and the fleet reader share it.
pub type Shared = Arc<Mutex<Ledger>>;

/// Lock a shared ledger; a panic elsewhere while it was held leaves totals
/// that are still worth reading.
pub fn lock(shared: &Shared) -> std::sync::MutexGuard<'_, Ledger> {
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

impl Ledger {
    /// A ledger that never touches the disk, its days in UTC.
    pub fn in_memory(now: i64) -> Self {
        Ledger {
            dir: None,
            tz: TimeZone::UTC,
            day: Day {
                version: VERSION,
                day: day_name(now, &TimeZone::UTC),
                ..Day::default()
            },
            state: State {
                version: VERSION,
                ..State::default()
            },
            receiver: None,
        }
    }

    /// The ledger kept in `dir`, its days in this machine's time zone.
    pub fn open_local(dir: PathBuf, now: i64) -> (Self, Vec<String>) {
        Self::open(dir, now, TimeZone::system())
    }

    /// The ledger kept in `dir`, its days in `tz`: today's file and the state
    /// file loaded, old day files pruned. Returns what could not be read.
    pub fn open(dir: PathBuf, now: i64, tz: TimeZone) -> (Self, Vec<String>) {
        let mut problems = Vec::new();
        if let Err(e) = std::fs::create_dir_all(&dir) {
            problems.push(format!("{}: {e}", dir.display()));
        }
        let mut state: State = load(&dir.join(STATE_FILE), &mut problems);
        state.version = VERSION;
        let mut ledger = Ledger {
            dir: Some(dir),
            tz,
            day: Day::default(),
            state,
            receiver: None,
        };
        ledger.start_day(now, &mut problems);
        (ledger, problems)
    }

    fn start_day(&mut self, now: i64, problems: &mut Vec<String>) {
        let name = day_name(now, &self.tz);
        self.day = match &self.dir {
            Some(dir) => load(&dir.join(format!("{name}.json")), problems),
            None => Day::default(),
        };
        self.day.version = VERSION;
        self.day.day = name;
        if let Some(dir) = &self.dir {
            prune(dir, now, &self.tz);
        }
        let horizon = now - RETENTION_DAYS * DAY;
        self.state.sessions.retain(|_, t| t.updated_at >= horizon);
        self.state.series.retain(|_, b| b.at >= horizon);
    }

    /// Move to `now`'s day when it is a new one.
    fn roll(&mut self, now: i64) {
        if self.day.day != day_name(now, &self.tz) {
            self.start_day(now, &mut Vec::new());
        }
        // A point may be dated up to MAX_AHEAD ahead and still count, so its
        // key must outlive the stale cutoff by as much.
        let cutoff = now - DEDUPE_WINDOW - MAX_AHEAD;
        self.state.seen.retain(|_, &mut counted| counted >= cutoff);
    }

    /// Record whether the receiver is listening.
    pub fn set_receiver(&mut self, r: Receiver) {
        self.receiver = Some(r);
    }

    /// The receiver's state, once it has tried to listen.
    pub fn receiver(&self) -> Option<&Receiver> {
        self.receiver.as_ref()
    }

    /// Today's file as it stands.
    pub fn day(&self) -> &Day {
        &self.day
    }

    /// A session's totals since its first export.
    pub fn session(&self, id: &str) -> Option<&Totals> {
        self.state.sessions.get(id)
    }

    fn add(&mut self, session: &str, f: Field, n: u64, now: i64) {
        self.update(session, now, |t| {
            let slot = t.slot(f);
            *slot = slot.saturating_add(n);
        });
    }

    fn bump(&mut self, session: &str, now: i64, f: impl Fn(&mut Totals) -> &mut u64) {
        self.update(session, now, |t| {
            let slot = f(t);
            *slot = slot.saturating_add(1);
        });
    }

    fn update(&mut self, session: &str, now: i64, f: impl Fn(&mut Totals)) {
        for map in [&mut self.day.sessions, &mut self.state.sessions] {
            let t = map.entry(session.to_string()).or_default();
            f(t);
            t.updated_at = now;
            cap_sessions(map, session);
        }
    }

    /// Count the points of one metrics export.
    pub fn record_metrics(&mut self, points: &[Point], now: i64) -> Tally {
        self.roll(now);
        let mut tally = Tally::default();
        for p in points {
            let Some((field, scale)) = classify(p) else {
                tally.ignored += 1;
                continue;
            };
            let Some(session) = p.attrs.get("session.id") else {
                tally.no_session += 1;
                self.day.no_session = self.day.no_session.saturating_add(1);
                continue;
            };
            if secs(p.end_ns) > now.saturating_add(MAX_AHEAD) {
                tally.future += 1;
                continue;
            }
            let Some(value) = scaled(p.value, scale) else {
                tally.ignored += 1;
                continue;
            };
            let amount = match p.temporality {
                Temporality::Delta => {
                    let end = secs(p.end_ns);
                    if end < now - DEDUPE_WINDOW {
                        tally.stale += 1;
                        continue;
                    }
                    if self.state.seen.insert(p.key, now).is_some() {
                        tally.duplicate += 1;
                        continue;
                    }
                    value
                }
                Temporality::Cumulative => {
                    let before = self.state.series.get(&p.series);
                    let amount = match before {
                        // An older or repeated point of the same run.
                        Some(b) if p.start_ns < b.start_ns => None,
                        Some(b) if p.start_ns == b.start_ns && p.end_ns <= b.end_ns => None,
                        Some(b) if p.start_ns == b.start_ns => {
                            let last = scaled(b.value, scale).unwrap_or(0);
                            // A total that went down was reset.
                            Some(if value >= last { value - last } else { value })
                        }
                        // A new start time is a reset: all of it is new.
                        _ => Some(value),
                    };
                    let Some(amount) = amount else {
                        tally.duplicate += 1;
                        continue;
                    };
                    self.state.series.insert(
                        p.series,
                        Baseline {
                            start_ns: p.start_ns,
                            end_ns: p.end_ns,
                            value: p.value,
                            at: now,
                        },
                    );
                    amount
                }
            };
            // A delta sum of a monotonic counter never goes down.
            let Ok(n) = u64::try_from(amount) else {
                tally.ignored += 1;
                continue;
            };
            self.add(session, field, n, now);
            tally.counted += 1;
        }
        tally
    }

    /// Count the events of one logs export.
    pub fn record_events(&mut self, events: &[Event], now: i64) -> Tally {
        self.roll(now);
        let mut tally = Tally::default();
        for e in events {
            let counted = matches!(
                e.name.as_str(),
                "tool_result" | "tool_decision" | "api_error" | "api_refusal"
            );
            let Some(session) = e.attrs.get("session.id").filter(|_| counted) else {
                tally.ignored += 1;
                continue;
            };
            let session = session.clone();
            let at = secs(e.time_ns);
            if at < now - DEDUPE_WINDOW {
                tally.stale += 1;
                continue;
            }
            if at > now.saturating_add(MAX_AHEAD) {
                tally.future += 1;
                continue;
            }
            let get = |k: &str| e.attrs.get(k).map_or("", String::as_str);
            let kind = match e.name.as_str() {
                "tool_decision" if get("decision") == "reject" => match get("source") {
                    "config" | "hook" => Some(true),
                    s if s.starts_with("user_") => Some(false),
                    _ => None,
                },
                "tool_decision" => None,
                _ => Some(false),
            };
            if e.name == "tool_decision" && kind.is_none() {
                tally.ignored += 1;
                continue;
            }
            if self.state.seen.insert(e.key, now).is_some() {
                tally.duplicate += 1;
                continue;
            }
            match e.name.as_str() {
                "tool_result" => {
                    self.bump(&session, now, |t| &mut t.tool_results.count);
                    if get("success") == "false" {
                        self.bump(&session, now, |t| &mut t.tool_results.failures);
                    }
                }
                "api_error" => self.bump(&session, now, |t| &mut t.api_errors),
                "api_refusal" => self.bump(&session, now, |t| &mut t.api_refusals),
                _ if kind == Some(true) => {
                    self.bump(&session, now, |t| &mut t.guardrail_rejects);
                    if self.day.guardrails.len() < GUARDRAIL_CAP {
                        self.day.guardrails.push(Guardrail {
                            at,
                            session_id: session.clone(),
                            tool_name: get("tool_name").to_string(),
                            source: get("source").to_string(),
                        });
                    }
                }
                _ => self.bump(&session, now, |t| &mut t.user_rejects),
            }
            tally.counted += 1;
        }
        tally
    }

    /// Write today's file and the state file. A ledger with no folder has
    /// nothing to write.
    pub fn save(&self) -> std::io::Result<()> {
        let Some(dir) = &self.dir else {
            return Ok(());
        };
        let day = serde_json::to_vec_pretty(&self.day).map_err(std::io::Error::other)?;
        write_atomic(&dir.join(format!("{}.json", self.day.day)), &day)?;
        let state = serde_json::to_vec(&self.state).map_err(std::io::Error::other)?;
        write_atomic(&dir.join(STATE_FILE), &state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::otel::{logs, metrics, tests::fixtures};
    use crate::scan::tests::Scratch;
    use serde_json::{json, Value};

    const SESSION: &str = "4ce1be96-f12f-4c66-87eb-4ab36e451dc5";
    /// Just after the recorded session's last export.
    const NOW: i64 = 1_792_535_750;

    fn replay(ledger: &mut Ledger, dir: &str, now: i64) -> Tally {
        let mut total = Tally::default();
        for (name, v) in fixtures(dir) {
            let t = if name.ends_with("metrics.json") {
                ledger.record_metrics(&metrics(&v), now)
            } else {
                ledger.record_events(&logs(&v), now)
            };
            total.counted += t.counted;
            total.duplicate += t.duplicate;
            total.stale += t.stale;
            total.ignored += t.ignored;
        }
        total
    }

    fn recorded_totals() -> Totals {
        Totals {
            tokens: Tokens {
                input: 2 + 4 + 2,
                output: 269 + 306 + 131,
                cache_read: 11_091 + 99_139 + 50_684,
                cache_creation: 37_641 + 1_952 + 263,
            },
            // 0.00777381 + 0.00153519 + 0.00062514 USD
            cost_usd_estimate_micros: 7_774 + 1_535 + 625,
            lines_added: 1,
            lines_removed: 1,
            commits: 0,
            pull_requests: 0,
            active: Active {
                user_ms: 0,
                cli_ms: 14_375,
            },
            edit_decisions: Decisions {
                accept: 1,
                reject: 0,
            },
            tool_results: ToolResults {
                count: 2,
                failures: 0,
            },
            api_errors: 0,
            api_refusals: 0,
            guardrail_rejects: 1,
            user_rejects: 0,
            updated_at: NOW,
        }
    }

    #[test]
    fn the_recorded_session_adds_up() {
        let mut l = Ledger::in_memory(NOW);
        replay(&mut l, "delta", NOW);
        assert_eq!(l.session(SESSION), Some(&recorded_totals()));
        assert_eq!(l.day().sessions[SESSION], recorded_totals());
        assert_eq!(
            l.day().guardrails,
            [Guardrail {
                at: 1_792_535_739,
                session_id: SESSION.into(),
                tool_name: "Bash".into(),
                source: "config".into(),
            }]
        );
    }

    #[test]
    fn a_retried_export_is_not_counted_twice() {
        let mut l = Ledger::in_memory(NOW);
        let first = replay(&mut l, "delta", NOW);
        let again = replay(&mut l, "delta", NOW);
        assert_eq!(again.counted, 0);
        assert_eq!(again.duplicate, first.counted);
        assert_eq!(l.session(SESSION), Some(&recorded_totals()));
    }

    #[test]
    fn the_dedupe_keys_survive_a_restart() {
        let dir = Scratch::new("ledger-restart");
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        replay(&mut l, "delta", NOW);
        l.save().unwrap();
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW + 5, TimeZone::UTC);
        assert_eq!(replay(&mut l, "delta", NOW + 5).counted, 0);
        assert_eq!(l.session(SESSION).unwrap().tokens.output, 706);
    }

    #[test]
    fn a_point_older_than_the_dedupe_window_is_stale() {
        let mut l = Ledger::in_memory(NOW);
        let t = replay(&mut l, "delta", NOW + DEDUPE_WINDOW + 60);
        assert_eq!(t.counted, 0);
        assert!(t.stale > 0);
        assert_eq!(l.session(SESSION), None);
    }

    #[test]
    fn the_recorded_cumulative_export_counts_each_token_once() {
        let mut l = Ledger::in_memory(NOW);
        replay(&mut l, "cumulative", 1_792_535_840);
        let t = l.session("6b8b469d-9144-4962-b1c7-214a002c91a2").unwrap();
        // The last cumulative point of each series is its whole total.
        assert_eq!(t.tokens.input, 4);
        assert_eq!(t.tokens.output, 130);
        assert_eq!(t.tokens.cache_read, 62_073);
        assert_eq!(t.tokens.cache_creation, 36_585);
        assert_eq!(t.cost_usd_estimate_micros, 8_003);
        assert_eq!(t.active.cli_ms, 6_660);
        // And replaying them changes nothing.
        let again = replay(&mut l, "cumulative", 1_792_535_840);
        assert_eq!(again.counted, 0);
    }

    fn cumulative(start: u64, end: u64, value: f64) -> Value {
        json!({"resourceMetrics":[{"resource":{"attributes":[]},"scopeMetrics":[{"scope":{"name":"s"},"metrics":[{"name":"claude_code.lines_of_code.count","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"added"}}],"startTimeUnixNano":start.to_string(),"timeUnixNano":end.to_string(),"asDouble":value}]}}]}]}]})
    }

    #[test]
    fn a_cumulative_series_counts_its_differences_and_survives_a_reset() {
        let s = |n: u64| n * 1_000_000_000;
        let mut l = Ledger::in_memory(NOW);
        let mut feed =
            |start, end, v| l.record_metrics(&metrics(&cumulative(s(start), s(end), v)), NOW);
        assert_eq!(feed(NOW as u64 - 60, NOW as u64 - 50, 10.0).counted, 1);
        assert_eq!(feed(NOW as u64 - 60, NOW as u64 - 40, 25.0).counted, 1);
        // A repeat and an older point of the same run.
        assert_eq!(feed(NOW as u64 - 60, NOW as u64 - 40, 25.0).duplicate, 1);
        assert_eq!(feed(NOW as u64 - 60, NOW as u64 - 50, 10.0).duplicate, 1);
        // A new start time: the process restarted and counts from zero.
        assert_eq!(feed(NOW as u64 - 30, NOW as u64 - 20, 4.0).counted, 1);
        // A total that went down without a new start time was reset too.
        assert_eq!(feed(NOW as u64 - 30, NOW as u64 - 10, 1.0).counted, 1);
        assert_eq!(l.session("s1").unwrap().lines_added, 25 + 4 + 1);
    }

    #[test]
    fn unknown_metrics_and_events_are_ignored() {
        let mut l = Ledger::in_memory(NOW);
        let end = (NOW as u64 * 1_000_000_000).to_string();
        let v = json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.something_new","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}}],"timeUnixNano":end,"asDouble":5}]}}]}]}]});
        let t = l.record_metrics(&metrics(&v), NOW);
        assert_eq!((t.counted, t.ignored), (0, 1));
        let v = json!({"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":end,"attributes":[{"key":"event.name","value":{"stringValue":"brand_new"}},{"key":"session.id","value":{"stringValue":"s1"}}]}]}]}]});
        let t = l.record_events(&logs(&v), NOW);
        assert_eq!((t.counted, t.ignored), (0, 1));
        assert_eq!(l.session("s1"), None);
    }

    fn event(name: &str, extra: &[(&str, &str)], seq: u64) -> Value {
        let mut attrs = vec![
            json!({"key":"event.name","value":{"stringValue":name}}),
            json!({"key":"session.id","value":{"stringValue":"s1"}}),
            json!({"key":"event.sequence","value":{"intValue":seq}}),
        ];
        for (k, v) in extra {
            attrs.push(json!({"key":k,"value":{"stringValue":v}}));
        }
        let t = (NOW as u64 * 1_000_000_000).to_string();
        json!({"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":t,"attributes":attrs}]}]}]})
    }

    #[test]
    fn rejections_split_by_source_and_failures_and_errors_count() {
        let mut l = Ledger::in_memory(NOW);
        let feed = [
            event(
                "tool_decision",
                &[
                    ("decision", "reject"),
                    ("source", "hook"),
                    ("tool_name", "Bash"),
                ],
                1,
            ),
            event(
                "tool_decision",
                &[
                    ("decision", "reject"),
                    ("source", "user_reject"),
                    ("tool_name", "Edit"),
                ],
                2,
            ),
            event(
                "tool_decision",
                &[
                    ("decision", "reject"),
                    ("source", "user_abort"),
                    ("tool_name", "Edit"),
                ],
                3,
            ),
            event(
                "tool_decision",
                &[("decision", "accept"), ("source", "hook")],
                4,
            ),
            event("tool_result", &[("success", "false")], 5),
            event("api_error", &[("status_code", "529")], 6),
            event("api_refusal", &[], 7),
        ];
        for v in &feed {
            l.record_events(&logs(v), NOW);
        }
        let t = l.session("s1").unwrap();
        assert_eq!((t.guardrail_rejects, t.user_rejects), (1, 2));
        assert_eq!((t.tool_results.count, t.tool_results.failures), (1, 1));
        assert_eq!((t.api_errors, t.api_refusals), (1, 1));
        assert_eq!(l.day().guardrails.len(), 1);
        assert_eq!(l.day().guardrails[0].source, "hook");
    }

    #[test]
    fn days_round_trip_and_name_utc_dates() {
        assert_eq!(day_name(0, &TimeZone::UTC), "1970-01-01");
        assert_eq!(day_name(NOW, &TimeZone::UTC), "2026-10-20");
        assert_eq!(day_name(951_782_400, &TimeZone::UTC), "2000-02-29");
        assert_eq!(day_name(-1, &TimeZone::UTC), "1969-12-31");
        for d in [-1, 0, 11_016, 20_746, 50_000] {
            let (y, m, dd) = civil(d);
            assert_eq!(days_from(y, m, dd), d);
        }
        assert_eq!(file_day("2026-10-20.json"), Some(NOW / DAY));
        for name in [
            "2026-02-30.json",
            "2026-13-01.json",
            "state.json",
            "2026-10-20.json.1.tmp",
            "x2026-10-20.json",
            "2026-1-020.json",
            "2026-10-20.txt",
        ] {
            assert_eq!(file_day(name), None, "{name}");
        }
    }

    #[test]
    fn retention_removes_only_old_day_files() {
        let dir = Scratch::new("ledger-prune");
        let today = NOW / DAY;
        let named = |age: i64| {
            let (y, m, d) = civil(today - age);
            format!("{y:04}-{m:02}-{d:02}.json")
        };
        for age in [0, 1, RETENTION_DAYS, RETENTION_DAYS + 1, 400] {
            dir.write(&named(age), "{}");
        }
        dir.write(&format!("{}.bad", named(RETENTION_DAYS + 2)), "x");
        dir.write(STATE_FILE, "{}");
        dir.write("notes.txt", "keep");
        std::fs::create_dir(dir.0.join(named(500))).unwrap();
        let removed = prune(&dir.0, NOW, &TimeZone::UTC);
        let mut want = vec![
            named(RETENTION_DAYS + 1),
            format!("{}.bad", named(RETENTION_DAYS + 2)),
            named(400),
        ];
        want.sort();
        assert_eq!(removed, want);
        for kept in [
            named(0),
            named(1),
            named(RETENTION_DAYS),
            STATE_FILE.into(),
            "notes.txt".into(),
            named(500),
        ] {
            assert!(dir.0.join(&kept).exists(), "{kept}");
        }
    }

    #[test]
    fn the_day_file_is_written_whole_and_reloaded() {
        let dir = Scratch::new("ledger-save");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        replay(&mut l, "delta", NOW);
        l.save().unwrap();
        let names: Vec<String> = std::fs::read_dir(&dir.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(names.iter().all(|n| !n.ends_with(".tmp")), "{names:?}");
        let text = std::fs::read_to_string(dir.0.join("2026-10-20.json")).unwrap();
        let day: Day = serde_json::from_str(&text).unwrap();
        assert_eq!(day.sessions[SESSION], recorded_totals());
        let (l, _) = Ledger::open(dir.0.clone(), NOW + 10, TimeZone::UTC);
        assert_eq!(l.day().sessions[SESSION], recorded_totals());
    }

    #[test]
    fn a_new_day_starts_a_new_file_and_keeps_lifetime_totals() {
        let dir = Scratch::new("ledger-roll");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        replay(&mut l, "delta", NOW);
        l.save().unwrap();
        let tomorrow = (NOW / DAY + 1) * DAY + 10;
        let v = cumulative(
            tomorrow as u64 * 1_000_000_000,
            tomorrow as u64 * 1_000_000_000,
            3.0,
        );
        l.record_metrics(&metrics(&v), tomorrow);
        l.save().unwrap();
        assert_eq!(l.day().day, "2026-10-21");
        assert!(!l.day().sessions.contains_key(SESSION));
        assert_eq!(l.session(SESSION), Some(&recorded_totals()));
        assert!(dir.0.join("2026-10-20.json").exists());
        assert!(dir.0.join("2026-10-21.json").exists());
    }

    #[test]
    fn an_older_file_without_newer_fields_still_loads() {
        let dir = Scratch::new("ledger-old");
        dir.write(
            "2026-10-20.json",
            r#"{"day":"2026-10-20","sessions":{"s1":{"tokens":{"output":5}}}}"#,
        );
        let (l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        let t = &l.day().sessions["s1"];
        assert_eq!(t.tokens.output, 5);
        assert_eq!(t.guardrail_rejects, 0);
        assert!(l.day().guardrails.is_empty());
    }

    #[test]
    fn an_unreadable_day_file_is_set_aside_not_overwritten() {
        let dir = Scratch::new("ledger-bad");
        dir.write("2026-10-20.json", "{half");
        let (l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(problems.len(), 1);
        l.save().unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.0.join("2026-10-20.json.bad")).unwrap(),
            "{half"
        );
    }

    #[test]
    fn nonsense_values_do_not_panic_or_count() {
        let mut l = Ledger::in_memory(NOW);
        let end = (NOW as u64 * 1_000_000_000).to_string();
        for value in [json!(-5), json!(1e300), json!("NaN"), json!("inf")] {
            let v = json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"n","value":{"stringValue":value.to_string()}}],"timeUnixNano":end,"asDouble":value}]}}]}]}]});
            l.record_metrics(&metrics(&v), NOW);
        }
        // 1e300 saturates rather than wrapping; the rest are not counted.
        assert_eq!(l.session("s1").map(|t| t.commits), Some(i64::MAX as u64));
    }

    fn point_at(session: &str, end_secs: u64) -> Value {
        let end = (end_secs * 1_000_000_000).to_string();
        json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":session}}],"startTimeUnixNano":end,"timeUnixNano":end,"asDouble":1}]}}]}]}]})
    }

    #[test]
    fn a_far_future_point_or_event_is_dropped_and_leaves_no_key() {
        // 2255-01-01
        let future = 8_993_548_800u64;
        let mut l = Ledger::in_memory(NOW);
        let t = l.record_metrics(&metrics(&point_at("s1", future)), NOW);
        assert_eq!(t.counted, 0);
        let mut e = event("api_error", &[], 1);
        let ns = (future * 1_000_000_000).to_string();
        e["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]["timeUnixNano"] = json!(ns);
        assert_eq!(l.record_events(&logs(&e), NOW).counted, 0);
        assert_eq!(l.session("s1"), None);
        l.record_metrics(&[], NOW + DEDUPE_WINDOW + 1);
        assert!(l.state.seen.is_empty(), "{:?}", l.state.seen);
    }

    #[test]
    fn a_point_a_little_ahead_counts_once() {
        let mut l = Ledger::in_memory(NOW);
        let p = metrics(&point_at("s1", NOW as u64 + 120));
        assert_eq!(l.record_metrics(&p, NOW).counted, 1);
        assert_eq!(l.record_metrics(&p, NOW + 60).duplicate, 1);
    }

    #[test]
    fn the_session_maps_are_capped_keeping_the_latest() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..600u64 {
            l.record_metrics(
                &metrics(&point_at(&format!("s{n}"), NOW as u64)),
                NOW + n as i64,
            );
        }
        assert!(l.day().sessions.len() <= 512, "{}", l.day().sessions.len());
        assert!(l.state.sessions.len() <= 512);
        assert!(l.session("s599").is_some());
        assert!(l.session("s0").is_none());
    }

    #[test]
    fn points_without_a_session_are_counted_as_such() {
        let mut l = Ledger::in_memory(NOW);
        let mut v = point_at("x", NOW as u64);
        v["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["sum"]["dataPoints"][0]
            ["attributes"] = json!([]);
        l.record_metrics(&metrics(&v), NOW);
        let day = serde_json::to_value(l.day()).unwrap();
        assert_eq!(day["no_session"], 1);
    }

    #[test]
    fn days_and_retention_follow_the_local_calendar() {
        // New York: 2026-10-20 22:35 UTC is 18:35 EDT the same day, and
        // 2026-10-21 02:00 UTC is still 2026-10-20 there.
        let ny = TimeZone::posix("EST5EDT,M3.2.0,M11.1.0").unwrap();
        let late = 1_792_548_000; // 2026-10-21T02:00:00Z
        assert_eq!(day_name(late, &TimeZone::UTC), "2026-10-21");
        assert_eq!(day_name(late, &ny), "2026-10-20");
        let tokyo = TimeZone::fixed(jiff::tz::offset(9));
        assert_eq!(day_name(NOW, &tokyo), "2026-10-21");

        let dir = Scratch::new("ledger-local");
        let (mut l, _) = Ledger::open(dir.0.clone(), late, ny.clone());
        l.record_metrics(&metrics(&point_at("s1", late as u64)), late);
        l.save().unwrap();
        assert!(dir.0.join("2026-10-20.json").exists());
        assert!(!dir.0.join("2026-10-21.json").exists());

        // 30 local days before 2026-10-20 is kept; 31 is not, though in UTC
        // `late` is already a day further on.
        dir.write("2026-09-20.json", "{}");
        dir.write("2026-09-19.json", "{}");
        assert_eq!(prune(&dir.0, late, &ny), ["2026-09-19.json"]);
        assert!(dir.0.join("2026-09-20.json").exists());
    }
}
