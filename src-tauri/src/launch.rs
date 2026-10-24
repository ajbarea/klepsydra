//! The one place klepsydra starts a process: wsl.exe, from a click, one call
//! at a time, running ~/.claude/klepsydra-launch.sh to start a session, bring
//! a session's tmux window forward, or end or interrupt it.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;
#[cfg(any(windows, test))]
use std::time::Instant;

use serde_json::Value;
use tauri::Manager;

/// The only program klepsydra starts.
#[cfg_attr(not(windows), allow(dead_code))]
pub const WSL_EXE: &str = r"C:\Windows\System32\wsl.exe";
/// The launcher, relative to the WSL home (`--cd ~`).
const SCRIPT: &str = ".claude/klepsydra-launch.sh";
/// Longest wait for wsl.exe to finish: a cold WSL start alone can take 20 s.
const TIMEOUT: Duration = Duration::from_secs(45);
/// How long the output is still read once wsl.exe exits; a process it left
/// behind holding the pipe open cannot keep the call running past this.
#[cfg(windows)]
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// Set while a call runs; a click meanwhile is refused.
#[derive(Default)]
pub struct InFlight(pub Mutex<bool>);

/// The sessions whose pane has an End or Interrupt running. Those two verbs
/// are per-session: another session, Jump and New session run independently.
#[derive(Default)]
pub struct PaneFlight(pub Mutex<HashSet<String>>);

/// The title of the Windows Terminal tab the launcher opens; the script's
/// `TAB_TITLE` is the same text, which a guard test asserts.
pub const FLEET_TAB: &str = "klepsydra sessions";

/// The launcher's tmux socket name; the script's default is the same text,
/// which a guard test asserts.
pub const FLEET_SOCKET: &str = "klepsydra";

/// A session's tmux pane, the Claude process that must still be in it, and the
/// distro they run in. `start` is `/proc/<pid>/stat` field 22.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub socket: String,
    pub pane: String,
    pub distro: String,
    pub pid: u32,
    pub start: u64,
}

fn distro_ok(d: &str) -> bool {
    (1..=64).contains(&d.len())
        && d.chars()
            .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

fn dir_ok(d: &str) -> bool {
    (d == "~" || d.starts_with("~/") || d.starts_with('/'))
        && d.len() <= 1024
        && !d.chars().any(char::is_control)
}

fn socket_ok(s: &str) -> bool {
    s.starts_with('/')
        && s.len() <= 256
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c))
}

fn pane_ok(p: &str) -> bool {
    (2..=10).contains(&p.len()) && p.starts_with('%') && p[1..].chars().all(|c| c.is_ascii_digit())
}

/// wsl.exe's arguments to start a session in `dir`.
pub fn new_args(dir: &str, distro: Option<&str>) -> Result<Vec<String>, String> {
    if !dir_ok(dir) {
        return Err(format!("launch_dir must start with ~ or /: {dir}"));
    }
    let mut a: Vec<String> = Vec::new();
    if let Some(d) = distro {
        if !distro_ok(d) {
            return Err(format!("launch_distro is not a distro name: {d}"));
        }
        a.extend(["-d".into(), d.into()]);
    }
    a.extend(["--cd", "~", "-e", "bash", "-l", SCRIPT, "new", dir].map(String::from));
    Ok(a)
}

/// What the launcher does to a session's tmux pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneVerb {
    /// Bring its window forward.
    Jump,
    /// Type /exit into it.
    End,
    /// Press Esc in it.
    Interrupt,
    /// Type /klepsydra-wrapup into it.
    Wrapup,
}

impl PaneVerb {
    fn word(self) -> &'static str {
        match self {
            PaneVerb::Jump => "jump",
            PaneVerb::End => "end",
            PaneVerb::Interrupt => "interrupt",
            PaneVerb::Wrapup => "wrapup",
        }
    }
}

