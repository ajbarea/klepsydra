//! The wall's wrap-up: the request the app made, and each session's answer,
//! from `<klepsydra_dir>/wrapup`. The app writes `request.json`;
//! `hooks/klepsydra-wrapup.sh` writes `<session>.json` when it asks a session
//! and when the session reports.

use std::io::Read;
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
const MAX_BYTES: u64 = 32768;
/// At most this many sessions in one request.
pub const MAX_IDS: usize = 256;

/// A session id as the request names it and an answer file is named.
fn id_ok(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// A wrap-up the wall asked for.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Request {
    /// Milliseconds since the epoch when it was made, as text.
    pub id: String,
    pub at: i64,
    /// When sessions stop being asked and silence reads "no answer".
    pub until: i64,
    /// The sessions the wall listed: only these are asked, and only these answer.
    #[serde(default)]
    pub ids: Vec<String>,
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
    /// When the turn that gave the answer ended (the Stop hook stamps it); a
    /// ready answer counts only from then.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_at: Option<i64>,
}

#[derive(Deserialize)]
struct File {
    request: String,
    state: State,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    settled: Option<i64>,
    at: i64,
    /// `MARK_BY` on a mark the app wrote before typing; the script writes none.
    #[serde(default)]
    by: Option<String>,
}

/// Who wrote a mark: the app, before typing `/klepsydra-wrapup`.
const MARK_BY: &str = "app";

fn text(path: &Path) -> Option<String> {
    match read_small(path, MAX_BYTES) {
        Found::Text(t) => Some(t),
        _ => None,
    }
}

/// A regular file's text and its mtime in seconds by this machine's clock,
/// both from one handle; none for anything else, or more than `MAX_BYTES`.
fn stamped(path: &Path) -> Option<(String, i64)> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    let mut f = std::fs::File::open(path).ok()?;
    let mut text = String::new();
    (&mut f).take(MAX_BYTES).read_to_string(&mut text).ok()?;
    let m = f.metadata().ok()?.modified().ok()?;
    let secs = m.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    Some((text, i64::try_from(secs).ok()?))
}

fn answer_path(klepsydra_dir: &Path, id: &str) -> std::path::PathBuf {
    klepsydra_dir.join(DIR).join(format!("{id}.json"))
}

/// The request in `klepsydra_dir`, while the wall still shows it at `now`.
pub fn request(klepsydra_dir: &Path, now: i64) -> Option<Request> {
    let r: Request = serde_json::from_str(&text(&klepsydra_dir.join(DIR).join(REQUEST))?).ok()?;
    let sane = !r.id.is_empty()
        && r.id.len() <= 20
        && r.id.bytes().all(|b| b.is_ascii_digit())
        && r.at <= r.until
        && r.ids.len() <= MAX_IDS
        && r.ids.iter().all(|i| id_ok(i));
    (sane && now <= r.until.saturating_add(SHOWN_AFTER)).then_some(r)
}

