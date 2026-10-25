//! Jump to terminal: select a Windows Terminal tab and bring its window to the
//! front, through UI Automation, an in-process API. The tab is titled with the
//! session's name, or exactly `FLEET_TAB` for a session in the launcher's
//! tmux. Which tab is decided by `klepsydra_fleet::tabs`, tested everywhere.

use klepsydra_fleet::tabs::{Lookup, TabError};

/// Why the tab step did nothing: no tab could be chosen, or UI Automation
/// itself failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum JumpError {
    Tab(TabError),
    Failed(String),
}

impl From<TabError> for JumpError {
    fn from(e: TabError) -> Self {
        JumpError::Tab(e)
    }
}

impl std::fmt::Display for JumpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JumpError::Tab(e) => e.fmt(f),
            JumpError::Failed(why) => f.write_str(why),
        }
    }
}

/// The outcome in a sentence for the card: Ok when the session's window or
/// tab was selected, Err when nothing was done. A session in tmux has its
/// window selected first, then the fleet tab, titled `FLEET_TAB`, is brought up
/// when the session is on the launcher's tmux server, else the session's own
/// tab. `dispatch` decides which.
#[tauri::command]
pub async fn jump_to_terminal(
    app: tauri::AppHandle,
    id: String,
    name: String,
) -> Result<String, String> {
    use tauri::Manager;
    let target = app
        .state::<crate::fleet::Fleet>()
        .with_latest(|v| crate::launch::target(v, &id))
        .flatten();
    tauri::async_runtime::spawn_blocking(move || {
        let tmux = match target {
            Some(t) => Tmux::of(&t, crate::launch::tmux_jump(&app, &t)),
            None => Tmux::None,
        };
        dispatch(tmux, &name, jump)
    })
    .await
    .map_err(|e| format!("Could not run the jump: {e}"))?
}

/// The tmux jump's result, by the server the session runs on.
#[derive(Debug, PartialEq, Eq)]
enum Tmux {
    /// The session is in no tmux the snapshot knows of.
    None,
    /// The launcher's own server, whose tab is titled `FLEET_TAB`.
    Fleet(Result<String, String>),
    /// A tmux started by hand.
    Other(Result<String, String>),
}

impl Tmux {
    fn of(t: &crate::launch::Target, result: Result<String, String>) -> Self {
        if crate::launch::is_fleet(t) {
            Tmux::Fleet(result)
        } else {
            Tmux::Other(result)
        }
    }
}

/// The card's result. A failed jump on the fleet's server says why (the
/// launcher's own line) and searches no tab; on any other server, or with no
/// tmux, the session's own tab is looked up by its name.
fn dispatch<'a>(
    tmux: Tmux,
    name: &'a str,
    tab: impl FnOnce(Lookup<'a>) -> Result<String, JumpError>,
) -> Result<String, String> {
    match tmux {
        Tmux::Fleet(Err(why)) => Err(why),
        Tmux::Fleet(Ok(_)) => settle(true, tab(Lookup::Exact(crate::launch::FLEET_TAB))),
        Tmux::Other(Ok(_)) => settle(true, tab(Lookup::Session(name))),
        Tmux::Other(Err(_)) | Tmux::None => settle(false, tab(Lookup::Session(name))),
    }
}

/// Whether the one tab among `titles` is the fleet's, by `FLEET_TAB`.
#[cfg(test)]
fn fleet_tab(titles: &[&str]) -> Result<usize, TabError> {
    let t: Vec<String> = titles.iter().map(|s| s.to_string()).collect();
    klepsydra_fleet::tabs::pick(Lookup::Exact(crate::launch::FLEET_TAB), &t, false)
}

