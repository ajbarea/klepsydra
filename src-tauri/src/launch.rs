//! The one place klepsydra starts a process: wsl.exe, from a click, one call
//! at a time, running ~/.claude/klepsydra-launch.sh to start a session or
//! bring a session's tmux window forward.

use std::sync::Mutex;
#[cfg(any(windows, test))]
use std::time::{Duration, Instant};

use serde_json::Value;
use tauri::Manager;

/// The only program klepsydra starts.
#[cfg_attr(not(windows), allow(dead_code))]
pub const WSL_EXE: &str = r"C:\Windows\System32\wsl.exe";
/// The launcher, relative to the WSL home (`--cd ~`).
const SCRIPT: &str = ".claude/klepsydra-launch.sh";
/// Longest wait for wsl.exe to finish: a cold WSL start alone can take 20 s.
#[cfg(any(windows, test))]
const TIMEOUT: Duration = Duration::from_secs(45);
/// How long the output is still read once wsl.exe exits; a process it left
/// behind holding the pipe open cannot keep the call running past this.
#[cfg(windows)]
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// Set while a call runs; a click meanwhile is refused.
#[derive(Default)]
pub struct InFlight(pub Mutex<bool>);

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

/// wsl.exe's arguments to bring `t`'s tmux window forward.
pub fn jump_args(t: &Target) -> Result<Vec<String>, String> {
    if !(distro_ok(&t.distro) && socket_ok(&t.socket) && pane_ok(&t.pane) && t.pid != 0) {
        return Err("This session's tmux pane cannot be named safely.".into());
    }
    let (pid, start) = (t.pid.to_string(), t.start.to_string());
    Ok([
        "-d", &t.distro, "--cd", "~", "-e", "bash", SCRIPT, "jump", &t.socket, &t.pane, &pid,
        &start,
    ]
    .map(String::from)
    .to_vec())
}

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
#[cfg(any(windows, test))]
fn timed_out() -> String {
    format!(
        "WSL did not answer within {} seconds. The session may still be starting; check the terminal before clicking again.",
        TIMEOUT.as_secs()
    )
}

#[cfg(windows)]
fn run(args: &[String]) -> Result<String, String> {
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
fn run(_args: &[String]) -> Result<String, String> {
    Err("Starting a session works on Windows only.".into())
}

/// Bring `t`'s tmux window to the front of its session.
pub fn tmux_jump(app: &tauri::AppHandle, t: &Target) -> Result<String, String> {
    let args = jump_args(t)?;
    gated(&app.state::<InFlight>(), || run(&args))
}

/// Start `claude` in the `launch_dir` pref as a window of the fleet session.
#[tauri::command]
pub async fn launch_session(app: tauri::AppHandle) -> Result<String, String> {
    let prefs = crate::read_prefs(&app)
        .ok_or("prefs.json could not be read, so the launch folder is unknown.")?;
    let dir = prefs
        .get("launch_dir")
        .and_then(Value::as_str)
        .unwrap_or("~")
        .to_owned();
    let distro = prefs
        .get("launch_distro")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let args = new_args(&dir, distro.as_deref())?;
    tauri::async_runtime::spawn_blocking(move || gated(&app.state::<InFlight>(), || run(&args)))
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
    fn new_args_refuse_a_relative_folder_or_a_bad_distro() {
        assert!(new_args("repos", None).is_err());
        assert!(new_args("~/a\nb", None).is_err());
        assert!(new_args("~", Some("Ub untu")).is_err());
        assert!(new_args("~", Some("")).is_err());
    }

    #[test]
    fn jump_args_refuse_anything_but_a_plain_pane_and_socket() {
        let ok = Target {
            socket: "/tmp/tmux-1001/klepsydra".into(),
            pane: "%3".into(),
            distro: "Ubuntu".into(),
            pid: 2231,
            start: 8_717_628,
        };
        assert_eq!(
            jump_args(&ok).unwrap()[6..],
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
            assert!(jump_args(&bad).is_err(), "{bad:?}");
        }
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
