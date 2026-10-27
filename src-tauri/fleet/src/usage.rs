//! The statusLine hook's readings, `accounts/<account>/<session>.json`, as
//! the gauge reads them (`read_usage`) and the phone wall serves them.

use std::path::Path;

use serde_json::{Map, Value};

use crate::bounded::read_text;

/// The most a reading file may hold: one is under 1 KiB.
pub const MAX_BYTES: u64 = 64 * 1024;
/// The most account folders, and reading files in each, read: the newest
/// first, so a cap drops the oldest.
pub const MAX_ACCOUNTS: usize = 32;
pub const MAX_SESSIONS: usize = 512;

/// An account folder's name as the hook makes it (its `owned` check).
fn account_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// The entries of `dir` that `keep` admits by name and type (never following
/// a symlink), newest first, at most `max`.
fn newest(
    dir: &Path,
    max: usize,
    keep: impl Fn(&str, &std::fs::FileType) -> bool,
) -> Vec<std::path::PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut found: Vec<(std::time::SystemTime, std::path::PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let kind = e.file_type().ok()?;
            let name = e.file_name();
            keep(name.to_str()?, &kind).then_some(())?;
            let at = e.metadata().and_then(|m| m.modified()).ok()?;
            Some((at, e.path()))
        })
        .collect();
    found.sort_by(|a, b| b.cmp(a));
    found.into_iter().take(max).map(|(_, p)| p).collect()
}

/// Every reading under each of `dirs`' `accounts`, one per Claude Code
/// session, as the hook leaves them: an account folder holding `.json`
/// files. A symlink, FIFO or other non-regular file, a file over
/// `MAX_BYTES`, or one that is not JSON is skipped, as is a stale
/// pre-per-session file in place of an account's folder. Sessions disagree
/// routinely; reconciling them is the frontend's job.
pub fn read<P: AsRef<Path>>(dirs: impl IntoIterator<Item = P>) -> Vec<Value> {
    read_capped(dirs, MAX_BYTES, MAX_ACCOUNTS, MAX_SESSIONS)
}

fn read_capped<P: AsRef<Path>>(
    dirs: impl IntoIterator<Item = P>,
    max_bytes: u64,
    max_accounts: usize,
    max_sessions: usize,
) -> Vec<Value> {
    let mut out = Vec::new();
    for dir in dirs {
        let accounts = dir.as_ref().join("accounts");
        if !std::fs::symlink_metadata(&accounts).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        for account in newest(&accounts, max_accounts, |name, kind| {
            kind.is_dir() && account_name(name)
        }) {
            // read_text refuses a symlink, a FIFO or any other non-file.
            for file in newest(&account, max_sessions, |name, _| name.ends_with(".json")) {
                let Ok(text) = read_text(&file, max_bytes) else {
                    continue;
                };
                if let Ok(value) = serde_json::from_str::<Value>(&text) {
                    out.push(value);
                }
            }
        }
    }
    out
}

type Object = Map<String, Value>;

/// A reading's fields the gauge reads besides its windows.
const STAMPS: [&str; 2] = ["observed_at", "written_at"];
/// A window's fields the gauge reads.
const WINDOW_FIELDS: [&str; 2] = ["used_percentage", "resets_at"];

/// The account a reading is filed under, as gauge.js groups it
/// (`String(entry.account ?? "?")`).
fn account_key(reading: &Object) -> String {
    match reading.get("account") {
        None | Some(Value::Null) => "?".into(),
        Some(Value::String(s)) => s.clone(),
        Some(v) => v.to_string(),
    }
}

/// The windows the gauge draws (gauge.js WINDOW_ORDER); no other reaches the phone.
pub const WINDOWS: [&str; 3] = ["five_hour", "seven_day", "spend_limit"];

