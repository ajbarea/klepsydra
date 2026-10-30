//! The Agora (#185) on the walls: the newest posts from `agora/posts.jsonl`,
//! which `fleet agora post` writes in the data folder, each with AJ's reaction
//! from `agora/reactions.json`, which only the app writes.

use serde_json::{json, Map, Value};
use std::path::Path;
use std::sync::Mutex;
use std::time::SystemTime;

pub const DIR: &str = "agora";
const POSTS: &str = "posts.jsonl";
const REACTIONS: &str = "reactions.json";
/// `fleet agora post` archives past 256 KiB, so this leaves room for a burst.
const MAX_POSTS_BYTES: u64 = 1024 * 1024;
const MAX_REACTIONS_BYTES: u64 = 64 * 1024;
/// Posts the walls show, newest first.
pub const MAX_SHOWN: usize = 50;
/// Reactions kept, the newest posts' first.
const MAX_KEPT: usize = 500;
const POST_MAX: usize = 280;
/// A post dated this far past now (a clock step) still shows.
const SKEW_S: i64 = 3600;
pub const KINDS: [&str; 5] = ["gripe", "win", "idea", "wish", "kudos"];
/// The reactions the wall offers: a small fixed set, as GitHub's.
pub const EMOJI: [&str; 4] = ["👍", "❤️", "🎉", "👀"];

/// An agent's name as the fleet registry holds it: letters, digits, `_`, `.`, `-`.
fn plain_name(s: &str) -> bool {
    let n = s.chars().count();
    (1..=64).contains(&n) && s.chars().all(|c| c.is_alphanumeric() || "_.-".contains(c))
}

/// A GitHub pull request or issue address, as `fleet agora post` accepts it.
pub fn post_link(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://github.com/") else {
        return false;
    };
    let parts: Vec<&str> = rest.split('/').collect();
    parts.len() == 4
        && matches!(parts[2], "pull" | "issues")
        && (1..=7).contains(&parts[3].len())
        && parts[3].chars().all(|c| c.is_ascii_digit())
        && parts[..2].iter().all(|p| {
            !p.is_empty()
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        })
}

/// A short text field: a string of at most `max` characters, else none.
fn short(v: &Value, max: usize) -> Option<&str> {
    v.as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= max)
}

/// A post's id: its agent and time, unique since an agent posts once an hour.
fn id_of(who: &str, at: i64) -> String {
    format!("{who}@{at}")
}

/// `id`'s time, when `id` is a post id.
fn id_time(id: &str) -> Option<i64> {
    let (who, at) = id.rsplit_once('@')?;
    if !plain_name(who) || at.is_empty() || !at.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    at.parse().ok()
}

/// LINE as the post the walls show, or none for a line that is not one.
fn post(line: &str, now: i64) -> Option<Value> {
    let p: Value = serde_json::from_str(line).ok()?;
    let at = p["at"].as_i64().filter(|&t| t > 0 && t <= now + SKEW_S)?;
    let who = p["who"].as_str().filter(|w| plain_name(w))?;
    let text: String = p["text"].as_str()?.chars().take(POST_MAX).collect();
    if text.trim().is_empty() {
        return None;
    }
    let kind = p["kind"]
        .as_str()
        .filter(|k| KINDS.contains(k))
        .unwrap_or("idea");
    Some(json!({
        "id": id_of(who, at),
        "at": at,
        "who": who,
        "name": short(&p["name"], 40).unwrap_or(who),
        "character": short(&p["character"], 80),
        "repo": short(&p["repo"], 100),
        "kind": kind,
        "text": text,
        "link": p["link"].as_str().filter(|l| post_link(l)),
    }))
}

/// The reactions map in `raw`: post id to one of `EMOJI`; anything else is dropped.
fn reactions(raw: Option<&str>) -> Map<String, Value> {
    let parsed: Value = raw
        .and_then(|r| serde_json::from_str(r).ok())
        .unwrap_or(Value::Null);
    parsed["reactions"]
        .as_object()
        .map(|m| {
            m.iter()
                .filter(|(id, e)| {
                    id_time(id).is_some() && e.as_str().is_some_and(|e| EMOJI.contains(&e))
                })
                .map(|(id, e)| (id.clone(), e.clone()))
                .collect()
        })
        .unwrap_or_default()
}

/// What the walls show of the Agora: the newest `MAX_SHOWN` posts, newest
/// first, each with AJ's reaction or null, and the reactions on offer.
pub fn view(posts: &str, reactions_raw: Option<&str>, now: i64) -> Value {
    let picked = reactions(reactions_raw);
    let mut shown: Vec<Value> = posts.lines().filter_map(|l| post(l, now)).collect();
    // Appended in time order; a stable sort keeps a same-second pair as written.
    shown.sort_by_key(|p| std::cmp::Reverse(p["at"].as_i64().unwrap_or(0)));
    shown.truncate(MAX_SHOWN);
    for p in &mut shown {
        let id = p["id"].as_str().unwrap_or_default().to_owned();
        p["reaction"] = picked.get(&id).cloned().unwrap_or(Value::Null);
    }
    json!({ "posts": shown, "emoji": EMOJI })
}

