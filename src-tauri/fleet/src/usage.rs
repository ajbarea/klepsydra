//! The statusLine hook's readings, `accounts/<account>/<session>.json`, as
//! the gauge reads them (`read_usage`) and the phone wall serves them.

use std::path::Path;

use serde_json::{Map, Value};

/// Every reading under each of `dirs`' `accounts`, one per Claude Code
/// session. A file that is missing, unreadable or not JSON is skipped, as is
/// a stale pre-per-session file in place of an account's directory.
/// Sessions disagree routinely; reconciling them is the frontend's job.
pub fn read<P: AsRef<Path>>(dirs: impl IntoIterator<Item = P>) -> Vec<Value> {
    let mut out = Vec::new();
    for dir in dirs {
        let Ok(accounts) = std::fs::read_dir(dir.as_ref().join("accounts")) else {
            continue;
        };
        for account in accounts.flatten() {
            let Ok(sessions) = std::fs::read_dir(account.path()) else {
                continue;
            };
            for session in sessions.flatten() {
                let path = session.path();
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&path) else {
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

/// A window name as Claude Code writes them (`five_hour`, `seven_day`).
fn window_name(k: &str) -> bool {
    !k.is_empty()
        && k.len() <= 32
        && k.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

/// The readings as the phone gets them: each cut to its label, its times and
/// each window's percent and reset time. The account id becomes `a1`, `a2`,
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
                .filter(|(k, _)| window_name(k))
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
}
