//! The Voices setting (#183, #273): who speaks through keryx. prefs.json keeps
//! it under `voices`, where `fleet voices` (fleet/voices.sh) reads it and sets
//! keryx to match, for running sessions too: "heph" (the default) lets only the
//! orchestrator's session speak, "everyone" every session, "off" none.

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
    crate::choice::of(&VOICES, KEY, prefs)
}

/// The value to save for mode `id`, or an error naming the modes.
pub fn value(id: &str) -> Result<Value, String> {
    crate::choice::value(&VOICES, "voices mode", id)
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
    fn the_modes_are_the_ones_fleet_voices_reads() {
        let script = include_str!("../../../fleet/voices.sh");
        let mut read = format!("case $(prefs_get {KEY}) in");
        for (id, _) in &VOICES[1..] {
            read.push_str(&format!(" '\"{id}\"') echo {id} ;;"));
        }
        read.push_str(&format!(" *) echo {} ;; esac", VOICES[0].0));
        assert!(script.contains(&read), "voices.sh reads: {read}");
    }
}
