//! What Claude Code's telemetry adds up to, per session: tokens, the
//! API-equivalent cost estimate, lines, commits and PRs, active time, edit
//! decisions, tool results, API errors and refusals, and the tool calls a
//! hook or a config rule turned down. Kept in memory for the fleet view and
//! on disk as one ledger file per local calendar day.

use std::collections::{BTreeMap, BTreeSet, HashMap};
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
/// Characters kept of a session's label; a card shows far fewer.
pub const MAX_LABEL: usize = 120;
/// Most guardrail entries one day file keeps.
pub const GUARDRAIL_CAP: usize = 10_000;
/// The file format's version.
pub const VERSION: u32 = 1;
/// Most names one session keeps per attribution kind; past it, tokens go
/// under `OTHER`.
pub const MAX_NAMES: usize = 32;
/// Most models one session keeps; past it, tokens and cost go under `OTHER`.
pub const MAX_MODELS: usize = 16;
/// Most receiver gaps the state file keeps; past it the oldest goes.
pub const MAX_GAPS: usize = 64;
/// Where the overlay stamps the time, in epoch seconds, while the receiver is
/// listening; the time since the last stamp is what a restart missed.
pub const ALIVE_FILE: &str = "alive";
/// How often the stamp is written.
pub const ALIVE_EVERY: i64 = 60;
/// Where tokens go once a session has `MAX_NAMES` names of one kind; in
/// parentheses so no skill, plugin or server name can be it.
pub const OTHER: &str = "(other)";
/// Most guardrail entries the wall is handed at once, newest first.
pub const GUARDRAIL_VIEW: usize = 200;
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

/// A session's tokens by the skill, plugin and MCP server active for the
/// request (`token.usage`'s `skill.name`, `plugin.name` and
/// `mcp_server.name`). Claude Code redacts user-defined MCP servers to
/// `custom` and third-party plugins and their skills to `third-party` unless
/// `OTEL_LOG_TOOL_DETAILS` is set.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Attribution {
    pub skills: BTreeMap<String, u64>,
    pub plugins: BTreeMap<String, u64>,
    pub mcp_servers: BTreeMap<String, u64>,
}

/// The key `name` is kept under in `map`: itself, or `OTHER` once `map` holds
/// `max` others.
fn capped<'a, V>(map: &BTreeMap<String, V>, name: &'a str, max: usize) -> &'a str {
    let named = map.len() - usize::from(map.contains_key(OTHER));
    if map.contains_key(name) || named < max {
        name
    } else {
        OTHER
    }
}

/// Add `n` to `name`, or to `OTHER` once `map` holds `MAX_NAMES` others.
fn attribute(map: &mut BTreeMap<String, u64>, name: &str, n: u64) {
    let key = capped(map, name, MAX_NAMES);
    let slot = map.entry(key.to_string()).or_default();
    *slot = slot.saturating_add(n);
}

/// One model's share of a session's tokens and cost estimate (the `model`
/// attribute of `token.usage` and `cost.usage`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ModelTotals {
    pub tokens: Tokens,
    /// In millionths of a US dollar, as `Totals` keeps it.
    pub cost_usd_estimate_micros: u64,
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
    /// Tokens by skill, plugin and MCP server, per session.
    pub attribution: BTreeMap<String, Attribution>,
    /// Tokens and cost by model, per session.
    pub models: BTreeMap<String, BTreeMap<String, ModelTotals>>,
    /// The voice (the fleet file's key, such as `af_heart`) each session had
    /// when it was first seen with one, so its tokens stay with its character
    /// after its card is gone.
    pub voices: BTreeMap<String, String>,
    /// The sessions in `voices` whose voice is the repo's home voice, which a
    /// later held voice, or the home voice of a repo it moves to, replaces, as
    /// on the card.
    #[serde(skip_serializing_if = "BTreeSet::is_empty")]
    pub home_voices: BTreeSet<String>,
    /// What told each session's card apart when last seen (its name, else its
    /// repo), so its row keeps it after the card is gone.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,
    /// The character the wall cast each session with no cast voice of its own
    /// (crate::picks), so its tokens stay with that character after its card
    /// is gone.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub picks: BTreeMap<String, String>,
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

/// A stretch of time in which the receiver was not listening, in epoch
/// seconds. A session alive during it may have lost exports.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Gap {
    pub from: i64,
    pub to: i64,
}

impl Gap {
    /// Whether `[from, to]` overlaps it, both ends included.
    pub fn overlaps(&self, from: i64, to: i64) -> bool {
        from <= self.to && to >= self.from
    }
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
    /// Per session, the receiver time of its latest counted cumulative point:
    /// its running total reached us then.
    cumulative_at: BTreeMap<String, i64>,
    /// When the receiver was down, oldest first.
    gaps: Vec<Gap>,
    /// The sessions in the day files when the state file could not be read,
    /// so their cumulative baselines were lost, and when it was set aside.
    reseed: BTreeMap<String, i64>,
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
    /// Names the ledger does not count, and values that are not numbers or
    /// are negative.
    pub ignored: usize,
    /// Cumulative points that only set a baseline: their running total was
    /// counted before the state file was lost.
    pub seeded: usize,
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

fn is_tokens(f: Field) -> bool {
    matches!(
        f,
        Field::Input | Field::Output | Field::CacheRead | Field::CacheCreation
    )
}

/// The epoch second `dir`'s `alive` file holds, if it is readable.
fn read_alive(dir: &Path) -> Option<i64> {
    std::fs::read_to_string(dir.join(ALIVE_FILE))
        .ok()?
        .trim()
        .parse()
        .ok()
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
    // A new file, never one already there: a link planted at the tmp name is
    // removed, not written through.
    match std::fs::remove_file(&tmp) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .and_then(|mut f| std::io::Write::write_all(&mut f, bytes))?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// The last `n` parts of `path`, joined by `/`: `ledger/2026-10-28.json` for a
/// day file, named as from the data folder without the user's home in it.
fn tail(path: &Path, n: usize) -> String {
    let parts: Vec<_> = path.iter().map(|p| p.to_string_lossy()).collect();
    parts[parts.len().saturating_sub(n)..].join("/")
}

/// Read `path` as `T`: the default when there is no file, and the default
/// after setting a file it could not read or parse aside as `<name>.bad`. A
/// file that can be neither moved nor copied is reported and replaced at the
/// next save: once this run counts, its baselines are stale anyway.
fn load<T: Default + for<'de> Deserialize<'de>>(path: &Path, problems: &mut Vec<String>) -> T {
    load_checked(path, problems).0
}

/// `load`, and whether a file was there that could not be read.
fn load_checked<T: Default + for<'de> Deserialize<'de>>(
    path: &Path,
    problems: &mut Vec<String>,
) -> (T, bool) {
    let failed = |e: &dyn std::fmt::Display, problems: &mut Vec<String>| {
        let mut aside = path.as_os_str().to_owned();
        aside.push(".bad");
        // A locked file may still copy where it cannot move.
        let kept = std::fs::rename(path, &aside)
            .or_else(|_| std::fs::copy(path, &aside).map(|_| ()))
            .map_or_else(|a| format!("not set aside ({a})"), |()| "set aside".into());
        problems.push(format!("{} {kept}: {e}", tail(path, 2)));
        (T::default(), true)
    };
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return (T::default(), false),
        Err(e) => return failed(&e, problems),
    };
    match serde_json::from_str(&text) {
        Ok(v) => (v, false),
        Err(e) => failed(&e, problems),
    }
}

/// The receiver gaps recorded in `dir`'s state file, oldest first; none when
/// there is no state file. It only reads: an unreadable file is an error and
/// stays where it is.
pub fn read_gaps(dir: &Path) -> Result<Vec<Gap>, String> {
    let path = dir.join(STATE_FILE);
    let failed = |e: &dyn std::fmt::Display| format!("{}: {e}", path.display());
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str::<State>(&text)
            .map(|s| s.gaps)
            .map_err(|e| failed(&e)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(failed(&e)),
    }
}

/// Every session in `dir`'s readable day files, with its latest update.
fn day_file_sessions(dir: &Path) -> BTreeMap<String, i64> {
    let mut out = BTreeMap::new();
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".json") || file_day(&name).is_none() {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(e.path()) else {
            continue;
        };
        if let Ok(day) = serde_json::from_str::<Day>(&text) {
            for (id, t) in day.sessions {
                let at = out.entry(id).or_insert(t.updated_at);
                *at = (*at).max(t.updated_at);
            }
        }
    }
    out
}

