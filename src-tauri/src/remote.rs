//! Open in Claude: a session's Remote Control link, opened in the default
//! browser. The link is the one in the app's own snapshot, checked again
//! (`lookup::remote_url`); the page sends only the session id. The opener
//! plugin is never registered, so the page has no opener command of its own.

use klepsydra_fleet::lookup;

use crate::fleet::Fleet;

/// Open session `id`'s Remote Control link; a sentence for the card's note.
#[tauri::command]
pub async fn open_remote(app: tauri::AppHandle, id: String) -> Result<String, String> {
    use tauri::Manager;
    let url = link(&app.state::<Fleet>(), &id)?;
    tauri_plugin_opener::open_url(&url, None::<&str>)
        .map_err(|e| format!("Could not open the link: {e}"))?;
    Ok("Opened in your browser".into())
}

/// The one link Open in Claude may open for session `id`: the latest
/// snapshot's, checked again; none before the first snapshot.
fn link(fleet: &Fleet, id: &str) -> Result<String, String> {
    fleet
        .with_latest(|v| lookup::remote_url(Some(v), id))
        .unwrap_or_else(|| lookup::remote_url(None, id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const LINK: &str = "https://claude.ai/code/session_01AbC";

    fn fleet(remote: serde_json::Value) -> Fleet {
        let f = Fleet::default();
        f.publish(
            json!({"sessions": [{"session_id": "a", "status": "working", "remote_url": remote}]}),
        );
        f
    }

    #[test]
    fn opens_the_snapshots_link_for_that_session_only() {
        assert_eq!(link(&fleet(json!(LINK)), "a"), Ok(LINK.into()));
        assert!(link(&fleet(json!(LINK)), "b").is_err());
        assert!(link(&Fleet::default(), "a").is_err(), "no snapshot yet");
    }

    #[test]
    fn a_link_the_reader_would_not_keep_is_refused() {
        for bad in [
            json!("https://evil.example/x"),
            json!("file:///C:/x"),
            json!(null),
        ] {
            assert!(link(&fleet(bad.clone()), "a").is_err(), "{bad}");
        }
    }
}