/// Follows the two files, reading them again only when one's modified time changes.
#[derive(Default)]
pub struct Follower {
    seen: Option<(Option<SystemTime>, Option<SystemTime>)>,
    view: Option<Value>,
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::symlink_metadata(path)
        .and_then(|m| m.modified())
        .ok()
}

impl Follower {
    /// The view when it changed since the last step; nothing before there is a post.
    pub fn step(&mut self, data: &Path, now: i64) -> Option<Value> {
        let dir = data.join(DIR);
        let stamps = (modified(&dir.join(POSTS)), modified(&dir.join(REACTIONS)));
        if self.seen == Some(stamps) {
            return None;
        }
        self.seen = Some(stamps);
        let posts =
            crate::bounded::read_text(&dir.join(POSTS), MAX_POSTS_BYTES).unwrap_or_default();
        let raw = crate::bounded::read_text(&dir.join(REACTIONS), MAX_REACTIONS_BYTES).ok();
        let view = view(&posts, raw.as_deref(), now);
        let empty = view["posts"].as_array().is_none_or(|p| p.is_empty());
        if self.view.as_ref() == Some(&view) || (self.view.is_none() && empty) {
            return None;
        }
        self.view = Some(view.clone());
        Some(view)
    }
}

/// Why a reaction was not saved.
#[derive(Debug, PartialEq)]
pub enum Refused {
    NotAPost,
    NotOffered,
    Unwritable(String),
}

/// One reaction written at a time: the wall's clicks arrive on several threads.
static WRITING: Mutex<()> = Mutex::new(());