/// The ledger: today's file, lifetime totals, and what stops a retried
/// export from counting twice.
pub struct Ledger {
    dir: Option<PathBuf>,
    tz: TimeZone,
    day: Day,
    state: State,
    receiver: Option<Receiver>,
    /// When `alive` was last written by this run.
    alive_at: Option<i64>,
}

/// Whether the OTLP receiver is listening, for the wall to show.
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Receiver {
    pub addr: String,
    pub listening: bool,
    /// Why it is not listening, such as the port being taken.
    pub error: Option<String>,
}

/// Today's ledger as the wall's drawer reads it.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct TodayView {
    /// Today's file, its guardrail log moved to `guardrails`.
    pub day: Day,
    pub receiver: Option<Receiver>,
    /// The newest `GUARDRAIL_VIEW` entries, newest first, of one session's
    /// when the view is filtered to it.
    pub guardrails: Vec<Guardrail>,
    /// How many entries matched before the cut.
    pub guardrails_total: usize,
}

/// Drop the least recently updated sessions past `MAX_SESSIONS`, never
/// `keep`, the one just updated.
/// Returns the sessions dropped.
fn cap_sessions(map: &mut BTreeMap<String, Totals>, keep: &str) -> Vec<String> {
    let mut dropped = Vec::new();
    while map.len() > MAX_SESSIONS {
        let oldest = map
            .iter()
            .filter(|(id, _)| id.as_str() != keep)
            .min_by_key(|(id, t)| (t.updated_at, id.as_str()))
            .map(|(id, _)| id.clone());
        let Some(id) = oldest else { break };
        map.remove(&id);
        dropped.push(id);
    }
    dropped
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
            alive_at: None,
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
            problems.push(format!("{}: {e}", tail(&dir, 1)));
        }
        let (mut state, lost): (State, bool) = load_checked(&dir.join(STATE_FILE), &mut problems);
        state.version = VERSION;
        if lost {
            // The most recently updated sessions, as the session maps keep.
            let mut found: Vec<_> = day_file_sessions(&dir).into_iter().collect();
            found.sort_by_key(|(id, at)| (std::cmp::Reverse(*at), id.clone()));
            found.truncate(MAX_SESSIONS);
            state.reseed = found.into_iter().map(|(id, _)| (id, now)).collect();
        }
        let mut ledger = Ledger {
            dir: Some(dir),
            tz,
            day: Day::default(),
            state,
            receiver: None,
            alive_at: None,
        };
        ledger.start_day(now, &mut problems);
        if lost {
            // Whatever ran before now may have lost tokens with the baselines.
            ledger.state.gaps.push(Gap { from: 0, to: now });
            // Saved at once: a quit before the first export must not lose it.
            if let Err(e) = ledger.save() {
                problems.push(format!("{STATE_FILE}: {e}"));
            }
        }
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
        self.state.cumulative_at.retain(|_, at| *at >= horizon);
        self.state.reseed.retain(|_, at| *at >= horizon);
        self.state.gaps.retain(|g| g.to >= horizon);
    }

    /// The receiver started listening at `now`: the time since the last
    /// stamp, or everything before now when there never was one, is a gap.
    /// Stamps `alive` and saves.
    pub fn note_listening(&mut self, now: i64) -> std::io::Result<()> {
        let from = self
            .dir
            .as_deref()
            .and_then(read_alive)
            .map_or(0, |at| at.min(now));
        self.state.gaps.push(Gap { from, to: now });
        let horizon = now - RETENTION_DAYS * DAY;
        self.state.gaps.retain(|g| g.to >= horizon);
        let extra = self.state.gaps.len().saturating_sub(MAX_GAPS);
        self.state.gaps.drain(..extra);
        self.write_alive(now);
        self.save()
    }

    fn write_alive(&mut self, now: i64) {
        if let Some(dir) = &self.dir {
            let _ = write_atomic(&dir.join(ALIVE_FILE), now.to_string().as_bytes());
        }
        self.alive_at = Some(now);
    }

    /// Write `alive` when the receiver is listening and `ALIVE_EVERY` has
    /// passed since the last stamp. Nothing is stamped while it is not
    /// listening, so that time reads as a gap at the next start. Returns
    /// whether it wrote.
    pub fn stamp_alive(&mut self, now: i64) -> bool {
        if !self.receiver.as_ref().is_some_and(|r| r.listening) {
            return false;
        }
        // A clock that went backwards stamps at once.
        if self
            .alive_at
            .is_some_and(|at| (0..ALIVE_EVERY).contains(&(now - at)))
        {
            return false;
        }
        self.write_alive(now);
        true
    }

    /// Whether `[from, to]` overlaps a time the receiver was not listening.
    pub fn overlaps_gap(&self, from: i64, to: i64) -> bool {
        self.state.gaps.iter().any(|g| g.overlaps(from, to))
    }

    /// Whether `session`, alive over `[from, to]`, may have lost exports in a
    /// gap: a gap overlaps it and no cumulative point arrived at or after the
    /// gap's end, which would have carried the running total. A session that
    /// lost its baselines always may have.
    // research(2026-10): cumulative OTLP points carry the running total, so a later one restores a gap (Grafana and Last9 Claude Code guides)
    pub fn lost_in_gap(&self, session: &str, from: i64, to: i64) -> bool {
        if self.state.reseed.contains_key(session) {
            return true;
        }
        let restored = self.state.cumulative_at.get(session).copied();
        self.state
            .gaps
            .iter()
            .any(|g| g.overlaps(from, to) && restored.is_none_or(|at| at < g.to))
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

    /// Today's ledger for the wall, its guardrail log cut to the newest
    /// `GUARDRAIL_VIEW` and, given a `session`, filtered to that session.
    pub fn today_view(&self, now: i64, session: Option<&str>) -> TodayView {
        let name = day_name(now, &self.tz);
        let current = self.day.day == name;
        // Every field named, so a new one cannot be left off the wall unseen.
        let Day {
            version: _,
            day: _,
            sessions,
            guardrails: _,
            attribution,
            models,
            voices,
            home_voices,
            labels,
            picks,
            no_session,
        } = &self.day;
        let day = if current {
            Day {
                version: VERSION,
                day: name,
                sessions: sessions.clone(),
                guardrails: Vec::new(),
                attribution: attribution.clone(),
                models: models.clone(),
                voices: voices.clone(),
                // The drawer never merges home-voiced sessions into one row.
                home_voices: home_voices.clone(),
                labels: labels.clone(),
                picks: picks.clone(),
                no_session: *no_session,
            }
        } else {
            Day {
                version: VERSION,
                day: name,
                ..Day::default()
            }
        };
        // Exports can arrive late, so the order is by when each happened.
        let mut matching: Vec<&Guardrail> = if current {
            self.day
                .guardrails
                .iter()
                .filter(|g| session.is_none_or(|s| g.session_id == s))
                .collect()
        } else {
            Vec::new()
        };
        matching.sort_by_key(|g| std::cmp::Reverse(g.at));
        TodayView {
            guardrails_total: matching.len(),
            guardrails: matching.into_iter().take(GUARDRAIL_VIEW).cloned().collect(),
            receiver: self.receiver.clone(),
            day,
        }
    }

    /// Remember `voice` for `session` if `now`'s file has the session and no
    /// voice for it yet, or only a `home` one that this voice replaces (a held
    /// one, or another repo's home), moving to `now`'s day first. Returns
    /// whether it recorded one; the caller saves.
    pub fn note_voice(&mut self, session: &str, voice: &str, home: bool, now: i64) -> bool {
        // A clock read before the receiver rolled must not roll the day back.
        if day_name(now, &self.tz) < self.day.day {
            return false;
        }
        self.roll(now);
        if voice.is_empty() || !self.day.sessions.contains_key(session) {
            return false;
        }
        match self.day.voices.get(session) {
            None => {}
            Some(v) if v == voice && home == self.day.home_voices.contains(session) => {
                return false
            }
            Some(_) if self.day.home_voices.contains(session) => {}
            Some(_) => return false,
        }
        self.day.voices.insert(session.into(), voice.into());
        if home {
            self.day.home_voices.insert(session.into());
        } else {
            self.day.home_voices.remove(session);
        }
        true
    }

    /// Remember `label` as what tells `session`'s card apart, the latest one
    /// winning, if `now`'s file has the session, moving to `now`'s day first.
    /// Returns whether it changed; the caller saves.
    pub fn note_label(&mut self, session: &str, label: &str, now: i64) -> bool {
        if day_name(now, &self.tz) < self.day.day {
            return false;
        }
        self.roll(now);
        if label.is_empty() || !self.day.sessions.contains_key(session) {
            return false;
        }
        let label: String = label.chars().take(MAX_LABEL).collect();
        if self.day.labels.get(session) == Some(&label) {
            return false;
        }
        self.day.labels.insert(session.into(), label);
        true
    }

    /// Remember `pick` as the character the wall cast `session`, the latest
    /// one winning, if `now`'s file has the session, moving to `now`'s day first.
    pub fn note_pick(&mut self, session: &str, pick: &str, now: i64) -> bool {
        if day_name(now, &self.tz) < self.day.day {
            return false;
        }
        self.roll(now);
        if pick.is_empty() || !self.day.sessions.contains_key(session) {
            return false;
        }
        if self.day.picks.get(session).map(String::as_str) == Some(pick) {
            return false;
        }
        self.day.picks.insert(session.into(), pick.into());
        true
    }

    /// Forget the pick recorded for `session` once it wears its own voice
    /// again, so its tokens follow the character it wears. Returns whether
    /// one was recorded.
    pub fn forget_pick(&mut self, session: &str) -> bool {
        self.day.picks.remove(session).is_some()
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
        }
        let dropped = cap_sessions(&mut self.day.sessions, session);
        for id in dropped {
            self.day.attribution.remove(&id);
            self.day.models.remove(&id);
            self.day.voices.remove(&id);
            self.day.home_voices.remove(&id);
            self.day.labels.remove(&id);
            self.day.picks.remove(&id);
        }
        cap_sessions(&mut self.state.sessions, session);
    }

    /// Credit `n` tokens of a counted `token.usage` point to its skill,
    /// plugin and MCP server, if it names any.
    fn attribute(&mut self, session: &str, p: &Point, n: u64) {
        const KEYS: [&str; 3] = ["skill.name", "plugin.name", "mcp_server.name"];
        if !KEYS.iter().any(|k| p.attrs.contains_key(*k)) {
            return;
        }
        let a = self.day.attribution.entry(session.to_string()).or_default();
        for (key, map) in KEYS
            .into_iter()
            .zip([&mut a.skills, &mut a.plugins, &mut a.mcp_servers])
        {
            if let Some(name) = p.attrs.get(key) {
                attribute(map, name, n);
            }
        }
    }

    /// Credit a counted `token.usage` or `cost.usage` point's `n` to its
    /// `model`, if it names one.
    fn credit_model(&mut self, session: &str, p: &Point, field: Field, n: u64) {
        let Some(model) = p.attrs.get("model") else {
            return;
        };
        let models = self.day.models.entry(session.to_string()).or_default();
        let key = capped(models, model, MAX_MODELS).to_string();
        let m = models.entry(key).or_default();
        let slot = match field {
            Field::Input => &mut m.tokens.input,
            Field::Output => &mut m.tokens.output,
            Field::CacheRead => &mut m.tokens.cache_read,
            Field::CacheCreation => &mut m.tokens.cache_creation,
            _ => &mut m.cost_usd_estimate_micros,
        };
        *slot = slot.saturating_add(n);
    }

    /// Note that a cumulative point of `session` reached us at `now`, and
    /// drop the oldest notes past `MAX_SESSIONS`.
    fn mark_cumulative(&mut self, session: &str, now: i64) {
        let map = &mut self.state.cumulative_at;
        map.insert(session.to_string(), now);
        while map.len() > MAX_SESSIONS {
            let oldest = map
                .iter()
                .filter(|(id, _)| id.as_str() != session)
                .min_by_key(|(id, at)| (**at, id.as_str()))
                .map(|(id, _)| id.clone());
            let Some(id) = oldest else { break };
            map.remove(&id);
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
            // Both ends are in the dedupe key and the cumulative baseline.
            if secs(p.start_ns.max(p.end_ns)) > now.saturating_add(MAX_AHEAD) {
                tally.future += 1;
                continue;
            }
            // A counter is never negative, and a negative total would be
            // kept as the next point's baseline.
            let Some(value) = scaled(p.value, scale).filter(|_| p.value >= 0.0) else {
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
                    let reseeded = self.state.reseed.contains_key(session);
                    let seed = before.is_none() && reseeded;
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
                    if seed {
                        tally.seeded += 1;
                        continue;
                    }
                    // Arrival time, not the point's own: the exporter's
                    // clock can drift from this one. A session that lost
                    // its baselines stays partial.
                    if !reseeded {
                        self.mark_cumulative(session, now);
                    }
                    amount
                }
            };
            let Ok(n) = u64::try_from(amount) else {
                tally.ignored += 1;
                continue;
            };
            self.add(session, field, n, now);
            if is_tokens(field) {
                self.attribute(session, p, n);
            }
            if is_tokens(field) || field == Field::Cost {
                self.credit_model(session, p, field, n);
            }
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

    /// Write the state file and today's file. A ledger with no folder has
    /// nothing to write.
    pub fn save(&self) -> std::io::Result<()> {
        let Some(dir) = &self.dir else {
            return Ok(());
        };
        // State first: a crash between the two undercounts one export
        // rather than counting it twice.
        let state = serde_json::to_vec(&self.state).map_err(std::io::Error::other)?;
        write_atomic(&dir.join(STATE_FILE), &state)?;
        let day = serde_json::to_vec_pretty(&self.day).map_err(std::io::Error::other)?;
        write_atomic(&dir.join(format!("{}.json", self.day.day)), &day)
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

    #[test]
    fn a_point_starting_in_the_future_is_dropped_and_keeps_no_baseline() {
        let s = |n: u64| n * 1_000_000_000;
        let future = 8_993_548_800u64; // 2255-01-01
        let mut l = Ledger::in_memory(NOW);
        let t = l.record_metrics(&metrics(&cumulative(s(future), s(NOW as u64), 7.0)), NOW);
        assert_eq!((t.counted, t.future), (0, 1));
        assert!(l.state.series.is_empty());
        assert_eq!(l.session("s1"), None);
        // The series still counts once a sane run starts.
        let t = l.record_metrics(
            &metrics(&cumulative(s(NOW as u64 - 60), s(NOW as u64), 3.0)),
            NOW,
        );
        assert_eq!(t.counted, 1);
        assert_eq!(l.session("s1").unwrap().lines_added, 3);
        // A delta point too, since its start is in its dedupe key.
        let mut d = point_at("s2", NOW as u64);
        d["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["sum"]["dataPoints"][0]
            ["startTimeUnixNano"] = json!(s(future).to_string());
        assert_eq!(l.record_metrics(&metrics(&d), NOW).future, 1);
    }

    /// A delta `token.usage` point of `value` tokens of `ty`, ending at `end`,
    /// carrying `attrs` beside its session.
    fn tokens_at(session: &str, ty: &str, value: u64, end: u64, attrs: &[(&str, &str)]) -> Value {
        let ns = (end * 1_000_000_000).to_string();
        let mut a = vec![
            json!({"key":"session.id","value":{"stringValue":session}}),
            json!({"key":"type","value":{"stringValue":ty}}),
        ];
        for (k, v) in attrs {
            a.push(json!({"key":k,"value":{"stringValue":v}}));
        }
        json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":a,"startTimeUnixNano":ns,"timeUnixNano":ns,"asDouble":value}]}}]}]}]})
    }

    #[test]
    fn tokens_are_attributed_to_their_skill_plugin_and_mcp_server() {
        let mut l = Ledger::in_memory(NOW);
        let now = NOW as u64;
        let skill = [
            ("skill.name", "third-party"),
            ("plugin.name", "third-party"),
        ];
        l.record_metrics(&metrics(&tokens_at("s1", "input", 100, now, &skill)), NOW);
        l.record_metrics(
            &metrics(&tokens_at("s1", "cacheRead", 900, now - 1, &skill)),
            NOW,
        );
        let mcp = [("mcp_server.name", "custom"), ("mcp_tool.name", "custom")];
        l.record_metrics(&metrics(&tokens_at("s1", "output", 40, now - 2, &mcp)), NOW);
        // No attribution, and a retried export: neither adds a name.
        l.record_metrics(&metrics(&tokens_at("s1", "output", 7, now - 3, &[])), NOW);
        let t = l.record_metrics(&metrics(&tokens_at("s1", "input", 100, now, &skill)), NOW);
        assert_eq!(t.duplicate, 1);

        let a = &l.day().attribution["s1"];
        assert_eq!(a.skills, BTreeMap::from([("third-party".into(), 1000)]));
        assert_eq!(a.plugins, BTreeMap::from([("third-party".into(), 1000)]));
        assert_eq!(a.mcp_servers, BTreeMap::from([("custom".into(), 40)]));
        // Tokens still add up whatever their attribution.
        let tokens = &l.day().sessions["s1"].tokens;
        assert_eq!(
            (tokens.input, tokens.output, tokens.cache_read),
            (100, 47, 900)
        );
    }

    #[test]
    fn attribution_names_past_the_cap_fold_into_other() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_NAMES as u64 + 5) {
            let name = format!("skill-{n:03}");
            let p = tokens_at("s1", "output", 1, NOW as u64 - n, &[("skill.name", &name)]);
            l.record_metrics(&metrics(&p), NOW);
        }
        let skills = &l.day().attribution["s1"].skills;
        assert_eq!(skills.len(), MAX_NAMES + 1);
        assert_eq!(skills[OTHER], 5);
        assert_eq!(skills.values().sum::<u64>(), MAX_NAMES as u64 + 5);
        // A source name that looks like the cap's key is not merged into it.
        assert!(!OTHER
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_:.".contains(c)));
        // A name already kept still counts under its own name.
        let p = tokens_at(
            "s1",
            "output",
            1,
            NOW as u64 + 1,
            &[("skill.name", "skill-000")],
        );
        l.record_metrics(&metrics(&p), NOW);
        assert_eq!(l.day().attribution["s1"].skills["skill-000"], 2);
    }

    #[test]
    fn a_dropped_session_takes_its_attribution_with_it() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_SESSIONS as u64 + 3) {
            let p = tokens_at(
                &format!("s{n}"),
                "output",
                1,
                NOW as u64,
                &[("skill.name", "x")],
            );
            l.record_metrics(&metrics(&p), NOW + n as i64);
        }
        let day = l.day();
        assert!(day.attribution.len() <= MAX_SESSIONS);
        assert!(day
            .attribution
            .keys()
            .all(|id| day.sessions.contains_key(id)));
        assert!(day
            .attribution
            .contains_key(&format!("s{}", MAX_SESSIONS + 2)));
    }

    #[test]
    fn today_is_empty_once_the_day_has_rolled_without_an_export() {
        let mut l = Ledger::in_memory(NOW);
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 5, NOW as u64, &[])),
            NOW,
        );
        l.day.guardrails.push(Guardrail {
            at: NOW,
            session_id: "s1".into(),
            tool_name: "Bash".into(),
            source: "hook".into(),
        });
        let today = l.today_view(NOW, None);
        assert_eq!(today.day.day, "2026-10-20");
        assert_eq!(today.day.sessions["s1"].tokens.output, 5);
        assert_eq!(today.guardrails_total, 1);
        // The last second of the day, then the first of the next.
        let midnight = 1_792_540_800; // 2026-10-21T00:00:00Z
        assert_eq!(l.today_view(midnight - 1, None).day.day, "2026-10-20");
        let tomorrow = l.today_view(midnight, None);
        assert_eq!(tomorrow.day.day, "2026-10-21");
        assert!(tomorrow.day.sessions.is_empty() && tomorrow.day.attribution.is_empty());
        assert_eq!(
            (tomorrow.guardrails_total, tomorrow.day.version),
            (0, VERSION)
        );
    }

    #[test]
    fn a_day_file_without_attribution_loads_and_one_with_it_round_trips() {
        let dir = Scratch::new("ledger-attr");
        dir.write("2026-10-20.json", r#"{"day":"2026-10-20","sessions":{}}"#);
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        assert!(l.day().attribution.is_empty());
        let p = tokens_at(
            "s1",
            "output",
            3,
            NOW as u64,
            &[("mcp_server.name", "github")],
        );
        l.record_metrics(&metrics(&p), NOW);
        l.save().unwrap();
        let (again, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(again.day().attribution["s1"].mcp_servers["github"], 3);
    }

    #[test]
    fn the_wall_gets_the_newest_guardrails_first_and_can_filter_by_session() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(GUARDRAIL_VIEW + 10) {
            let session = if n % 2 == 0 { "even" } else { "odd" };
            l.day.guardrails.push(Guardrail {
                at: NOW - 1000 + n as i64,
                session_id: session.into(),
                tool_name: format!("tool{n}"),
                source: "hook".into(),
            });
        }
        // One that arrived late but happened first sorts by when it happened.
        l.day.guardrails.push(Guardrail {
            at: NOW - 5000,
            session_id: "late".into(),
            tool_name: "late".into(),
            source: "config".into(),
        });
        let all = l.today_view(NOW, None);
        assert_eq!(all.guardrails_total, GUARDRAIL_VIEW + 11);
        assert!(all.guardrails.windows(2).all(|w| w[0].at >= w[1].at));
        assert!(all.guardrails.iter().all(|g| g.tool_name != "late"));
        l.day.guardrails.pop();
        let all = l.today_view(NOW, None);
        assert_eq!(all.guardrails_total, GUARDRAIL_VIEW + 10);
        assert_eq!(all.guardrails.len(), GUARDRAIL_VIEW);
        assert_eq!(
            all.guardrails[0].tool_name,
            format!("tool{}", GUARDRAIL_VIEW + 9)
        );
        assert!(all.day.guardrails.is_empty());
        let odd = l.today_view(NOW, Some("odd"));
        assert_eq!(odd.guardrails_total, (GUARDRAIL_VIEW + 10) / 2);
        assert!(odd.guardrails.iter().all(|g| g.session_id == "odd"));
        assert!(l.today_view(NOW, Some("none")).guardrails.is_empty());
        assert_eq!(all.receiver, None);
        l.set_receiver(Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: false,
            error: Some("taken".into()),
        });
        let v = serde_json::to_value(l.today_view(NOW, None)).unwrap();
        assert_eq!(v["receiver"]["error"], "taken");
        assert_eq!(v["day"]["day"], "2026-10-20");
    }

    /// A delta `cost.usage` point of `usd` dollars for `model`.
    fn cost_at(session: &str, usd: f64, end: u64, model: &str) -> Value {
        let ns = (end * 1_000_000_000).to_string();
        let a = json!([
            {"key":"session.id","value":{"stringValue":session}},
            {"key":"model","value":{"stringValue":model}},
        ]);
        json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.cost.usage","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":a,"startTimeUnixNano":ns,"timeUnixNano":ns,"asDouble":usd}]}}]}]}]})
    }

    #[test]
    fn tokens_and_cost_are_kept_per_session_and_model() {
        let mut l = Ledger::in_memory(NOW);
        let now = NOW as u64;
        let opus = [("model", "claude-opus-5-5")];
        let haiku = [("model", "claude-haiku-5")];
        l.record_metrics(
            &metrics(&tokens_at("s1", "cacheRead", 900, now, &opus)),
            NOW,
        );
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 40, now - 1, &opus)),
            NOW,
        );
        l.record_metrics(&metrics(&tokens_at("s1", "input", 7, now - 2, &haiku)), NOW);
        l.record_metrics(
            &metrics(&cost_at("s1", 0.5, now - 3, "claude-opus-5-5")),
            NOW,
        );
        // No model attribute: counted in the totals, under no model.
        l.record_metrics(&metrics(&tokens_at("s1", "output", 5, now - 4, &[])), NOW);
        // A retried export counts once, models included.
        let again = l.record_metrics(&metrics(&tokens_at("s1", "input", 7, now - 2, &haiku)), NOW);
        assert_eq!(again.duplicate, 1);

        let m = &l.day().models["s1"];
        assert_eq!(m.len(), 2);
        let opus = &m["claude-opus-5-5"];
        assert_eq!((opus.tokens.cache_read, opus.tokens.output), (900, 40));
        assert_eq!(opus.cost_usd_estimate_micros, 500_000);
        assert_eq!(m["claude-haiku-5"].tokens.input, 7);
        assert_eq!(m["claude-haiku-5"].cost_usd_estimate_micros, 0);
        assert_eq!(l.day().sessions["s1"].tokens.output, 45);
    }

    #[test]
    fn models_past_the_cap_fold_into_other() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_MODELS as u64 + 4) {
            let name = format!("model-{n:03}");
            let p = tokens_at("s1", "output", 1, NOW as u64 - n, &[("model", &name)]);
            l.record_metrics(&metrics(&p), NOW);
        }
        let m = &l.day().models["s1"];
        assert_eq!(m.len(), MAX_MODELS + 1);
        assert_eq!(m[OTHER].tokens.output, 4);
        // A kept model still counts under its own name, cost too.
        l.record_metrics(
            &metrics(&cost_at("s1", 1.0, NOW as u64 + 1, "model-000")),
            NOW,
        );
        assert_eq!(
            l.day().models["s1"]["model-000"].cost_usd_estimate_micros,
            1_000_000
        );
        assert_eq!(l.day().models["s1"].len(), MAX_MODELS + 1);
    }

    #[test]
    fn a_dropped_session_takes_its_models_with_it() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_SESSIONS as u64 + 3) {
            let p = tokens_at(
                &format!("s{n}"),
                "output",
                1,
                NOW as u64,
                &[("model", "claude-opus-5-5")],
            );
            l.record_metrics(&metrics(&p), NOW + n as i64);
        }
        let day = l.day();
        assert!(day.models.len() <= MAX_SESSIONS);
        assert!(day.models.keys().all(|id| day.sessions.contains_key(id)));
        assert!(day.models.contains_key(&format!("s{}", MAX_SESSIONS + 2)));
    }

    #[test]
    fn a_day_file_without_models_loads_and_one_with_them_round_trips() {
        let dir = Scratch::new("ledger-models");
        dir.write("2026-10-20.json", r#"{"day":"2026-10-20","sessions":{}}"#);
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        assert!(l.day().models.is_empty());
        let p = tokens_at("s1", "output", 3, NOW as u64, &[("model", "m")]);
        l.record_metrics(&metrics(&p), NOW);
        l.save().unwrap();
        let (again, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(again.day().models["s1"]["m"].tokens.output, 3);
        // The wall's view carries them too.
        assert_eq!(
            l.today_view(NOW, None).day.models["s1"]["m"].tokens.output,
            3
        );
    }

    /// One cumulative `cacheRead` point of `session`, exported at `at`
    /// seconds, its process started at `at0`.
    fn tokens(session: &str, at0: i64, at: i64, value: f64) -> Vec<Point> {
        let ns = |n: i64| (n as u64 * 1_000_000_000).to_string();
        metrics(
            &json!({"resourceMetrics":[{"resource":{"attributes":[]},"scopeMetrics":[{"scope":{"name":"s"},"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":session}},{"key":"type","value":{"stringValue":"cacheRead"}}],"startTimeUnixNano":ns(at0),"timeUnixNano":ns(at),"asDouble":value}]}}]}]}]}),
        )
    }

    fn cache_read(l: &Ledger, session: &str) -> u64 {
        l.session(session).unwrap().tokens.cache_read
    }

    #[test]
    fn a_gap_with_no_exports_then_one_cumulative_export_restores_the_total() {
        let mut l = Ledger::in_memory(NOW);
        l.record_metrics(&tokens("s1", NOW - 60, NOW, 100.0), NOW);
        l.record_metrics(&tokens("s1", NOW - 60, NOW + 15, 250.0), NOW + 15);
        // Ten minutes with no receiver, then one export of the running total.
        let back = NOW + 15 + 600;
        let t = l.record_metrics(&tokens("s1", NOW - 60, back, 900.0), back);
        assert_eq!(t.counted, 1);
        assert_eq!(cache_read(&l, "s1"), 900);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 900);
    }

    #[test]
    fn a_receiver_restart_mid_session_double_counts_nothing() {
        let dir = Scratch::new("ledger-cumulative-restart");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        l.record_metrics(&tokens("s1", NOW - 60, NOW, 100.0), NOW);
        l.record_metrics(&tokens("s1", NOW - 60, NOW + 15, 250.0), NOW + 15);
        l.save().unwrap();
        drop(l);
        let back = NOW + 120;
        let (mut l, _) = Ledger::open(dir.0.clone(), back, TimeZone::UTC);
        l.note_listening(back).unwrap();
        // The repeat of the last export before the restart.
        let t = l.record_metrics(&tokens("s1", NOW - 60, NOW + 15, 250.0), back);
        assert_eq!((t.counted, t.duplicate), (0, 1));
        l.record_metrics(&tokens("s1", NOW - 60, back, 400.0), back);
        assert_eq!(cache_read(&l, "s1"), 400);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 400);
    }

    #[test]
    fn a_cumulative_baseline_survives_midnight() {
        let dir = Scratch::new("ledger-cumulative-midnight");
        // 2026-10-21 23:59:00 UTC.
        let late = 1_792_627_140;
        let (mut l, _) = Ledger::open(dir.0.clone(), late, TimeZone::UTC);
        l.record_metrics(&tokens("s1", late - 600, late, 100.0), late);
        let yesterday = l.day().day.clone();
        l.save().unwrap();
        drop(l);
        let next = late + 120;
        let (mut l, _) = Ledger::open(dir.0.clone(), next, TimeZone::UTC);
        assert_ne!(l.day().day, yesterday);
        l.record_metrics(&tokens("s1", late - 600, next, 130.0), next);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 30);
        assert_eq!(cache_read(&l, "s1"), 130);
        let old: Day = load(&dir.0.join(format!("{yesterday}.json")), &mut Vec::new());
        assert_eq!(old.sessions["s1"].tokens.cache_read, 100);
    }

    #[test]
    fn delta_and_cumulative_sessions_count_side_by_side() {
        let mut l = Ledger::in_memory(NOW);
        let ns = (NOW as u64 * 1_000_000_000).to_string();
        let delta = metrics(
            &json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"d1"}},{"key":"type","value":{"stringValue":"cacheRead"}}],"startTimeUnixNano":ns.clone(),"timeUnixNano":ns,"asDouble":40}]}}]}]}]}),
        );
        l.record_metrics(&delta, NOW);
        l.record_metrics(&tokens("c1", NOW - 60, NOW, 100.0), NOW);
        l.record_metrics(&tokens("c1", NOW - 60, NOW + 15, 160.0), NOW + 15);
        assert_eq!(cache_read(&l, "d1"), 40);
        assert_eq!(cache_read(&l, "c1"), 160);
        assert_eq!(l.day().sessions["d1"].tokens.cache_read, 40);
    }

    #[test]
    fn an_export_after_a_gap_means_the_gap_lost_nothing() {
        let dir = Scratch::new("ledger-lost-in-gap");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        l.note_listening(NOW + 1000).unwrap(); // gap 0..NOW + 1000
        let (from, to) = (NOW + 500, NOW + 1100);
        assert!(l.lost_in_gap("s1", from, to), "no export at all");
        // A delta session never makes up for it.
        let ns = ((NOW + 1050) as u64 * 1_000_000_000).to_string();
        let delta = metrics(
            &json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"cacheRead"}}],"timeUnixNano":ns,"asDouble":5}]}}]}]}]}),
        );
        l.record_metrics(&delta, NOW + 1050);
        assert!(l.lost_in_gap("s1", from, to));
        // A cumulative export before the gap ended does not either.
        l.record_metrics(&tokens("s2", NOW, NOW + 900, 10.0), NOW + 900);
        assert!(l.lost_in_gap("s2", from, to));
        // One at or after the end does.
        l.record_metrics(&tokens("s2", NOW, NOW + 1000, 20.0), NOW + 1000);
        assert!(!l.lost_in_gap("s2", from, to));
        // A session outside every gap is never lost.
        assert!(!l.lost_in_gap("s1", NOW + 1001, NOW + 1100));
        // Saved with the state.
        l.save().unwrap();
        let (l, _) = Ledger::open(dir.0.clone(), NOW + 1300, TimeZone::UTC);
        assert!(!l.lost_in_gap("s2", from, to));
        assert!(l.lost_in_gap("s1", NOW + 100, NOW + 200));
    }

    #[test]
    fn cumulative_marks_are_capped_and_pruned_like_sessions() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_SESSIONS as i64 + 3) {
            let id = format!("s{n}");
            l.record_metrics(&tokens(&id, NOW, NOW + n, 1.0), NOW + n);
        }
        assert_eq!(l.state.cumulative_at.len(), MAX_SESSIONS);
        assert!(l
            .state
            .cumulative_at
            .contains_key(&format!("s{}", MAX_SESSIONS + 2)));
        let late = NOW + (RETENTION_DAYS + 2) * DAY;
        l.record_metrics(&[], late);
        assert!(l.state.cumulative_at.is_empty());
    }

    fn listening() -> Receiver {
        Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: true,
            error: None,
        }
    }

    #[test]
    fn the_first_listen_ever_records_everything_before_it_as_a_gap() {
        let dir = Scratch::new("ledger-gap-first");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(!l.overlaps_gap(0, NOW));
        l.note_listening(NOW).unwrap();
        assert!(l.overlaps_gap(NOW - 1000, NOW - 500));
        assert!(!l.overlaps_gap(NOW + 1, NOW + 100));
        assert_eq!(
            std::fs::read_to_string(dir.0.join(ALIVE_FILE)).unwrap(),
            NOW.to_string()
        );
    }

    #[test]
    fn the_time_since_the_last_stamp_is_a_gap_and_survives_a_restart() {
        let dir = Scratch::new("ledger-gap");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        l.note_listening(NOW).unwrap();
        l.set_receiver(listening());
        assert!(l.stamp_alive(NOW + 60));
        // Not stamped again inside the interval.
        assert!(!l.stamp_alive(NOW + 61));
        assert!(l.stamp_alive(NOW + 120));
        // The overlay is gone for ten minutes, then listens again.
        let back = NOW + 120 + 600;
        let (mut l, _) = Ledger::open(dir.0.clone(), back, TimeZone::UTC);
        l.note_listening(back).unwrap();
        assert!(l.overlaps_gap(NOW + 300, NOW + 301));
        assert!(
            !l.overlaps_gap(NOW + 60, NOW + 110),
            "the overlay was running"
        );
        assert!(!l.overlaps_gap(back + 1, back + 50));
        // Inclusive at both ends: a session ending as the overlay went away.
        assert!(l.overlaps_gap(NOW, NOW + 120));
        // Saved with the state, so a third start still knows it.
        let (l, _) = Ledger::open(dir.0.clone(), back + 5, TimeZone::UTC);
        assert!(l.overlaps_gap(NOW + 300, NOW + 301));
    }

    #[test]
    fn nothing_is_stamped_while_the_receiver_is_not_listening() {
        let dir = Scratch::new("ledger-gap-down");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(!l.stamp_alive(NOW));
        l.set_receiver(Receiver {
            addr: "127.0.0.1:4318".into(),
            listening: false,
            error: Some("address in use".into()),
        });
        assert!(!l.stamp_alive(NOW + 600));
        assert!(!dir.0.join(ALIVE_FILE).exists());
    }

    #[test]
    fn gaps_are_capped_and_pruned_with_the_retention() {
        let dir = Scratch::new("ledger-gap-cap");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        for n in 0..(MAX_GAPS as i64 + 5) {
            l.note_listening(NOW + n * 10).unwrap();
        }
        assert_eq!(l.state.gaps.len(), MAX_GAPS);
        // The oldest went: the first start's gap from 0 is no more.
        assert!(!l.overlaps_gap(0, 5));
        // A gap older than the retention goes with the next listen.
        let late = NOW + (RETENTION_DAYS + 2) * DAY;
        l.note_listening(late).unwrap();
        assert!(!l.overlaps_gap(NOW, NOW + 500));
        assert_eq!(l.state.gaps.len(), 1);
    }

    #[test]
    fn a_state_file_without_gaps_loads() {
        let dir = Scratch::new("ledger-gap-old");
        dir.write(STATE_FILE, r#"{"version":1,"sessions":{}}"#);
        let (l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        assert!(!l.overlaps_gap(0, NOW));
    }

    #[test]
    fn a_pre_gap_point_repeated_after_the_gap_leaves_the_session_partial() {
        let dir = Scratch::new("ledger-stale-repeat");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW - 100, TimeZone::UTC);
        l.note_listening(NOW - 100).unwrap();
        l.set_receiver(listening());
        l.record_metrics(&tokens("s1", NOW - 100, NOW, 100.0), NOW);
        // The overlay stamps at NOW + 10, closes, and listens again at NOW + 1000.
        assert!(l.stamp_alive(NOW + 10));
        l.note_listening(NOW + 1000).unwrap();
        // s1 ended at NOW + 500, inside the gap.
        let (from, to) = (NOW - 100, NOW + 500);
        assert!(l.lost_in_gap("s1", from, to));
        // Its last pre-gap export, retried after the gap, carries nothing new.
        let t = l.record_metrics(&tokens("s1", NOW - 100, NOW, 100.0), NOW + 1001);
        assert_eq!((t.counted, t.duplicate), (0, 1));
        assert!(l.lost_in_gap("s1", from, to));
        // One that moves the running total on restores it.
        l.record_metrics(&tokens("s1", NOW - 100, NOW + 500, 300.0), NOW + 1002);
        assert!(!l.lost_in_gap("s1", from, to));
        assert_eq!(cache_read(&l, "s1"), 300);
    }

    #[test]
    fn a_negative_or_nan_cumulative_value_is_ignored_and_keeps_no_baseline() {
        let mut l = Ledger::in_memory(NOW);
        let t = l.record_metrics(&tokens("s1", NOW - 60, NOW, -5.0), NOW);
        assert_eq!((t.counted, t.ignored), (0, 1));
        let mut nan = tokens("s1", NOW - 60, NOW + 5, 0.0);
        nan[0].value = f64::NAN;
        assert_eq!(l.record_metrics(&nan, NOW + 5).ignored, 1);
        let t = l.record_metrics(&tokens("s1", NOW - 60, NOW + 15, 100.0), NOW + 15);
        assert_eq!(t.counted, 1);
        assert_eq!(cache_read(&l, "s1"), 100);
    }

    #[test]
    fn an_unreadable_state_file_reseeds_baselines_and_marks_sessions_partial() {
        let dir = Scratch::new("ledger-state-bad");
        let today = day_name(NOW, &TimeZone::UTC);
        let yesterday = day_name(NOW - DAY, &TimeZone::UTC);
        dir.write(
            &format!("{today}.json"),
            r#"{"sessions":{"s1":{"tokens":{"cache_read":300}}}}"#,
        );
        // A session that ran over midnight has its earlier tokens in yesterday's file.
        dir.write(
            &format!("{yesterday}.json"),
            r#"{"sessions":{"s3":{"tokens":{"cache_read":70}}}}"#,
        );
        dir.write(STATE_FILE, "{not json");
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        named_from_its_folder(&problems, &dir);
        // The running total already counted 300 of these 550: it only seeds.
        let t = l.record_metrics(&tokens("s1", NOW - 600, NOW + 10, 550.0), NOW + 10);
        assert_eq!((t.counted, t.seeded), (0, 1));
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 300);
        l.record_metrics(&tokens("s1", NOW - 600, NOW + 25, 600.0), NOW + 25);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 350);
        // Tokens between the last save and the seed are gone: partial.
        assert!(l.lost_in_gap("s1", NOW - 600, NOW + 25));
        l.record_metrics(&tokens("s3", NOW - 900, NOW + 25, 90.0), NOW + 25);
        assert!(!l.day().sessions.contains_key("s3"));
        // A session the ledger never had counts its whole running total.
        l.record_metrics(&tokens("s2", NOW, NOW + 25, 40.0), NOW + 25);
        assert_eq!(l.day().sessions["s2"].tokens.cache_read, 40);
        // The seeded baselines are saved with the state and hold after a restart.
        l.save().unwrap();
        drop(l);
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW + 40, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        l.record_metrics(&tokens("s1", NOW - 600, NOW + 40, 610.0), NOW + 40);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 360);
        assert!(l.lost_in_gap("s1", NOW - 600, NOW + 40), "still partial");
        assert!(!l.lost_in_gap("s2", NOW + 30, NOW + 40));
    }

    /// The set-aside state file is named from the ledger's own folder
    /// (`ledger/state.json` in the app), never by the path above it, which
    /// holds the user's home.
    fn named_from_its_folder(problems: &[String], dir: &Scratch) {
        let folder = dir.0.file_name().unwrap().to_string_lossy();
        let p = problems
            .iter()
            .find(|p| p.contains("set aside"))
            .unwrap_or_else(|| panic!("{problems:?}"));
        assert!(
            p.starts_with(&format!("{folder}/{STATE_FILE} set aside: ")),
            "{p}"
        );
        let above = dir.0.parent().unwrap().to_string_lossy().into_owned();
        assert!(!p.contains(&above), "{p}");
    }

    #[test]
    fn a_ledger_folder_that_cannot_be_made_is_named_alone() {
        let dir = Scratch::new("ledger-blocked");
        dir.write("ledger", "a file where the folder goes");
        let (_, problems) = Ledger::open(dir.0.join("ledger"), NOW, TimeZone::UTC);
        let p = problems.first().unwrap_or_else(|| panic!("{problems:?}"));
        assert!(p.starts_with("ledger: "), "{p}");
        assert!(!p.contains(&dir.0.to_string_lossy().into_owned()), "{p}");
    }

    /// A ledger folder with `s1` at 300 cache tokens today and a state file
    /// that does not parse.
    fn lost_state(name: &str) -> Scratch {
        let dir = Scratch::new(name);
        let today = day_name(NOW, &TimeZone::UTC);
        dir.write(
            &format!("{today}.json"),
            r#"{"sessions":{"s1":{"tokens":{"cache_read":300}}}}"#,
        );
        dir.write(STATE_FILE, "{not json");
        dir
    }

    #[test]
    fn a_quit_before_any_export_keeps_the_reseed() {
        let dir = lost_state("ledger-reseed-quit");
        let (l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        named_from_its_folder(&problems, &dir);
        drop(l);
        let (l, problems) = Ledger::open(dir.0.clone(), NOW + 40, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        drop(l);
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW + 45, TimeZone::UTC);
        let t = l.record_metrics(&tokens("s1", NOW - 600, NOW + 50, 550.0), NOW + 50);
        assert_eq!((t.counted, t.seeded), (0, 1));
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 300);
        assert!(l.lost_in_gap("s1", NOW - 600, NOW + 50));
    }

    #[test]
    fn a_reseeded_session_stays_partial_across_a_restart() {
        let dir = lost_state("ledger-reseed-restart");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        l.note_listening(NOW).unwrap();
        let t = l.record_metrics(&tokens("s1", NOW - 600, NOW + 10, 550.0), NOW + 10);
        assert_eq!(t.seeded, 1);
        l.record_metrics(&tokens("s1", NOW - 600, NOW + 25, 560.0), NOW + 25);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 310);
        l.save().unwrap();
        drop(l);
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW + 40, TimeZone::UTC);
        l.note_listening(NOW + 40).unwrap();
        l.record_metrics(&tokens("s1", NOW - 600, NOW + 70, 600.0), NOW + 70);
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 350);
        // Partial whatever span is asked about, after cumulative points.
        assert!(l.lost_in_gap("s1", NOW - 600, NOW + 70));
        assert!(l.lost_in_gap("s1", NOW + 50, NOW + 70));
        // A series it never had, here a new model, only seeds.
        let ns = |n: i64| (n as u64 * 1_000_000_000).to_string();
        let model = metrics(
            &json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":2,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"cacheRead"}},{"key":"model","value":{"stringValue":"m2"}}],"startTimeUnixNano":ns(NOW + 50),"timeUnixNano":ns(NOW + 85),"asDouble":80}]}}]}]}]}),
        );
        let t = l.record_metrics(&model, NOW + 85);
        assert_eq!((t.counted, t.seeded), (0, 1));
        assert_eq!(l.day().sessions["s1"].tokens.cache_read, 350);
    }

    #[test]
    fn reseed_marks_are_capped_and_pruned_like_sessions() {
        let dir = Scratch::new("ledger-reseed-cap");
        let today = day_name(NOW, &TimeZone::UTC);
        let sessions: serde_json::Map<String, Value> = (0..MAX_SESSIONS as i64 + 3)
            .map(|n| (format!("s{n}"), json!({"updated_at": NOW - 1000 + n})))
            .collect();
        dir.write(
            &format!("{today}.json"),
            &json!({ "sessions": sessions }).to_string(),
        );
        dir.write(STATE_FILE, "{not json");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(l.state.reseed.len(), MAX_SESSIONS);
        // The least recently updated go.
        assert!(!l.state.reseed.contains_key("s0"));
        assert!(l
            .state
            .reseed
            .contains_key(&format!("s{}", MAX_SESSIONS + 2)));
        let late = NOW + (RETENTION_DAYS + 2) * DAY;
        l.record_metrics(&[], late);
        assert!(l.state.reseed.is_empty());
    }

    #[test]
    fn a_file_that_is_not_utf8_is_set_aside_not_overwritten() {
        let dir = Scratch::new("ledger-not-utf8");
        let today = day_name(NOW, &TimeZone::UTC);
        let bytes = b"{\"sessions\":\xff}";
        std::fs::write(dir.0.join(format!("{today}.json")), bytes).unwrap();
        std::fs::write(dir.0.join(STATE_FILE), bytes).unwrap();
        let (l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(problems.len(), 2, "{problems:?}");
        l.save().unwrap();
        for name in [format!("{today}.json"), STATE_FILE.to_string()] {
            let kept = std::fs::read(dir.0.join(format!("{name}.bad"))).unwrap();
            assert_eq!(kept, bytes, "{name}");
        }
        // The state counts as lost: the gap before the open is recorded.
        assert!(l.overlaps_gap(0, NOW));
    }

    #[test]
    fn a_voice_is_kept_for_a_session_in_todays_file_and_the_first_one_wins() {
        let mut l = Ledger::in_memory(NOW);
        // Not in the file yet: nothing to attach it to.
        assert!(!l.note_voice("s1", "af_heart", false, NOW));
        assert!(l.day().voices.is_empty());
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, NOW as u64, &[])),
            NOW,
        );
        assert!(l.note_voice("s1", "af_heart", false, NOW));
        assert!(!l.note_voice("s1", "af_heart", false, NOW), "unchanged");
        assert!(
            !l.note_voice("s1", "bf_emma", false, NOW),
            "the first value wins"
        );
        assert!(
            !l.note_voice("s1", "", false, NOW),
            "an empty voice is none"
        );
        assert_eq!(l.day().voices["s1"], "af_heart");
        assert_eq!(l.today_view(NOW, None).day.voices["s1"], "af_heart");
    }

    #[test]
    fn a_hold_or_a_later_home_replaces_a_home_voice_and_a_home_never_replaces_a_hold() {
        let mut l = Ledger::in_memory(NOW);
        for id in ["s1", "s2"] {
            l.record_metrics(&metrics(&tokens_at(id, "output", 1, NOW as u64, &[])), NOW);
        }
        assert!(l.note_voice("s1", "bf_emma", true, NOW));
        assert!(
            !l.note_voice("s1", "bf_emma", true, NOW),
            "the same home again changes nothing"
        );
        assert!(
            l.note_voice("s1", "af_heart", true, NOW),
            "the home of the repo it moved to replaces the launch folder's, as on the card"
        );
        assert_eq!(l.day().voices["s1"], "af_heart");
        assert!(l.day().home_voices.contains("s1"));
        assert!(
            l.note_voice("s1", "am_adam", false, NOW),
            "a later hold wins, as on the card"
        );
        assert!(!l.note_voice("s1", "bf_emma", true, NOW));
        assert!(
            !l.note_voice("s1", "af_heart", false, NOW),
            "the first hold stays"
        );
        assert_eq!(l.day().voices["s1"], "am_adam");
        assert!(l.day().home_voices.is_empty());
        assert!(l.note_voice("s2", "bf_emma", true, NOW));
        assert!(l.day().home_voices.contains("s2"));
        // Holding the home voice itself makes it a hold, which then stays.
        assert!(l.note_voice("s2", "bf_emma", false, NOW));
        assert!(!l.day().home_voices.contains("s2"));
        assert!(!l.note_voice("s2", "am_adam", false, NOW));
        assert_eq!(l.day().voices["s2"], "bf_emma");
    }

    #[test]
    fn the_wall_gets_which_voices_are_home_voices() {
        let mut l = Ledger::in_memory(NOW);
        for id in ["home", "held"] {
            l.record_metrics(&metrics(&tokens_at(id, "output", 1, NOW as u64, &[])), NOW);
        }
        assert!(l.note_voice("home", "am_michael", true, NOW));
        assert!(l.note_voice("held", "am_michael", false, NOW));
        // The drawer never merges home-voiced sessions, so it must know which they are.
        let v = serde_json::to_value(l.today_view(NOW, None)).unwrap();
        assert_eq!(v["day"]["home_voices"], json!(["home"]));
        assert_eq!(v["day"]["voices"]["held"], "am_michael");
    }

    #[test]
    fn a_stale_clock_never_rolls_the_day_back() {
        let mut l = Ledger::in_memory(NOW);
        let next = NOW + DAY;
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, next as u64, &[])),
            next,
        );
        let today = l.day().day.clone();
        assert!(!l.note_voice("s1", "af_heart", false, NOW));
        assert_eq!(l.day().day, today);
        assert!(l.day().sessions.contains_key("s1"));
    }

    #[test]
    fn a_dropped_session_takes_its_voice_with_it() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_SESSIONS as u64 + 3) {
            let id = format!("s{n}");
            l.record_metrics(
                &metrics(&tokens_at(&id, "output", 1, NOW as u64, &[])),
                NOW + n as i64,
            );
            l.note_voice(&id, "af_heart", false, NOW + n as i64);
        }
        let day = l.day();
        assert!(day.voices.len() <= MAX_SESSIONS);
        assert!(day.voices.keys().all(|id| day.sessions.contains_key(id)));
        assert!(day.voices.contains_key(&format!("s{}", MAX_SESSIONS + 2)));
    }

    #[test]
    fn a_label_is_kept_for_a_session_of_the_day_and_the_latest_wins() {
        let mut l = Ledger::in_memory(NOW);
        assert!(
            !l.note_label("s1", "Techne PR queue", NOW),
            "no session, no label"
        );
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, NOW as u64, &[])),
            NOW,
        );
        assert!(!l.note_label("s1", "", NOW));
        assert!(l.note_label("s1", "techne", NOW));
        assert!(l.note_label("s1", "Techne PR queue", NOW));
        assert!(!l.note_label("s1", "Techne PR queue", NOW), "unchanged");
        let long = "é".repeat(MAX_LABEL + 5);
        assert!(l.note_label("s1", &long, NOW));
        assert_eq!(
            l.day().labels["s1"].chars().count(),
            MAX_LABEL,
            "capped on a char boundary"
        );
        assert!(
            !l.note_label("s1", &long, NOW),
            "the same long name again changes nothing"
        );
        assert!(l.note_label("s1", "Techne PR queue", NOW));
        let v = serde_json::to_value(l.today_view(NOW, None)).unwrap();
        assert_eq!(v["day"]["labels"]["s1"], "Techne PR queue");
    }

    #[test]
    fn a_dropped_session_takes_its_label_with_it() {
        let mut l = Ledger::in_memory(NOW);
        for n in 0..(MAX_SESSIONS as u64 + 3) {
            let id = format!("s{n}");
            l.record_metrics(
                &metrics(&tokens_at(&id, "output", 1, NOW as u64, &[])),
                NOW + n as i64,
            );
            l.note_label(&id, "a card", NOW + n as i64);
        }
        let day = l.day();
        assert!(day.labels.len() <= MAX_SESSIONS);
        assert!(day.labels.keys().all(|id| day.sessions.contains_key(id)));
    }

    #[test]
    fn a_day_file_without_voices_loads_and_one_with_them_round_trips() {
        let dir = Scratch::new("ledger-voices");
        dir.write(
            "2026-10-20.json",
            r#"{"day":"2026-10-20","sessions":{"s1":{"tokens":{"output":5}}}}"#,
        );
        let (mut l, problems) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(problems.is_empty(), "{problems:?}");
        assert!(l.day().voices.is_empty());
        assert!(l.day().labels.is_empty());
        assert!(l.note_voice("s1", "am_michael", false, NOW));
        assert!(l.note_label("s1", "Techne PR queue", NOW));
        l.save().unwrap();
        let (again, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(again.day().voices["s1"], "am_michael");
        assert_eq!(again.day().labels["s1"], "Techne PR queue");
    }

    #[test]
    fn a_cast_pick_is_kept_for_the_day_and_the_latest_wins() {
        let mut l = Ledger::in_memory(NOW);
        assert!(!l.note_pick("s1", "af_heart", NOW), "no session, no pick");
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, NOW as u64, &[])),
            NOW,
        );
        assert!(!l.note_pick("s1", "", NOW));
        assert!(l.note_pick("s1", "af_heart", NOW));
        assert!(!l.note_pick("s1", "af_heart", NOW), "unchanged");
        assert!(l.note_pick("s1", "am_puck", NOW), "the latest wins");
        assert_eq!(l.today_view(NOW, None).day.picks["s1"], "am_puck");
        let dir = Scratch::new("ledger-picks");
        dir.write(
            "2026-10-20.json",
            r#"{"day":"2026-10-20","sessions":{"s1":{"tokens":{"output":5}}}}"#,
        );
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert!(
            l.day().picks.is_empty(),
            "an older file without picks loads"
        );
        assert!(l.note_pick("s1", "af_heart", NOW));
        l.save().unwrap();
        let (mut again, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        assert_eq!(again.day().picks["s1"], "af_heart");
        assert!(again.forget_pick("s1"), "its own voice is back");
        assert!(again.day().picks.is_empty());
        assert!(!again.forget_pick("s1"));
    }

    #[test]
    fn a_voice_noted_after_midnight_goes_into_the_new_day_not_yesterdays() {
        let dir = Scratch::new("ledger-voice-midnight");
        let (mut l, _) = Ledger::open(dir.0.clone(), NOW, TimeZone::UTC);
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, NOW as u64, &[])),
            NOW,
        );
        l.save().unwrap();
        let yesterday = l.day().day.clone();
        let next = (NOW / DAY + 1) * DAY + 10;
        // No export yet today: the session is not in the new day's file.
        assert!(!l.note_voice("s1", "af_heart", false, next));
        assert_ne!(l.day().day, yesterday, "the day rolled");
        assert!(l.day().voices.is_empty());
        l.record_metrics(
            &metrics(&tokens_at("s1", "output", 1, next as u64, &[])),
            next,
        );
        assert!(l.note_voice("s1", "af_heart", false, next));
        l.save().unwrap();
        let read = |name: &str| -> Value {
            serde_json::from_slice(&std::fs::read(dir.0.join(format!("{name}.json"))).unwrap())
                .unwrap()
        };
        assert_eq!(read(&l.day().day)["voices"]["s1"], "af_heart");
        assert!(
            read(&yesterday)["voices"].get("s1").is_none(),
            "yesterday's file never took today's voice"
        );
    }
}