/// wsl.exe's arguments to do `verb` to `t`'s tmux pane. Only Jump reaches a
/// tmux started by hand; klepsydra types into its own server's panes alone.
pub fn pane_args(t: &Target, verb: PaneVerb) -> Result<Vec<String>, String> {
    if !(distro_ok(&t.distro) && socket_ok(&t.socket) && pane_ok(&t.pane) && t.pid != 0) {
        return Err("This session's tmux pane cannot be named safely.".into());
    }
    if verb != PaneVerb::Jump && !is_fleet(t) {
        return Err(NOT_FLEET.into());
    }
    let (pid, start) = (t.pid.to_string(), t.start.to_string());
    Ok([
        "-d",
        &t.distro,
        "--cd",
        "~",
        "-e",
        "bash",
        SCRIPT,
        verb.word(),
        &t.socket,
        &t.pane,
        &pid,
        &start,
    ]
    .map(String::from)
    .to_vec())
}

/// Why End and Interrupt refuse a session outside the launcher's tmux; the
/// launcher says the same.
const NOT_FLEET: &str =
    "That session is not in klepsydra's tmux, so klepsydra will not type into it.";

/// Whether `t` runs on the launcher's own tmux server, the only one whose tab
/// carries `FLEET_TAB`.
pub fn is_fleet(t: &Target) -> bool {
    t.socket.rsplit('/').next() == Some(FLEET_SOCKET)
}

/// Session `id`'s tmux pane, Claude process and distro from a published snapshot.
pub fn target(snapshot: &Value, id: &str) -> Option<Target> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let tmux = s.get("tmux")?;
    let claude = s.get("claude")?;
    Some(Target {
        socket: tmux.get("socket")?.as_str()?.into(),
        pane: tmux.get("pane")?.as_str()?.into(),
        distro: s.get("distro")?.as_str()?.into(),
        pid: u32::try_from(claude.get("pid")?.as_u64()?).ok()?,
        start: claude.get("start")?.as_u64()?,
    })
}

/// Reopens the gate when dropped, even while unwinding.
struct Reopen<'a>(&'a InFlight);

impl Drop for Reopen<'_> {
    fn drop(&mut self) {
        let mut busy = self.0 .0.lock().unwrap_or_else(|e| e.into_inner());
        *busy = false;
    }
}

/// Run `f` unless another call is running.
pub fn gated<T>(flight: &InFlight, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    {
        let mut busy = flight.0.lock().unwrap_or_else(|e| e.into_inner());
        if *busy {
            return Err("A launch is already running.".into());
        }
        *busy = true;
    }
    let _reopen = Reopen(flight);
    f()
}

/// Frees session `id` in a `PaneFlight` when dropped, even while unwinding.
struct Release<'a>(&'a PaneFlight, String);

impl Drop for Release<'_> {
    fn drop(&mut self) {
        let mut busy = self.0 .0.lock().unwrap_or_else(|e| e.into_inner());
        busy.remove(&self.1);
    }
}

/// Run `f` unless an End or Interrupt of session `id` is already running.
pub fn pane_gated<T>(
    flight: &PaneFlight,
    id: &str,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    {
        let mut busy = flight.0.lock().unwrap_or_else(|e| e.into_inner());
        if !busy.insert(id.to_owned()) {
            return Err(PANE_BUSY.into());
        }
    }
    let _release = Release(flight, id.to_owned());
    f()
}

const PANE_BUSY: &str = "That session is already being ended or interrupted.";

/// wsl.exe writes its own messages as UTF-16LE and the Linux side's as UTF-8.
#[cfg(any(windows, test))]
fn decode(b: &[u8]) -> String {
    let utf16 =
        b.len() >= 2 && b.len().is_multiple_of(2) && b.iter().skip(1).step_by(2).all(|&x| x == 0);
    if utf16 {
        let units: Vec<u16> = b
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&c| u16::from_le_bytes(c))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(b).into_owned()
    }
}

/// The last non-blank line, at most 200 characters.
#[cfg(any(windows, test))]
fn last_line(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .unwrap_or("");
    line.chars().take(200).collect()
}

/// Most output kept from each stream.
#[cfg(any(windows, test))]
const KEEP: usize = 64 * 1024;

/// A stream being read on its own thread.
#[cfg(any(windows, test))]
struct Drain {
    kept: std::sync::Arc<Mutex<Vec<u8>>>,
    done: std::sync::mpsc::Receiver<()>,
}

