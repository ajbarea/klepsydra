//! The one place klepsydra starts a process: wsl.exe, from a click, running
//! ~/.claude/klepsydra-launch.sh to start a session, bring a session's tmux
//! window forward, or end or interrupt it. Each call is logged.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;

use serde_json::Value;
use tauri::Manager;

/// The only program klepsydra starts on Windows.
#[cfg_attr(not(windows), allow(dead_code))]
pub const WSL_EXE: &str = r"C:\Windows\System32\wsl.exe";
/// The shell used on Linux to run scripts.
#[cfg_attr(windows, allow(dead_code))]
pub const LINUX_EXE: &str = "/bin/bash";
/// The launcher, relative to the WSL home (`--cd ~`).
const SCRIPT: &str = ".claude/klepsydra-launch.sh";
/// Longest wait for wsl.exe to finish: a cold WSL start alone can take 20 s.
const TIMEOUT: Duration = Duration::from_secs(45);
/// Longest wait for `fleet voices`: two keryx calls of up to 120 s each (a new
/// keryx's first run syncs its environment). Behind another run's lock it can
/// take longer; the run goes on, and the next resume pass applies what it misses.
const VOICES_TIMEOUT: Duration = Duration::from_secs(300);
/// Longest wait for a Jump, whose session already runs in a started WSL: long
/// enough for a refused interop connection to report its own error.
const JUMP_TIMEOUT: Duration = Duration::from_secs(15);
/// How long the output is still read once wsl.exe exits; a process it left
/// behind holding the pipe open cannot keep the call running past this.
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// Set while a New session runs; another meanwhile is refused.
#[derive(Default)]
pub struct InFlight(pub Mutex<bool>);

/// Sessions with a call of one kind running.
#[derive(Default)]
struct Keyed(Mutex<HashSet<String>>);

/// The sessions whose pane has an End or Interrupt running. Those two verbs
/// are per-session: another session, Jump and New session run independently.
#[derive(Default)]
pub struct PaneFlight(Keyed);

/// The sessions with a Jump running. A second Jump of that card is refused;
/// another card, New session, End and Interrupt run independently.
#[derive(Default)]
pub struct JumpFlight(Keyed);

/// The title of the Windows Terminal tab the launcher opens; the script's
/// `TAB_TITLE` is the same text, which a guard test asserts.
pub const FLEET_TAB: &str = "klepsydra sessions";

/// The launcher's tmux socket name; the script's default is the same text,
/// which a guard test asserts.
pub const FLEET_SOCKET: &str = "klepsydra";

/// A session's tmux pane, the Claude process that must still be in it, and the
/// distro they run in (none on native Linux). `start` is `/proc/<pid>/stat` field 22.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub socket: String,
    pub pane: String,
    pub distro: Option<String>,
    pub pid: u32,
    pub start: u64,
}

fn distro_ok(d: &str) -> bool {
    (1..=64).contains(&d.len())
        && d.chars()
            .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// Whether this build runs the launcher itself rather than through wsl.exe.
/// The wall gets it with each snapshot (fleet.rs `for_wall`).
pub const NATIVE: bool = cfg!(not(windows));

/// Session `s`'s distro as its record has it, on a native Linux build
/// (`native`) or through wsl.exe: the inner None on native Linux, which has
/// no WSL_DISTRO_NAME; the outer None through wsl.exe, where a record without
/// one names no session klepsydra can reach. The wall's `paneKnown` (end.js)
/// judges the same way.
pub fn session_distro(s: &Value, native: bool) -> Option<Option<String>> {
    let distro = s.get("distro").and_then(Value::as_str).map(String::from);
    (distro.is_some() || native).then_some(distro)
}

/// wsl.exe's `-d DISTRO` for a session's `distro`, the one check every call
/// on a session's behalf makes. Through wsl.exe a plain name is required; on
/// native Linux (`native`) a record has none, and the words are dropped.
/// None when the distro cannot be used.
fn distro_words(distro: Option<&str>, native: bool) -> Option<Vec<String>> {
    match distro {
        Some(d) if distro_ok(d) => Some(vec!["-d".into(), d.into()]),
        None if native => Some(Vec::new()),
        _ => None,
    }
}

/// An agy model id as `agy models` names them (#323): the launcher checks it
/// again before it reaches a shell.
fn model_ok(m: &str) -> bool {
    (1..=64).contains(&m.len())
        && m.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && m.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || ".-".contains(c))
}

fn voice_ok(v: &str) -> bool {
    (1..=128).contains(&v.len())
        && v.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "+()._".contains(c))
        && v.split('+').all(|part| {
            let name = part.split('(').next().unwrap_or("");
            !name.is_empty()
                && name
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        })
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

/// wsl.exe's arguments to make keryx follow the Voices mode just saved (#273):
/// the launcher runs the installed `fleet voices`, which reads prefs.json.
pub fn voices_args() -> Vec<String> {
    ["--cd", "~", "-e", "bash", "-l", SCRIPT, "voices"]
        .map(String::from)
        .to_vec()
}

/// One `fleet voices` at a time: it reads the mode saved when it runs, so
/// changes made while one runs (a held arrow key on Settings' Voices row)
/// fold into one more run.
static VOICES_RUN: klepsydra_fleet::coalesce::Coalesce = klepsydra_fleet::coalesce::Coalesce::new();

