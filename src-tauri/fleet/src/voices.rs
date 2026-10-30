//! The Voices setting (#183): who speaks through keryx. prefs.json keeps it
//! under `voices`, where `fleet/launch.sh` reads it each time it starts a session:
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
    fn the_modes_are_the_ones_launch_sh_reads() {
        let launch = include_str!("../../../fleet/launch.sh");
        let others: Vec<String> = VOICES[1..]
            .iter()
            .map(|(id, _)| format!(". == \"{id}\""))
            .collect();
        let read = format!(
            "voices=$(jq -ser 'if length == 1 then .[0].{KEY} else empty end | select({})' \"$KLEPSYDRA_DIR/prefs.json\" 2>/dev/null) || voices={}",
            others.join(" or "),
            VOICES[0].0
        );
        assert!(launch.contains(&read), "launch.sh reads: {read}");
    }
}
