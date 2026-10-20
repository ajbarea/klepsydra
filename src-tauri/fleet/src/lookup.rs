//! A session in a published snapshot, by id.

use serde_json::Value;

/// The session `id` in `snapshot` (`{"sessions": [...]}`), if it is there.
pub fn session<'a>(snapshot: &'a Value, id: &str) -> Option<&'a Value> {
    snapshot
        .get("sessions")?
        .as_array()?
        .iter()
        .find(|s| s.get("session_id").and_then(Value::as_str) == Some(id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn finds_a_session_by_id_and_nothing_else() {
        let s = json!({"sessions": [{"session_id": "a", "status": "ended"}, {"session_id": "b"}]});
        assert_eq!(session(&s, "a").unwrap()["status"], "ended");
        assert!(session(&s, "c").is_none());
        assert!(session(&json!({}), "a").is_none());
    }
}
