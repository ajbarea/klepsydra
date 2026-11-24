//! The wall's character themes (#135): which look the cards wear, kept in
//! prefs.json under `theme`. Each id names a data file the frontend loads,
//! `src/fleet/themes/<id>.json`; the first is the default.

use std::path::Path;
use std::sync::Mutex;

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
    crate::choice::known(&THEMES, id)
}

/// The saved theme, or the default for a missing, unknown or unreadable one.
pub fn of(prefs: Option<&Map<String, Value>>) -> &'static str {
    crate::choice::of(&THEMES, KEY, prefs)
}

/// The value to save for `id`, or an error naming the choices.
pub fn value(id: &str) -> Result<Value, String> {
    crate::choice::value(&THEMES, "theme", id)
}

/// The file in the data folder the fleet hook reads its tmux window colours
/// from (`klepsydra-fleet.sh`, `colour_window`): the theme worn, as its file.
pub const HOOK_CAST: &str = "cast.json";

/// One cast.json write at a time in this process: each writes one temp file
/// and renames it, so two at once would share it.
static CAST_WRITE: Mutex<()> = Mutex::new(());

/// Whether prefs.json (`prefs`, read back after the save) holds the theme
/// `asked` for, as opacity::confirm does: else why not, for the wall to say.
/// The wall wears what prefs.json yields (`of`), so a refused save names that
/// theme. Asking for the theme the file already yields without holding it
/// (the default, from a corrupt file) is still a refusal (#484): nothing was
/// written, and the wall says why.
pub fn confirm(asked: &str, prefs: Option<&Map<String, Value>>) -> Result<(), String> {
    if prefs.and_then(|p| p.get(KEY)).and_then(Value::as_str) == Some(asked) {
        return Ok(());
    }
    let worn = of(prefs);
    let why = if prefs.is_none() {
        "prefs.json does not read as one JSON object, so nothing is saved until it is fixed or removed"
    } else {
        "prefs.json could not be written"
    };
    if worn == asked {
        Err(format!(
            "{why}: {asked} shows because it is the default, not because it is saved."
        ))
    } else {
        Err(format!("{why}: the theme is still {worn}, not {asked}."))
    }
}

/// Write `theme` (a theme file's bytes) to `<dir>/cast.json` for the fleet
/// hook, whole or not at all: a temp file renamed into place. Refused, and
/// the old file kept, unless it is a JSON object whose `characters` is one.
pub fn write_cast(dir: &Path, theme: &[u8]) -> std::io::Result<()> {
    let _one = CAST_WRITE.lock().unwrap_or_else(|e| e.into_inner());
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

    #[test]
    fn a_choice_not_saved_says_so() {
        let prefs =
            |v: Value| -> Map<String, Value> { [(KEY.to_string(), v)].into_iter().collect() };
        assert_eq!(confirm("dicebear", Some(&prefs(json!("dicebear")))), Ok(()));
        // A write that failed while prefs.json already held the choice: kept, so no error.
        assert_eq!(confirm("kourai", Some(&prefs(json!("kourai")))), Ok(()));
        // A corrupt prefs.json (None) reads as the default kourai: still a refusal, saying why.
        let err = confirm("kourai", None).unwrap_err();
        assert!(err.contains("does not read as one JSON object"), "{err}");
        assert!(
            err.contains("kourai shows because it is the default"),
            "{err}"
        );
        let err = confirm("dicebear", None).unwrap_err();
        assert!(err.contains("still kourai, not dicebear"), "{err}");
        // A write that failed over another saved theme names the one still worn.
        let err = confirm("dicebear", Some(&prefs(json!("professions")))).unwrap_err();
        assert!(err.contains("still professions, not dicebear"), "{err}");
        // A readable file that the write could not change.
        let err = confirm("kourai", Some(&Map::new())).unwrap_err();
        assert!(
            err.contains("could not be written: kourai shows because it is the default"),
            "{err}"
        );
    }

    #[test]
    fn cast_writes_from_many_threads_each_land_whole() {
        let dir = temp_dir("threads");
        let themes: Vec<Vec<u8>> = (0..8)
            .map(|i| {
                format!(
                    r#"{{"v":1,"label":"{}","characters":{{}}}}"#,
                    "x".repeat(4000 + i)
                )
                .into_bytes()
            })
            .collect();
        std::thread::scope(|s| {
            for t in &themes {
                let dir = &dir;
                s.spawn(move || {
                    for _ in 0..40 {
                        write_cast(dir, t).unwrap();
                    }
                });
            }
        });
        let last = std::fs::read(dir.join(HOOK_CAST)).unwrap();
        assert!(themes.contains(&last), "the cast is one theme, whole");
        assert!(!dir.join("cast.json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
