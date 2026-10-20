//! Clear: remove an ended or silent session's two files from the wall.

use std::io::ErrorKind;
use std::path::Path;

use serde_json::Value;

use crate::lookup;
use crate::session::is_session_id;

/// Whether session `id` in `snapshot` may be cleared: only an ended or silent
/// one, and only while it is still on the wall.
pub fn check_clearable(snapshot: Option<&Value>, id: &str) -> Result<(), String> {
    let status = snapshot
        .and_then(|v| lookup::session(v, id))
        .ok_or("That session is no longer on the wall.")?
        .get("status")
        .and_then(Value::as_str);
    match status {
        Some("ended" | "silent") => Ok(()),
        _ => Err("Only an ended or silent card can be cleared.".into()),
    }
}

/// Delete `<id>.json` and `<id>.beat` in `fleet`, each only if it is a regular
/// file; anything else there leaves both in place.
pub fn remove_session(fleet: &Path, id: &str) -> Result<(), String> {
    if !is_session_id(id) {
        return Err("Not a session id.".into());
    }
    match std::fs::symlink_metadata(fleet) {
        Ok(m) if m.is_dir() => {}
        _ => return Err("The fleet folder is missing or not a plain folder.".into()),
    }
    let mut doomed = Vec::new();
    for ext in ["json", "beat"] {
        let p = fleet.join(format!("{id}.{ext}"));
        match std::fs::symlink_metadata(&p) {
            Ok(m) if m.is_file() => doomed.push(p),
            Ok(_) => {
                return Err(format!(
                    "{id}.{ext} is not a plain file, so nothing was removed."
                ))
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    for p in doomed {
        std::fs::remove_file(&p).map_err(|e| format!("Could not remove {}: {e}", p.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;
    use serde_json::json;

    const ID: &str = "11111111-2222-4333-8444-555555555555";

    fn snap(status: &str) -> Value {
        json!({"sessions": [{"session_id": ID, "status": status}]})
    }

    #[test]
    fn no_snapshot_or_missing_id_is_off_the_wall() {
        let gone = "That session is no longer on the wall.";
        assert_eq!(check_clearable(None, ID), Err(gone.into()));
        let other = snap("ended");
        assert_eq!(
            check_clearable(Some(&other), "99999999-2222-4333-8444-555555555555"),
            Err(gone.into())
        );
    }

    #[test]
    fn only_ended_and_silent_are_clearable() {
        for s in ["ended", "silent"] {
            assert_eq!(check_clearable(Some(&snap(s)), ID), Ok(()), "{s}");
        }
        for s in ["working", "done", "needs_you"] {
            assert_eq!(
                check_clearable(Some(&snap(s)), ID),
                Err("Only an ended or silent card can be cleared.".into()),
                "{s}"
            );
        }
    }

    #[test]
    fn removes_both_files_and_nothing_else() {
        let d = Scratch::new("clear-both");
        for f in [&format!("{ID}.json"), &format!("{ID}.beat"), "other.json"] {
            d.write(f, "x");
        }
        remove_session(&d.0, ID).unwrap();
        let left: Vec<_> = std::fs::read_dir(&d.0)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(left, ["other.json"]);
    }

    #[test]
    fn a_missing_beat_is_fine() {
        let d = Scratch::new("clear-nobeat");
        d.write(&format!("{ID}.json"), "x");
        remove_session(&d.0, ID).unwrap();
    }

    #[test]
    fn refuses_a_bad_id_and_a_path() {
        let d = Scratch::new("clear-badid");
        assert!(remove_session(&d.0, "../x").is_err());
        assert!(remove_session(&d.0, &format!("{ID}/..")).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_never_followed_or_removed() {
        let d = Scratch::new("clear-link");
        let outside = Scratch::new("clear-outside");
        outside.write("keep", "x");
        let target = outside.0.join("keep");
        d.write(&format!("{ID}.json"), "x");
        std::os::unix::fs::symlink(&target, d.0.join(format!("{ID}.beat"))).unwrap();
        assert!(remove_session(&d.0, ID).is_err());
        assert!(target.exists());
        assert!(d.0.join(format!("{ID}.json")).exists(), "nothing removed");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_fleet_folder_is_refused() {
        let real = Scratch::new("clear-real");
        let d = Scratch::new("clear-linkdir");
        let link = d.0.join("fleet");
        std::os::unix::fs::symlink(&real.0, &link).unwrap();
        real.write(&format!("{ID}.json"), "x");
        assert!(remove_session(&link, ID).is_err());
        assert!(real.0.join(format!("{ID}.json")).exists());
    }
}