/// Session `id`'s answer to `request`, if it has one. An answer to an older
/// request is none. `id` must already be a session id the scan accepted.
/// Its times are put on this machine's clock as a session file's are: the
/// script stamps them by the session's clock, which a Linux guest lets drift,
/// and the last of them (`settled`, else `at`) is the stamp of the last write.
pub fn answer(klepsydra_dir: &Path, request: &Request, id: &str) -> Option<Answer> {
    let (text, modified) = stamped(&answer_path(klepsydra_dir, id))?;
    let f: File = serde_json::from_str(&text).ok()?;
    if f.request != request.id {
        return None;
    }
    let reason = f
        .reason
        .filter(|_| f.state == State::Blocked)
        .map(|r| r.chars().take(REASON_CHARS).collect());
    let shift = crate::session::skew(f.settled.unwrap_or(f.at), modified);
    Some(Answer {
        state: f.state,
        reason,
        at: f.at.saturating_add(shift),
        settled_at: f.settled.map(|t| t.saturating_add(shift)),
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

/// The reason of a session whose turn is over but whose background work is
/// still out: it sits idle at its prompt, and its Stop has already run.
pub const AFTER_TURN: &str = "background";

/// How a session with `status` and `reason` gets the wrap-up; none once it
/// has ended. `in_fleet` is whether it runs in klepsydra's own tmux server.
pub fn route(status: Status, reason: Option<&str>, in_fleet: bool) -> Option<Route> {
    let after_turn = status == Status::Working && reason == Some(AFTER_TURN);
    match status {
        Status::Working if after_turn && in_fleet => Some(Route::Type),
        Status::Working if after_turn => Some(Route::ByHand),
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

/// Start a wrap-up of sessions `ids` at `now_ms`: they are asked until
/// `WINDOW` passes. A new one replaces any before it, and the answers to it
/// are removed, so every session is asked again, except one still asked by
/// a request that was asking: it may be mid-checkpoint, so it stays asked
/// and is not typed into again.
pub fn start(klepsydra_dir: &Path, now_ms: i64, ids: &[String]) -> std::io::Result<Request> {
    let at = now_ms.div_euclid(1000);
    let mut listed: Vec<String> = Vec::new();
    for id in ids.iter().filter(|i| id_ok(i)) {
        if !listed.contains(id) && listed.len() < MAX_IDS {
            listed.push(id.clone());
        }
    }
    let r = Request {
        id: now_ms.to_string(),
        at,
        until: at + WINDOW,
        ids: listed,
    };
    let previous = request(klepsydra_dir, at);
    save_request(klepsydra_dir, &r)?;
    prune(&klepsydra_dir.join(DIR), &r, previous.as_ref(), at);
    Ok(r)
}

/// Settle the answers in `dir` on `r`, written just before: one to `r`
/// stays, an ask by `previous` of a session `r` lists, written less than
/// `WINDOW` ago by the file's own time (that session may still be
/// checkpointing, stopped or not), is carried over to it, and every other
/// regular `<session>.json` goes. A `dir` that is not a folder (a symlink to
/// one) is left alone.
fn prune(dir: &Path, r: &Request, previous: Option<&Request>, now: i64) {
    if !std::fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir()) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let name = e.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        if name == REQUEST || !id_ok(stem) || !e.file_type().is_ok_and(|t| t.is_file()) {
            continue;
        }
        let read = stamped(&e.path());
        let recent = read
            .as_ref()
            .is_some_and(|(_, written)| now - written < WINDOW);
        let mut file: Option<serde_json::Value> =
            read.and_then(|(text, _)| serde_json::from_str(&text).ok());
        let of =
            |v: &serde_json::Value, k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_owned);
        if let Some(v) = &file {
            if of(v, "request").as_deref() == Some(r.id.as_str()) {
                continue;
            }
        }
        let carried = file.as_mut().filter(|v| {
            recent
                && previous.is_some_and(|o| of(v, "request").as_deref() == Some(o.id.as_str()))
                && of(v, "state").as_deref() == Some("asked")
                && r.ids.iter().any(|i| i == stem)
        });
        if let Some(v) = carried {
            // Stamped now by this clock, so the reader's correction stays nil.
            v["request"] = r.id.clone().into();
            v["at"] = now.into();
            if write_atomic(&e.path(), v.to_string().as_bytes()).is_ok() {
                continue;
            }
        }
        let _ = std::fs::remove_file(e.path());
    }
}

/// Remove the request once the wall no longer shows it (`SHOWN_AFTER` past
/// its window), so a Stop hook reads nothing; its answers go at the next start.
pub fn forget_expired(klepsydra_dir: &Path, now: i64) {
    let path = klepsydra_dir.join(DIR).join(REQUEST);
    let Some(text) = text(&path) else {
        return;
    };
    let Ok(r) = serde_json::from_str::<Request>(&text) else {
        return;
    };
    if now > r.until.saturating_add(SHOWN_AFTER) {
        let _ = std::fs::remove_file(path);
    }
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
/// so the Stop hook at the end of that turn does not ask again. False, with
/// nothing written, when the session already has an answer to `r` (asked by
/// the Stop hook, or answered), which is then not typed into. Create-only
/// where hard links work; without them the file is checked and then
/// replaced, so an answer written between the two is lost.
pub fn mark_asked(klepsydra_dir: &Path, r: &Request, id: &str, now: i64) -> std::io::Result<bool> {
    let dir = folder(klepsydra_dir)?;
    let path = dir.join(format!("{id}.json"));
    let text =
        serde_json::json!({"request": r.id, "state": State::Asked, "at": now, "by": MARK_BY})
            .to_string();
    // A hard link to a written file creates the answer whole, or fails if one is there.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let tmp = dir.join(format!("{id}.json.{nanos}.mark.tmp"));
    std::fs::write(&tmp, &text)?;
    let linked = std::fs::hard_link(&tmp, &path);
    let _ = std::fs::remove_file(&tmp);
    if linked.is_ok() {
        return Ok(true);
    }
    if answer(klepsydra_dir, r, id).is_some() {
        return Ok(false);
    }
    // An older request's answer, or a filesystem without hard links.
    write_atomic(&path, text.as_bytes())?;
    Ok(true)
}

/// Undo `mark_asked` when the typing failed, so the Stop hook asks instead.
/// Only a mark the app wrote for `r` goes; an answer, or the Stop hook's ask, stays.
pub fn unmark(klepsydra_dir: &Path, r: &Request, id: &str) {
    let path = answer_path(klepsydra_dir, id);
    let Some((text, _)) = stamped(&path) else {
        return;
    };
    let ours = serde_json::from_str::<File>(&text).is_ok_and(|f| {
        f.request == r.id && f.state == State::Asked && f.by.as_deref() == Some(MARK_BY)
    });
    if ours {
        let _ = std::fs::remove_file(path);
    }
}

/// What asking one session did.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Asked {
    pub id: String,
    pub route: Route,
    /// Why typing the command failed; the Stop hook asks it at its next turn end.
    pub error: Option<String>,
    /// `/klepsydra-wrapup` was typed into it now.
    pub typed: bool,
}

/// One session the wall listed, how it is asked, and the raw `state_at` of
/// the session file that decided it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Planned {
    pub id: String,
    pub route: Route,
    state_at: i64,
}

/// Sessions `ids` as their files read at `now`, each with its route;
/// `typable(id)` is whether its pane is one klepsydra types into. A session
/// with no file, or ended, is left out. In `ids` order.
pub fn plan(
    klepsydra_dir: &Path,
    ids: &[String],
    typable: impl Fn(&str) -> bool,
    now: i64,
) -> Vec<Planned> {
    let listing = crate::scan::scan(&klepsydra_dir.join("fleet"));
    ids.iter()
        .filter_map(|id| {
            let e = listing.entries.iter().find(|e| e.file.session_id == *id)?;
            let v = crate::view::view(e, now)?;
            let route = route(v.status, v.reason.as_deref(), typable(id))?;
            Some(Planned {
                id: id.clone(),
                route,
                state_at: e.file.state_at,
            })
        })
        .collect()
}

/// Whether `p` would still be typed into: its file unchanged in state since
/// the plan, and still routed Type.
fn unmoved(klepsydra_dir: &Path, p: &Planned, now: i64) -> bool {
    plan(klepsydra_dir, std::slice::from_ref(&p.id), |_| true, now)
        .first()
        .is_some_and(|q| q.route == Route::Type && q.state_at == p.state_at)
}

/// The card's note for a session that changed between the plan and its typing.
const MOVED: &str =
    "It changed before klepsydra could type; its Stop hook asks it when its next turn ends.";

/// Why typing into one session failed, and whether it may have been typed all the same.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failed {
    pub error: String,
    pub maybe_typed: bool,
}

