//! The fleet's health on the walls (#208): `fleet-health.json` in the data
//! folder, which the fleet-doctor timer writes from `fleet doctor --json`
//! every 5 minutes, as one line per check. Read capped, text capped, links
//! taken out of the details (the phone gets them too), stale after 15 min.

use serde_json::{json, Value};

/// The file's name in the data folder.
pub const FILE: &str = "fleet-health.json";
/// The most checks shown.
const MAX_CHECKS: usize = 60;
/// The most characters kept of a check's name or detail.
const MAX_CHARS: usize = 200;
const STATUSES: [&str; 3] = ["FAIL", "warn", "ok"];

fn capped(v: &Value) -> String {
    v.as_str().unwrap_or("").chars().take(MAX_CHARS).collect()
}

/// DETAIL with each web address made "(link)": a Remote Control link opens a session.
fn unlinked(detail: &str) -> String {
    detail
        .split(' ')
        .map(|w| if w.contains("://") { "(link)" } else { w })
        .collect::<Vec<_>>()
        .join(" ")
}

/// The view of a `fleet-health.json` text at time `now`: each check, failing
/// ones first, the failing and warning counts, and whether the reading is stale.
pub fn view(raw: &str, now: i64) -> Option<Value> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let observed = v["observed_at"].as_i64()?;
    let mut checks: Vec<Value> = v["checks"]
        .as_array()?
        .iter()
        .filter_map(|c| {
            let status = c["status"].as_str().filter(|s| STATUSES.contains(s))?;
            let check = capped(&c["check"]);
            (!check.is_empty()).then(|| {
                json!({"status": status, "check": check, "detail": unlinked(&capped(&c["detail"]))})
            })
        })
        .collect();
    // Sorted before the cap, so a failing check is never the one cut.
    let rank = |c: &Value| STATUSES.iter().position(|s| c["status"] == *s);
    checks.sort_by_key(rank);
    checks.truncate(MAX_CHECKS);
    let count = |s: &str| checks.iter().filter(|c| c["status"] == s).count();
    Some(json!({
        "observed_at": observed,
        "stale": now - observed > crate::ci::STALE_S,
        "failed": count("FAIL"),
        "warned": count("warn"),
        "checks": checks,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ci::Follower;
    use crate::scan::tests::Scratch;

    fn report(at: i64) -> String {
        json!({"v": 1, "observed_at": at, "failed": 1, "checks": [
            {"status": "ok", "check": "resume service", "detail": "active"},
            {"status": "ok", "check": "remote control %0 (orchestrator)", "detail": "https://claude.ai/code/session_01X"},
            {"status": "warn", "check": "briefs", "detail": "stale: task-x.src"},
            {"status": "FAIL", "check": "pane watcher", "detail": "none running"},
        ]})
        .to_string()
    }

    #[test]
    fn failing_checks_come_first_with_counts_and_no_links() {
        let v = view(&report(1000), 1100).unwrap();
        assert_eq!(
            (v["failed"].clone(), v["warned"].clone(), v["stale"].clone()),
            (json!(1), json!(1), json!(false))
        );
        let order: Vec<&str> = v["checks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["check"].as_str().unwrap())
            .collect();
        assert_eq!(
            order,
            [
                "pane watcher",
                "briefs",
                "resume service",
                "remote control %0 (orchestrator)"
            ]
        );
        assert_eq!(
            v["checks"][3]["detail"], "(link)",
            "a session link never reaches the phone"
        );
    }

    #[test]
    fn an_odd_check_is_dropped_and_text_is_capped() {
        let raw = json!({"observed_at": 5, "checks": [
            {"status": "bad", "check": "x", "detail": ""},
            {"status": "ok", "check": "", "detail": ""},
            {"status": "ok", "check": "y".repeat(500), "detail": 7},
        ]})
        .to_string();
        let v = view(&raw, 5).unwrap();
        assert_eq!(v["checks"].as_array().unwrap().len(), 1);
        assert_eq!(v["checks"][0]["check"].as_str().unwrap().len(), MAX_CHARS);
        assert_eq!(v["checks"][0]["detail"], "");
        for bad in [
            "not json",
            "{}",
            r#"{"observed_at": 1}"#,
            r#"{"checks": []}"#,
        ] {
            assert!(view(bad, 5).is_none(), "{bad}");
        }
    }

    #[test]
    fn a_failing_check_past_the_cap_still_shows() {
        let mut checks: Vec<Value> = (0..MAX_CHECKS + 1)
            .map(|i| json!({"status": "ok", "check": format!("c{i}"), "detail": ""}))
            .collect();
        checks.push(json!({"status": "FAIL", "check": "pane watcher", "detail": "none"}));
        let raw = json!({"observed_at": 5, "checks": checks}).to_string();
        let v = view(&raw, 5).unwrap();
        assert_eq!(v["checks"].as_array().unwrap().len(), MAX_CHECKS);
        assert_eq!(
            (v["failed"].as_u64(), v["checks"][0]["check"].as_str()),
            (Some(1), Some("pane watcher"))
        );
    }

    #[test]
    fn the_follower_reads_the_health_file_and_goes_stale() {
        let s = Scratch::new("health-follow");
        let mut f = Follower::of(FILE, view);
        assert!(f.step(&s.0, 1000).is_none(), "nothing before a reading");
        s.write(FILE, &report(1000));
        assert_eq!(f.step(&s.0, 1000).unwrap()["failed"], 1);
        assert!(f.step(&s.0, 1060).is_none());
        assert_eq!(
            f.step(&s.0, 1000 + crate::ci::STALE_S + 1).unwrap()["stale"],
            true
        );
        s.write(crate::ci::FILE, "{}");
        assert!(
            f.step(&s.0, 1000 + crate::ci::STALE_S + 1).is_none(),
            "ci.json is not its file"
        );
    }
}
