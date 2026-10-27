//! The wall's character themes (#135): which look the cards wear, kept in
//! prefs.json under `theme`. Each id names a data file the frontend loads,
//! `src/fleet/themes/<id>.json`; the first is the default.

use std::path::Path;

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

/// The file in the data folder the fleet hook reads its tmux window colours
/// from (`klepsydra-fleet.sh`, `colour_window`): the theme worn, as its file.
pub const HOOK_CAST: &str = "cast.json";

/// Write `theme` (a theme file's bytes) to `<dir>/cast.json` for the fleet
/// hook, whole or not at all: a temp file renamed into place. Refused, and
/// the old file kept, unless it is a JSON object whose `characters` is one.
pub fn write_cast(dir: &Path, theme: &[u8]) -> std::io::Result<()> {
    let invalid =
        |what: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, what.to_string());
    let v: Value = serde_json::from_slice(theme).map_err(|e| invalid(&e.to_string()))?;
    if !v.get("characters").is_some_and(Value::is_object) {
        return Err(invalid("a theme has a characters object"));
    }
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{HOOK_CAST}.tmp"));
    std::fs::write(&tmp, theme)?;
    std::fs::rename(&tmp, dir.join(HOOK_CAST))
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

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-theme-{name}-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_hook_cast_is_the_theme_file_whole() {
        let dir = temp_dir("cast");
        let theme =
            br##"{"v":1,"characters":{"am_michael":{"name":"Foreman","accent":"#FF8D70"}}}"##;
        write_cast(&dir, theme).unwrap();
        assert_eq!(std::fs::read(dir.join(HOOK_CAST)).unwrap(), theme);
        assert!(!dir.join("cast.json.tmp").exists(), "no temp file left");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_is_no_theme_is_refused_and_the_old_cast_kept() {
        let dir = temp_dir("refused");
        let good = br#"{"v":1,"characters":{}}"#;
        write_cast(&dir, good).unwrap();
        for bad in [
            &b"not json"[..],
            br#"{"v":1}"#,
            br#"{"characters":[]}"#,
            br#"[1,2]"#,
            b"",
        ] {
            assert!(
                write_cast(&dir, bad).is_err(),
                "{}",
                String::from_utf8_lossy(bad)
            );
            assert_eq!(std::fs::read(dir.join(HOOK_CAST)).unwrap(), good);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
