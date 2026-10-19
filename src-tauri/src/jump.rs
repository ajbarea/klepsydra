//! Jump to terminal: select the Windows Terminal tab titled with a session's
//! name and bring its window to the front, through UI Automation, an
//! in-process API. Which tab is decided by `klepsydra_fleet::tabs`, tested everywhere.

/// The outcome in a sentence for the card: Ok when the tab was selected,
/// Err when nothing was done.
#[tauri::command]
pub async fn jump_to_terminal(name: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || jump(&name))
        .await
        .map_err(|e| e.to_string())?
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
    use klepsydra_fleet::tabs::{many_tabs, match_tab, no_tab, TabMatch};
    use windows::core::{Interface, BSTR};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Variant::VARIANT;
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomation2, IUIAutomationElement,
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
    /// UI Automation waits this long (ms) to reach a provider and to finish a call.
    const CONNECTION_TIMEOUT_MS: u32 = 2000;
    const TRANSACTION_TIMEOUT_MS: u32 = 3000;

    /// Balances a CoInitializeEx that succeeded on this thread.
    struct Com;

    impl Drop for Com {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    /// A candidate title: a tab to select, or a window whose tab row is hidden.
    struct Tab {
        window: IUIAutomationElement,
        item: Option<IUIAutomationElement>,
        title: String,
    }

    /// Every Windows Terminal tab, with its title; a window showing no tab row
    /// stands for its single session under its own title.
    fn tabs(uia: &IUIAutomation) -> windows::core::Result<Vec<Tab>> {
        let mut out = Vec::new();
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
                if items.Length()? == 0 {
                    let title = window.CurrentName()?.to_string();
                    out.push(Tab {
                        window,
                        item: None,
                        title,
                    });
                    continue;
                }
                for j in 0..items.Length()? {
                    let item = items.GetElement(j)?;
                    let title = item.CurrentName()?.to_string();
                    out.push(Tab {
                        window: window.clone(),
                        item: Some(item),
                        title,
                    });
                }
            }
        }
        Ok(out)
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
            unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
                .map_err(|e| format!("Could not start UI Automation: {e}"))?;
        if let Ok(uia2) = uia.cast::<IUIAutomation2>() {
            unsafe {
                let _ = uia2.SetConnectionTimeout(CONNECTION_TIMEOUT_MS);
                let _ = uia2.SetTransactionTimeout(TRANSACTION_TIMEOUT_MS);
            }
        }
        let tabs =
            tabs(&uia).map_err(|e| format!("Could not list Windows Terminal windows: {e}"))?;
        let titles: Vec<String> = tabs.iter().map(|t| t.title.clone()).collect();
        let tab = match match_tab(name, &titles) {
            TabMatch::None => return Err(no_tab(name)),
            TabMatch::Many(n) => return Err(many_tabs(name, n)),
            TabMatch::One(i) => &tabs[i],
        };
        let hwnd = unsafe { tab.window.CurrentNativeWindowHandle() }
            .map_err(|e| format!("Could not find the terminal window: {e}"))?;
        if let Some(item) = &tab.item {
            unsafe {
                let select: IUIAutomationSelectionItemPattern = item
                    .GetCurrentPatternAs(UIA_SelectionItemPatternId)
                    .map_err(|e| format!("Could not select the tab: {e}"))?;
                select
                    .Select()
                    .map_err(|e| format!("Could not select the tab: {e}"))?;
            }
        }
        Ok(forward(hwnd, &tab.title))
    }
}