#[cfg(any(windows, test))]
impl Drain {
    /// What was read, once the stream ends or at `deadline`, whichever is
    /// first; a stream still open then is left to its thread.
    fn wait(self, deadline: Instant) -> Vec<u8> {
        let _ = self
            .done
            .recv_timeout(deadline.saturating_duration_since(Instant::now()));
        let kept = self.kept.lock().unwrap_or_else(|e| e.into_inner());
        kept.clone()
    }
}

/// Read `r` to its end on a thread, keeping the last `KEEP` bytes, so a full
/// pipe never stalls the child.
#[cfg(any(windows, test))]
fn drain<R: std::io::Read + Send + 'static>(mut r: R) -> Drain {
    let kept = std::sync::Arc::new(Mutex::new(Vec::new()));
    let (tx, done) = std::sync::mpsc::channel();
    let shared = std::sync::Arc::clone(&kept);
    std::thread::spawn(move || {
        let mut chunk = [0u8; 4096];
        while let Ok(n) = r.read(&mut chunk) {
            if n == 0 {
                break;
            }
            let mut kept = shared.lock().unwrap_or_else(|e| e.into_inner());
            kept.extend_from_slice(&chunk[..n]);
            if kept.len() > KEEP {
                let extra = kept.len() - KEEP;
                kept.drain(..extra);
            }
        }
        let _ = tx.send(());
    });
    Drain { kept, done }
}

/// The card's line when wsl.exe does not finish within `TIMEOUT`.
fn timed_out() -> String {
    format!(
        "WSL did not answer within {} seconds. The session may still be starting; check the terminal before clicking again.",
        TIMEOUT.as_secs()
    )
}

/// The card's line when End or Interrupt gets no answer from WSL in `TIMEOUT`.
fn pane_timed_out() -> String {
    format!(
        "WSL did not answer within {} seconds; the session may not have ended. Check its terminal.",
        TIMEOUT.as_secs()
    )
}

/// The card's line when typing the wrap-up gets no answer from WSL in `TIMEOUT`.
fn wrapup_timed_out() -> String {
    format!(
        "WSL did not answer within {} seconds; the session may not have been asked. Check its terminal.",
        TIMEOUT.as_secs()
    )
}

#[cfg(windows)]
fn run(args: &[String], timed_out: fn() -> String) -> Result<String, String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut child = Command::new(WSL_EXE)
        .args(args)
        .env("WSL_UTF8", "1")
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start {WSL_EXE}: {e}"))?;
    let out = drain(child.stdout.take().ok_or("wsl.exe gave no stdout.")?);
    let err = drain(child.stderr.take().ok_or("wsl.exe gave no stderr.")?);
    let deadline = Instant::now() + TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                return Err(timed_out());
            }
            Err(e) => return Err(e.to_string()),
        }
    };
    let until = Instant::now() + DRAIN_GRACE;
    let (stdout, stderr) = (
        last_line(&decode(&out.wait(until))),
        last_line(&decode(&err.wait(until))),
    );
    if status.success() {
        Ok(stdout)
    } else if stderr.is_empty() {
        Err(if stdout.is_empty() {
            format!("wsl.exe exited with {status}.")
        } else {
            stdout
        })
    } else {
        Err(stderr)
    }
}

#[cfg(not(windows))]
fn run(_args: &[String], _timed_out: fn() -> String) -> Result<String, String> {
    Err("Starting a session works on Windows only.".into())
}

/// Bring `t`'s tmux window to the front of its session.
pub fn tmux_jump(app: &tauri::AppHandle, t: &Target) -> Result<String, String> {
    let args = pane_args(t, PaneVerb::Jump)?;
    gated(&app.state::<InFlight>(), || run(&args, timed_out))
}

