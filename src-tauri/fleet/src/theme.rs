//! The wall's character themes (#135): which look the cards wear, kept in
//! prefs.json under `theme`. Each id names a data file the frontend loads,
//! `src/fleet/themes/<id>.json`; the first is the default.

use serde_json::{Map, Value};

/// prefs.json's key for the theme.
pub const KEY: &str = "theme";

/// Each theme's id and the name the tray gives it, the default first.
pub const THEMES: [(&str, &str); 3] = [
    ("kourai", "Kourai"),
    ("professions", "Professions"),
    ("dicebear", "DiceBear"),
];

/// `id` when it names a theme; else the default.
pub fn known(id: Option<&str>) -> &'static str {
    THEMES
        .iter()
        .find(|(t, _)| Some(*t) == id)
        .map_or(THEMES[0].0, |(t, _)| t)
}

/// The saved theme, or the default for a missing, unknown or unreadable one.
pub fn of(prefs: Option<&Map<String, Value>>) -> &'static str {
    known(prefs.and_then(|p| p.get(KEY)?.as_str()))
}

/// The value to save for `id`, or an error naming the choices.
pub fn value(id: &str) -> Result<Value, String> {
    if THEMES.iter().any(|(t, _)| *t == id) {
        Ok(Value::from(id))
    } else {
        let ids: Vec<&str> = THEMES.iter().map(|(t, _)| *t).collect();
        Err(format!("unknown theme {id:?}; one of {}", ids.join(", ")))
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
    fn the_default_is_kourai() {
        assert_eq!(THEMES[0].0, "kourai");
        assert_eq!(of(None), "kourai", "prefs.json unreadable");
        assert_eq!(of(Some(&prefs(json!({})))), "kourai", "no theme saved");
    }

    #[test]
    fn an_unknown_or_malformed_theme_reads_as_kourai() {
        for bad in [
            json!("Professions"),
            json!("lorelei"),
            json!(""),
            json!("__proto__"),
            json!(2),
            json!(["dicebear"]),
            Value::Null,
        ] {
            let p = prefs(json!({ "theme": bad }));
            assert_eq!(of(Some(&p)), "kourai", "{bad}");
        }
    }

    #[test]
    fn a_saved_theme_reads_back() {
        for (id, _) in THEMES {
            let p = prefs(json!({ "zoom": 2, "theme": value(id).unwrap() }));
            assert_eq!(of(Some(&p)), id);
        }
    }

    #[test]
    fn an_unknown_theme_is_refused() {
        let err = value("Kourai").unwrap_err();
        assert!(err.contains("kourai, professions, dicebear"), "{err}");
        assert!(value("").is_err());
        assert!(value("../kourai").is_err());
    }
}