/// A selected tmux window is a success when no tab matched: a hand-renamed
/// tab keeps its frozen title with the right window active inside. Hidden
/// tabs, two matching tabs and a UI Automation failure still reach the card.
fn settle(tmux_ok: bool, title_result: Result<String, JumpError>) -> Result<String, String> {
    match title_result {
        Ok(said) => Ok(said),
        Err(JumpError::Tab(TabError::NoMatch(_) | TabError::NoName)) if tmux_ok => {
            Ok("Selected the session's tmux window.".into())
        }
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(not(windows))]
fn jump(_lookup: Lookup<'_>) -> Result<String, JumpError> {
    Err(JumpError::Failed(
        "Jump to terminal works on Windows only.".into(),
    ))
}

#[cfg(windows)]
fn jump(lookup: Lookup<'_>) -> Result<String, JumpError> {
    uia::jump(lookup)
}

#[cfg(windows)]
pub(crate) use uia::TERMINAL_CLASS;

/// The handle of the Windows Terminal window holding the fleet tab, for split
/// mode. It only finds the window: no tab is selected and nothing moves.
#[cfg(windows)]
pub(crate) fn fleet_window() -> Result<isize, JumpError> {
    uia::window(Lookup::Exact(crate::launch::FLEET_TAB))
}

#[cfg(windows)]
mod uia {
    use super::JumpError;
    use klepsydra_fleet::tabs::{pick, Lookup};
    use windows::core::{Interface, BSTR};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Variant::VARIANT;
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationElement,
        IUIAutomationSelectionItemPattern, TreeScope_Children, TreeScope_Descendants,
        UIA_ClassNamePropertyId, UIA_ControlTypePropertyId, UIA_SelectionItemPatternId,
        UIA_TabItemControlTypeId,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        FlashWindowEx, IsIconic, SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL,
        FLASHW_TIMERNOFG, SW_RESTORE,
    };

    /// Windows Terminal's top-level window class.
    pub const TERMINAL_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";
    /// Longest (ms) UI Automation waits to reach a provider; its default is 2000.
    const CONNECTION_TIMEOUT_MS: u32 = 1000;
    /// Longest (ms) UI Automation waits for one call to a provider to finish.
    const TRANSACTION_TIMEOUT_MS: u32 = 3000;

    /// Balances a CoInitializeEx that succeeded on this thread.
    struct Com;

    impl Drop for Com {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    struct Tab {
        window: IUIAutomationElement,
        item: IUIAutomationElement,
        title: String,
    }

    /// Every Windows Terminal tab with its title, and whether some Terminal
    /// window exposed no tab at all (full screen or focus mode).
    fn tabs(uia: &IUIAutomation) -> windows::core::Result<(Vec<Tab>, bool)> {
        let mut out = Vec::new();
        let mut hidden = false;
        unsafe {
            let terminal = uia.CreatePropertyCondition(
                UIA_ClassNamePropertyId,
                &VARIANT::from(BSTR::from(TERMINAL_CLASS)),
            )?;
            let tab_item = uia.CreatePropertyCondition(
                UIA_ControlTypePropertyId,
                &VARIANT::from(UIA_TabItemControlTypeId.0),
            )?;
            let windows = uia
                .GetRootElement()?
                .FindAll(TreeScope_Children, &terminal)?;
            for i in 0..windows.Length()? {
                let window = windows.GetElement(i)?;
                let items = window.FindAll(TreeScope_Descendants, &tab_item)?;
                hidden |= items.Length()? == 0;
                for j in 0..items.Length()? {
                    let item = items.GetElement(j)?;
                    let title = item.CurrentName()?.to_string();
                    out.push(Tab {
                        window: window.clone(),
                        item,
                        title,
                    });
                }
            }
        }
        Ok((out, hidden))
    }

    fn forward(hwnd: HWND, title: &str) -> String {
        unsafe {
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
            if SetForegroundWindow(hwnd).as_bool() {
                return format!("Jumped to \u{201c}{title}\u{201d}.");
            }
            let flash = FLASHWINFO {
                cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                hwnd,
                dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                uCount: 0,
                dwTimeout: 0,
            };
            let _ = FlashWindowEx(&flash);
        }
        "Windows kept the focus, so the terminal\u{2019}s taskbar button is flashing.".into()
    }

    /// A UI Automation call's failure, said with what was being done.
    fn failed(doing: &'static str) -> impl FnOnce(windows::core::Error) -> JumpError {
        move |e| JumpError::Failed(format!("{doing}: {e}"))
    }

    /// Run `then` on the one tab `lookup` picks, with UI Automation up.
    fn with_tab<R>(
        lookup: Lookup<'_>,
        then: impl FnOnce(&Tab) -> Result<R, JumpError>,
    ) -> Result<R, JumpError> {
        lookup.check()?;
        let _com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .is_ok()
            .then_some(Com);
        let uia: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) }
                .or_else(|_| unsafe {
                    CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                })
                .map_err(failed("Could not start UI Automation"))?;
        if let Ok(uia2) = uia.cast::<IUIAutomation2>() {
            unsafe {
                let _ = uia2.SetConnectionTimeout(CONNECTION_TIMEOUT_MS);
                let _ = uia2.SetTransactionTimeout(TRANSACTION_TIMEOUT_MS);
            }
        }
        let (tabs, hidden) =
            tabs(&uia).map_err(failed("Could not list Windows Terminal windows"))?;
        let titles: Vec<String> = tabs.iter().map(|t| t.title.clone()).collect();
        then(&tabs[pick(lookup, &titles, hidden)?])
    }

    fn window_of(tab: &Tab) -> Result<HWND, JumpError> {
        unsafe { tab.window.CurrentNativeWindowHandle() }
            .map_err(failed("Could not find the terminal window"))
    }

    /// The window holding the tab `lookup` picks, as an integer handle.
    pub fn window(lookup: Lookup<'_>) -> Result<isize, JumpError> {
        with_tab(lookup, |tab| Ok(window_of(tab)?.0 as isize))
    }

    pub fn jump(lookup: Lookup<'_>) -> Result<String, JumpError> {
        with_tab(lookup, |tab| {
            let hwnd = window_of(tab)?;
            select(tab)?;
            Ok(forward(hwnd, &tab.title))
        })
    }

    fn select(tab: &Tab) -> Result<(), JumpError> {
        unsafe {
            let select: IUIAutomationSelectionItemPattern = tab
                .item
                .GetCurrentPatternAs(UIA_SelectionItemPatternId)
                .map_err(failed("Could not select the tab"))?;
            select.Select().map_err(failed("Could not select the tab"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{dispatch, fleet_tab, settle, JumpError, Tmux};
    use crate::launch::{Target, FLEET_TAB};
    use klepsydra_fleet::tabs::{many_tabs, no_tab, Lookup, TabError, HIDDEN_TABS};

    #[test]
    fn only_the_exact_fleet_title_matches() {
        assert_eq!(fleet_tab(&["pwsh", "klepsydra sessions", "x"]), Ok(1));
        assert!(fleet_tab(&["klepsydra session", "klepsydra", "sessions"]).is_err());
        assert!(fleet_tab(&["klepsydra sessions", "klepsydra sessions"]).is_err());
        assert!(
            fleet_tab(&["\u{2733} klepsydra sessions"]).is_err(),
            "a hand-opened session named klepsydra sessions is not the fleet tab"
        );
        assert_eq!(
            fleet_tab(&["\u{2733} klepsydra sessions", "klepsydra sessions"]),
            Ok(1)
        );
    }

    #[test]
    fn a_matched_tab_keeps_its_message() {
        assert_eq!(settle(true, Ok("Jumped.".into())), Ok("Jumped.".into()));
        assert_eq!(settle(false, Ok("Jumped.".into())), Ok("Jumped.".into()));
    }

    #[test]
    fn a_selected_window_without_a_matching_tab_is_a_success() {
        let selected = Ok("Selected the session's tmux window.".into());
        assert_eq!(
            settle(true, Err(TabError::NoMatch("x".into()).into())),
            selected
        );
        assert_eq!(settle(true, Err(TabError::NoName.into())), selected);
    }

    #[test]
    fn a_real_failure_after_tmux_still_reaches_the_card() {
        assert_eq!(
            settle(true, Err(TabError::Hidden.into())),
            Err(HIDDEN_TABS.into())
        );
        assert_eq!(
            settle(true, Err(TabError::Many("x".into(), 2).into())),
            Err(many_tabs("x", 2))
        );
        let uia = "Could not start UI Automation: x";
        assert_eq!(
            settle(true, Err(JumpError::Failed(uia.into()))),
            Err(uia.into())
        );
    }

    #[test]
    fn without_tmux_the_title_error_stands() {
        assert_eq!(
            settle(false, Err(TabError::NoMatch("x".into()).into())),
            Err(no_tab("x"))
        );
        assert_eq!(
            settle(false, Err(TabError::NoName.into())),
            Err("This session has no name yet.".into())
        );
    }

    /// The card's result for a tmux outcome and a fixed tab-step result, and
    /// the lookup the tab step was asked for, if it ran.
    fn run(
        tmux: Tmux,
        tab: Result<String, JumpError>,
    ) -> (Result<String, String>, Option<Lookup<'static>>) {
        let mut asked = None;
        let out = dispatch(tmux, "my session", |l| {
            asked = Some(l);
            tab
        });
        (out, asked)
    }

    #[test]
    fn a_failed_fleet_jump_says_why_and_searches_no_tab() {
        for why in [
            "That session's tmux pane now belongs to another session.",
            "A launch is already running.",
        ] {
            let (out, asked) = run(Tmux::Fleet(Err(why.into())), Ok("Jumped.".into()));
            assert_eq!(out, Err(why.into()));
            assert_eq!(asked, None);
        }
    }

    #[test]
    fn a_fleet_jump_brings_up_the_fleet_tab_by_its_exact_title() {
        let (out, asked) = run(Tmux::Fleet(Ok("x".into())), Ok("Jumped.".into()));
        assert_eq!(
            (out, asked),
            (Ok("Jumped.".into()), Some(Lookup::Exact(FLEET_TAB)))
        );
        let (out, _) = run(
            Tmux::Fleet(Ok("x".into())),
            Err(TabError::NoMatch(FLEET_TAB.into()).into()),
        );
        assert_eq!(out, Ok("Selected the session's tmux window.".into()));
        let (out, _) = run(Tmux::Fleet(Ok("x".into())), Err(TabError::Hidden.into()));
        assert_eq!(out, Err(HIDDEN_TABS.into()));
    }

    #[test]
    fn another_socket_falls_back_to_the_session_title() {
        let none = Err(TabError::NoMatch("my session".into()).into());
        let (out, asked) = run(Tmux::Other(Ok("x".into())), none.clone());
        assert_eq!(
            (out, asked),
            (
                Ok("Selected the session's tmux window.".into()),
                Some(Lookup::Session("my session"))
            )
        );
        let (out, asked) = run(Tmux::Other(Err("tmux failed".into())), none.clone());
        assert_eq!(
            (out, asked),
            (
                Err(no_tab("my session")),
                Some(Lookup::Session("my session"))
            )
        );
        let (out, asked) = run(Tmux::None, Ok("Jumped.".into()));
        assert_eq!(
            (out, asked),
            (Ok("Jumped.".into()), Some(Lookup::Session("my session")))
        );
        let (out, _) = run(Tmux::None, none);
        assert_eq!(out, Err(no_tab("my session")));
    }

    #[test]
    fn the_socket_decides_the_kind() {
        let t = |socket: &str| Target {
            socket: socket.into(),
            pane: "%1".into(),
            distro: "Ubuntu".into(),
            pid: 1,
            start: 1,
        };
        assert_eq!(
            Tmux::of(&t("/tmp/tmux-1/klepsydra"), Ok("x".into())),
            Tmux::Fleet(Ok("x".into()))
        );
        assert_eq!(
            Tmux::of(&t("/tmp/tmux-1/default"), Err("y".into())),
            Tmux::Other(Err("y".into()))
        );
    }
}
