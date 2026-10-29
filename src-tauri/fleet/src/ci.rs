//! The CI watch's file, `ci.json` in the data folder, as the wall and the phone
//! show it: each red run with its repo, workflow, branch, failing step and
//! triage, and how many Dependabot reds wait for the morning. The file is
//! written by `fleet/ci_watch.py`; it is read capped, its text capped per
//! field, and a link kept only when it is a GitHub Actions run.

use serde_json::{json, Map, Value};
use std::path::Path;
use std::time::SystemTime;

/// The file's name in the data folder.
pub const FILE: &str = "ci.json";
/// The most of it read.
const MAX_BYTES: u64 = 1 << 20;
/// The most red runs shown.
const MAX_RED: usize = 20;
/// The most characters kept of any text field.
const MAX_CHARS: usize = 300;
/// A reading older than this says the watch has stopped.
pub const STALE_S: i64 = 15 * 60;

fn text(v: &Value) -> Value {
    match v.as_str() {
        Some(s) => Value::from(s.chars().take(MAX_CHARS).collect::<String>()),
        None => Value::Null,
    }
}

/// Whether `url` is a run page on github.com.
fn run_link(url: &str) -> bool {
    let rest = url.strip_prefix("https://github.com/");
    rest.is_some_and(|r| {
        let parts: Vec<&str> = r.split('/').collect();
        parts.len() == 5
            && parts[2] == "actions"
            && parts[3] == "runs"
            && parts[4].chars().all(|c| c.is_ascii_digit())
            && !parts[4].is_empty()
            && parts[..2].iter().all(|p| {
                !p.is_empty()
                    && p.chars()
                        .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
            })
    })
}

fn red_run(r: &Value) -> Value {
    let mut out = Map::new();
    for k in ["repo", "workflow", "branch", "conclusion", "at"] {
        out.insert(k.into(), text(&r[k]));
    }
    out.insert(
        "pr".into(),
        r["pr"].as_u64().map_or(Value::Null, Value::from),
    );
    let url = r["url"].as_str().filter(|u| run_link(u));
    out.insert("url".into(), url.map_or(Value::Null, Value::from));
    out.insert(
        "failing".into(),
        json!({ "job": text(&r["failing"]["job"]), "step": text(&r["failing"]["step"]) }),
    );
    let t = &r["triage"];
    out.insert(
        "triage".into(),
        json!({
            "state": text(&t["state"]),
            "cause": text(&t["cause"]),
            "location": text(&t["location"]),
        }),
    );
    Value::Object(out)
}

/// The view of a `ci.json` text at time `now`: the red runs, the Dependabot
/// count, how many repos could not be read, and whether the reading is stale.
pub fn view(raw: &str, now: i64) -> Option<Value> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let observed = v["observed_at"].as_i64()?;
    let red: Vec<Value> = v["red"]
        .as_array()
        .map(|a| a.iter().take(MAX_RED).map(red_run).collect())
        .unwrap_or_default();
    Some(json!({
        "observed_at": observed,
        "stale": now - observed > STALE_S,
        "repos": v["repos"].as_u64().unwrap_or(0),
        "red": red,
        "dependabot": v["dependabot"].as_array().map_or(0, Vec::len),
        "unread": v["errors"].as_array().map_or(0, Vec::len),
    }))
}

/// Follows `ci.json`, reading it again only when its modified time changes.
#[derive(Default)]
pub struct Follower {
    seen: Option<SystemTime>,
    stale: Option<bool>,
}

