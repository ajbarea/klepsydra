//! The gauges' on/off settings (#421): each a boolean in prefs.json with a
//! default, sent as one object to every window that follows them, so a
//! switch in the gear or a chevron applies at once and the next start keeps it.

use serde_json::{Map, Value};

/// One on/off setting: its prefs.json key and its value before anyone sets it.
#[derive(Debug, PartialEq, Eq)]
pub struct Toggle {
    pub key: &'static str,
    pub default: bool,
}

/// The usage chips docked in the wall's header bar.
pub const GAUGES_IN_HEADER: Toggle = Toggle {
    key: "gauges_in_header",
    default: true,
};

/// Every toggle, in the order the gear lists them.
pub const ALL: &[Toggle] = &[GAUGES_IN_HEADER];

/// The toggle saved under `key`, or an error naming the known keys.
pub fn find(key: &str) -> Result<&'static Toggle, String> {
    ALL.iter().find(|t| t.key == key).ok_or_else(|| {
        let known: Vec<_> = ALL.iter().map(|t| t.key).collect();
        format!("unknown setting {key:?}; one of {}", known.join(", "))
    })
}

/// The saved value, or the default when prefs.json is missing, unreadable or
/// holds no boolean there (a hand edit to "yes" is not a choice).
pub fn of(prefs: Option<&Map<String, Value>>, t: &Toggle) -> bool {
    prefs
        .and_then(|p| p.get(t.key))
        .and_then(Value::as_bool)
        .unwrap_or(t.default)
}

/// Every toggle's value as one object, the message each window is sent.
pub fn all(prefs: Option<&Map<String, Value>>) -> Value {
    Value::Object(
        ALL.iter()
            .map(|t| (t.key.to_owned(), Value::Bool(of(prefs, t))))
            .collect(),
    )
}

/// Ok when prefs.json now holds what was asked; otherwise the reason the
/// setting keeps its saved value.
pub fn confirm(t: &Toggle, asked: bool, prefs: Option<&Map<String, Value>>) -> Result<(), String> {
    if prefs.and_then(|p| p.get(t.key)).and_then(Value::as_bool) == Some(asked) {
        Ok(())
    } else {
        let saved = if of(prefs, t) { "on" } else { "off" };
        Err(format!(
            "prefs.json could not be saved, so {} is still {saved}.",
            t.key
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn prefs(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn finds_a_known_key_and_names_the_rest() {
        assert_eq!(find("gauges_in_header"), Ok(&GAUGES_IN_HEADER));
        for bad in ["", "Gauges_in_header", "gauge_opacity", "gauges_in_header "] {
            let err = find(bad).unwrap_err();
            assert!(err.contains("gauges_in_header"), "{bad:?}: {err}");
        }
    }

    #[test]
    fn reads_the_saved_value_or_the_default() {
        let t = &GAUGES_IN_HEADER;
        assert!(of(None, t), "prefs.json unreadable: the default");
        assert!(of(Some(&Map::new()), t), "never set");
        assert!(!of(Some(&prefs(json!({"gauges_in_header": false}))), t));
        assert!(of(Some(&prefs(json!({"gauges_in_header": true}))), t));
        for odd in [json!("false"), json!(0), json!(null), json!([])] {
            assert!(
                of(Some(&prefs(json!({ "gauges_in_header": odd.clone() }))), t),
                "{odd}: not a boolean, so the default"
            );
        }
    }

    #[test]
    fn all_sends_every_toggle() {
        assert_eq!(all(None), json!({"gauges_in_header": true}));
        assert_eq!(
            all(Some(&prefs(json!({"gauges_in_header": false, "zoom": 2})))),
            json!({"gauges_in_header": false}),
            "only toggles, not the other prefs"
        );
    }

    #[test]
    fn confirm_checks_the_stored_value() {
        let t = &GAUGES_IN_HEADER;
        assert_eq!(
            confirm(t, false, Some(&prefs(json!({"gauges_in_header": false})))),
            Ok(())
        );
        let err = confirm(t, false, Some(&prefs(json!({"gauges_in_header": true})))).unwrap_err();
        assert!(err.contains("still on"), "{err}");
        // Missing or unreadable reads as the default: asking for it is still not a save.
        assert!(confirm(t, true, None).is_err(), "prefs.json unreadable");
        assert!(
            confirm(t, true, Some(&Map::new())).is_err(),
            "key not written"
        );
    }
}
