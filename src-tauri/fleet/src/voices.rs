//! The Voices setting (#183, #273): who speaks through keryx. prefs.json keeps
//! it under `voices`, where `fleet voices` (fleet/voices.sh) reads it and sets
//! keryx to match, for running sessions too: "heph" (the default) lets only the
//! orchestrator's session speak, "everyone" every session, "off" none.
//!
//! The tray shows what keryx does, not what was saved (#337): each time its
//! menu opens it reads keryx's own config (found through [`PATHS_FILE`], which
//! `fleet voices` keeps in the data folder) and ticks the mode that config
//! matches, or none, naming what keryx does instead. Nothing is cached, so a
//! `keryx off` or a `fleet voices heph` done elsewhere shows on the next open.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value};

use crate::bounded::{self, Refused};

/// The prefs.json key.
pub const KEY: &str = "voices";
/// Each mode's id and its tray label; the first is the default.
pub const VOICES: [(&str, &str); 3] = [
    ("heph", "Heph only"),
    ("everyone", "Everyone"),
    ("off", "Off"),
];

/// The saved mode, or the default for a missing or unknown one.
pub fn of(prefs: Option<&Map<String, Value>>) -> &'static str {
    crate::choice::of(&VOICES, KEY, prefs)
}

/// The value to save for mode `id`, or an error naming the modes.
pub fn value(id: &str) -> Result<Value, String> {
    crate::choice::value(&VOICES, "voices mode", id)
}

/// The file in the data folder where `fleet voices` names keryx's config (as
/// a path this side can open: a UNC path into the Linux distro on Windows)
/// and the orchestrator's session file, the one entry `speak_only` holds for
/// "heph".
pub const PATHS_FILE: &str = "keryx-paths.json";
/// Largest keryx config or paths file read; both are a few hundred bytes.
const MAX: u64 = 64 * 1024;
/// How long a menu open waits for keryx's config. A warm read across the
/// distro's file share took 4 ms (28 ms the first time); a distro that is not
/// running can take seconds to start, which the share's first read sets off
/// (the fleet keeps it running), and until that read ends each open shows
/// "unknown" without waiting.
pub const WAIT: Duration = Duration::from_millis(250);

/// What keryx's config.json says it does, read by keryx's own rules
/// (keryx `Config.load`): a missing or non-bool `enabled` is on; `speak_only`
/// missing is every session, a string is a list of one, anything else not a
/// list of strings is nobody.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Keryx {
    Off,
    Everyone,
    /// On, speaking only for sessions these entries name.
    Only(Vec<String>),
    /// On, with a malformed `speak_only`: nobody speaks.
    Nobody,
    /// No config file: keryx runs on its defaults, every session speaking
    /// (as `fleet voices` reads it too).
    NoConfig,
    /// A config that cannot be read, or is not a JSON object.
    Unreadable,
}

/// keryx's state from a read of its config.
pub fn keryx(text: Result<String, Refused>) -> Keryx {
    let text = match text {
        Ok(t) => t,
        Err(Refused::Missing) => return Keryx::NoConfig,
        Err(_) => return Keryx::Unreadable,
    };
    let Some(cfg) = serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v.as_object().cloned())
    else {
        return Keryx::Unreadable;
    };
    if cfg.get("enabled") == Some(&Value::Bool(false)) {
        return Keryx::Off;
    }
    match cfg.get("speak_only") {
        None => Keryx::Everyone,
        Some(Value::String(s)) => Keryx::Only(vec![s.clone()]),
        Some(Value::Array(a)) if a.is_empty() => Keryx::Everyone,
        Some(Value::Array(a)) => a
            .iter()
            .map(|v| v.as_str().map(String::from))
            .collect::<Option<Vec<_>>>()
            .map_or(Keryx::Nobody, Keryx::Only),
        Some(_) => Keryx::Nobody,
    }
}

