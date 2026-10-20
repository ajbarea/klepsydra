//! Jump to terminal: select a Windows Terminal tab and bring its window to the
//! front, through UI Automation, an in-process API. The tab is titled with the
//! session's name, or `FLEET_TAB` for a session in the launcher's tmux. Which
//! tab is decided by `klepsydra_fleet::tabs`, tested everywhere.

/// The outcome in a sentence for the card: Ok when the session's window or
/// tab was selected, Err when nothing was done. A session in tmux has its
/// window selected first, then the fleet tab, titled `FLEET_TAB`, is brought up
/// when the session is on the launcher's tmux server, else the session's own tab.
#[tauri::command]
pub async fn jump_to_terminal(
    app: tauri::AppHandle,
    id: String,
    name: String,
) -> Result<String, String> {
    use tauri::Manager;
    let target = app
        .state::<crate::fleet::Fleet>()
        .latest()
        .and_then(|v| crate::launch::target(&v, &id));
    tauri::async_runtime::spawn_blocking(move || match target {
        Some(t) if crate::launch::tmux_jump(&app, &t).is_ok() => {
            settle(true, jump(tab_title(&t, &name)))
        }
        _ => jump(&name),
    })
    .await
    .map_err(|e| format!("Could not run the jump: {e}"))?
}

/// The title of the tab that shows `t`'s session.
fn tab_title<'a>(t: &crate::launch::Target, name: &'a str) -> &'a str {
    if crate::launch::is_fleet(t) {
        crate::launch::FLEET_TAB
    } else {
        name
    }
}

/// Whether the one tab among `titles` is the fleet's, by `FLEET_TAB`.
#[cfg(test)]
fn fleet_tab(titles: &[&str]) -> Result<usize, String> {
    let t: Vec<String> = titles.iter().map(|s| s.to_string()).collect();
    klepsydra_fleet::tabs::pick_tab(crate::launch::FLEET_TAB, &t, false)
}

/// A selected tmux window is a success even when no tab title matches: a
/// hand-renamed tab keeps its frozen title with the right window active inside.
fn settle(tmux_ok: bool, title_result: Result<String, String>) -> Result<String, String> {
    match title_result {
        Err(_) if tmux_ok => Ok("Selected the session's tmux window.".into()),
        other => other,
    }
}

#[cfg(not(windows))]
fn jump(_name: &str) -> Result<String, String> {
    Err("Jump to terminal works on Windows only.".into())
}

#[cfg(windows)]
fn jump(name: &str) -> Result<String, String> {
    uia::jump(name)
}

#[cfg(windows)]
mod uia {
    use klepsydra_fleet::tabs::pick_tab;
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
    const TERMINAL_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";
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

    pub fn jump(name: &str) -> Result<String, String> {
        let name = name.trim();
        if name.is_empty() {
            return Err("This session has no name yet.".into());
        }
        let _com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .is_ok()
            .then_some(Com);
        let uia: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) }
                .or_else(|_| unsafe {
                    CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                })
                .map_err(|e| format!("Could not start UI Automation: {e}"))?;
        if let Ok(uia2) = uia.cast::<IUIAutomation2>() {
            unsafe {
                let _ = uia2.SetConnectionTimeout(CONNECTION_TIMEOUT_MS);
                let _ = uia2.SetTransactionTimeout(TRANSACTION_TIMEOUT_MS);
            }
        }
        let (tabs, hidden) =
            tabs(&uia).map_err(|e| format!("Could not list Windows Terminal windows: {e}"))?;
        let titles: Vec<String> = tabs.iter().map(|t| t.title.clone()).collect();
        let tab = &tabs[pick_tab(name, &titles, hidden)?];
        let hwnd = unsafe { tab.window.CurrentNativeWindowHandle() }
            .map_err(|e| format!("Could not find the terminal window: {e}"))?;
        unsafe {
            let select: IUIAutomationSelectionItemPattern = tab
                .item
                .GetCurrentPatternAs(UIA_SelectionItemPatternId)
                .map_err(|e| format!("Could not select the tab: {e}"))?;
            select
                .Select()
                .map_err(|e| format!("Could not select the tab: {e}"))?;
        }
        Ok(forward(hwnd, &tab.title))
    }
}

#[cfg(test)]
mod tests {
    use super::{fleet_tab, settle, tab_title};
    use crate::launch::{Target, FLEET_TAB};

    #[test]
    fn a_hand_started_tmux_is_found_by_the_session_name() {
        let t = |socket: &str| Target {
            socket: socket.into(),
            pane: "%1".into(),
            distro: "Ubuntu".into(),
            pid: 1,
            start: 1,
        };
        assert_eq!(
            tab_title(&t("/tmp/tmux-1/klepsydra"), "my session"),
            FLEET_TAB
        );
        assert_eq!(
            tab_title(&t("/tmp/tmux-1/default"), "my session"),
            "my session"
        );
    }

    #[test]
    fn only_the_exact_fleet_title_matches() {
        assert_eq!(fleet_tab(&["pwsh", "klepsydra fleet", "x"]), Ok(1));
        assert!(fleet_tab(&["klepsydra fleets", "klepsydra", "fleet"]).is_err());
        assert!(fleet_tab(&["klepsydra fleet", "klepsydra fleet"]).is_err());
    }

    #[test]
    fn a_matched_tab_keeps_its_message() {
        assert_eq!(settle(true, Ok("Jumped.".into())), Ok("Jumped.".into()));
        assert_eq!(settle(false, Ok("Jumped.".into())), Ok("Jumped.".into()));
    }

    #[test]
    fn a_selected_window_without_a_matching_tab_is_a_success() {
        assert_eq!(
            settle(true, Err("No tab.".into())),
            Ok("Selected the session's tmux window.".into())
        );
    }

    #[test]
    fn without_tmux_the_title_error_stands() {
        assert_eq!(settle(false, Err("No tab.".into())), Err("No tab.".into()));
    }
}