/// Do `verb` to session `id`'s pane, as the latest snapshot names it.
async fn to_pane(app: tauri::AppHandle, id: String, verb: PaneVerb) -> Result<String, String> {
    let target = app
        .state::<crate::fleet::Fleet>()
        .with_latest(|v| target(v, &id))
        .flatten()
        .ok_or("This session has no tmux pane klepsydra knows, so it can only be stopped from its own terminal.")?;
    let args = pane_args(&target, verb)?;
    tauri::async_runtime::spawn_blocking(move || {
        pane_gated(&app.state::<PaneFlight>(), &id, || {
            run(&args, pane_timed_out)
        })
    })
    .await
    .map_err(|e| format!("Could not reach the session: {e}"))?
}

/// End session `id` as if /exit were typed in its terminal. The wall asks
/// first and waits out its undo window before calling this.
#[tauri::command]
pub async fn end_session(app: tauri::AppHandle, id: String) -> Result<String, String> {
    to_pane(app, id, PaneVerb::End).await
}

/// The card's line when Wrap up finds an End or Interrupt of that session running.
const WRAPUP_BUSY: &str =
    "klepsydra is already sending that session something; ask it by hand: type /klepsydra-wrapup in its terminal.";

/// Start a wrap-up of the sessions `ids` the wall's confirm listed: each is
/// asked to checkpoint and report, idle ones in klepsydra's tmux at once (all
/// marked asked first, then typed into together), the rest by the Stop hook.
/// A session not listed is never asked.
#[tauri::command]
pub async fn start_wrapup(
    app: tauri::AppHandle,
    ids: Vec<String>,
) -> Result<Vec<klepsydra_fleet::wrapup::Asked>, String> {
    use klepsydra_fleet::wrapup::{self, Failed};
    let dir = crate::klepsydra_dir(&app).ok_or("klepsydra has no data folder.")?;
    let snapshot = app
        .state::<crate::fleet::Fleet>()
        .with_latest(Value::clone)
        .ok_or("The fleet has not been read yet.")?;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let sessions = snapshot["sessions"].as_array().cloned().unwrap_or_default();
    let on_wall = |id: &String| {
        sessions
            .iter()
            .any(|s| s["session_id"].as_str() == Some(id))
    };
    let listed: Vec<String> = ids.into_iter().filter(on_wall).collect();
    if listed.is_empty() {
        return Err("None of those sessions is on the wall any more.".into());
    }
    let r = wrapup::start(&dir, i64::try_from(now_ms).unwrap_or(i64::MAX), &listed)
        .map_err(|e| format!("Could not start the wrap-up: {e}"))?;
    // As the wall judges it: a fleet pane with a known Claude process.
    let targets: std::collections::HashMap<String, Target> = r
        .ids
        .iter()
        .filter_map(|id| Some((id.clone(), target(&snapshot, id)?)))
        .filter(|(_, t)| is_fleet(t) && t.pid > 0)
        .collect();
    // Routed from the session files as they read now; each is read again just before typing.
    let plan = wrapup::plan(&dir, &r.ids, |id| targets.contains_key(id), r.at);
    tauri::async_runtime::spawn_blocking(move || {
        wrapup::ask(&dir, &r, &plan, r.at, |id| {
            let failed = |error: String| Failed {
                // A timeout may have typed it: keep the mark, so the Stop hook does not ask twice.
                maybe_typed: error == wrapup_timed_out(),
                error,
            };
            let args = targets
                .get(id)
                .ok_or_else(|| "This session has no tmux pane klepsydra knows.".to_owned())
                .and_then(|t| pane_args(t, PaneVerb::Wrapup))
                .map_err(failed)?;
            pane_gated(&app.state::<PaneFlight>(), id, || {
                run(&args, wrapup_timed_out)
            })
            .map(|_| ())
            .map_err(|e| {
                failed(if e == PANE_BUSY {
                    WRAPUP_BUSY.into()
                } else {
                    e
                })
            })
        })
    })
    .await
    .map_err(|e| format!("Could not ask the sessions: {e}"))
}

/// Stop asking sessions to wrap up; answers so far stay on the wall.
#[tauri::command]
pub fn cancel_wrapup(app: tauri::AppHandle) -> Result<(), String> {
    let dir = crate::klepsydra_dir(&app).ok_or("klepsydra has no data folder.")?;
    klepsydra_fleet::wrapup::cancel(&dir, klepsydra_fleet::watch::unix_now())
        .map_err(|e| format!("Could not stop the wrap-up: {e}"))
}

