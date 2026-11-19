//! The gauge's background opacity (#438): 0 to 100 in steps of 5, kept in
//! prefs.json under [`KEY`] and sent to every window that draws a gauge, so
//! a change applies at once and the next start keeps it.

use serde_json::{Map, Value};

/// prefs.json's key for the opacity.
pub const KEY: &str = "gauge_opacity";

/// The opacity before anyone picks one: the first step at or above the 82%
/// the panel wore before the setting existed, and the lowest at which its
/// faint words keep 4.5:1 over any desktop (opacity.js FULL_INK_BELOW).
pub const DEFAULT: u8 = 85;

/// The slider's step.
pub const STEP: u8 = 5;

/// `v` on the slider's grid, rounded to the nearest step. A value that is
/// not a number from 0 to 100 (a hand edit) is the default, not an extreme.
pub fn snap(v: f64) -> u8 {
    if !(0.0..=100.0).contains(&v) {
        return DEFAULT;
    }
    let steps = (v / f64::from(STEP)).round();
    steps as u8 * STEP
}

/// The saved opacity, or the default when prefs.json is missing, unreadable
/// or holds no number there; a hand-edited value off the grid snaps to it.
pub fn of(prefs: Option<&Map<String, Value>>) -> u8 {
    prefs
        .and_then(|p| p.get(KEY))
        .and_then(Value::as_f64)
        .map_or(DEFAULT, snap)
}

/// The value to save for `asked`, on the grid, or an error when it is not
/// a number from 0 to 100.
pub fn value(asked: f64) -> Result<Value, String> {
    if !asked.is_finite() || !(0.0..=100.0).contains(&asked) {
        return Err(format!(
            "the opacity is a number from 0 to 100, not {asked}"
        ));
    }
    Ok(Value::from(snap(asked)))
}

/// Ok when prefs.json now holds what was asked; otherwise the reason the
/// gauge still wears the saved opacity.
pub fn confirm(asked: u8, saved: u8) -> Result<(), String> {
    if asked == saved {
        Ok(())
    } else {
        Err(format!(
            "prefs.json could not be saved, so the opacity is still {saved}%, not {asked}%."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn prefs(v: Value) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert(KEY.into(), v);
        m
    }

    #[test]
    fn snaps_to_the_grid_and_clamps() {
        for (v, want) in [
            (0.0, 0),
            (2.4, 0),
            (2.5, 5),
            (82.0, 80),
            (83.0, 85),
            (100.0, 100),
            (140.0, DEFAULT),
            (-3.0, DEFAULT),
            (f64::NAN, DEFAULT),
            (f64::INFINITY, DEFAULT),
        ] {
            assert_eq!(snap(v), want, "{v}");
        }
    }

    #[test]
    fn reads_the_saved_value_or_the_default() {
        assert_eq!(of(None), DEFAULT, "prefs.json unreadable");
        assert_eq!(of(Some(&Map::new())), DEFAULT, "never set");
        assert_eq!(of(Some(&prefs(json!(35)))), 35);
        assert_eq!(
            of(Some(&prefs(json!(0)))),
            0,
            "fully transparent is a choice, not unset"
        );
        assert_eq!(
            of(Some(&prefs(json!(37.4)))),
            35,
            "hand-edited off the grid"
        );
        assert_eq!(of(Some(&prefs(json!("50")))), DEFAULT, "not a number");
        assert_eq!(of(Some(&prefs(json!(null)))), DEFAULT);
    }

    #[test]
    fn refuses_what_is_not_an_opacity() {
        assert_eq!(value(50.0), Ok(json!(50)));
        assert_eq!(value(47.0), Ok(json!(45)));
        assert_eq!(value(0.0), Ok(json!(0)));
        assert_eq!(value(100.0), Ok(json!(100)));
        for bad in [-1.0, 100.5, f64::NAN, f64::NEG_INFINITY] {
            assert!(value(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn confirm_names_the_saved_value() {
        assert_eq!(confirm(40, 40), Ok(()));
        assert!(confirm(40, 80).unwrap_err().contains("still 80%"));
    }
}
