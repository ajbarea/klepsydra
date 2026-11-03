//! Heph's account (#271): the account AJ picks for the orchestrator on the
//! wall, kept in prefs.json under `heph_account` as the account's id, or
//! "auto" for the fleet's own order. The resume service reads it each pass
//! (fleet/lib.sh `heph_pick`) and moves Heph to that account at a finished
//! turn while it has room.

use serde_json::{Map, Value};

/// The prefs.json key.
pub const KEY: &str = "heph_account";
/// The value for no pick: the fleet's own order.
pub const AUTO: &str = "auto";
/// The tray's label for no pick.
pub const AUTO_LABEL: &str = "Fleet's order (auto)";

/// An account id as the statusLine hook files readings under it, and as
/// lib.sh's `heph_pick` accepts one.
pub fn id_ok(id: &str) -> bool {
    let mut bytes = id.bytes();
    id.len() <= 64
        && bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// The saved pick: an account id, or `AUTO` for none, "auto", or an odd value.
pub fn of(prefs: Option<&Map<String, Value>>) -> String {
    prefs
        .and_then(|p| p.get(KEY)?.as_str())
        .filter(|id| *id != AUTO && id_ok(id))
        .map_or_else(|| AUTO.to_string(), str::to_string)
}

/// The value to save for `id` (`AUTO` or an account id), or an error.
pub fn value(id: &str) -> Result<Value, String> {
    if id == AUTO || id_ok(id) {
        Ok(Value::from(id))
    } else {
        Err(format!("not an account id: {id:?}"))
    }
}

/// One account the tray offers: its id and its label with its room now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Choice {
    pub id: String,
    pub label: String,
}

/// A window's room at `now` (epoch seconds), as lib.sh's `headroom`: 100 less
/// the percentage used, 100 for a window that has reset; None for a window
/// the reading does not have.
fn room(windows: &Map<String, Value>, name: &str, now: f64) -> Option<i64> {
    let w = windows.get(name)?.as_object()?;
    let resets = w.get("resets_at").and_then(Value::as_f64).unwrap_or(0.0);
    if resets <= now {
        return Some(100);
    }
    let used = w
        .get("used_percentage")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    Some((100.0 - used).clamp(0.0, 100.0).floor() as i64)
}

/// A reading's time: its observed_at, else its written_at.
fn stamp(r: &Map<String, Value>) -> f64 {
    ["observed_at", "written_at"]
        .iter()
        .find_map(|k| r.get(*k).and_then(Value::as_f64))
        .unwrap_or(0.0)
}

/// The accounts in `readings` (`usage::read`'s), one choice each from its
/// newest reading, sorted by label: "RIT: 5-hour room 63%, weekly room 80%".
/// A reading with no usable account id is skipped.
pub fn choices(readings: &[Value], now: f64) -> Vec<Choice> {
    let mut newest: Vec<(&str, &Map<String, Value>)> = Vec::new();
    for r in readings.iter().filter_map(Value::as_object) {
        let Some(id) = r
            .get("account")
            .and_then(Value::as_str)
            .filter(|id| id_ok(id))
        else {
            continue;
        };
        match newest.iter_mut().find(|(i, _)| *i == id) {
            Some(slot) if stamp(r) > stamp(slot.1) => slot.1 = r,
            Some(_) => {}
            None => newest.push((id, r)),
        }
    }
    let mut out: Vec<Choice> = newest
        .into_iter()
        .map(|(id, r)| {
            let name = r
                .get("label")
                .and_then(Value::as_str)
                .filter(|l| !l.trim().is_empty())
                .unwrap_or(id);
            let mut parts = Vec::new();
            if let Some(w) = r.get("windows").and_then(Value::as_object) {
                if let Some(f) = room(w, "five_hour", now) {
                    parts.push(format!("5-hour room {f}%"));
                }
                if let Some(s) = room(w, "seven_day", now) {
                    parts.push(format!("weekly room {s}%"));
                }
            }
            let label = if parts.is_empty() {
                name.to_string()
            } else {
                format!("{name}: {}", parts.join(", "))
            };
            Choice {
                id: id.to_string(),
                label,
            }
        })
        .collect();
    out.sort_by(|a, b| a.label.cmp(&b.label).then(a.id.cmp(&b.id)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const RIT: &str = "00000000-0000-4000-8000-0000000000a1";
    const PERSONAL: &str = "00000000-0000-4000-8000-0000000000b2";

    fn reading(account: &str, label: &str, at: u64, five: f64, seven: Option<f64>) -> Value {
        let mut windows = json!({"five_hour": {"used_percentage": five, "resets_at": 2_000}});
        if let Some(s) = seven {
            windows["seven_day"] = json!({"used_percentage": s, "resets_at": 9_000});
        }
        json!({"account": account, "label": label, "observed_at": at, "windows": windows})
    }

    #[test]
    fn no_pick_auto_and_odd_values_read_as_auto() {
        assert_eq!(of(None), AUTO);
        for bad in [
            json!({}),
            json!({"heph_account": "auto"}),
            json!({"heph_account": 3}),
            json!({"heph_account": "../a"}),
            json!({"heph_account": ""}),
            json!({"heph_account": "-a"}),
        ] {
            assert_eq!(of(bad.as_object()), AUTO, "{bad}");
        }
        assert_eq!(of(json!({"heph_account": RIT}).as_object()), RIT);
    }

    #[test]
    fn only_auto_or_an_account_id_is_saved() {
        assert_eq!(value(AUTO), Ok(json!("auto")));
        assert_eq!(value(RIT), Ok(json!(RIT)));
        for bad in ["", "../x", "a b", "a/b", &"a".repeat(65)] {
            assert!(value(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn the_id_rule_is_the_one_lib_sh_reads() {
        let lib = include_str!("../../../fleet/lib.sh");
        assert!(
            lib.contains("$HEPH_PICK_ID =~ ^[0-9A-Za-z][0-9A-Za-z-]*$"),
            "heph_pick's id rule"
        );
        assert!(lib.contains(".[0].heph_account"), "heph_pick reads the key");
        assert_eq!(KEY, "heph_account");
    }

    #[test]
    fn one_choice_per_account_from_its_newest_reading_with_its_room() {
        let readings = vec![
            reading(RIT, "RIT", 100, 90.0, None),
            reading(RIT, "RIT", 200, 37.4, None),
            reading(PERSONAL, "Personal", 150, 10.0, Some(20.0)),
            json!({"account": "../x", "label": "bad", "windows": {}}),
            json!("not an object"),
        ];
        assert_eq!(
            choices(&readings, 1_000.0),
            vec![
                Choice {
                    id: PERSONAL.into(),
                    label: "Personal: 5-hour room 90%, weekly room 80%".into()
                },
                Choice {
                    id: RIT.into(),
                    label: "RIT: 5-hour room 62%".into()
                },
            ]
        );
    }

    #[test]
    fn a_window_past_its_reset_has_all_its_room() {
        let r = vec![reading(RIT, "RIT", 1, 99.0, Some(50.0))];
        assert_eq!(
            choices(&r, 5_000.0)[0].label,
            "RIT: 5-hour room 100%, weekly room 50%"
        );
    }

    #[test]
    fn no_label_or_windows_falls_back_to_the_id() {
        let r = vec![json!({"account": RIT, "label": " ", "observed_at": 1})];
        assert_eq!(
            choices(&r, 0.0),
            vec![Choice {
                id: RIT.into(),
                label: RIT.into()
            }]
        );
    }
}