/// Interrupt session `id`'s turn, as if Esc were pressed in its terminal.
#[tauri::command]
pub async fn interrupt_session(app: tauri::AppHandle, id: String) -> Result<String, String> {
    to_pane(app, id, PaneVerb::Interrupt).await
}

type Prefs = serde_json::Map<String, Value>;

/// The `launch_dir` pref, `~` when unset.
fn launch_dir(prefs: &Prefs) -> &str {
    prefs
        .get("launch_dir")
        .and_then(Value::as_str)
        .unwrap_or("~")
}

/// The folder a launch would start in, when prefs.json can be read and the
/// folder is one `new_args` takes.
fn launch_dir_of(prefs: Option<&Prefs>) -> Option<String> {
    let dir = launch_dir(prefs?);
    dir_ok(dir).then(|| dir.to_owned())
}

/// The folder + New session starts in, for the wall's empty state. Reads only.
#[tauri::command]
pub fn get_launch_dir(app: tauri::AppHandle) -> Option<String> {
    launch_dir_of(crate::read_prefs(&app).as_ref())
}

/// Start `claude` in the `launch_dir` pref as a window of the fleet session.
#[tauri::command]
pub async fn launch_session(app: tauri::AppHandle) -> Result<String, String> {
    let prefs = crate::read_prefs(&app)
        .ok_or("prefs.json could not be read, so the launch folder is unknown.")?;
    let distro = prefs.get("launch_distro").and_then(Value::as_str);
    let args = new_args(launch_dir(&prefs), distro)?;
    tauri::async_runtime::spawn_blocking(move || {
        gated(&app.state::<InFlight>(), || run(&args, timed_out))
    })
    .await
    .map_err(|e| format!("Could not run the launch: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Instant;

    #[test]
    fn new_args_pass_the_folder_as_one_argument() {
        let a = new_args("~/my repos;x", None).unwrap();
        assert_eq!(
            a,
            [
                "--cd",
                "~",
                "-e",
                "bash",
                "-l",
                SCRIPT,
                "new",
                "~/my repos;x"
            ]
        );
        let a = new_args("/home/aj", Some("Ubuntu")).unwrap();
        assert_eq!(&a[..2], ["-d", "Ubuntu"]);
    }

    #[test]
    fn the_empty_state_names_the_folder_a_launch_would_use() {
        let prefs = |v: Value| v.as_object().cloned().unwrap();
        assert_eq!(launch_dir_of(None), None, "prefs.json unreadable");
        assert_eq!(launch_dir_of(Some(&prefs(json!({})))).as_deref(), Some("~"));
        let set = prefs(json!({"launch_dir": "/home/aj/ajsoftworks"}));
        assert_eq!(
            launch_dir_of(Some(&set)).as_deref(),
            Some("/home/aj/ajsoftworks")
        );
        assert_eq!(
            launch_dir(&set),
            "/home/aj/ajsoftworks",
            "the launch reads the same key"
        );
        for bad in [json!("relative/dir"), json!("")] {
            assert_eq!(
                launch_dir_of(Some(&prefs(json!({"launch_dir": bad})))),
                None
            );
        }
        // Not a string: the launch falls back to ~, so the label does too.
        assert_eq!(
            launch_dir_of(Some(&prefs(json!({"launch_dir": 3})))).as_deref(),
            Some("~")
        );
    }

    #[test]
    fn new_args_refuse_a_relative_folder_or_a_bad_distro() {
        assert!(new_args("repos", None).is_err());
        assert!(new_args("~/a\nb", None).is_err());
        assert!(new_args("~", Some("Ub untu")).is_err());
        assert!(new_args("~", Some("")).is_err());
    }

    #[test]
    fn pane_args_refuse_anything_but_a_plain_pane_and_socket() {
        let ok = Target {
            socket: "/tmp/tmux-1001/klepsydra".into(),
            pane: "%3".into(),
            distro: "Ubuntu".into(),
            pid: 2231,
            start: 8_717_628,
        };
        assert_eq!(
            pane_args(&ok, PaneVerb::Jump).unwrap()[6..],
            [
                SCRIPT,
                "jump",
                "/tmp/tmux-1001/klepsydra",
                "%3",
                "2231",
                "8717628"
            ]
        );
        for bad in [
            Target {
                pane: "%3;x".into(),
                ..ok.clone()
            },
            Target {
                pane: "3".into(),
                ..ok.clone()
            },
            Target {
                socket: "rel".into(),
                ..ok.clone()
            },
            Target {
                socket: "/tmp/a b".into(),
                ..ok.clone()
            },
            Target {
                distro: "a;b".into(),
                ..ok.clone()
            },
            Target {
                pid: 0,
                ..ok.clone()
            },
        ] {
            for verb in [PaneVerb::Jump, PaneVerb::End, PaneVerb::Interrupt] {
                assert!(pane_args(&bad, verb).is_err(), "{verb:?} {bad:?}");
            }
        }
    }

    #[test]
    fn end_and_interrupt_name_their_verb_and_only_reach_the_fleet() {
        let fleet = Target {
            socket: "/tmp/tmux-1001/klepsydra".into(),
            pane: "%3".into(),
            distro: "Ubuntu".into(),
            pid: 2231,
            start: 8_717_628,
        };
        assert_eq!(pane_args(&fleet, PaneVerb::End).unwrap()[7], "end");
        assert_eq!(
            pane_args(&fleet, PaneVerb::Interrupt).unwrap()[7],
            "interrupt"
        );
        assert_eq!(pane_args(&fleet, PaneVerb::Wrapup).unwrap()[7], "wrapup");
        let hand = Target {
            socket: "/tmp/tmux-1001/default".into(),
            ..fleet
        };
        assert!(pane_args(&hand, PaneVerb::Jump).is_ok());
        for verb in [PaneVerb::End, PaneVerb::Interrupt, PaneVerb::Wrapup] {
            assert_eq!(pane_args(&hand, verb), Err(NOT_FLEET.to_string()));
        }
    }

    #[test]
    fn the_launcher_refuses_a_hand_started_tmux_in_the_same_words() {
        let script = include_str!("../../hooks/klepsydra-launch.sh");
        assert!(script.contains(&format!("fail \"{NOT_FLEET}\"")));
    }

    #[test]
    fn only_the_launchers_socket_is_the_fleet() {
        let t = |socket: &str| Target {
            socket: socket.into(),
            pane: "%1".into(),
            distro: "Ubuntu".into(),
            pid: 1,
            start: 1,
        };
        assert!(is_fleet(&t("/tmp/tmux-1001/klepsydra")));
        assert!(!is_fleet(&t("/tmp/tmux-1001/default")));
        assert!(!is_fleet(&t("/tmp/klepsydra/default")));
        assert!(!is_fleet(&t("/tmp/tmux-1001/klepsydra2")));
    }

    #[test]
    fn target_needs_tmux_distro_and_claude() {
        let c = json!({"pid": 7, "start": 99});
        let s = json!({"sessions": [
            {"session_id": "a", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu", "claude": c},
            {"session_id": "b", "tmux": {"socket": "/s", "pane": "%1"}, "distro": null, "claude": c},
            {"session_id": "c", "tmux": null, "distro": "Ubuntu", "claude": c},
            {"session_id": "d", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu", "claude": null},
            {"session_id": "e", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu"}]});
        let t = target(&s, "a").unwrap();
        assert_eq!((t.pane.as_str(), t.pid, t.start), ("%1", 7, 99));
        for id in ["b", "c", "d", "e"] {
            assert!(target(&s, id).is_none(), "{id}");
        }
    }

    #[test]
    fn a_call_while_one_runs_is_refused_and_the_gate_reopens() {
        let flight = InFlight::default();
        let inner = gated(&flight, || Ok(gated(&flight, || Ok(()))));
        assert_eq!(inner.unwrap(), Err("A launch is already running.".into()));
        assert!(gated(&flight, || Ok(())).is_ok());
        let _ = gated::<()>(&flight, || Err("x".into()));
        assert!(
            gated(&flight, || Ok(())).is_ok(),
            "an error reopens the gate"
        );
    }

    #[test]
    fn a_second_end_of_the_same_session_is_refused_and_the_guard_reopens() {
        let flight = PaneFlight::default();
        let inner = pane_gated(&flight, "a", || {
            Ok((
                pane_gated(&flight, "a", || Ok(())),
                pane_gated(&flight, "b", || Ok(())),
            ))
        })
        .unwrap();
        assert_eq!(inner.0, Err(PANE_BUSY.into()));
        assert!(inner.1.is_ok(), "another session runs independently");
        assert!(pane_gated(&flight, "a", || Ok(())).is_ok());
        let _ = pane_gated::<()>(&flight, "a", || Err("x".into()));
        assert!(
            pane_gated(&flight, "a", || Ok(())).is_ok(),
            "an error reopens the guard"
        );
    }

    #[test]
    fn a_pane_verb_does_not_hold_the_launch_gate_nor_wait_for_it() {
        let (launch, panes) = (InFlight::default(), PaneFlight::default());
        let r = gated(&launch, || pane_gated(&panes, "a", || Ok(())));
        assert!(r.is_ok(), "End runs while a Jump holds the gate");
        let r = pane_gated(&panes, "a", || gated(&launch, || Ok(())));
        assert!(r.is_ok(), "Jump and New run while an End does");
    }

    #[test]
    fn a_panic_in_a_pane_verb_reopens_its_session() {
        let flight = PaneFlight::default();
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = pane_gated::<()>(&flight, "a", || panic!("boom"));
        }));
        assert!(r.is_err());
        assert!(pane_gated(&flight, "a", || Ok(())).is_ok());
    }

    #[test]
    fn a_pane_verb_timeout_says_the_session_may_not_have_ended() {
        assert_eq!(
            pane_timed_out(),
            "WSL did not answer within 45 seconds; the session may not have ended. Check its terminal."
        );
    }

    #[test]
    fn decode_reads_both_encodings_and_last_line_trims() {
        assert_eq!(decode(b"ok\n"), "ok\n");
        let utf16: Vec<u8> = "Error: no distro\r\n"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert_eq!(last_line(&decode(&utf16)), "Error: no distro");
        assert_eq!(last_line("a\n\n  b  \n\n"), "b");
        assert_eq!(last_line(&"x".repeat(300)).len(), 200);
    }

    #[test]
    fn a_panic_in_the_call_leaves_the_gate_open() {
        let flight = InFlight::default();
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = gated::<()>(&flight, || panic!("boom"));
        }));
        assert!(r.is_err());
        assert!(gated(&flight, || Ok(())).is_ok());
    }

    #[test]
    fn drain_keeps_the_tail_of_a_long_stream() {
        let mut data = vec![b'a'; KEEP * 2];
        data.extend_from_slice(b"\nlast\n");
        let kept = drain(std::io::Cursor::new(data)).wait(Instant::now() + Duration::from_secs(5));
        assert_eq!(kept.len(), KEEP);
        assert_eq!(last_line(&decode(&kept)), "last");
    }

    /// A pipe a grandchild still holds open: some output, then no EOF.
    struct Held(Option<&'static [u8]>);

    impl std::io::Read for Held {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            match self.0.take() {
                Some(b) => {
                    buf[..b.len()].copy_from_slice(b);
                    Ok(b.len())
                }
                None => loop {
                    std::thread::park();
                },
            }
        }
    }

    #[test]
    fn a_stream_without_eof_is_given_up_on_at_the_deadline() {
        let started = Instant::now();
        let kept = drain(Held(Some(b"Started a session in /x.\n")))
            .wait(Instant::now() + Duration::from_millis(300));
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(250), "{waited:?}");
        assert!(waited < Duration::from_secs(2), "{waited:?}");
        assert_eq!(last_line(&decode(&kept)), "Started a session in /x.");
    }

    #[test]
    fn a_timeout_waits_45_seconds_and_says_the_session_may_be_starting() {
        assert_eq!(TIMEOUT, Duration::from_secs(45));
        assert_eq!(
            timed_out(),
            "WSL did not answer within 45 seconds. The session may still be starting; check the terminal before clicking again."
        );
    }
}
