//! A choice kept in prefs.json under one key, from a fixed table of ids and
//! the tray's labels, the first the default: the Characters theme and the
//! Voices mode.

use serde_json::{Map, Value};

/// Each choice's id and the label the tray gives it, the default first.
pub type Table = [(&'static str, &'static str)];

/// `id` when it is in `table`; else the default.
pub fn known(table: &'static Table, id: Option<&str>) -> &'static str {
    table
        .iter()
        .find(|(t, _)| Some(*t) == id)
        .map_or(table[0].0, |(t, _)| t)
}

/// The choice saved under `key`, or the default for a missing, unknown or
/// unreadable one.
pub fn of(table: &'static Table, key: &str, prefs: Option<&Map<String, Value>>) -> &'static str {
    known(table, prefs.and_then(|p| p.get(key)?.as_str()))
}

/// The value to save for `id`, or an error naming `what` and the choices.
pub fn value(table: &Table, what: &str, id: &str) -> Result<Value, String> {
    if table.iter().any(|(t, _)| *t == id) {
        Ok(Value::from(id))
    } else {
        let ids: Vec<&str> = table.iter().map(|(t, _)| *t).collect();
        Err(format!("unknown {what} {id:?}; one of {}", ids.join(", ")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const T: [(&str, &str); 2] = [("a", "A"), ("b", "B")];

    #[test]
    fn the_first_is_the_default_and_an_odd_value_reads_as_it() {
        assert_eq!(of(&T, "k", None), "a");
        for bad in [
            json!({}),
            json!({"k": "c"}),
            json!({"k": 3}),
            json!({"other": "b"}),
        ] {
            assert_eq!(of(&T, "k", bad.as_object()), "a", "{bad}");
        }
        assert_eq!(of(&T, "k", json!({"k": "b"}).as_object()), "b");
    }

    #[test]
    fn only_a_known_choice_is_saved() {
        assert_eq!(value(&T, "thing", "b"), Ok(json!("b")));
        assert_eq!(
            value(&T, "thing", "c"),
            Err("unknown thing \"c\"; one of a, b".into())
        );
    }
}
