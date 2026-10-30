//! The Voices setting (#183): who speaks through keryx. prefs.json keeps it
//! under `voices`, where `fleet/launch.sh` reads it at each fresh start:
//! "heph" (the default) starts workers with keryx off, "everyone" leaves it on
//! for them, "off" turns it off for Heph too.

use serde_json::{Map, Value};

/// The prefs.json key.
pub const KEY: &str = "voices";
/// Each mode's id and its tray label; the first is the default.
pub const VOICES: [(&str, &str); 3] = [
    ("heph", "Heph only"),
    ("everyone", "Everyone"),
    ("off", "Off"),
];

/// The saved mode, or the default for a missing or unknown one.
pub fn of(prefs: Option<&Map<String, Value>>) -> &'static str {
    let saved = prefs.and_then(|p| p.get(KEY)?.as_str());
    VOICES
        .iter()
        .map(|(id, _)| *id)
        .find(|id| Some(*id) == saved)
        .unwrap_or(VOICES[0].0)
}

/// The value to save for mode `id`, or an error naming the modes.
pub fn value(id: &str) -> Result<Value, String> {
    if VOICES.iter().any(|(v, _)| *v == id) {
        Ok(Value::from(id))
    } else {
        let all: Vec<&str> = VOICES.iter().map(|(v, _)| *v).collect();
        Err(format!(
            "unknown voices mode {id:?}; one of {}",
            all.join(", ")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn heph_only_is_the_default_and_an_odd_value_reads_as_it() {
        assert_eq!(of(None), "heph");
        for bad in [json!({}), json!({"voices": "loud"}), json!({"voices": 3})] {
            assert_eq!(of(bad.as_object()), "heph", "{bad}");
        }
        assert_eq!(of(json!({"voices": "off"}).as_object()), "off");
    }

    #[test]
    fn only_a_known_mode_is_saved() {
        assert_eq!(value("everyone"), Ok(json!("everyone")));
        assert!(value("loud").unwrap_err().contains("heph, everyone, off"));
    }

    #[test]
    fn the_modes_are_the_ones_launch_sh_reads() {
        let launch = include_str!("../../../fleet/launch.sh");
        assert!(launch.contains("case $voices in everyone | off) ;; *) voices=heph ;; esac"));
        assert!(launch.contains(".voices // empty"), "the same key");
    }
}
