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
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Variant::{VARIANT, VT_I4};
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationSelectionItemPattern,
        TreeScope_Children, TreeScope_Descendants, UIA_ControlTypePropertyId,
        UIA_SelectionItemPatternId, UIA_TabItemControlTypeId,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        FlashWindowEx, IsIconic, SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL,
        FLASHW_TIMERNOFG, SW_RESTORE,
    };

    /// Windows Terminal's top-level window class.
    const TERMINAL_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";

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

    fn i4(value: i32) -> VARIANT {
        let mut v = VARIANT::default();
        unsafe {
            (*v.Anonymous.Anonymous).vt = VT_I4;
            (*v.Anonymous.Anonymous).Anonymous.lVal = value;
        }
        v
    }

    /// Every tab of every Windows Terminal window, with its title.
    fn tabs(uia: &IUIAutomation) -> windows::core::Result<Vec<Tab>> {
        let mut out = Vec::new();
        unsafe {
            let any = uia.CreateTrueCondition()?;
            let tab_item = uia.CreatePropertyCondition(
                UIA_ControlTypePropertyId,
                &i4(UIA_TabItemControlTypeId.0),
            )?;
            let windows = uia.GetRootElement()?.FindAll(TreeScope_Children, &any)?;
            for i in 0..windows.Length()? {
                let window = windows.GetElement(i)?;
                if window.CurrentClassName()? != TERMINAL_CLASS {
                    continue;
                }
                let items = window.FindAll(TreeScope_Descendants, &tab_item)?;
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
        Ok(out)
    }

    pub fn jump(name: &str) -> Result<String, String> {
        let _com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .is_ok()
            .then_some(Com);
        let uia: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
                .map_err(|e| e.to_string())?;
        let tabs = tabs(&uia).map_err(|e| e.to_string())?;
        let titles: Vec<String> = tabs.iter().map(|t| t.title.clone()).collect();
        let tab = match match_tab(name, &titles) {
            TabMatch::None => return Err(no_tab(name)),
            TabMatch::Many(n) => return Err(many_tabs(name, n)),
            TabMatch::One(i) => &tabs[i],
        };
        unsafe {
            let select: IUIAutomationSelectionItemPattern = tab
                .item
                .GetCurrentPatternAs(UIA_SelectionItemPatternId)
                .map_err(|e| e.to_string())?;
            select.Select().map_err(|e| e.to_string())?;
            let hwnd = tab
                .window
                .CurrentNativeWindowHandle()
                .map_err(|e| e.to_string())?;
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
            if SetForegroundWindow(hwnd).as_bool() {
                return Ok(format!("Jumped to \u{201c}{}\u{201d}.", tab.title));
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
        Ok("Windows kept the focus, so the terminal\u{2019}s taskbar button is flashing.".into())
    }
}