/// The readings as the phone gets them, one per session, unmerged (gauge.js
/// reconciles them): each cut to its label, its times and each of `WINDOWS`'
/// percent and reset time, numbers only. The account id becomes `a1`, `a2`,
/// ... in the ids' sorted order, which groups the readings as the id does and
/// says nothing of it; the session id and API time stay home.
pub fn phone_view(readings: &[Value]) -> Value {
    let usable: Vec<(&Object, &Object)> = readings
        .iter()
        .filter_map(|r| {
            let r = r.as_object()?;
            Some((r, r.get("windows")?.as_object()?))
        })
        .collect();
    let mut ids: Vec<String> = usable.iter().map(|(r, _)| account_key(r)).collect();
    ids.sort();
    ids.dedup();
    let out = usable
        .into_iter()
        .map(|(r, windows)| {
            let mut o = Map::new();
            let key = account_key(r);
            let n = ids.binary_search(&key).unwrap_or(0) + 1;
            o.insert("account".into(), Value::from(format!("a{n}")));
            if let Some(label) = r.get("label").filter(|v| v.is_string()) {
                o.insert("label".into(), label.clone());
            }
            for k in STAMPS {
                if let Some(t) = r.get(k).filter(|v| v.is_number()) {
                    o.insert(k.into(), t.clone());
                }
            }
            let w: Map<String, Value> = windows
                .iter()
                .filter(|(k, _)| WINDOWS.contains(&k.as_str()))
                .filter_map(|(k, w)| {
                    let w = w.as_object()?;
                    let kept: Map<String, Value> = WINDOW_FIELDS
                        .iter()
                        .filter_map(|f| {
                            w.get(*f)
                                .filter(|v| v.is_number())
                                .map(|v| (f.to_string(), v.clone()))
                        })
                        .collect();
                    Some((k.clone(), Value::Object(kept)))
                })
                .collect();
            o.insert("windows".into(), Value::Object(w));
            Value::Object(o)
        })
        .collect();
    Value::Array(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;
    use serde_json::json;

    const PERSONAL: &str = "00000000-0000-4000-8000-0000000000b2";
    const TEAM: &str = "00000000-0000-4000-8000-0000000000a1";

    fn reading(account: &str, label: &str, session: &str, pct: u32) -> Value {
        json!({
            "account": account, "label": label, "session": session,
            "written_at": 1_800_000_000, "observed_at": 1_800_000_000, "api_ms": 41_234,
            "windows": {
                "five_hour": {"used_percentage": pct, "resets_at": 1_800_003_600, "extra": "x"},
                "seven_day": {"used_percentage": 27.5, "resets_at": 1_800_500_000}
            }
        })
    }

    fn put(dir: &Path, account: &str, file: &str, body: &str) {
        let a = dir.join("accounts").join(account);
        std::fs::create_dir_all(&a).unwrap();
        std::fs::write(a.join(file), body).unwrap();
    }

    #[test]
    fn every_session_file_of_every_account_in_every_dir_is_read() {
        let (one, two) = (Scratch::new("usage-one"), Scratch::new("usage-two"));
        let (one, two) = (&one.0, &two.0);
        put(
            one,
            PERSONAL,
            "s1.json",
            &reading(PERSONAL, "Personal", "s1", 57).to_string(),
        );
        put(
            one,
            PERSONAL,
            "s2.json",
            &reading(PERSONAL, "Personal", "s2", 58).to_string(),
        );
        put(
            two,
            TEAM,
            "s3.json",
            &reading(TEAM, "Team", "s3", 0).to_string(),
        );
        // Skipped: not JSON, not a .json, a write in flight, a file where an account's folder goes.
        put(one, PERSONAL, "torn.json", "{\"account\":");
        put(one, PERSONAL, "s1.json.123.tmp", "{}");
        put(one, PERSONAL, "notes.txt", "{}");
        std::fs::write(one.join("accounts").join("old.json"), "{}").unwrap();
        let missing = one.join("nowhere");
        let mut got: Vec<String> = read([one, two, &missing])
            .iter()
            .map(|v| v["session"].as_str().unwrap().to_string())
            .collect();
        got.sort();
        assert_eq!(got, ["s1", "s2", "s3"]);
        assert!(read([&missing]).is_empty());
    }

    #[test]
    fn the_phone_gets_only_what_the_gauge_draws() {
        let v = phone_view(&[reading(PERSONAL, "Personal", "s1", 57)]);
        assert_eq!(
            v,
            json!([{
                "account": "a1", "label": "Personal",
                "observed_at": 1_800_000_000, "written_at": 1_800_000_000,
                "windows": {
                    "five_hour": {"used_percentage": 57, "resets_at": 1_800_003_600},
                    "seven_day": {"used_percentage": 27.5, "resets_at": 1_800_500_000}
                }
            }])
        );
        let text = v.to_string();
        for secret in [PERSONAL, "s1", "api_ms", "session", "extra"] {
            assert!(!text.contains(secret), "{secret} reached the phone: {text}");
        }
    }

    #[test]
    fn account_ids_become_ordinals_that_group_as_the_ids_do() {
        let all = [
            reading(PERSONAL, "Personal", "s1", 57),
            reading(TEAM, "Team", "s2", 3),
            reading(PERSONAL, "Personal", "s3", 58),
            json!({"label": "Claude", "windows": {}}),
            json!({"account": "?", "label": "Claude", "windows": {}}),
        ];
        let v = phone_view(&all);
        let ids: Vec<&str> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["account"].as_str().unwrap())
            .collect();
        // Sorted: "0...a1" (TEAM), "0...b2" (PERSONAL), then "?" sorts after digits.
        assert_eq!(ids, ["a2", "a1", "a2", "a3", "a3"]);
        let text = v.to_string();
        assert!(!text.contains(PERSONAL) && !text.contains(TEAM), "{text}");
    }

    #[test]
    fn odd_shapes_are_cut_not_passed_through() {
        let v = phone_view(&[
            json!(null),
            json!("text"),
            json!({"account": PERSONAL, "label": "Personal"}),
            json!({"account": PERSONAL, "windows": []}),
            json!({
                "account": PERSONAL, "label": {"email": "someone@example.com"},
                "observed_at": "1800000000", "written_at": null,
                "windows": {
                    "five_hour": {"used_percentage": "57", "resets_at": 1_800_003_600},
                    "Five Hour": {"used_percentage": 1, "resets_at": 1},
                    "spend_limit": "x",
                    "seven_day": {"used_percentage": 3, "resets_at": 1_800_500_000}
                }
            }),
        ]);
        assert_eq!(
            v,
            json!([{
                "account": "a1",
                "windows": {
                    "five_hour": {"resets_at": 1_800_003_600},
                    "seven_day": {"used_percentage": 3, "resets_at": 1_800_500_000}
                }
            }])
        );
        assert_eq!(phone_view(&[]), json!([]));
    }

    fn sessions(values: &[Value]) -> Vec<String> {
        let mut got: Vec<String> = values
            .iter()
            .map(|v| v["session"].as_str().unwrap_or("?").to_string())
            .collect();
        got.sort();
        got
    }

    fn ok(dir: &Path, account: &str, session: &str) {
        put(
            dir,
            account,
            &format!("{session}.json"),
            &reading(account, "Personal", session, 5).to_string(),
        );
    }

    #[test]
    fn a_file_over_the_cap_is_skipped() {
        let d = Scratch::new("usage-big");
        ok(&d.0, PERSONAL, "small");
        let pad = "x".repeat(MAX_BYTES as usize);
        put(
            &d.0,
            PERSONAL,
            "big.json",
            &json!({"session": "big", "pad": pad, "windows": {}}).to_string(),
        );
        assert_eq!(sessions(&read([&d.0])), ["small"]);
    }

    #[test]
    fn an_odd_account_folder_name_is_skipped() {
        let d = Scratch::new("usage-names");
        ok(&d.0, PERSONAL, "kept");
        for name in ["-dash", ".hidden", "under_score", "sp ace"] {
            ok(&d.0, name, name.trim_start_matches(['-', '.']));
        }
        assert_eq!(sessions(&read([&d.0])), ["kept"]);
    }

    /// Set the modified time of `path`, a file or a folder, to `secs` past the epoch.
    fn touch(path: &Path, secs: u64) {
        let mut options = std::fs::File::options();
        #[cfg(unix)]
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            // SetFileTime takes a folder's handle only with backup semantics:
            // FILE_WRITE_ATTRIBUTES, FILE_FLAG_BACKUP_SEMANTICS.
            options.access_mode(0x0100).custom_flags(0x0200_0000);
        }
        options
            .open(path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .unwrap();
    }

    #[test]
    fn past_a_cap_the_newest_files_and_accounts_are_kept() {
        let d = Scratch::new("usage-caps");
        for (n, at) in [("old", 1_000), ("new", 3_000), ("mid", 2_000)] {
            ok(&d.0, PERSONAL, n);
            touch(
                &d.0.join("accounts")
                    .join(PERSONAL)
                    .join(format!("{n}.json")),
                at,
            );
        }
        assert_eq!(
            sessions(&read_capped([&d.0], MAX_BYTES, 8, 2)),
            ["mid", "new"]
        );
        ok(&d.0, TEAM, "team");
        // The account written to last is kept: here the team's, once the
        // personal folder is dated earlier.
        touch(&d.0.join("accounts").join(PERSONAL), 1_000);
        assert_eq!(sessions(&read_capped([&d.0], MAX_BYTES, 1, 8)), ["team"]);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_and_fifos_are_never_followed_or_opened() {
        use std::os::unix::fs::symlink;
        let d = Scratch::new("usage-links");
        let outside = Scratch::new("usage-outside");
        ok(&d.0, PERSONAL, "kept");
        // A file outside, linked in as a reading and as an account folder.
        put(
            &outside.0,
            TEAM,
            "away.json",
            &reading(TEAM, "Outside", "away", 9).to_string(),
        );
        let away = outside.0.join("accounts").join(TEAM);
        symlink(
            away.join("away.json"),
            d.0.join("accounts").join(PERSONAL).join("link.json"),
        )
        .unwrap();
        symlink(&away, d.0.join("accounts").join(TEAM)).unwrap();
        // A FIFO named as a reading: opening it would block.
        let fifo = d.0.join("accounts").join(PERSONAL).join("pipe.json");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let got = read([&d.0]);
        assert_eq!(sessions(&got), ["kept"]);
        assert!(!serde_json::to_string(&got).unwrap().contains("Outside"));
        // The accounts folder itself a link: nothing is read through it.
        let linked = Scratch::new("usage-linked");
        symlink(d.0.join("accounts"), linked.0.join("accounts")).unwrap();
        assert!(read([&linked.0]).is_empty());
    }
}