/// Make keryx follow the saved Voices mode now, off the caller's thread, logged
/// like every call. The resume service applies a changed mode as well.
pub fn apply_voices() {
    if !VOICES_RUN.ask() {
        return;
    }
    let args = voices_args();
    tauri::async_runtime::spawn_blocking(move || {
        VOICES_RUN.serve("voices", || {
            let _ = logged("voices", None, || run(&args, VOICES_TIMEOUT, timed_out));
        });
    });
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
    let distro = distro_words(t.distro.as_deref(), NATIVE);
    let Some(mut args) = distro.filter(|_| socket_ok(&t.socket) && pane_ok(&t.pane) && t.pid != 0)
    else {
        return Err("This session's tmux pane cannot be named safely.".into());
    };
    if verb != PaneVerb::Jump && !is_fleet(t) {
        return Err(NOT_FLEET.into());
    }
    let (pid, start) = (t.pid.to_string(), t.start.to_string());
    args.extend(
        [
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
        .map(String::from),
    );
    Ok(args)
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
    target_on(snapshot, id, NATIVE)
}

/// `target` on a native Linux build (`native`) or through wsl.exe, where a
/// session without its distro has no pane klepsydra can reach and is found by
/// its tab instead.
fn target_on(snapshot: &Value, id: &str, native: bool) -> Option<Target> {
    let s = klepsydra_fleet::lookup::session(snapshot, id)?;
    let tmux = s.get("tmux")?;
    let claude = s.get("claude")?;
    let distro = session_distro(s, native)?;
    Some(Target {
        socket: tmux.get("socket")?.as_str()?.into(),
        pane: tmux.get("pane")?.as_str()?.into(),
        distro,
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

/// Frees session `id` in a `Keyed` when dropped, even while unwinding.
struct Release<'a>(&'a Keyed, String);

impl Drop for Release<'_> {
    fn drop(&mut self) {
        let mut busy = self.0 .0.lock().unwrap_or_else(|e| e.into_inner());
        busy.remove(&self.1);
    }
}

/// Run `f` unless `flight` already has a call of session `id` running.
fn keyed<T>(
    flight: &Keyed,
    id: &str,
    busy_said: &str,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    {
        let mut busy = flight.0.lock().unwrap_or_else(|e| e.into_inner());
        if !busy.insert(id.to_owned()) {
            return Err(busy_said.into());
        }
    }
    let _release = Release(flight, id.to_owned());
    f()
}

/// Run `f` unless an End or Interrupt of session `id` is already running.
pub fn pane_gated<T>(
    flight: &PaneFlight,
    id: &str,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    keyed(&flight.0, id, PANE_BUSY, f)
}

/// Run `f` unless a Jump of session `id` is already running.
pub fn jump_gated<T>(
    flight: &JumpFlight,
    id: &str,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    keyed(&flight.0, id, JUMP_BUSY, f)
}

const PANE_BUSY: &str = "That session is already being ended or interrupted.";
pub const JUMP_BUSY: &str = "That session is already being brought forward.";

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

/// The last non-blank line of `text`.
fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

/// The last non-blank line, capped at 200 characters for error messages.
fn error_line(text: &str) -> String {
    last_line(text).chars().take(200).collect()
}

/// Most output kept from each stream.
const KEEP: usize = 64 * 1024;

/// A stream being read on its own thread.
struct Drain {
    kept: std::sync::Arc<Mutex<Vec<u8>>>,
    done: std::sync::mpsc::Receiver<()>,
}

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

/// The card's line when a Jump gets no answer from WSL in `JUMP_TIMEOUT`.
fn jump_timed_out() -> String {
    format!(
        "WSL did not answer within {} seconds. The window may still come forward; if it does not, try again.",
        JUMP_TIMEOUT.as_secs()
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

/// The log's line for one call: its verb, how long it took and its outcome.
fn call_line(verb: &str, took: Duration, r: &Result<String, String>) -> String {
    let secs = took.as_secs_f64();
    match r {
        Ok(_) => format!("wsl {verb}: ok in {secs:.2} s"),
        Err(e) => format!("wsl {verb}: failed in {secs:.2} s: {e}"),
    }
}

/// A call's level: info when it worked; warn when WSL did not answer in
/// time, since the call may still land; error when it failed.
fn call_level(r: &Result<String, String>) -> log::Level {
    match r {
        Ok(_) => log::Level::Info,
        Err(e)
            if [
                timed_out(),
                jump_timed_out(),
                pane_timed_out(),
                wrapup_timed_out(),
            ]
            .contains(e) =>
        {
            log::Level::Warn
        }
        Err(_) => log::Level::Error,
    }
}

/// Run `f`, a call named `verb` for session `session` if it has one, and log
/// it with `call_line` at `call_level`.
fn logged<T>(
    verb: &str,
    session: Option<&str>,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    let started = std::time::Instant::now();
    let r = f();
    let said = r.as_ref().map(|_| String::new()).map_err(String::clone);
    let (level, line) = (call_level(&said), call_line(verb, started.elapsed(), &said));
    match session {
        Some(id) => log::log!(level, session_id = id; "{line}"),
        None => log::log!(level, "{line}"),
    }
    r
}

#[cfg(windows)]
fn run(args: &[String], wait: Duration, timed_out: fn() -> String) -> Result<String, String> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let child = Command::new(WSL_EXE)
        .args(args)
        .env("WSL_UTF8", "1")
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start {WSL_EXE}: {e}"))?;
    wait_child(child, "wsl.exe", wait, timed_out)
}

/// Wait for `child`, started with piped output, at most `wait`; its last
/// stdout line, or on failure its last stderr line, in the card's words.
fn wait_child(
    mut child: std::process::Child,
    name: &str,
    wait: Duration,
    timed_out: fn() -> String,
) -> Result<String, String> {
    let out = drain(
        child
            .stdout
            .take()
            .ok_or_else(|| format!("{name} gave no stdout."))?,
    );
    let err = drain(
        child
            .stderr
            .take()
            .ok_or_else(|| format!("{name} gave no stderr."))?,
    );
    let deadline = Instant::now() + wait;
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
    let (stdout_raw, stderr_raw) = (decode(&out.wait(until)), decode(&err.wait(until)));
    let (stdout, stderr) = (last_line(&stdout_raw), error_line(&stderr_raw));
    if status.success() {
        Ok(stdout)
    } else if stderr.is_empty() {
        let err = error_line(&stdout_raw);
        Err(if err.is_empty() {
            format!("{name} exited with {status}.")
        } else {
            err
        })
    } else {
        Err(stderr)
    }
}

/// The launcher's path on Linux: `$HOME/.claude/klepsydra-launch.sh`. An unset,
/// empty or relative HOME is refused, so the script is never looked up from
/// the working directory.
#[cfg(any(not(windows), test))]
fn linux_script(home: Option<&str>) -> Result<String, String> {
    match home {
        Some(h) if h.starts_with('/') => Ok(format!("{}/{SCRIPT}", h.trim_end_matches('/'))),
        _ => Err("HOME is not set to a folder, so the launcher cannot be found.".into()),
    }
}

/// bash's arguments on Linux for a launcher call given as wsl.exe's: the
/// words after the script are the launcher's own (`new DIR`, `jump ...`), and
/// `-l` stays where wsl.exe's `bash -l` had it.
#[cfg(any(not(windows), test))]
fn linux_argv(home: Option<&str>, args: &[String]) -> Result<Vec<String>, String> {
    let script = linux_script(home)?;
    let at = args
        .iter()
        .position(|a| a == SCRIPT)
        .ok_or("That is not a launcher call.")?;
    let mut argv: Vec<String> = Vec::new();
    if at > 0 && args[at - 1] == "-l" {
        argv.push("-l".into());
    }
    argv.push(script);
    argv.extend(args[at + 1..].iter().cloned());
    Ok(argv)
}

/// bash's arguments on Linux to hand `target` (a folder or a GitHub URL) to
/// the desktop through the launcher's `folder` or `github` verb.
#[cfg(any(not(windows), test))]
fn linux_open_argv(home: Option<&str>, verb: &str, target: &str) -> Result<Vec<String>, String> {
    Ok(vec![linux_script(home)?, verb.into(), target.into()])
}

#[cfg(not(windows))]
fn run_linux(argv: &[String], wait: Duration, timed_out: fn() -> String) -> Result<String, String> {
    use std::process::{Command, Stdio};
    let child = Command::new(LINUX_EXE)
        .args(argv)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start {LINUX_EXE}: {e}"))?;
    wait_child(child, "The launcher", wait, timed_out)
}

#[cfg(not(windows))]
fn run(args: &[String], wait: Duration, timed_out: fn() -> String) -> Result<String, String> {
    let argv = linux_argv(std::env::var("HOME").ok().as_deref(), args)?;
    run_linux(&argv, wait, timed_out)
}

/// Show `target` on the desktop: a folder (`verb` "folder") or a GitHub page
/// ("github"). `wsl` is the same call as wsl.exe's arguments, which end in
/// explorer.exe; that exits 1 even when it opened the target.
fn run_open(
    verb: &str,
    target: &str,
    wsl: &[String],
    wait: Duration,
    timed_out: fn() -> String,
) -> Result<String, String> {
    #[cfg(windows)]
    {
        let _ = (verb, target);
        explorer_opened(run(wsl, wait, timed_out))
    }
    #[cfg(not(windows))]
    {
        let _ = wsl;
        let argv = linux_open_argv(std::env::var("HOME").ok().as_deref(), verb, target)?;
        run_linux(&argv, wait, timed_out)
    }
}

/// Bring session `id`'s tmux window, `t`, to the front of its tmux session.
pub fn tmux_jump(app: &tauri::AppHandle, id: &str, t: &Target) -> Result<String, String> {
    let args = pane_args(t, PaneVerb::Jump)?;
    jump_with(&app.state::<JumpFlight>(), id, |wait, said| {
        logged(PaneVerb::Jump.word(), Some(id), || run(&args, wait, said))
    })
}

/// A Jump of session `id`: `call` runs under that card's gate alone, given
/// the Jump's wait and its timeout line.
fn jump_with<T>(
    jumps: &JumpFlight,
    id: &str,
    call: impl FnOnce(Duration, fn() -> String) -> Result<T, String>,
) -> Result<T, String> {
    jump_gated(jumps, id, || call(JUMP_TIMEOUT, jump_timed_out))
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
            logged(verb.word(), Some(&id), || {
                run(&args, TIMEOUT, pane_timed_out)
            })
        })
    })
    .await
    .map_err(|e| format!("Could not reach the session: {e}"))?
}