/// Where keryx's config is and the orchestrator's session file, from the
/// paths file in data folder `dir`; `None` until `fleet voices` has run.
pub fn paths(dir: &Path) -> Option<(PathBuf, String)> {
    let text = bounded::read_text(&dir.join(PATHS_FILE), MAX).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let config = v.get("config")?.as_str().filter(|s| !s.is_empty())?;
    let heph = v.get("heph")?.as_str()?;
    Some((PathBuf::from(config), heph.into()))
}

/// What the tray's Voices submenu shows: the mode keryx's state matches, if
/// any, and the status line naming what keryx does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shown {
    pub tick: Option<&'static str>,
    pub says: String,
}

fn label(id: &str) -> &'static str {
    VOICES.iter().find(|(i, _)| *i == id).map_or("", |(_, l)| l)
}

/// The tick and status line for keryx state `k`, with `heph` the orchestrator's
/// session file and `saved` the mode in prefs.json. Heph is an exact match on
/// the path `fleet voices` gives keryx (already resolved by `realpath`). The
/// state is the file's: a `KERYX_*` variable in one session's environment can
/// override it there, which no file shows.
pub fn shown(k: &Keryx, heph: &str, saved: &str) -> Shown {
    let tick = match k {
        Keryx::Off => Some("off"),
        Keryx::Everyone | Keryx::NoConfig => Some("everyone"),
        Keryx::Only(e) if e.len() == 1 && !heph.is_empty() && e[0] == heph => Some("heph"),
        _ => None,
    };
    let what = match (k, tick) {
        (Keryx::NoConfig, _) => "Everyone (keryx's defaults: no config file)".into(),
        (_, Some(id)) => label(id).to_string(),
        (Keryx::Only(e), _) if e.len() == 1 => "on for 1 other session only".into(),
        (Keryx::Only(e), _) => format!("on for {} other sessions only", e.len()),
        (Keryx::Nobody, _) => "on, but nobody speaks (speak_only is malformed)".into(),
        // keryx reads a broken file as its defaults, but one caught mid-write
        // is broken only for a moment: no tick rather than a guess.
        _ => "unknown (config unreadable)".into(),
    };
    let says = if tick != Some(saved) {
        format!("keryx now: {what}; saved: {}", label(saved))
    } else {
        format!("keryx now: {what}")
    };
    Shown { tick, says }
}

/// What the tray shows when keryx's state cannot be told: no tick.
pub fn unknown(why: &str) -> Shown {
    Shown {
        tick: None,
        says: format!("keryx now: unknown ({why})"),
    }
}

/// Read keryx's state afresh through data folder `dir` (blocking: the config
/// may sit across the distro's file share).
pub fn now(dir: &Path, saved: &str) -> Shown {
    let Some((config, heph)) = paths(dir) else {
        return unknown("fleet voices has not run yet");
    };
    shown(&keryx(bounded::read_text(&config, MAX)), &heph, saved)
}

/// Reads keryx's state when the tray menu is about to open, on a thread the
/// open waits on for at most a bound, so a slow file share never holds the
/// tray. A read that outlasts the bound shows "unknown" at once and hands its
/// own answer, stamped, to `late` when it lands: never a tick from before.
/// While one is still out, another open starts none: one stuck read, not one
/// per click.
#[derive(Default)]
pub struct Reader {
    busy: Arc<AtomicBool>,
    /// Bumped by each read and each change of mode: a late answer applies
    /// only while nothing newer has been shown.
    stamp: Arc<AtomicU64>,
}

/// A read's answer that came after its open stopped waiting.
#[derive(Debug, PartialEq, Eq)]
pub struct Late {
    pub shown: Shown,
    stamp: u64,
}

impl Reader {
    /// keryx's state through data folder `dir`: see [`Reader::read_with`].
    pub fn read(
        &self,
        dir: &Path,
        saved: &'static str,
        wait: Duration,
        late: impl FnOnce(Late) + Send + 'static,
    ) -> Option<Shown> {
        let dir = dir.to_path_buf();
        self.read_with(move || now(&dir, saved), wait, late)
    }

    /// Something newer than any read still out has been shown (a click
    /// saved a mode): that read's late answer no longer applies.
    pub fn supersede(&self) {
        self.stamp.fetch_add(1, Ordering::AcqRel);
    }