/// At most this many sessions are typed into at once.
const TYPING_AT_ONCE: usize = 8;

/// Ask the sessions in `plan` about `r`: every Type one is marked asked
/// first, then typed into by `type_one`, several at once. One already asked
/// or answered is not typed into; one whose typing failed is unmarked, unless
/// it may have been typed, so the Stop hook asks it instead. In plan order.
pub fn ask<F>(
    klepsydra_dir: &Path,
    r: &Request,
    plan: &[Planned],
    now: i64,
    type_one: F,
) -> Vec<Asked>
where
    F: Fn(&str) -> Result<(), Failed> + Sync,
{
    let mut out: Vec<Asked> = plan
        .iter()
        .map(|p| Asked {
            id: p.id.clone(),
            route: p.route,
            error: None,
            typed: false,
        })
        .collect();
    let mut to_type = Vec::new();
    for (i, a) in out.iter_mut().enumerate() {
        if a.route != Route::Type {
            continue;
        }
        match mark_asked(klepsydra_dir, r, &a.id, now) {
            Ok(true) => to_type.push(i),
            Ok(false) => {}
            Err(e) => a.error = Some(format!("Could not record the ask: {e}")),
        }
    }
    for batch in to_type.chunks(TYPING_AT_ONCE) {
        let results: Vec<(usize, Result<(), Failed>)> = std::thread::scope(|scope| {
            let running: Vec<_> = batch
                .iter()
                .map(|&i| {
                    let p = &plan[i];
                    let type_one = &type_one;
                    // Re-read just before typing: Ctrl+C must not reach a turn that began since.
                    let go = move || {
                        if unmoved(klepsydra_dir, p, now) {
                            type_one(&p.id)
                        } else {
                            Err(Failed {
                                error: MOVED.into(),
                                maybe_typed: false,
                            })
                        }
                    };
                    (i, scope.spawn(go))
                })
                .collect();
            running
                .into_iter()
                .map(|(i, h)| {
                    let res = h.join().unwrap_or_else(|_| {
                        Err(Failed {
                            error: "Typing the wrap-up failed; check its terminal.".into(),
                            maybe_typed: true,
                        })
                    });
                    (i, res)
                })
                .collect()
        });
        for (i, result) in results {
            match result {
                Ok(()) => out[i].typed = true,
                Err(f) => {
                    if !f.maybe_typed {
                        unmark(klepsydra_dir, r, &out[i].id);
                    }
                    out[i].error = Some(f.error);
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    const A: &str = "4ce1be96-f12f-4c66-87eb-4ab36e451dc5";
    const B: &str = "0b6f0f3e-1111-4c66-87eb-4ab36e451dc5";
    const C: &str = "9a9a9a9a-2222-4c66-87eb-4ab36e451dc5";
    const NOW: i64 = 1_792_600_000;

    fn dir() -> Scratch {
        let d = Scratch::new("wrapup");
        std::fs::create_dir(d.0.join(DIR)).unwrap();
        d
    }

    fn put(d: &Scratch, name: &str, text: &str) {
        d.write(&format!("{DIR}/{name}"), text);
    }

    /// Set `name`'s modified time to `secs`, the reader's clock for it.
    fn written_at(d: &Scratch, name: &str, secs: i64) {
        std::fs::File::options()
            .write(true)
            .open(d.0.join(DIR).join(name))
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs as u64))
            .unwrap();
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
            ids: vec![A.to_owned()],
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
        let blocked = answer(&d.0, &r, A).unwrap();
        assert_eq!(
            (blocked.state, blocked.reason.as_deref()),
            (State::Blocked, Some("a 2 h build"))
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
            ids: vec![A.to_owned()],
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
            assert_eq!(
                route(status, None, fleet),
                want,
                "{status:?} in_fleet={fleet}"
            );
        }
    }

    #[test]
    fn a_session_idle_at_its_prompt_with_work_out_is_typed_into_not_left_for_a_stop() {
        // Its turn is over (Stop has run) and a background shell or agent is out:
        // no Stop is coming, so it is asked as an idle session is.
        use Route::*;
        assert_eq!(route(Status::Working, Some("background"), true), Some(Type));
        assert_eq!(
            route(Status::Working, Some("background"), false),
            Some(ByHand)
        );
        assert_eq!(route(Status::Working, Some("other"), true), Some(TurnEnd));
        assert_eq!(route(Status::Done, Some("background"), true), Some(Type));
        assert_eq!(
            route(Status::NeedsYou, Some("background"), true),
            Some(AfterAnswer)
        );
    }

    #[test]
    fn start_cancel_and_marks_round_trip() {
        let d = Scratch::new("wrapup-start");
        let r = start(&d.0, NOW * 1000 + 250, &[A.to_owned()]).unwrap();
        assert_eq!(
            r,
            Request {
                id: format!("{}", NOW * 1000 + 250),
                at: NOW,
                until: NOW + WINDOW,
                ids: vec![A.to_owned()],
            }
        );
        assert_eq!(request(&d.0, NOW), Some(r.clone()));
        assert!(mark_asked(&d.0, &r, A, NOW + 1).unwrap());
        assert_eq!(answer(&d.0, &r, A).unwrap().state, State::Asked);
        unmark(&d.0, &r, A);
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
        start(&d.0, 1_792_600_000_123, &[A.to_owned()]).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(d.0.join(DIR).join(REQUEST)).unwrap())
                .unwrap();
        assert!(v["id"].is_string() && v["until"].is_i64(), "{v}");
        assert_eq!(
            v["ids"],
            serde_json::json!([A]),
            "and .ids as an array of text"
        );
    }

    #[test]
    fn start_lists_each_valid_id_once_and_caps_the_list() {
        let d = Scratch::new("wrapup-ids");
        let many: Vec<String> = (0..MAX_IDS + 5).map(|n| format!("s-{n}")).collect();
        let mut ids = vec![
            A.to_owned(),
            A.to_owned(),
            "../x".into(),
            String::new(),
            "a".repeat(65),
        ];
        ids.extend(many);
        let r = start(&d.0, NOW * 1000, &ids).unwrap();
        assert_eq!(r.ids.len(), MAX_IDS);
        assert_eq!(r.ids[0], A);
        assert_eq!(r.ids.iter().filter(|i| *i == A).count(), 1);
        assert!(r.ids.iter().all(|i| id_ok(i)));
        assert_eq!(request(&d.0, NOW), Some(r), "a full list still reads back");
    }

    #[test]
    fn a_request_naming_a_bad_id_or_too_many_is_none() {
        let d = dir();
        let with = |ids: &str| {
            put(
                &d,
                REQUEST,
                &format!(
                    r#"{{"id":"9","at":{NOW},"until":{},"ids":{ids}}}"#,
                    NOW + 600
                ),
            );
            request(&d.0, NOW)
        };
        assert!(with(&format!(r#"["{A}"]"#)).is_some());
        assert!(with(r#"["../etc"]"#).is_none());
        assert!(with(r#"[""]"#).is_none());
        let too_many: Vec<String> = (0..=MAX_IDS).map(|n| format!(r#""s{n}""#)).collect();
        assert!(with(&format!("[{}]", too_many.join(","))).is_none());
        put(
            &d,
            REQUEST,
            &format!(r#"{{"id":"9","at":{NOW},"until":{}}}"#, NOW + 600),
        );
        assert_eq!(
            request(&d.0, NOW).unwrap().ids,
            Vec::<String>::new(),
            "none listed: nobody is asked"
        );
    }

    #[test]
    fn a_new_request_removes_the_old_answers_and_nothing_else() {
        let d = dir();
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"1","state":"ready","at":1}"#,
        );
        put(&d, "notes.txt", "keep");
        put(&d, "x.json.123.tmp", "keep");
        std::fs::create_dir(d.0.join(DIR).join("b.json")).unwrap();
        let r = start(&d.0, NOW * 1000, &[A.to_owned()]).unwrap();
        assert_eq!(answer(&d.0, &r, A), None);
        assert!(!d.0.join(DIR).join(format!("{A}.json")).exists());
        for kept in ["notes.txt", "x.json.123.tmp", "b.json", REQUEST] {
            assert!(d.0.join(DIR).join(kept).exists(), "{kept}");
        }
    }

    fn mark_file(d: &Scratch, text: &str) {
        put(d, &format!("{A}.json"), text);
    }

    #[test]
    fn a_mark_never_overwrites_an_answer_to_this_request_and_unmark_takes_only_its_own() {
        let d = dir();
        let r = Request {
            id: "7".into(),
            at: NOW,
            until: NOW + WINDOW,
            ids: vec![A.to_owned()],
        };
        let path = d.0.join(DIR).join(format!("{A}.json"));
        for (theirs, what) in [
            (
                r#"{"request":"7","state":"ready","at":1}"#,
                "a ready answer",
            ),
            (
                r#"{"request":"7","state":"blocked","reason":"x","at":1}"#,
                "a blocked answer",
            ),
            (
                r#"{"request":"7","state":"asked","at":1}"#,
                "the Stop hook's ask",
            ),
        ] {
            mark_file(&d, theirs);
            assert!(!mark_asked(&d.0, &r, A, NOW).unwrap(), "{what}: not marked");
            assert_eq!(
                std::fs::read_to_string(&path).unwrap(),
                theirs,
                "{what}: kept"
            );
            unmark(&d.0, &r, A);
            assert_eq!(
                std::fs::read_to_string(&path).unwrap(),
                theirs,
                "{what}: unmark leaves it"
            );
        }
        mark_file(&d, r#"{"request":"6","state":"ready","at":1}"#);
        assert!(
            mark_asked(&d.0, &r, A, NOW).unwrap(),
            "an older request's answer is replaced"
        );
        assert_eq!(answer(&d.0, &r, A).unwrap().state, State::Asked);
        unmark(&d.0, &r, A);
        assert!(!path.exists(), "its own mark is removed");
        assert!(mark_asked(&d.0, &r, A, NOW).unwrap(), "none there: marked");
        let newer = Request {
            id: "8".into(),
            ..r.clone()
        };
        unmark(&d.0, &newer, A);
        assert!(path.exists(), "another request's mark stays");
        let leftovers: Vec<_> = std::fs::read_dir(d.0.join(DIR))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n != &format!("{A}.json"))
            .collect();
        assert!(leftovers.is_empty(), "no temp file left: {leftovers:?}");
    }

    #[test]
    fn an_answer_gets_the_writer_clock_correction_a_session_file_gets() {
        // The script stamps `at` by its own clock (a Linux guest's drifts); the
        // file's mtime is this machine's. Same rule as session::skew.
        let d = dir();
        let r = Request {
            id: "7".into(),
            at: NOW,
            until: NOW + WINDOW,
            ids: vec![A.to_owned()],
        };
        let mtime = NOW + 100;
        for (ahead, want) in [
            (-300, mtime),
            (-2, mtime - 2),
            (0, mtime),
            (2, mtime + 2),
            (120, mtime),
            (700, mtime),
        ] {
            mark_file(
                &d,
                &format!(
                    r#"{{"request":"7","state":"ready","at":{}}}"#,
                    mtime + ahead
                ),
            );
            let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(mtime as u64);
            std::fs::File::options()
                .write(true)
                .open(d.0.join(DIR).join(format!("{A}.json")))
                .unwrap()
                .set_modified(t)
                .unwrap();
            assert_eq!(
                answer(&d.0, &r, A).unwrap().at,
                want,
                "writer clock {ahead:+} s"
            );
            assert_eq!(
                want - (mtime + ahead),
                crate::session::skew(mtime + ahead, mtime)
            );
        }
    }

    #[test]
    fn ask_marks_every_typed_session_before_typing_any_and_types_them_at_once() {
        use std::sync::{Condvar, Mutex};
        use std::time::Duration;
        let d = Scratch::new("wrapup-ask");
        let ids: Vec<String> = (1..=5)
            .map(|n| format!("4ce1be96-f12f-4c66-87eb-4ab36e451dc{n}"))
            .collect();
        let now = crate::watch::unix_now();
        std::fs::create_dir_all(d.0.join("fleet")).unwrap();
        for (i, id) in ids.iter().enumerate() {
            let state = if i == 4 { "working" } else { "done" };
            d.write(
                &format!("fleet/{id}.json"),
                &crate::scan::tests::session(id, state),
            );
        }
        let r = start(&d.0, now * 1000, &ids).unwrap();
        let answered = &ids[3];
        put(
            &d,
            &format!("{answered}.json"),
            &format!(r#"{{"request":"{}","state":"ready","at":{now}}}"#, r.id),
        );
        let plan = plan(&d.0, &ids, |_| true, now);
        assert_eq!(
            plan.iter().map(|p| p.route).collect::<Vec<_>>(),
            [
                Route::Type,
                Route::Type,
                Route::Type,
                Route::Type,
                Route::TurnEnd
            ]
        );
        let typed = Mutex::new(Vec::new());
        let gate = (Mutex::new(0usize), Condvar::new());
        let marked_first = Mutex::new(true);
        let out = ask(&d.0, &r, &plan, now, |id| {
            for t in &ids[..3] {
                let state = answer(&d.0, &r, t).map(|a| a.state);
                if state != Some(State::Asked) {
                    *marked_first.lock().unwrap() = false;
                }
            }
            typed.lock().unwrap().push(id.to_owned());
            let (n, cv) = &gate;
            let mut n = n.lock().unwrap();
            *n += 1;
            cv.notify_all();
            let _ = cv
                .wait_timeout_while(n, Duration::from_secs(5), |n| *n < 3)
                .unwrap();
            if id == ids[1] {
                Err(Failed {
                    error: "the prompt did not read it".into(),
                    maybe_typed: false,
                })
            } else if id == ids[2] {
                Err(Failed {
                    error: "no answer in time".into(),
                    maybe_typed: true,
                })
            } else {
                Ok(())
            }
        });
        assert!(
            *marked_first.lock().unwrap(),
            "every typed session was marked before any typing"
        );
        assert_eq!(*gate.0.lock().unwrap(), 3, "all three were typed at once");
        let mut typed = typed.into_inner().unwrap();
        typed.sort();
        assert_eq!(
            typed,
            ids[..3].to_vec(),
            "never the answered one or the mid-turn one"
        );
        let route_of = |i: usize| out.iter().find(|a| a.id == ids[i]).unwrap();
        assert_eq!((route_of(0).error.clone(), route_of(0).typed), (None, true));
        assert!(
            !route_of(3).typed && !route_of(4).typed,
            "only the ones typed into now"
        );
        assert_eq!(
            route_of(1).error.as_deref(),
            Some("the prompt did not read it")
        );
        assert_eq!(route_of(2).error.as_deref(), Some("no answer in time"));
        assert_eq!(
            (route_of(3).route, route_of(3).error.clone()),
            (Route::Type, None)
        );
        assert_eq!(
            (route_of(4).route, route_of(4).error.clone()),
            (Route::TurnEnd, None)
        );
        assert_eq!(answer(&d.0, &r, &ids[0]).unwrap().state, State::Asked);
        assert_eq!(
            answer(&d.0, &r, &ids[1]),
            None,
            "a failed typing is unmarked: the Stop hook asks"
        );
        assert_eq!(
            answer(&d.0, &r, &ids[2]).unwrap().state,
            State::Asked,
            "one that may have been typed keeps its mark"
        );
        assert_eq!(
            answer(&d.0, &r, &ids[3]).unwrap().state,
            State::Ready,
            "an answer stays"
        );
        assert_eq!(
            answer(&d.0, &r, &ids[4]),
            None,
            "the Stop hook asks a mid-turn one"
        );
        assert_eq!(
            out.iter().map(|a| a.id.clone()).collect::<Vec<_>>(),
            ids,
            "in plan order"
        );
    }

    #[test]
    fn a_session_that_moved_since_the_plan_is_not_typed_into() {
        let d = Scratch::new("wrapup-moved");
        let now = crate::watch::unix_now();
        std::fs::create_dir_all(d.0.join("fleet")).unwrap();
        d.write(
            &format!("fleet/{A}.json"),
            &crate::scan::tests::session(A, "done"),
        );
        let r = start(&d.0, now * 1000, &[A.to_owned()]).unwrap();
        let planned = plan(&d.0, &[A.to_owned()], |_| true, now);
        assert_eq!(planned[0].route, Route::Type);
        // A prompt lands between the plan and the typing.
        d.write(
            &format!("fleet/{A}.json"),
            &format!(r#"{{"v":1,"session_id":"{A}","state":"working","state_at":1700000050}}"#),
        );
        let typed = std::sync::Mutex::new(0);
        let out = ask(&d.0, &r, &planned, now, |_| {
            *typed.lock().unwrap() += 1;
            Ok(())
        });
        assert_eq!(
            *typed.lock().unwrap(),
            0,
            "Ctrl+C never reaches a session that started a turn"
        );
        assert!(out[0].error.is_some() && !out[0].typed);
        assert_eq!(answer(&d.0, &r, A), None, "unmarked: its Stop hook asks it");
        // The same state, written again with nothing new, still types.
        d.write(
            &format!("fleet/{A}.json"),
            &crate::scan::tests::session(A, "done"),
        );
        let r = start(&d.0, now * 1000 + 1, &[A.to_owned()]).unwrap();
        let planned = plan(&d.0, &[A.to_owned()], |_| true, now);
        let out = ask(&d.0, &r, &planned, now, |_| Ok(()));
        assert!(out[0].typed, "{out:?}");
    }

    #[test]
    fn start_over_keeps_a_running_ask_and_clears_answers() {
        let d = dir();
        let ids = [A.to_owned(), B.to_owned(), C.to_owned()];
        let first = start(&d.0, NOW * 1000, &ids).unwrap();
        put(
            &d,
            &format!("{A}.json"),
            &format!(r#"{{"request":"{}","state":"asked","at":{NOW}}}"#, first.id),
        );
        written_at(&d, &format!("{A}.json"), NOW);
        put(
            &d,
            &format!("{B}.json"),
            &format!(
                r#"{{"request":"{}","state":"ready","at":{NOW},"settled":{NOW}}}"#,
                first.id
            ),
        );
        put(
            &d,
            &format!("{C}.json"),
            &format!(
                r#"{{"request":"{}","state":"blocked","reason":"x","at":{NOW}}}"#,
                first.id
            ),
        );
        let again = start(&d.0, (NOW + 60) * 1000, &ids).unwrap();
        assert_eq!(
            answer(&d.0, &again, A).map(|a| a.state),
            Some(State::Asked),
            "mid-checkpoint: still asked"
        );
        assert_eq!(answer(&d.0, &again, B), None);
        assert_eq!(answer(&d.0, &again, C), None);
        assert!(
            !mark_asked(&d.0, &again, A, NOW + 60).unwrap(),
            "so it is not typed into"
        );
        // Past the old window an ask is not carried.
        written_at(&d, &format!("{A}.json"), NOW + 60);
        let late = start(&d.0, (NOW + 60 + WINDOW + 1) * 1000, &ids).unwrap();
        assert_eq!(answer(&d.0, &late, A), None);
    }

    #[test]
    fn stop_then_start_over_keeps_an_ask_still_checkpointing() {
        let d = dir();
        let ids = [A.to_owned()];
        let first = start(&d.0, NOW * 1000, &ids).unwrap();
        put(
            &d,
            &format!("{A}.json"),
            &format!(r#"{{"request":"{}","state":"asked","at":{NOW}}}"#, first.id),
        );
        written_at(&d, &format!("{A}.json"), NOW);
        cancel(&d.0, NOW + 30).unwrap();
        let again = start(&d.0, (NOW + 60) * 1000, &ids).unwrap();
        assert_eq!(
            answer(&d.0, &again, A).map(|a| a.state),
            Some(State::Asked),
            "stopped, yet that session may still be checkpointing"
        );
        assert!(
            !mark_asked(&d.0, &again, A, NOW + 60).unwrap(),
            "so it is not typed into"
        );
    }

    #[test]
    fn prune_never_follows_a_symlinked_folder() {
        #[cfg(unix)]
        {
            let d = Scratch::new("wrapup-link");
            let elsewhere = Scratch::new("wrapup-elsewhere");
            elsewhere.write(
                &format!("{A}.json"),
                r#"{"request":"1","state":"ready","at":1}"#,
            );
            std::os::unix::fs::symlink(&elsewhere.0, d.0.join(DIR)).unwrap();
            let _ = start(&d.0, NOW * 1000, &[A.to_owned()]);
            assert!(elsewhere.0.join(format!("{A}.json")).exists());
        }
    }

    #[test]
    fn a_settled_answer_is_corrected_by_its_last_write() {
        // Reported at T+5 and settled at T+30 by a writer clock `ahead`; the
        // settling write landed at T+30 by this clock.
        let d = dir();
        let r = Request {
            id: "7".into(),
            at: NOW,
            until: NOW + WINDOW,
            ids: vec![A.to_owned()],
        };
        for ahead in [-300, 0, 120] {
            put(
                &d,
                &format!("{A}.json"),
                &format!(
                    r#"{{"request":"7","state":"ready","at":{},"settled":{}}}"#,
                    NOW + 5 + ahead,
                    NOW + 30 + ahead
                ),
            );
            let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs((NOW + 30) as u64);
            std::fs::File::options()
                .write(true)
                .open(d.0.join(DIR).join(format!("{A}.json")))
                .unwrap()
                .set_modified(t)
                .unwrap();
            let a = answer(&d.0, &r, A).unwrap();
            assert_eq!(
                (a.at, a.settled_at),
                (NOW + 5, Some(NOW + 30)),
                "writer clock {ahead:+} s"
            );
        }
        put(
            &d,
            &format!("{A}.json"),
            r#"{"request":"7","state":"ready","at":1}"#,
        );
        assert_eq!(
            answer(&d.0, &r, A).unwrap().settled_at,
            None,
            "an old file: not settled"
        );
    }

    #[test]
    fn a_request_past_the_walls_hour_is_removed() {
        let d = dir();
        let r = start(&d.0, NOW * 1000, &[A.to_owned()]).unwrap();
        put(
            &d,
            &format!("{A}.json"),
            &format!(r#"{{"request":"{}","state":"ready","at":1}}"#, r.id),
        );
        let path = d.0.join(DIR).join(REQUEST);
        forget_expired(&d.0, r.until + SHOWN_AFTER);
        assert!(path.exists(), "still shown");
        forget_expired(&d.0, r.until + SHOWN_AFTER + 1);
        assert!(!path.exists(), "gone: a Stop pays nothing for it");
        assert!(
            d.0.join(DIR).join(format!("{A}.json")).exists(),
            "answers stay until the next start"
        );
        put(&d, REQUEST, "not json");
        forget_expired(&d.0, i64::MAX);
        assert!(path.exists(), "not ours to judge: left alone");
    }
}