/// wsl.exe's arguments to show folder `dir` of `distro` in the file manager:
/// Explorer, started from WSL there (interop) through env, which finds it on
/// the login PATH (wsl.exe -e looks only on its relay's, without /mnt/c) and
/// fails (125) on a folder that is gone, where --cd would fall back to /.
/// Only the folder, one argument, comes from the session's record.
pub fn folder_args(dir: &str, distro: Option<&str>) -> Result<Vec<String>, String> {
    let Some(mut args) = distro_words(distro, NATIVE).filter(|_| crate::folder::plain_dir(dir))
    else {
        return Err("This session's folder cannot be named safely.".into());
    };
    args.extend(["--cd", "/", "-e", "env", "-C", dir, "explorer.exe", "."].map(String::from));
    Ok(args)
}

/// explorer.exe exits 1 even when it opened the folder: that status, with
/// nothing on stderr, is its success.
#[cfg_attr(not(windows), allow(dead_code))]
fn explorer_opened(said: Result<String, String>) -> Result<String, String> {
    match said {
        Err(e) if e == "wsl.exe exited with exit code: 1." => Ok(String::new()),
        other => other,
    }
}

const NO_FOLDER: &str = "klepsydra does not know this session's folder.";
const NO_PAGE: &str = "klepsydra does not know this session's GitHub page.";

/// Session `id`'s folder in `snapshot` and the arguments that open it, as
/// this build reaches it.
fn folder_request(snapshot: &Value, id: &str) -> Result<(String, Vec<String>), String> {
    let (dir, distro) = crate::folder::folder_of(snapshot, id, NATIVE).ok_or(NO_FOLDER)?;
    let args = folder_args(&dir, distro.as_deref())?;
    Ok((dir, args))
}

/// Session `id`'s GitHub page in `snapshot`, or with `branch` its branch's,
/// and the arguments that open it, as this build reaches it.
fn github_request(
    snapshot: &Value,
    id: &str,
    branch: bool,
) -> Result<(String, Vec<String>), String> {
    let (url, distro) = crate::folder::github_of(snapshot, id, branch, NATIVE).ok_or(NO_PAGE)?;
    let args = github_args(&url, distro.as_deref())?;
    Ok((url, args))
}

/// Show session `id`'s work folder in the file manager (#149).
#[tauri::command]
pub async fn open_folder(app: tauri::AppHandle, id: String) -> Result<String, String> {
    let (dir, args) = app
        .state::<crate::fleet::Fleet>()
        .with_latest(|v| folder_request(v, &id))
        .unwrap_or_else(|| Err(NO_FOLDER.into()))?;
    let shown = dir.rsplit('/').next().unwrap_or(&dir).to_string();
    tauri::async_runtime::spawn_blocking(move || {
        logged("open folder", Some(&id), || {
            run_open("folder", &dir, &args, JUMP_TIMEOUT, jump_timed_out)
        })
    })
    .await
    .map_err(|e| format!("Could not open the folder: {e}"))??;
    Ok(format!("Opened {shown}."))
}

/// wsl.exe's arguments that hand GitHub page `url` to Windows, whose
/// explorer.exe opens a URL in the default browser. Only an https
/// github.com address of plain and percent-encoded characters is passed.
pub fn github_args(url: &str, distro: Option<&str>) -> Result<Vec<String>, String> {
    let plain = url.len() <= 600
        && url.strip_prefix("https://github.com/").is_some_and(|rest| {
            !rest.is_empty()
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-._~%/!*'()".contains(&b))
        });
    let Some(mut args) = distro_words(distro, NATIVE).filter(|_| plain) else {
        return Err("This session's GitHub page cannot be named safely.".into());
    };
    args.extend(["--cd", "/", "-e", "env", "explorer.exe", url].map(String::from));
    Ok(args)
}

