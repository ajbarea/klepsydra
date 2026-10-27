//! A session in a published snapshot, by id.

use serde_json::Value;

use crate::session::remote_url_ok;

/// The session `id` in `snapshot` (`{"sessions": [...]}`), if it is there.
pub fn session<'a>(snapshot: &'a Value, id: &str) -> Option<&'a Value> {
    snapshot
        .get("sessions")?
        .as_array()?
        .iter()
        .find(|s| s.get("session_id").and_then(Value::as_str) == Some(id))
}

/// Session `id`'s Remote Control link in `snapshot`, checked again as the
/// hook and the reader check it: the one link Open in Claude may open.
pub fn remote_url(snapshot: Option<&Value>, id: &str) -> Result<String, String> {
    let s = snapshot
        .and_then(|v| session(v, id))
        .ok_or("That session is no longer on the wall.")?;
    match s.get("remote_url").and_then(Value::as_str) {
        Some(url) if remote_url_ok(url) => Ok(url.to_owned()),
        _ => Err("This session has no Remote Control link.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const URL: &str = "https://claude.ai/code/session_01AbC-x_9";

    fn with_link(link: Value) -> Value {
        json!({"sessions": [{"session_id": "a", "status": "working", "remote_url": link}]})
    }

    #[test]
    fn a_remote_control_link_is_read_from_the_snapshot() {
        assert_eq!(
            remote_url(Some(&with_link(json!(URL))), "a"),
            Ok(URL.into())
        );
    }

    #[test]
    fn no_snapshot_or_another_session_opens_nothing() {
        let gone = Err("That session is no longer on the wall.".into());
        assert_eq!(remote_url(None, "a"), gone);
        assert_eq!(remote_url(Some(&with_link(json!(URL))), "b"), gone);
        assert_eq!(remote_url(Some(&json!({})), "a"), gone);
        assert_eq!(remote_url(Some(&with_link(json!(URL))), ""), gone);
    }

    #[test]
    fn anything_but_a_remote_control_link_opens_nothing() {
        let none = Err("This session has no Remote Control link.".into());
        let s = json!({"sessions": [{"session_id": "a", "status": "working"}]});
        assert_eq!(remote_url(Some(&s), "a"), none);
        for bad in [
            json!(null),
            json!(7),
            json!([URL]),
            json!({"url": URL}),
            json!(""),
            json!("https://claude.ai/code/"),
            json!("http://claude.ai/code/session_01"),
            json!("HTTPS://claude.ai/code/session_01"),
            json!("https://claude.ai.evil.example/code/session_01"),
            json!("https://evil.example/https://claude.ai/code/session_01"),
            json!("https://claude.ai/code/session_01?next=https://evil.example"),
            json!("https://claude.ai/code/session_01#x"),
            json!("https://claude.ai/code/session_01/../../x"),
            json!("https://claude.ai/code/@evil.example"),
            json!("https://claude.ai/code/session 01"),
            json!("https://claude.ai/code/session_01\n"),
            json!(" https://claude.ai/code/session_01"),
            json!("file:///C:/Windows/System32/calc.exe"),
            json!("javascript:alert(1)//https://claude.ai/code/x"),
            json!(format!("https://claude.ai/code/{}", "a".repeat(129))),
        ] {
            assert_eq!(
                remote_url(Some(&with_link(bad.clone())), "a"),
                none,
                "{bad}"
            );
        }
        let longest = format!("https://claude.ai/code/{}", "a".repeat(128));
        assert_eq!(
            remote_url(Some(&with_link(json!(longest))), "a"),
            Ok(longest)
        );
    }

    #[test]
    fn finds_a_session_by_id_and_nothing_else() {
        let s = json!({"sessions": [{"session_id": "a", "status": "ended"}, {"session_id": "b"}]});
        assert_eq!(session(&s, "a").unwrap()["status"], "ended");
        assert!(session(&s, "c").is_none());
        assert!(session(&json!({}), "a").is_none());
    }
}