    /// Whether late answer `l` may still be shown: no read or change came
    /// after its own. Check it where it is shown (the tray's main thread,
    /// where reads and changes happen too), so none can come between.
    pub fn current(&self, l: &Late) -> bool {
        self.stamp.load(Ordering::Acquire) == l.stamp
    }

    /// What `read` returns, within `wait`, to show now; "unknown" past it,
    /// with `read`'s answer handed to `late` (on the read's thread: post it
    /// to where the menu is changed) when it lands. `None` while an earlier
    /// read is still out: what shows stays, and that read's `late` follows.
    pub fn read_with(
        &self,
        read: impl FnOnce() -> Shown + Send + 'static,
        wait: Duration,
        late: impl FnOnce(Late) + Send + 'static,
    ) -> Option<Shown> {
        if self.busy.swap(true, Ordering::AcqRel) {
            return None;
        }
        let stamp = self.stamp.fetch_add(1, Ordering::AcqRel) + 1;
        let (tx, rx) = mpsc::channel();
        // Set by the open once it stops waiting: the read then hands itself to `late`.
        let gave_up = Arc::new(Mutex::new(false));
        let (busy, gave_up_t) = (Arc::clone(&self.busy), Arc::clone(&gave_up));
        let spawned = std::thread::Builder::new()
            .name("voices-read".into())
            .spawn(move || {
                let shown = read();
                // Held until the answer is sent, so the open, under the same
                // lock, either finds it sent or has given up before the check.
                let g = gave_up_t.lock().unwrap_or_else(|e| e.into_inner());
                // Free before answering, so the next open never finds it busy.
                busy.store(false, Ordering::Release);
                if *g {
                    drop(g);
                    late(Late { shown, stamp });
                } else {
                    let _ = tx.send(shown);
                }
            });
        if spawned.is_err() {
            self.busy.store(false, Ordering::Release);
            return Some(unknown("could not start a read"));
        }
        if let Ok(s) = rx.recv_timeout(wait) {
            return Some(s);
        }
        // Under the lock, an answer either was sent already or goes to `late`.
        let mut g = gave_up.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(s) = rx.try_recv() {
            return Some(s);
        }
        *g = true;
        Some(unknown("keryx's config did not answer in time"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;
    use serde_json::json;

    #[test]
    fn heph_only_is_the_default_and_an_odd_value_reads_as_it() {
        assert_eq!(of(None), "heph");
        for bad in [json!({}), json!({"voices": "loud"}), json!({"voices": 3})] {
            assert_eq!(of(bad.as_object()), "heph", "{bad}");
        }
        assert_eq!(of(json!({"voices": "off"}).as_object()), "off");
    }

    #[test]
    fn only_a_known_mode_is_saved() {
        assert_eq!(value("everyone"), Ok(json!("everyone")));
        assert!(value("loud").unwrap_err().contains("heph, everyone, off"));
    }

    #[test]
    fn the_modes_are_the_ones_fleet_voices_reads() {
        let script = include_str!("../../../fleet/voices.sh");
        let mut read = format!("case $(prefs_get {KEY}) in");
        for (id, _) in &VOICES[1..] {
            read.push_str(&format!(" '\"{id}\"') echo {id} ;;"));
        }
        read.push_str(&format!(" *) echo {} ;; esac", VOICES[0].0));
        assert!(script.contains(&read), "voices.sh reads: {read}");
    }

    const ORCH: &str = "/home/aj/.local/state/fleet-orchestrator/orchestrator.session";
    /// Tests wait far longer than a menu open would: the bound is an upper
    /// limit, and a loaded CI runner must not read as a logic bug.
    const TEST_WAIT: Duration = Duration::from_secs(10);

    fn k(text: &str) -> Keryx {
        keryx(Ok(text.into()))
    }

    /// What keryx is said to do, without the saved mode.
    fn doing(s: &Shown) -> &str {
        s.says.split("; saved: ").next().unwrap()
    }

    #[test]
    fn keryx_state_is_read_by_keryx_rules() {
        assert_eq!(k(r#"{"enabled": false, "speak_only": ["x"]}"#), Keryx::Off);
        assert_eq!(k("{}"), Keryx::Everyone);
        let misfit = k(r#"{"enabled": "no"}"#);
        assert_eq!(misfit, Keryx::Everyone, "a misfit is the default");
        assert_eq!(k(r#"{"speak_only": []}"#), Keryx::Everyone);
        assert_eq!(k(r#"{"speak_only": "a"}"#), Keryx::Only(vec!["a".into()]));
        assert_eq!(k(r#"{"speak_only": ["a", 3]}"#), Keryx::Nobody);
        assert_eq!(k(r#"{"speak_only": 3}"#), Keryx::Nobody);
        for broken in ["[1]", "not json", "", r#"{"enabled": NaN}"#] {
            assert_eq!(k(broken), Keryx::Unreadable, "{broken:?}");
        }
        assert_eq!(keryx(Err(Refused::Missing)), Keryx::NoConfig);
        assert_eq!(keryx(Err(Refused::TooLarge)), Keryx::Unreadable);
        assert_eq!(keryx(Err(Refused::NotUtf8)), Keryx::Unreadable);
    }

    #[test]
    fn each_mode_is_ticked_only_when_keryx_holds_it() {
        let only = |e: &[&str]| Keryx::Only(e.iter().map(|s| s.to_string()).collect());
        let tick = |k: &Keryx| shown(k, ORCH, "heph").tick;
        assert_eq!(tick(&Keryx::Off), Some("off"));
        assert_eq!(tick(&Keryx::Everyone), Some("everyone"));
        // No config: keryx's defaults, every session (fleet voices agrees).
        assert_eq!(tick(&Keryx::NoConfig), Some("everyone"));
        assert_eq!(tick(&only(&[ORCH])), Some("heph"));
        for odd in [
            only(&["/elsewhere"]),
            only(&[ORCH, "/elsewhere"]),
            Keryx::Nobody,
            Keryx::Unreadable,
        ] {
            let s = shown(&odd, ORCH, "heph");
            assert_eq!(s.tick, None, "{odd:?}");
            assert!(!doing(&s).contains("Heph only"), "{s:?}");
            assert!(s.says.ends_with("; saved: Heph only"), "{s:?}");
        }
        // No orchestrator file named: an empty entry is not Heph.
        assert_eq!(shown(&only(&[""]), "", "heph").tick, None);
    }

    #[test]
    fn the_status_line_names_what_keryx_does_and_a_differing_saved_mode() {
        let say = |k: &Keryx, saved| shown(k, ORCH, saved).says;
        assert_eq!(say(&Keryx::Off, "heph"), "keryx now: Off; saved: Heph only");
        assert_eq!(say(&Keryx::Off, "off"), "keryx now: Off");
        let two = Keryx::Only(vec!["/a".into(), "/b".into()]);
        assert_eq!(
            say(&two, "everyone"),
            "keryx now: on for 2 other sessions only; saved: Everyone"
        );
        let one = Keryx::Only(vec!["/a".into()]);
        assert_eq!(
            say(&one, "heph"),
            "keryx now: on for 1 other session only; saved: Heph only"
        );
        assert_eq!(
            say(&Keryx::NoConfig, "everyone"),
            "keryx now: Everyone (keryx's defaults: no config file)"
        );
    }

    /// The data folder with the paths file pointing at its own config.json.
    fn setup(name: &str) -> Scratch {
        let d = Scratch::new(name);
        let config = d.0.join("config.json");
        d.write(
            PATHS_FILE,
            &json!({"config": config.to_str().unwrap(), "heph": ORCH}).to_string(),
        );
        d
    }

    /// One menu open's read, which must answer in time.
    fn open(r: &Reader, d: &Scratch, saved: &'static str) -> Shown {
        r.read(&d.0, saved, TEST_WAIT, |_| panic!("answered late"))
            .expect("no read was out")
    }

    #[test]
    fn a_mode_saved_by_the_cli_shows_on_the_next_open() {
        let d = setup("cli-mode");
        let r = Reader::default();
        // The tray saved Everyone; `fleet voices heph` then ran in a terminal.
        d.write("config.json", r#"{"enabled": true, "speak_only": []}"#);
        assert_eq!(open(&r, &d, "everyone").tick, Some("everyone"));
        d.write(
            "config.json",
            &json!({"enabled": true, "speak_only": [ORCH]}).to_string(),
        );
        let s = open(&r, &d, "heph");
        assert_eq!(
            (s.tick, s.says.as_str()),
            (Some("heph"), "keryx now: Heph only")
        );
    }

    #[test]
    fn keryx_off_done_outside_the_tray_shows_off_and_no_stale_tick_survives() {
        let d = setup("keryx-off");
        let r = Reader::default();
        d.write(
            "config.json",
            &json!({"enabled": true, "speak_only": [ORCH]}).to_string(),
        );
        assert_eq!(open(&r, &d, "heph").tick, Some("heph"));
        // `/keryx off`: keryx writes enabled false and leaves speak_only.
        d.write(
            "config.json",
            &json!({"enabled": false, "speak_only": [ORCH]}).to_string(),
        );
        let s = open(&r, &d, "heph");
        assert_eq!(
            (s.tick, s.says.as_str()),
            (Some("off"), "keryx now: Off; saved: Heph only")
        );
        // A bare `keryx speak-only` for another session: no mode, named.
        d.write("config.json", r#"{"speak_only": ["/x"]}"#);
        assert_eq!(open(&r, &d, "heph").tick, None);
    }

    #[test]
    fn without_the_paths_file_nothing_is_ticked() {
        let d = Scratch::new("no-paths");
        let s = open(&Reader::default(), &d, "heph");
        assert_eq!(s.tick, None);
        assert!(s.says.contains("fleet voices has not run"), "{s:?}");
        for bad in ["{}", r#"{"config": "", "heph": ""}"#, "[]"] {
            d.write(PATHS_FILE, bad);
            assert_eq!(paths(&d.0), None, "{bad}");
        }
    }

    #[test]
    fn a_slow_read_shows_unknown_then_its_own_answer_and_frees_the_reader() {
        let r = Reader::default();
        let heph = || shown(&Keryx::Only(vec![ORCH.into()]), ORCH, "heph");
        let (tx, late) = mpsc::channel();
        let slow = move || {
            std::thread::sleep(Duration::from_millis(300));
            heph()
        };
        let s = r.read_with(slow, Duration::from_millis(20), move |l| {
            let _ = tx.send(l);
        });
        assert_eq!(s.as_ref().map(|s| s.tick), Some(None), "{s:?}");
        assert!(s.unwrap().says.contains("did not answer in time"));
        // A second open while it is out starts no read and leaves what shows.
        let again = r.read_with(|| panic!("a second read"), TEST_WAIT, |_| {});
        assert_eq!(again, None);
        // The late answer is the real state, and nothing newer came first.
        let l = late.recv_timeout(TEST_WAIT).unwrap();
        assert_eq!(l.shown, heph());
        assert!(r.current(&l));
        // And the reader is free again; a newer read makes the late one stale.
        let next = r.read_with(heph, TEST_WAIT, |_| panic!("answered late"));
        assert_eq!(next, Some(heph()));
        assert!(
            !r.current(&l),
            "an older late answer would overwrite a newer read"
        );
    }

    #[test]
    fn a_mode_clicked_while_a_read_is_out_outranks_its_late_answer() {
        let r = Reader::default();
        let (tx, late) = mpsc::channel();
        let slow = || {
            std::thread::sleep(Duration::from_millis(200));
            shown(&Keryx::Off, ORCH, "heph")
        };
        r.read_with(slow, Duration::from_millis(10), move |l| {
            let _ = tx.send(l);
        });
        // The click on a mode comes while the read is out.
        r.supersede();
        let l = late.recv_timeout(TEST_WAIT).unwrap();
        assert!(!r.current(&l), "{l:?}");
    }
}