/// Open session `id`'s GitHub page, or with `branch` its branch's page, in
/// the default browser (#149): the wall's webview opens no new window.
#[tauri::command]
pub async fn open_github(
    app: tauri::AppHandle,
    id: String,
    branch: bool,
) -> Result<String, String> {
    let (url, args) = app
        .state::<crate::fleet::Fleet>()
        .with_latest(|v| github_request(v, &id, branch))
        .unwrap_or_else(|| Err(NO_PAGE.into()))?;
    tauri::async_runtime::spawn_blocking(move || {
        logged("open github", Some(&id), || {
            run_open("github", &url, &args, JUMP_TIMEOUT, jump_timed_out)
        })
    })
    .await
    .map_err(|e| format!("Could not open GitHub: {e}"))??;
    Ok(if branch {
        "Opened the branch on GitHub."
    } else {
        "Opened GitHub."
    }
    .into())
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
                logged(PaneVerb::Wrapup.word(), Some(id), || {
                    run(&args, TIMEOUT, wrapup_timed_out)
                })
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

/// The folder a launch starts in and wsl.exe's arguments for it: one check
/// for the empty state's label and the launch.
fn launch_plan(prefs: &Prefs) -> Result<(&str, Vec<String>), String> {
    let dir = launch_dir(prefs);
    let distro = prefs.get("launch_distro").and_then(Value::as_str);
    Ok((dir, new_args(dir, distro)?))
}

/// The folder a launch would start in, when prefs.json can be read and the
/// launch would run.
fn launch_dir_of(prefs: Option<&Prefs>) -> Option<String> {
    launch_plan(prefs?).ok().map(|(dir, _)| dir.to_owned())
}

/// The folder + New session starts in, for the wall's empty state. Reads only.
#[tauri::command]
pub async fn get_launch_dir(app: tauri::AppHandle) -> Option<String> {
    launch_dir_of(crate::read_prefs(&app).as_ref())
}

/// What + New session starts (#440): Claude on an account (on a model, or its
/// own default), agy on a model, or Copilot (on a model, or auto).
#[derive(Clone, Debug, PartialEq)]
pub enum Engine {
    Claude {
        account: String,
        model: Option<String>,
    },
    Agy(String),
    Copilot(Option<String>),
}

/// A Claude account id as the statusLine hook files it, or an engine's pref id
/// part: letters, digits and dashes, a letter or digit first.
fn account_ok(a: &str) -> bool {
    (1..=64).contains(&a.len())
        && a.starts_with(|c: char| c.is_ascii_alphanumeric())
        && a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

impl Engine {
    /// The wall's id for it, as prefs.json keeps the default and the last used:
    /// `claude:ACCOUNT`, `agy` or `copilot`.
    pub fn pref_id(&self) -> String {
        match self {
            Engine::Claude { account, .. } => format!("claude:{account}"),
            Engine::Agy(_) => "agy".into(),
            Engine::Copilot(_) => "copilot".into(),
        }
    }

    /// The launcher's arguments after `new DIR`.
    fn args(&self) -> Vec<String> {
        match self {
            Engine::Claude { account, model } => {
                let mut a = vec!["claude".to_owned(), account.clone()];
                a.extend(model.clone());
                a
            }
            Engine::Agy(m) => vec!["agy".into(), m.clone()],
            Engine::Copilot(m) => {
                let mut a = vec!["copilot".to_owned()];
                a.extend(m.clone());
                a
            }
        }
    }
}

/// Whether `id` names an engine as the wall saves it.
pub fn pref_id_ok(id: &str) -> bool {
    matches!(id, "agy" | "copilot") || id.strip_prefix("claude:").is_some_and(account_ok)
}

/// The engine a launch names, checked: `engine` with its `account` and `model`,
/// or the older call's `agy_model` alone; `None` is plain `claude` on the
/// server's account, as before.
fn engine_of(
    engine: Option<&str>,
    agy_model: Option<&str>,
    account: Option<&str>,
    model: Option<&str>,
) -> Result<Option<Engine>, String> {
    let checked = |m: &str, what: &str| {
        if model_ok(m) {
            Ok(m.to_owned())
        } else {
            Err(format!("That is not {what}: {m}"))
        }
    };
    let Some(name) = engine.or(agy_model.map(|_| "agy")) else {
        return Ok(None);
    };
    if agy_model.is_some() && name != "agy" {
        return Err(format!("An agy model does not start {name}."));
    }
    match name {
        "agy" => {
            let m = agy_model.or(model).ok_or("Antigravity needs a model.")?;
            Ok(Some(Engine::Agy(checked(m, "an agy model id")?)))
        }
        "claude" => {
            let a = account.ok_or("Claude needs an account.")?;
            if !account_ok(a) {
                return Err(format!("That is not a Claude account id: {a}"));
            }
            Ok(Some(Engine::Claude {
                account: a.to_owned(),
                model: model.map(|m| checked(m, "a Claude model")).transpose()?,
            }))
        }
        "copilot" => Ok(Some(Engine::Copilot(
            model
                .map(|m| checked(m, "a Copilot model id"))
                .transpose()?,
        ))),
        e => Err(format!("klepsydra does not start {e}.")),
    }
}

/// wsl.exe's arguments for a launch: `claude`, or `engine` (#323, #440), with
/// `keryx_voice` session-named voice (#389).
fn session_args(
    prefs: &Prefs,
    engine: Option<&Engine>,
    keryx_voice: Option<&str>,
) -> Result<Vec<String>, String> {
    let (_, mut args) = launch_plan(prefs)?;
    if let Some(v) = keryx_voice {
        if !voice_ok(v) {
            return Err(format!("That is not a keryx voice id: {v}"));
        }
        if let Some(pos) = args.iter().position(|x| x == "-e") {
            args.splice(pos + 1..pos + 1, ["env".into(), format!("KERYX_VOICE={v}")]);
        }
    }
    if let Some(e) = engine {
        args.extend(e.args());
    }
    Ok(args)
}

/// "in 2 h 14 min" / "in 9 min" until `at`, from `now` (unix seconds).
fn wait_words(at: i64, now: i64) -> String {
    let mins = (at - now + 59) / 60;
    if mins >= 60 {
        format!("in {} h {} min", mins / 60, mins % 60)
    } else {
        format!("in {} min", mins.max(1))
    }
}

/// The refusal for a Claude account whose newest reading is spent, so a menu
/// drawn before it ran out starts nothing.
fn refuse_spent(readings: &[Value], engine: Option<&Engine>, now: i64) -> Result<(), String> {
    if let Some(Engine::Claude { account, .. }) = engine {
        if let Some(at) = klepsydra_fleet::usage::spent_until(readings, account, now) {
            return Err(format!(
                "Not started: that Claude account is out of its limit; it comes back {}.",
                wait_words(at, now)
            ));
        }
    }
    Ok(())
}

/// prefs.json's key for the engine + New session last started (#440).
pub const LAST_ENGINE: &str = "new_session_last";
/// prefs.json's key for the engine the user set as + New session's default.
pub const DEFAULT_ENGINE: &str = "new_session_default";

/// Start `claude`, or `engine` (Claude on `account` and `model`, agy on
/// `model` or the older `agy_model`, Copilot on `model`), in the `launch_dir`
/// pref as a window of the fleet session. A launch the wall names its engine
/// for is remembered as the last used.
#[tauri::command]
pub async fn launch_session(
    app: tauri::AppHandle,
    agy_model: Option<String>,
    keryx_voice: Option<String>,
    engine: Option<String>,
    account: Option<String>,
    model: Option<String>,
) -> Result<String, String> {
    let prefs = crate::read_prefs(&app)
        .ok_or("prefs.json could not be read, so the launch folder is unknown.")?;
    let engine = engine_of(
        engine.as_deref(),
        agy_model.as_deref(),
        account.as_deref(),
        model.as_deref(),
    )?;
    let args = session_args(&prefs, engine.as_ref(), keryx_voice.as_deref())?;
    if matches!(engine, Some(Engine::Claude { .. })) {
        let readings = klepsydra_fleet::usage::read(crate::usage_dirs(&app));
        refuse_spent(
            &readings,
            engine.as_ref(),
            klepsydra_fleet::watch::unix_now(),
        )?;
    }
    let started = tauri::async_runtime::spawn_blocking({
        let app = app.clone();
        move || {
            gated(&app.state::<InFlight>(), || {
                logged("launch", None, || run(&args, TIMEOUT, timed_out))
            })
        }
    })
    .await
    .map_err(|e| format!("Could not run the launch: {e}"))??;
    if let Some(e) = &engine {
        crate::write_pref(&app, LAST_ENGINE, Value::String(e.pref_id()));
    }
    Ok(started)
}

/// + New session's saved choices: the user's default and the engine last
/// started from the wall, each an engine id or null.
#[tauri::command]
pub fn new_session_prefs(app: tauri::AppHandle) -> Value {
    let prefs = crate::read_prefs(&app).unwrap_or_default();
    let id = |k: &str| {
        prefs
            .get(k)
            .and_then(Value::as_str)
            .filter(|id| pref_id_ok(id))
            .map(|id| Value::String(id.to_owned()))
            .unwrap_or(Value::Null)
    };
    serde_json::json!({ "default": id(DEFAULT_ENGINE), "last": id(LAST_ENGINE) })
}

/// Ok when prefs.json took the write, else the words the wall shows.
fn saved_or_say(saved: bool) -> Result<(), String> {
    if saved {
        Ok(())
    } else {
        Err("prefs.json could not be saved, so the default is not kept.".to_string())
    }
}

/// Save `id` as + New session's default, or with none go back to the last used.
#[tauri::command]
pub fn set_new_session_default(app: tauri::AppHandle, id: Option<String>) -> Result<(), String> {
    match id {
        Some(id) if !pref_id_ok(&id) => Err(format!("That is not an engine: {id}")),
        Some(id) => saved_or_say(crate::write_pref(&app, DEFAULT_ENGINE, Value::String(id))),
        None => saved_or_say(crate::write_pref(&app, DEFAULT_ENGINE, Value::Null)),
    }
}

/// Which engines can start here (#440): the Claude accounts with a login in a
/// config folder, and whether agy and Copilot are on PATH.
#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Debug, Default)]
pub struct Engines {
    pub claude: Vec<String>,
    pub agy: bool,
    pub copilot: bool,
}

fn parse_engines(line: &str) -> Result<Engines, String> {
    let mut e: Engines = serde_json::from_str(line)
        .map_err(|e| format!("The launcher's engine list could not be read: {e}"))?;
    e.claude.retain(|a| account_ok(a));
    Ok(e)
}

/// wsl.exe's arguments for one of the launcher's own lists, in the launch's distro.
fn list_args(prefs: Option<&Prefs>, what: &str) -> Vec<String> {
    let mut a: Vec<String> = Vec::new();
    if let Some(d) = prefs
        .and_then(|p| p.get("launch_distro"))
        .and_then(Value::as_str)
        .filter(|d| distro_ok(d))
    {
        a.extend(["-d".into(), d.into()]);
    }
    a.extend(["--cd", "~", "-e", "bash", "-l", SCRIPT, what].map(String::from));
    a
}

/// Which engines can start here, asked each time (an engine installed or
/// signed in since shows at once); the wall asks on load and on opening its menu.
#[tauri::command]
pub async fn engines_status(app: tauri::AppHandle) -> Result<Engines, String> {
    let args = list_args(crate::read_prefs(&app).as_ref(), "engines");
    tauri::async_runtime::spawn_blocking(move || {
        logged("engines", None, || {
            run(&args, TIMEOUT, timed_out).and_then(|l| parse_engines(&l))
        })
    })
    .await
    .map_err(|e| format!("Could not ask which engines are here: {e}"))?
}

/// agy's models, asked of the launcher once and kept for the app's run: the
/// wall's New session menu offers them (#323).
#[derive(Default)]
pub struct AgyModels(Mutex<Option<Vec<AgyModel>>>);

#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Debug)]
pub struct AgyModel {
    pub id: String,
    pub label: String,
    /// Its quota group as agy's /quota names it (`gemini`, `3p`), which says
    /// which usage windows bind it; none when agy did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
}

/// The models in the launcher's one line of JSON, the ones that are ids.
fn parse_models(line: &str) -> Result<Vec<AgyModel>, String> {
    let all: Vec<AgyModel> =
        serde_json::from_str(line).map_err(|e| format!("agy's models could not be read: {e}"))?;
    let ok: Vec<AgyModel> = all.into_iter().filter(|m| model_ok(&m.id)).collect();
    if ok.is_empty() {
        return Err("agy listed no models.".into());
    }
    Ok(ok)
}

/// wsl.exe's arguments to list agy's models, in the launch's distro.
fn models_args(prefs: Option<&Prefs>) -> Vec<String> {
    list_args(prefs, "models")
}

/// agy's models (a failure is not kept, so the next ask tries again).
#[tauri::command]
pub async fn agy_models(app: tauri::AppHandle) -> Result<Vec<AgyModel>, String> {
    if let Some(kept) = app
        .state::<AgyModels>()
        .0
        .lock()
        .ok()
        .and_then(|k| k.clone())
    {
        return Ok(kept);
    }
    let args = models_args(crate::read_prefs(&app).as_ref());
    let got = tauri::async_runtime::spawn_blocking(move || {
        logged("agy models", None, || {
            run(&args, TIMEOUT, timed_out).and_then(|l| parse_models(&l))
        })
    })
    .await
    .map_err(|e| format!("Could not ask agy for its models: {e}"))??;
    if let Ok(mut k) = app.state::<AgyModels>().0.lock() {
        *k = Some(got.clone());
    }
    Ok(got)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_default_prefs_json_refused_is_an_error_the_wall_shows() {
        assert_eq!(saved_or_say(true), Ok(()));
        let err = saved_or_say(false).unwrap_err();
        assert!(err.contains("could not be saved"), "{err}");
    }
    use serde_json::json;
    use std::time::Instant;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn linux_runs_the_launcher_by_the_home_path_with_its_own_words() {
        let home = Some("/home/aj");
        let new = new_args("~/my repos;x", Some("Ubuntu")).unwrap();
        assert_eq!(
            linux_argv(home, &new).unwrap(),
            s(&[
                "-l",
                "/home/aj/.claude/klepsydra-launch.sh",
                "new",
                "~/my repos;x"
            ])
        );
        assert_eq!(
            linux_argv(home, &voices_args()).unwrap(),
            s(&["-l", "/home/aj/.claude/klepsydra-launch.sh", "voices"])
        );
        let ok = Target {
            distro: Some("Ubuntu".into()),
            socket: "/tmp/tmux-1001/klepsydra".into(),
            pane: "%3".into(),
            pid: 42,
            start: 7,
        };
        assert_eq!(
            linux_argv(home, &pane_args(&ok, PaneVerb::Jump).unwrap()).unwrap(),
            s(&[
                "/home/aj/.claude/klepsydra-launch.sh",
                "jump",
                "/tmp/tmux-1001/klepsydra",
                "%3",
                "42",
                "7"
            ])
        );
        assert_eq!(
            linux_argv(Some("/home/aj/"), &models_args(None)).unwrap(),
            s(&["-l", "/home/aj/.claude/klepsydra-launch.sh", "models"])
        );
    }

    #[test]
    fn linux_refuses_a_home_it_cannot_trust_and_a_call_that_is_not_the_launcher() {
        let args = voices_args();
        for home in [None, Some(""), Some("."), Some("home/aj")] {
            assert!(linux_argv(home, &args).is_err(), "{home:?}");
            assert!(linux_open_argv(home, "folder", "/x").is_err(), "{home:?}");
        }
        assert!(linux_argv(Some("/home/aj"), &s(&["-e", "explorer.exe", "."])).is_err());
    }

    #[test]
    fn linux_hands_a_folder_or_a_page_to_the_launcher_as_one_argument() {
        assert_eq!(
            linux_open_argv(Some("/home/aj"), "folder", "/home/aj/my repos").unwrap(),
            s(&[
                "/home/aj/.claude/klepsydra-launch.sh",
                "folder",
                "/home/aj/my repos"
            ])
        );
        assert_eq!(
            linux_open_argv(Some("/home/aj"), "github", "https://github.com/a/b").unwrap(),
            s(&[
                "/home/aj/.claude/klepsydra-launch.sh",
                "github",
                "https://github.com/a/b"
            ])
        );
    }

    /// The Linux spawn itself (wait_child under /bin/bash): its last stdout
    /// line on success, its stderr on failure, the timeout line past `wait`.
    #[cfg(unix)]
    #[test]
    fn linux_run_reports_the_launchers_line_its_failure_and_a_timeout() {
        let dir = std::env::temp_dir().join(format!("klepsydra-run-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("l.sh");
        let body = "case $1 in ok) echo noise; echo fine;; bad) echo why >&2; exit 1;; slow) sleep 5;; esac\n";
        std::fs::write(&script, body).unwrap();
        let go = |word: &str, wait: u64| {
            let argv = [script.display().to_string(), word.to_string()];
            run_linux(&argv, Duration::from_secs(wait), timed_out)
        };
        assert_eq!(go("ok", 5), Ok("fine".to_string()));
        assert_eq!(go("bad", 5), Err("why".to_string()));
        assert_eq!(go("slow", 1), Err(timed_out()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

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
    fn the_label_names_a_folder_only_when_the_launch_would_run() {
        let prefs = |v: Value| v.as_object().cloned().unwrap();
        let bad = prefs(json!({"launch_dir": "/home/aj", "launch_distro": "Ubuntu 24.04"}));
        assert_eq!(
            launch_dir_of(Some(&bad)),
            None,
            "a distro wsl.exe would refuse"
        );
        let good = prefs(json!({"launch_dir": "/home/aj", "launch_distro": "Ubuntu-24.04"}));
        assert_eq!(launch_dir_of(Some(&good)).as_deref(), Some("/home/aj"));
    }

    #[test]
    fn an_agy_launch_names_its_model_and_refuses_one_that_is_no_id() {
        let prefs = json!({"launch_dir": "/home/aj"})
            .as_object()
            .cloned()
            .unwrap();
        let agy = engine_of(None, Some("gemini-3.8-flash-high"), None, None).unwrap();
        let a = session_args(&prefs, agy.as_ref(), None).unwrap();
        assert_eq!(
            &a[a.len() - 4..],
            ["new", "/home/aj", "agy", "gemini-3.8-flash-high"]
        );
        assert_eq!(
            session_args(&prefs, None, None)
                .unwrap()
                .last()
                .map(String::as_str),
            Some("/home/aj")
        );
        for bad in ["", "Gemini", "x;rm", "-x", "a b", &"a".repeat(65)] {
            assert!(engine_of(None, Some(bad), None, None).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_launch_with_a_voice_sets_keryx_voice_and_refuses_a_bad_voice_id() {
        let prefs = json!({"launch_dir": "/home/aj"})
            .as_object()
            .cloned()
            .unwrap();
        let a = session_args(&prefs, None, Some("am_michael")).unwrap();
        let pos = a.iter().position(|x| x == "-e").unwrap();
        assert_eq!(
            &a[pos..pos + 5],
            ["-e", "env", "KERYX_VOICE=am_michael", "bash", "-l"]
        );
        let blend = session_args(&prefs, None, Some("af_bella(0.7)+af_heart(0.3)")).unwrap();
        let bpos = blend.iter().position(|x| x == "-e").unwrap();
        assert_eq!(
            &blend[bpos..bpos + 3],
            ["-e", "env", "KERYX_VOICE=af_bella(0.7)+af_heart(0.3)"]
        );
        for bad in ["", "Michael", "am_michael;rm", "x\n", &"a".repeat(129)] {
            assert!(session_args(&prefs, None, Some(bad)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn agys_models_keep_only_ids_and_an_empty_list_is_an_error() {
        let got = parse_models(r#"[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)"},{"id":"bad;id","label":"x"}]"#).unwrap();
        assert_eq!(
            got,
            [AgyModel {
                id: "gemini-3.8-flash-high".into(),
                label: "Gemini 3.8 Flash (High)".into(),
                group: None,
            }]
        );
        assert!(parse_models("[]").is_err());
        assert!(parse_models("not json").is_err());
        assert_eq!(models_args(None).last().map(String::as_str), Some("models"));
    }

    #[test]
    fn agy_models_parses_real_fleet_models_longer_than_200_chars() {
        let json = r#"[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)"},{"id":"gemini-3.8-flash-medium","label":"Gemini 3.8 Flash (Medium)"},{"id":"gemini-3.8-flash-low","label":"Gemini 3.8 Flash (Low)"},{"id":"claude-sonnet-4-6","label":"Claude Sonnet 4.6 (Thinking)"},{"id":"claude-opus-4-6-thinking","label":"Claude Opus 4.6 (Thinking)"},{"id":"gpt-oss-120b-medium","label":"GPT-OSS 120B (Medium)"}]"#;
        assert!(json.len() > 200);
        let got = parse_models(&last_line(json)).unwrap();
        assert_eq!(got.len(), 6);
        assert_eq!(got[0].id, "gemini-3.8-flash-high");
        assert_eq!(got[5].id, "gpt-oss-120b-medium");
    }

    #[test]
    fn agys_models_keep_their_quota_group() {
        let got = parse_models(r#"[{"id":"claude-sonnet-4-6","label":"Claude Sonnet 4.6 (Thinking)","group":"3p","spent":"2026-11-19T13:24:14Z"}]"#).unwrap();
        assert_eq!(got[0].group.as_deref(), Some("3p"));
        let back = serde_json::to_value(&got).unwrap();
        assert_eq!(
            back[0].get("spent"),
            None,
            "a spent time is not kept: the readings say it"
        );
    }

    #[test]
    fn each_engine_reaches_the_launcher_as_its_own_arguments() {
        let prefs = json!({"launch_dir": "/home/aj"})
            .as_object()
            .cloned()
            .unwrap();
        let tail = |e: Option<Engine>| {
            let a = session_args(&prefs, e.as_ref(), None).unwrap();
            let at = a.iter().position(|x| x == "new").unwrap();
            a[at + 2..].to_vec()
        };
        let acct = "96130a18-106b-49a2-9b8e-a0b4d52aa214";
        assert_eq!(
            tail(engine_of(Some("claude"), None, Some(acct), Some("opus")).unwrap()),
            ["claude", acct, "opus"]
        );
        assert_eq!(
            tail(engine_of(Some("claude"), None, Some(acct), None).unwrap()),
            ["claude", acct]
        );
        assert_eq!(
            tail(engine_of(Some("copilot"), None, None, None).unwrap()),
            ["copilot"]
        );
        assert_eq!(
            tail(engine_of(Some("copilot"), None, None, Some("gpt-5.6-sol")).unwrap()),
            ["copilot", "gpt-5.6-sol"]
        );
        assert_eq!(
            tail(engine_of(Some("agy"), None, None, Some("gemini-3.8-flash-low")).unwrap()),
            ["agy", "gemini-3.8-flash-low"]
        );
        assert!(
            tail(engine_of(None, None, None, None).unwrap()).is_empty(),
            "plain claude, as before"
        );
        for (engine, agy, account, model) in [
            (Some("claude"), None, None, None),
            (Some("claude"), None, Some("../x"), None),
            (Some("claude"), None, Some("-a"), None),
            (Some("claude"), None, Some(acct), Some("opus;id")),
            (Some("copilot"), None, None, Some("A B")),
            (Some("agy"), None, None, None),
            (Some("codex"), None, None, None),
            (
                Some("claude"),
                Some("gemini-3.8-flash-low"),
                Some(acct),
                None,
            ),
        ] {
            assert!(
                engine_of(engine, agy, account, model).is_err(),
                "{engine:?} {agy:?} {account:?} {model:?}"
            );
        }
    }

    #[test]
    fn the_wall_saves_only_an_engine_id() {
        let e = engine_of(Some("claude"), None, Some("6f5fe38b-9f23"), None)
            .unwrap()
            .unwrap();
        assert_eq!(e.pref_id(), "claude:6f5fe38b-9f23");
        assert!(pref_id_ok(&e.pref_id()));
        for ok in ["agy", "copilot", "claude:abc-1"] {
            assert!(pref_id_ok(ok), "{ok}");
        }
        for bad in [
            "",
            "claude",
            "claude:",
            "claude:../x",
            "codex",
            "agy ",
            "claude:a;b",
        ] {
            assert!(!pref_id_ok(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_engine_list_keeps_only_account_ids() {
        let e = parse_engines(r#"{"claude":["6f5fe38b-9f23-4588-b57a-6efd1225cadd","bad;id"],"agy":true,"copilot":false}"#).unwrap();
        assert_eq!(e.claude, ["6f5fe38b-9f23-4588-b57a-6efd1225cadd"]);
        assert!(e.agy && !e.copilot);
        assert!(parse_engines("not json").is_err());
        assert_eq!(
            list_args(None, "engines").last().map(String::as_str),
            Some("engines")
        );
    }

    #[test]
    fn a_spent_claude_account_is_refused_with_when_it_comes_back() {
        let acct = "96130a18";
        let readings = [json!({"account": acct, "observed_at": 100, "windows": {
            "five_hour": {"used_percentage": 100, "resets_at": 1_000 + 2 * 3600 + 14 * 60}}})];
        let claude = engine_of(Some("claude"), None, Some(acct), None).unwrap();
        assert_eq!(
            refuse_spent(&readings, claude.as_ref(), 1_000),
            Err("Not started: that Claude account is out of its limit; it comes back in 2 h 14 min.".into())
        );
        assert_eq!(
            refuse_spent(&readings, claude.as_ref(), 1_000 + 3 * 3600),
            Ok(()),
            "reset since"
        );
        let other = engine_of(Some("claude"), None, Some("6f5fe38b"), None).unwrap();
        assert_eq!(refuse_spent(&readings, other.as_ref(), 1_000), Ok(()));
        let agy = engine_of(Some("agy"), None, None, Some("gemini-3.8-flash-low")).unwrap();
        assert_eq!(
            refuse_spent(&readings, agy.as_ref(), 1_000),
            Ok(()),
            "agy's own launcher check"
        );
        assert_eq!(wait_words(1_030, 1_000), "in 1 min");
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
            distro: Some("Ubuntu".into()),
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
                distro: Some("a;b".into()),
                ..ok.clone()
            },
            Target {
                distro: Some("".into()),
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
            distro: Some("Ubuntu".into()),
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
            distro: Some("Ubuntu".into()),
            pid: 1,
            start: 1,
        };
        assert!(is_fleet(&t("/tmp/tmux-1001/klepsydra")));
        assert!(!is_fleet(&t("/tmp/tmux-1001/default")));
        assert!(!is_fleet(&t("/tmp/klepsydra/default")));
        assert!(!is_fleet(&t("/tmp/tmux-1001/klepsydra2")));
    }

    #[test]
    fn a_folder_opens_through_wsl_with_only_its_path_from_the_record() {
        assert_eq!(
            folder_args("/home/aj/ajsoftworks/cv", Some("Ubuntu")).unwrap(),
            [
                "-d",
                "Ubuntu",
                "--cd",
                "/",
                "-e",
                "env",
                "-C",
                "/home/aj/ajsoftworks/cv",
                "explorer.exe",
                "."
            ]
        );
        assert!(
            explorer_opened(Err(
                "env: cannot change directory to '/gone': No such file or directory".into()
            ))
            .is_err(),
            "a folder that is gone is said, not opened"
        );
        assert_eq!(
            explorer_opened(Err("wsl.exe exited with exit code: 1.".into())),
            Ok(String::new())
        );
        assert!(explorer_opened(Err("wsl.exe exited with exit code: 2.".into())).is_err());
        assert!(explorer_opened(Err("Could not start wsl.exe".into())).is_err());
        assert!(folder_args("/home/aj/../x", Some("Ubuntu")).is_err());
        assert!(folder_args("/home/aj", Some("Ubuntu;rm")).is_err());
        assert!(folder_args("/home/aj/../x", None).is_err());
    }

    #[test]
    fn voices_runs_the_launcher_with_no_mode() {
        assert_eq!(
            voices_args(),
            ["--cd", "~", "-e", "bash", "-l", SCRIPT, "voices"]
        );
    }

    #[test]
    fn a_github_page_opens_through_wsl_and_only_a_plain_github_address() {
        let page = "https://github.com/ajbarea/klepsydra/tree/feat/a%20b%231";
        assert_eq!(
            github_args(page, Some("Ubuntu")).unwrap(),
            [
                "-d",
                "Ubuntu",
                "--cd",
                "/",
                "-e",
                "env",
                "explorer.exe",
                page
            ]
        );
        for bad in [
            "https://github.com/",
            "http://github.com/a/b",
            "https://github.com.evil.example/a/b",
            "https://github.com/a/b?x=1",
            "https://github.com/a/b c",
            "https://github.com/a/b\"&calc",
            "file:///C:/Windows",
        ] {
            assert!(github_args(bad, Some("Ubuntu")).is_err(), "{bad}");
            assert!(github_args(bad, None).is_err(), "{bad}");
        }
        assert!(github_args("https://github.com/a/b", Some("Ubuntu;rm")).is_err());
    }

    #[test]
    fn target_needs_tmux_and_claude_and_keeps_the_distro_on_record() {
        let c = json!({"pid": 7, "start": 99});
        let s = json!({"sessions": [
            {"session_id": "a", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu", "claude": c},
            {"session_id": "b", "tmux": {"socket": "/s", "pane": "%1"}, "distro": null, "claude": c},
            {"session_id": "c", "tmux": null, "distro": "Ubuntu", "claude": c},
            {"session_id": "d", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu", "claude": null},
            {"session_id": "e", "tmux": {"socket": "/s", "pane": "%1"}, "distro": "Ubuntu"}]});
        let t = target(&s, "a").unwrap();
        assert_eq!((t.pane.as_str(), t.pid, t.start), ("%1", 7, 99));
        assert_eq!(t.distro.as_deref(), Some("Ubuntu"));
        assert_eq!(
            target_on(&s, "b", true).unwrap().distro,
            None,
            "native Linux records none"
        );
        assert_eq!(
            target_on(&s, "b", false),
            None,
            "through wsl.exe it is found by its tab instead"
        );
        for id in ["c", "d", "e"] {
            assert!(target(&s, id).is_none(), "{id}");
        }
    }

    #[test]
    fn the_distro_is_required_through_wsl_and_dropped_on_native_linux() {
        for native in [false, true] {
            assert_eq!(
                distro_words(Some("Ubuntu"), native),
                Some(vec!["-d".to_string(), "Ubuntu".to_string()])
            );
            for bad in ["", "a;b", "Ubuntu 24.04", "a/b"] {
                assert_eq!(distro_words(Some(bad), native), None, "{bad:?} {native}");
            }
        }
        assert_eq!(distro_words(None, false), None, "wsl.exe needs a distro");
        assert_eq!(distro_words(None, true), Some(Vec::new()));
    }

    /// A session on native Linux as its hook writes it (#460), with no
    /// distro: every card action reaches the launcher there, and each is
    /// refused through wsl.exe, which needs one.
    #[test]
    fn a_native_linux_session_reaches_every_card_action() {
        let snap = json!({"sessions": [{
            "session_id": "n",
            "distro": null,
            "tmux": {"socket": "/tmp/tmux-1001/klepsydra", "pane": "%1"},
            "claude": {"pid": 68991, "start": 127674},
            "where": {"repo": "klepsydra", "dir": "/home/aj/ajsoftworks/klepsydra",
                      "github": "https://github.com/ajbarea/klepsydra", "branch": "main"}}]});
        let t = target_on(&snap, "n", true).expect("a native session has a tmux target");
        for verb in [PaneVerb::Jump, PaneVerb::End, PaneVerb::Interrupt] {
            let args = pane_args(&t, verb);
            assert_eq!(args.is_ok(), NATIVE, "{verb:?}");
            if let Ok(args) = args {
                assert_eq!(
                    linux_argv(Some("/home/aj"), &args).unwrap(),
                    [
                        "/home/aj/.claude/klepsydra-launch.sh",
                        verb.word(),
                        "/tmp/tmux-1001/klepsydra",
                        "%1",
                        "68991",
                        "127674"
                    ]
                );
            }
        }
        let (dir, distro) = crate::folder::folder_of(&snap, "n", true).expect("its folder");
        assert_eq!(folder_args(&dir, distro.as_deref()).is_ok(), NATIVE);
        for branch in [false, true] {
            let (url, distro) =
                crate::folder::github_of(&snap, "n", branch, true).expect("its page");
            assert_eq!(
                github_args(&url, distro.as_deref()).is_ok(),
                NATIVE,
                "{branch}"
            );
        }
    }

    /// What Folder and GitHub answer for a session with no distro, as this
    /// build reads the snapshot: opened on native Linux, not known through
    /// wsl.exe.
    #[test]
    fn folder_and_github_read_the_snapshot_as_this_build_reaches_it() {
        let snap = json!({"sessions": [{
            "session_id": "n",
            "distro": null,
            "where": {"repo": "klepsydra", "dir": "/home/aj/ajsoftworks/klepsydra",
                      "github": "https://github.com/ajbarea/klepsydra", "branch": "main"}}]});
        let folder = folder_request(&snap, "n").map(|(dir, _)| dir);
        let page = github_request(&snap, "n", false).map(|(url, _)| url);
        let branch = github_request(&snap, "n", true).map(|(url, _)| url);
        if NATIVE {
            assert_eq!(folder, Ok("/home/aj/ajsoftworks/klepsydra".into()));
            assert_eq!(page, Ok("https://github.com/ajbarea/klepsydra".into()));
            assert_eq!(
                branch,
                Ok("https://github.com/ajbarea/klepsydra/tree/main".into())
            );
        } else {
            assert_eq!(folder, Err(NO_FOLDER.into()));
            assert_eq!(page, Err(NO_PAGE.into()));
            assert_eq!(branch, Err(NO_PAGE.into()));
        }
        assert_eq!(folder_request(&snap, "gone"), Err(NO_FOLDER.into()));
        assert_eq!(github_request(&snap, "gone", false), Err(NO_PAGE.into()));
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
    fn a_hung_jump_blocks_neither_another_card_nor_a_launch() {
        let (jumps, launch) = (
            std::sync::Arc::new(JumpFlight::default()),
            InFlight::default(),
        );
        let (held_tx, held) = std::sync::mpsc::channel();
        let (free, free_rx) = std::sync::mpsc::channel::<()>();
        let hung = {
            let jumps = std::sync::Arc::clone(&jumps);
            std::thread::spawn(move || {
                jump_gated(&jumps, "a", || {
                    held_tx.send(()).unwrap();
                    free_rx.recv().unwrap();
                    Ok(())
                })
            })
        };
        held.recv().unwrap();
        assert!(
            jump_gated(&jumps, "b", || Ok(())).is_ok(),
            "another card jumps"
        );
        assert!(gated(&launch, || Ok(())).is_ok(), "New session runs");
        let again = jump_gated(&jumps, "a", || Ok(()));
        assert_eq!(again, Err(JUMP_BUSY.into()));
        assert!(!JUMP_BUSY.contains("launch"), "{JUMP_BUSY}");
        free.send(()).unwrap();
        assert!(hung.join().unwrap().is_ok());
        assert!(
            jump_gated(&jumps, "a", || Ok(())).is_ok(),
            "the card reopens"
        );
    }

    #[test]
    fn a_jump_runs_under_its_card_alone_with_the_jump_wait() {
        let (jumps, launch) = (JumpFlight::default(), InFlight::default());
        let r = gated(&launch, || {
            jump_with(&jumps, "a", |wait, said| Ok((wait, said())))
        });
        assert_eq!(r, Ok((JUMP_TIMEOUT, jump_timed_out())));
        let again = jump_with(&jumps, "a", |_, _| jump_with(&jumps, "a", |_, _| Ok(())));
        assert_eq!(again, Err(JUMP_BUSY.into()));
    }

    #[test]
    fn a_jump_neither_holds_nor_waits_for_an_end_of_its_session() {
        let (jumps, panes) = (JumpFlight::default(), PaneFlight::default());
        assert!(jump_gated(&jumps, "a", || pane_gated(&panes, "a", || Ok(()))).is_ok());
        assert!(pane_gated(&panes, "a", || jump_gated(&jumps, "a", || Ok(()))).is_ok());
    }

    #[test]
    fn a_jump_gives_up_past_a_failed_interop_call_and_well_before_a_launch() {
        // A refused WSL interop connection takes about 10 s to fail.
        assert!(JUMP_TIMEOUT > Duration::from_secs(10), "{JUMP_TIMEOUT:?}");
        assert!(JUMP_TIMEOUT * 2 < TIMEOUT, "{JUMP_TIMEOUT:?}");
        assert_eq!(
            jump_timed_out(),
            "WSL did not answer within 15 seconds. The window may still come forward; if it does not, try again."
        );
    }

    #[test]
    fn each_call_logs_its_verb_time_and_outcome() {
        let ms = Duration::from_millis;
        assert_eq!(
            call_line("jump", ms(420), &Ok("x".into())),
            "wsl jump: ok in 0.42 s"
        );
        assert_eq!(
            call_line("launch", ms(15_003), &Err("WSL did not answer.".into())),
            "wsl launch: failed in 15.00 s: WSL did not answer."
        );
    }

    #[test]
    fn a_call_logs_info_when_it_worked_warn_when_wsl_was_late_and_error_when_it_failed() {
        assert_eq!(call_level(&Ok("x".into())), log::Level::Info);
        for late in [
            timed_out(),
            jump_timed_out(),
            pane_timed_out(),
            wrapup_timed_out(),
        ] {
            assert_eq!(call_level(&Err(late.clone())), log::Level::Warn, "{late}");
        }
        for failed in [
            "Could not start C:\\Windows\\System32\\wsl.exe: access denied",
            "wsl.exe exited with exit code: 1.",
            "WSL did not answer.",
        ] {
            assert_eq!(
                call_level(&Err(failed.into())),
                log::Level::Error,
                "{failed}"
            );
        }
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
        assert_eq!(last_line(&"x".repeat(300)).len(), 300);
        assert_eq!(error_line(&"x".repeat(300)).len(), 200);
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
