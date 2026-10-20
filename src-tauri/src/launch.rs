//! The one place klepsydra starts a process: wsl.exe, from a click, one call
//! at a time, running ~/.claude/klepsydra-launch.sh to start a session or
//! bring a session's tmux window forward.

use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;
use tauri::Manager;

/// The only program klepsydra starts.
pub const WSL_EXE: &str = r"C:\Windows\System32\wsl.exe";
/// The launcher, relative to the WSL home (`--cd ~`).
const SCRIPT: &str = ".claude/klepsydra-launch.sh";
/// Longest wait for wsl.exe to finish.
#[cfg(windows)]
const TIMEOUT: Duration = Duration::from_secs(20);

/// Set while a call runs; a click meanwhile is refused.
#[derive(Default)]
pub struct InFlight(pub Mutex<bool>);

/// A session's tmux pane and the distro it runs in.
#[allow(dead_code)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub socket: String,
    pub pane: String,
    pub distro: String,
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

#[allow(dead_code)]
fn socket_ok(s: &str) -> bool {
    s.starts_with('/')
        && s.len() <= 256
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c))
}

#[allow(dead_code)]
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
#[allow(dead_code)]
pub fn jump_args(t: &Target) -> Result<Vec<String>, String> {
    if !(distro_ok(&t.distro) && socket_ok(&t.socket) && pane_ok(&t.pane)) {
        return Err("This session's tmux pane cannot be named safely.".into());
    }
    Ok([
        "-d", &t.distro, "--cd", "~", "-e", "bash", SCRIPT, "jump", &t.socket, &t.pane,
    ]
    .map(String::from)
    .to_vec())
}

/// Session `id`'s tmux pane and distro from a published snapshot.
#[allow(dead_code)]
pub fn target(snapshot: &Value, id: &str) -> Option<Target> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let tmux = s.get("tmux")?;
    Some(Target {
        socket: tmux.get("socket")?.as_str()?.into(),
        pane: tmux.get("pane")?.as_str()?.into(),
        distro: s.get("distro")?.as_str()?.into(),
    })
}

/// Run `f` unless another call is running.
pub fn gated<T>(flight: &InFlight, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    {
        let mut busy = flight
            .0
            .lock()
            .map_err(|_| "The launcher's lock was poisoned.")?;
        if *busy {
            return Err("A launch is already running.".into());
        }
        *busy = true;
    }
    let r = f();
    if let Ok(mut busy) = flight.0.lock() {
        *busy = false;
    }
    r
}

/// wsl.exe writes its own messages as UTF-16LE and the Linux side's as UTF-8.
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
fn last_line(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .unwrap_or("");
    line.chars().take(200).collect()
}

#[cfg(windows)]
fn run(args: &[String]) -> Result<String, String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::time::Instant;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut child = Command::new(WSL_EXE)
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start {WSL_EXE}: {e}"))?;
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                return Err("WSL did not answer within 20 seconds.".into());
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let (stdout, stderr) = (
        last_line(&decode(&out.stdout)),
        last_line(&decode(&out.stderr)),
    );
    if out.status.success() {
        Ok(stdout)
    } else if stderr.is_empty() {
        Err(if stdout.is_empty() {
            format!("wsl.exe exited with {}.", out.status)
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
#[allow(dead_code)]
pub fn tmux_jump(app: &tauri::AppHandle, t: &Target) -> Result<String, String> {
    let args = jump_args(t)?;
    gated(&app.state::<InFlight>(), || run(&args))
}

/// Start `claude` in the `launch_dir` pref as a window of the fleet session.
#[tauri::command]
pub async fn launch_session(app: tauri::AppHandle) -> Result<String, String> {
    let prefs = crate::read_prefs(&app).unwrap_or_default();
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
        };
        assert_eq!(
            jump_args(&ok).unwrap()[6..],
            [SCRIPT, "jump", "/tmp/tmux-1001/klepsydra", "%3"]
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
        ] {
            assert!(jump_args(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn target_needs_both_tmux_and_distro() {
        let s = json!({"sessions": [
            {"session_id": "a", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu"},
            {"session_id": "b", "tmux": {"socket": "/s", "pane": "%1"}, "distro": null},
            {"session_id": "c", "tmux": null, "distro": "Ubuntu"}]});
        assert_eq!(target(&s, "a").unwrap().pane, "%1");
        assert!(target(&s, "b").is_none());
        assert!(target(&s, "c").is_none());
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
}