impl Follower {
    /// The view when the file or its staleness changed since the last step.
    pub fn step(&mut self, dir: &Path, now: i64) -> Option<Value> {
        let path = dir.join(FILE);
        let modified = std::fs::symlink_metadata(&path)
            .and_then(|m| m.modified())
            .ok();
        let raw = crate::bounded::read_text(&path, MAX_BYTES).ok();
        let view = raw.as_deref().and_then(|r| view(r, now));
        let stale = view.as_ref().map(|v| v["stale"] == true);
        if modified == self.seen && stale == self.stale {
            return None;
        }
        self.seen = modified;
        self.stale = stale;
        Some(view.unwrap_or(Value::Null))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Value {
        json!({
            "v": 1, "observed_at": 1000, "repos": 14,
            "red": [{
                "repo": "pharos", "workflow": "CI", "branch": "main", "pr": null,
                "run_id": 5, "url": "https://github.com/ajbarea/pharos/actions/runs/5",
                "conclusion": "failure", "at": "2026-10-29T03:00:00Z",
                "failing": {"job": "test", "step": "pytest"},
                "triage": {"state": "done", "cause": "a test fails", "location": "a.py:3",
                           "summary": "s", "report": "/home/aj/x/report.md"}
            }],
            "dependabot": [{}, {}], "errors": [{"repo": "x"}]
        })
    }

    #[test]
    fn a_red_run_comes_through_with_only_what_the_wall_shows() {
        let v = view(&sample().to_string(), 1100).unwrap();
        assert_eq!(v["repos"], 14);
        assert_eq!(v["dependabot"], 2);
        assert_eq!(v["unread"], 1);
        assert_eq!(v["stale"], false);
        let r = &v["red"][0];
        assert_eq!(r["url"], "https://github.com/ajbarea/pharos/actions/runs/5");
        assert_eq!(r["failing"]["step"], "pytest");
        assert_eq!(r["triage"]["location"], "a.py:3");
        assert!(
            r["triage"].get("report").is_none(),
            "a local path never reaches the phone"
        );
    }

    #[test]
    fn only_a_github_run_link_is_kept() {
        for (url, kept) in [
            ("https://github.com/o/r/actions/runs/12", true),
            ("http://github.com/o/r/actions/runs/12", false),
            ("https://github.com.evil/o/r/actions/runs/12", false),
            ("https://github.com/o/r/actions/runs/12/x", false),
            ("javascript:alert(1)", false),
            ("https://github.com/o/r/pull/3", false),
        ] {
            assert_eq!(run_link(url), kept, "{url}");
        }
    }

    #[test]
    fn long_text_is_capped_and_a_flood_of_runs_is_cut() {
        let mut s = sample();
        s["red"][0]["triage"]["cause"] = Value::from("x".repeat(5000));
        let one = s["red"][0].clone();
        s["red"] = Value::Array(vec![one; 50]);
        let v = view(&s.to_string(), 1000).unwrap();
        assert_eq!(v["red"].as_array().unwrap().len(), MAX_RED);
        assert_eq!(
            v["red"][0]["triage"]["cause"].as_str().unwrap().len(),
            MAX_CHARS
        );
    }

    #[test]
    fn an_old_reading_is_stale_and_a_bad_file_is_no_view() {
        assert_eq!(
            view(&sample().to_string(), 1000 + STALE_S + 1).unwrap()["stale"],
            true
        );
        assert!(view("{not json", 0).is_none());
        assert!(view("{}", 0).is_none(), "no observed_at");
    }

    #[test]
    fn the_follower_sends_only_changes() {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("klepsydra-ci-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let mut f = Follower::default();
        assert_eq!(
            f.step(&dir, 1000),
            None,
            "no file and nothing sent before: no change"
        );
        std::fs::write(dir.join(FILE), sample().to_string()).unwrap();
        assert!(f.step(&dir, 1000).is_some());
        assert_eq!(f.step(&dir, 1001), None, "unchanged");
        let stale = f.step(&dir, 1000 + STALE_S + 1).unwrap();
        assert_eq!(stale["stale"], true, "going stale is a change");
        std::fs::remove_file(dir.join(FILE)).unwrap();
        assert_eq!(
            f.step(&dir, 1000).unwrap(),
            Value::Null,
            "the file gone clears the view"
        );
        let _ = std::fs::remove_dir(&dir);
    }
}