/// Set AJ's reaction on post `id` to `emoji`, or clear it when it is already
/// that one; returns the reaction the post now has. Only the newest
/// `MAX_KEPT` posts' reactions are kept.
pub fn react(data: &Path, id: &str, emoji: &str) -> Result<Option<String>, Refused> {
    if id_time(id).is_none() {
        return Err(Refused::NotAPost);
    }
    if !EMOJI.contains(&emoji) {
        return Err(Refused::NotOffered);
    }
    let _held = WRITING.lock().unwrap_or_else(|e| e.into_inner());
    let dir = data.join(DIR);
    let path = dir.join(REACTIONS);
    let raw = crate::bounded::read_text(&path, MAX_REACTIONS_BYTES).ok();
    let mut map = reactions(raw.as_deref());
    let now = if map.get(id).and_then(Value::as_str) == Some(emoji) {
        map.remove(id);
        None
    } else {
        map.insert(id.to_owned(), Value::from(emoji));
        Some(emoji.to_owned())
    };
    if map.len() > MAX_KEPT {
        let mut ids: Vec<(i64, String)> = map
            .keys()
            .map(|k| (id_time(k).unwrap_or(0), k.clone()))
            .collect();
        ids.sort();
        for (_, old) in ids.iter().take(map.len() - MAX_KEPT) {
            map.remove(old);
        }
    }
    let text = json!({ "v": 1, "reactions": map }).to_string();
    let tmp = dir.join(format!("{REACTIONS}.tmp"));
    std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::write(&tmp, text))
        .and_then(|()| std::fs::rename(&tmp, &path))
        .map_err(|e| Refused::Unwritable(e.to_string()))?;
    Ok(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    const NOW: i64 = 1_800_000_000;

    fn line(who: &str, at: i64, text: &str) -> String {
        json!({"at": at, "who": who, "session_id": "s", "character": "am_michael",
               "name": "Hephaestus", "repo": "klepsydra", "kind": "gripe",
               "text": text, "link": "https://github.com/ajbarea/klepsydra/pull/192"})
        .to_string()
    }

    #[test]
    fn posts_show_newest_first_with_what_the_wall_needs() {
        let raw = [
            line("heph", NOW - 100, "old"),
            line("techne", NOW - 10, "new"),
        ]
        .join("\n");
        let v = view(&raw, None, NOW);
        let posts = v["posts"].as_array().unwrap();
        assert_eq!(posts.len(), 2);
        assert_eq!(posts[0]["text"], "new");
        assert_eq!(posts[0]["id"], format!("techne@{}", NOW - 10));
        assert_eq!(posts[1]["name"], "Hephaestus");
        assert_eq!(
            posts[1]["link"],
            "https://github.com/ajbarea/klepsydra/pull/192"
        );
        assert_eq!(posts[1]["reaction"], Value::Null);
        assert!(
            posts[0].get("session_id").is_none(),
            "a session id never reaches the phone"
        );
        assert_eq!(v["emoji"], json!(EMOJI));
    }

    #[test]
    fn a_line_that_is_not_a_post_is_skipped() {
        let mut huge = serde_json::from_str::<Value>(&line("a", NOW, "x")).unwrap();
        huge["at"] = json!(10u64.pow(19));
        for bad in [
            "not json".to_owned(),
            "[]".to_owned(),
            line("bad name!", NOW, "x"),
            line("a", NOW + SKEW_S + 1, "from the future"),
            line("a", 0, "x"),
            line("a", NOW, "   "),
            huge.to_string(),
            r#"{"at":5,"who":"a"}"#.to_owned(),
        ] {
            assert_eq!(view(&bad, None, NOW)["posts"], json!([]), "{bad}");
        }
    }

    #[test]
    fn odd_fields_fall_back_and_a_bad_link_is_dropped() {
        let mut p: Value = serde_json::from_str(&line("a", NOW, "x")).unwrap();
        p["kind"] = json!("rant");
        p["name"] = json!("n".repeat(41));
        p["link"] = json!("javascript:x//https://github.com/a/b/pull/1");
        let v = view(&p.to_string(), None, NOW);
        assert_eq!(v["posts"][0]["kind"], "idea");
        assert_eq!(v["posts"][0]["name"], "a");
        assert_eq!(v["posts"][0]["link"], Value::Null);
        p["text"] = json!("y".repeat(400));
        let v = view(&p.to_string(), None, NOW);
        assert_eq!(
            v["posts"][0]["text"].as_str().unwrap().chars().count(),
            POST_MAX
        );
    }

    #[test]
    fn only_a_github_pull_or_issue_address_is_a_link() {
        for (url, ok) in [
            ("https://github.com/o/r/pull/12", true),
            ("https://github.com/o/r/issues/1234567", true),
            ("https://github.com/o/r/issues/12345678", false),
            ("https://github.com/o/r/pull/12/files", false),
            ("https://github.com/o/r/actions/runs/1", false),
            ("http://github.com/o/r/pull/1", false),
            ("https://github.com.evil/o/r/pull/1", false),
            ("https://github.com/o/r/pull/", false),
            ("https://github.com/o r/r/pull/1", false),
        ] {
            assert_eq!(post_link(url), ok, "{url}");
        }
    }

    #[test]
    fn at_most_the_newest_fifty_show() {
        let raw: Vec<String> = (0..80)
            .map(|i| line("a", NOW - 1000 + i, &format!("p{i}")))
            .collect();
        let v = view(&raw.join("\n"), None, NOW);
        assert_eq!(v["posts"].as_array().unwrap().len(), MAX_SHOWN);
        assert_eq!(v["posts"][0]["text"], "p79");
    }

    #[test]
    fn a_reaction_toggles_and_shows_on_its_post() {
        let s = Scratch::new("agora-react");
        let dir = s.0.join(DIR);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(POSTS), line("a", NOW, "hi") + "\n").unwrap();
        let id = format!("a@{NOW}");
        assert_eq!(react(&s.0, &id, "👍"), Ok(Some("👍".into())));
        let mut f = Follower::default();
        assert_eq!(f.step(&s.0, NOW).unwrap()["posts"][0]["reaction"], "👍");
        assert_eq!(react(&s.0, &id, "🎉"), Ok(Some("🎉".into())));
        assert_eq!(react(&s.0, &id, "🎉"), Ok(None));
        let raw = std::fs::read_to_string(dir.join(REACTIONS)).unwrap();
        assert_eq!(reactions(Some(&raw)).len(), 0);
        assert_eq!(react(&s.0, "a@x", "👍"), Err(Refused::NotAPost));
        assert_eq!(react(&s.0, &id, "💩"), Err(Refused::NotOffered));
    }

    #[test]
    fn only_the_newest_posts_reactions_are_kept() {
        let s = Scratch::new("agora-keep");
        for i in 0..(MAX_KEPT as i64 + 3) {
            react(&s.0, &format!("a@{}", 1000 + i), "👀").unwrap();
        }
        let raw = std::fs::read_to_string(s.0.join(DIR).join(REACTIONS)).unwrap();
        let kept = reactions(Some(&raw));
        assert_eq!(kept.len(), MAX_KEPT);
        assert!(!kept.contains_key("a@1000"), "the oldest goes first");
        assert!(kept.contains_key(&format!("a@{}", 1000 + MAX_KEPT as i64 + 2)));
    }

    #[test]
    fn the_follower_speaks_only_on_a_change_and_not_before_a_post() {
        let s = Scratch::new("agora-follow");
        let mut f = Follower::default();
        assert!(f.step(&s.0, NOW).is_none(), "no folder, no view");
        let dir = s.0.join(DIR);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(POSTS), line("a", NOW, "hi") + "\n").unwrap();
        assert!(f.step(&s.0, NOW).is_some());
        assert!(f.step(&s.0, NOW).is_none(), "nothing changed");
        std::fs::write(dir.join(REACTIONS), "{not json").unwrap();
        // A broken reactions file changes the stamps but not the view.
        assert!(f.step(&s.0, NOW).is_none());
    }
}
