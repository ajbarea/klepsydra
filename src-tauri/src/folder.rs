//! A card's folder name opens the folder the session works in (#149). The
//! folder comes from the latest snapshot's record of that session, never from
//! the page, so the wall can open no other path; the launcher opens it.

use serde_json::Value;

/// Session `id`'s work folder and its distro, as the latest snapshot has them.
pub fn folder_of(snapshot: &Value, id: &str) -> Option<(String, String)> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let dir = s.get("where")?.get("dir")?.as_str()?;
    let distro = s.get("distro")?.as_str()?;
    plain_dir(dir).then(|| (dir.to_string(), distro.to_string()))
}

/// Session `id`'s GitHub page as the latest snapshot has it, or with `branch`
/// that branch's page, each part of its name encoded as encodeURIComponent
/// would: the wall's links, but taken from the app's own record. With the
/// session's distro, which opens it.
pub fn github_of(snapshot: &Value, id: &str, branch: bool) -> Option<(String, String)> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let distro = s.get("distro")?.as_str()?.to_string();
    page_of(s, branch).map(|url| (url, distro))
}

fn page_of(s: &Value, branch: bool) -> Option<String> {
    let place = s.get("where")?;
    let page = place.get("github")?.as_str()?;
    if !klepsydra_fleet::session::is_github(page) {
        return None;
    }
    if !branch {
        return Some(page.to_string());
    }
    let name = place.get("branch")?.as_str()?;
    if name.is_empty() || name.len() > 255 || name.chars().any(char::is_control) {
        return None;
    }
    let parts: Vec<String> = name.split('/').map(component).collect();
    Some(format!("{page}/tree/{}", parts.join("/")))
}

/// `part` percent-encoded as JavaScript's encodeURIComponent does.
fn component(part: &str) -> String {
    let mut out = String::with_capacity(part.len());
    for b in part.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// An absolute path with no `.`, `..` or empty part and no control character:
/// what the hook writes for a folder.
pub fn plain_dir(dir: &str) -> bool {
    dir.len() > 1
        && dir.len() <= 1024
        && dir.starts_with('/')
        && !dir.chars().any(char::is_control)
        && dir[1..]
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_folder_comes_from_the_sessions_own_record() {
        let snap = json!({"sessions": [
            {"session_id": "a", "distro": "Ubuntu", "where": {"repo": "k", "dir": "/home/aj/ajsoftworks/klepsydra/.claude/worktrees/x"}},
            {"session_id": "b", "distro": "Ubuntu", "where": {"repo": "k"}},
            {"session_id": "c", "distro": "Ubuntu", "where": {"repo": "k", "dir": "/home/aj/../etc"}},
            {"session_id": "d", "distro": "Ubuntu", "where": {"repo": "k", "dir": "relative/path"}},
            {"session_id": "e", "where": {"repo": "k", "dir": "/home/aj"}}]});
        assert_eq!(
            folder_of(&snap, "a"),
            Some((
                "/home/aj/ajsoftworks/klepsydra/.claude/worktrees/x".into(),
                "Ubuntu".into()
            ))
        );
        for id in ["b", "c", "d", "e", "missing"] {
            assert_eq!(folder_of(&snap, id), None, "{id}");
        }
    }

    #[test]
    fn the_github_page_and_branch_come_from_the_sessions_own_record() {
        let snap = json!({"sessions": [
            {"session_id": "a", "distro": "Ubuntu", "where": {"github": "https://github.com/ajbarea/klepsydra", "branch": "feat/a b#1"}},
            {"session_id": "b", "distro": "Ubuntu", "where": {"github": "https://evil.example/x/y", "branch": "main"}},
            {"session_id": "c", "distro": "Ubuntu", "where": {"github": "https://github.com/ajbarea/klepsydra"}},
            {"session_id": "d", "distro": "Ubuntu", "where": {"github": "https://github.com/ajbarea/klepsydra", "branch": "a\nb"}},
            {"session_id": "e", "where": {"github": "https://github.com/ajbarea/klepsydra"}}]});
        let url = |id, branch| github_of(&snap, id, branch).map(|(u, _)| u);
        assert_eq!(
            github_of(&snap, "a", false),
            Some((
                "https://github.com/ajbarea/klepsydra".into(),
                "Ubuntu".into()
            ))
        );
        assert_eq!(
            url("a", true).as_deref(),
            Some("https://github.com/ajbarea/klepsydra/tree/feat/a%20b%231")
        );
        assert_eq!(url("b", false), None, "only github.com");
        assert_eq!(url("c", true), None, "no branch on record");
        assert_eq!(url("d", true), None, "a control character");
        assert_eq!(url("e", false), None, "no distro to open it from");
        assert_eq!(url("missing", false), None);
    }

    #[test]
    fn only_a_plain_absolute_folder() {
        for bad in ["/", "/home/./aj", "/home//aj", "/home/a\nb", "~/x", ""] {
            assert!(!plain_dir(bad), "{bad:?}");
        }
        assert!(plain_dir("/home/aj/ajsoftworks/cv"));
    }
}
