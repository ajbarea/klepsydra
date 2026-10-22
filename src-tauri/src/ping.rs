//! The tray's Ping: a short cue when a session needs AJ or finishes, played
//! here rather than in a webview so it sounds with the wall closed and no
//! autoplay gate applies.

use std::sync::atomic::{AtomicBool, Ordering};

use klepsydra_fleet::cue::Cue;

const NEEDS_YOU: &[u8] = include_bytes!("../sounds/needs-you.wav");
const DONE: &[u8] = include_bytes!("../sounds/done.wav");

fn wav(cue: Cue) -> &'static [u8] {
    match cue {
        Cue::NeedsYou => NEEDS_YOU,
        Cue::Done => DONE,
    }
}

/// Whether Ping is on, as the tray last set it.
static ON: AtomicBool = AtomicBool::new(false);

fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

pub fn set(on: bool) {
    ON.store(on, Ordering::Relaxed);
}

/// Play `cue` if Ping is on and the desktop is not quiet.
pub fn cue(cue: Cue) {
    if !on() {
        return;
    }
    #[cfg(windows)]
    if !win::do_not_disturb() && !win::full_screen() {
        win::play(wav(cue));
    }
    #[cfg(target_os = "linux")]
    if !linux::full_screen() {
        linux::play(wav(cue));
    }
}

/// Play `cue` whatever the desktop says: AJ just asked to hear it.
pub fn preview(cue: Cue) {
    #[cfg(windows)]
    win::play(wav(cue));
    #[cfg(target_os = "linux")]
    linux::play(wav(cue));
}

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::{c_char, c_void, CString};
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};

    type CaContext = c_void;
    type CaCreate = unsafe extern "C" fn(*mut *mut CaContext) -> i32;
    type CaOpen = unsafe extern "C" fn(*mut CaContext) -> i32;
    type CaPlay = unsafe extern "C" fn(*mut CaContext, u32, ...) -> i32;
    type CaDestroy = unsafe extern "C" fn(*mut CaContext) -> i32;

    unsafe extern "C" {
        fn dlopen(filename: *const c_char, flags: i32) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
        fn dlclose(handle: *mut c_void) -> i32;
        fn getpid() -> i32;
    }

    struct Canberra {
        _handle: *mut c_void,
        create: CaCreate,
        open: CaOpen,
        play: CaPlay,
        destroy: CaDestroy,
    }

    // SAFETY: pointers are dynamically loaded function pointers and dlopen handle
    unsafe impl Send for Canberra {}
    unsafe impl Sync for Canberra {}

    static CANBERRA: OnceLock<Option<Canberra>> = OnceLock::new();
    static FILES: Mutex<Option<(PathBuf, PathBuf)>> = Mutex::new(None);

    fn get_canberra() -> Option<&'static Canberra> {
        CANBERRA
            .get_or_init(|| unsafe {
                let lib_name = CString::new("libcanberra.so.0").ok()?;
                let handle = dlopen(lib_name.as_ptr(), 1); // RTLD_LAZY = 1
                if handle.is_null() {
                    None
                } else {
                    let c_create = CString::new("ca_context_create").ok()?;
                    let c_open = CString::new("ca_context_open").ok()?;
                    let c_play = CString::new("ca_context_play").ok()?;
                    let c_destroy = CString::new("ca_context_destroy").ok()?;

                    let p_create = dlsym(handle, c_create.as_ptr());
                    let p_open = dlsym(handle, c_open.as_ptr());
                    let p_play = dlsym(handle, c_play.as_ptr());
                    let p_destroy = dlsym(handle, c_destroy.as_ptr());

                    if p_create.is_null()
                        || p_open.is_null()
                        || p_play.is_null()
                        || p_destroy.is_null()
                    {
                        dlclose(handle);
                        None
                    } else {
                        Some(Canberra {
                            _handle: handle,
                            create: std::mem::transmute::<*mut c_void, CaCreate>(p_create),
                            open: std::mem::transmute::<*mut c_void, CaOpen>(p_open),
                            play: std::mem::transmute::<*mut c_void, CaPlay>(p_play),
                            destroy: std::mem::transmute::<*mut c_void, CaDestroy>(p_destroy),
                        })
                    }
                }
            })
            .as_ref()
    }

    fn cue_file(wav: &'static [u8]) -> Option<PathBuf> {
        let mut slot = FILES.lock().ok()?;
        if slot.is_none() {
            let base = if std::path::Path::new("/dev/shm").is_dir() {
                PathBuf::from("/dev/shm")
            } else {
                std::env::temp_dir()
            };
            let pid = unsafe { getpid() };
            let p_needs = base.join(format!("klepsydra-{pid}-needs.wav"));
            let p_done = base.join(format!("klepsydra-{pid}-done.wav"));
            let _ = std::fs::write(&p_needs, super::NEEDS_YOU);
            let _ = std::fs::write(&p_done, super::DONE);
            *slot = Some((p_needs, p_done));
        }
        let (ref p_needs, ref p_done) = slot.as_ref()?;
        if wav == super::NEEDS_YOU {
            Some(p_needs.clone())
        } else {
            Some(p_done.clone())
        }
    }

    pub fn play(wav: &'static [u8]) {
        let Some(path) = cue_file(wav) else { return };
        std::thread::spawn(move || unsafe {
            let Some(ca) = get_canberra() else { return };
            let mut ctx: *mut CaContext = std::ptr::null_mut();
            if (ca.create)(&mut ctx) == 0 && (ca.open)(ctx) == 0 {
                let Ok(prop) = CString::new("media.filename") else {
                    (ca.destroy)(ctx);
                    return;
                };
                let Ok(file_str) = CString::new(path.to_string_lossy().as_bytes()) else {
                    (ca.destroy)(ctx);
                    return;
                };
                (ca.play)(
                    ctx,
                    1,
                    prop.as_ptr(),
                    file_str.as_ptr(),
                    std::ptr::null::<c_char>(),
                );
                std::thread::sleep(std::time::Duration::from_millis(600));
                (ca.destroy)(ctx);
            }
        });
    }

    /// Whether the active window on X11 is full screen.
    pub fn full_screen() -> bool {
        use x11rb::connection::Connection;
        use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};

        let Ok((conn, screen_num)) = x11rb::connect(None) else {
            return false;
        };
        let Some(screen) = conn.setup().roots.get(screen_num) else {
            return false;
        };
        let Ok(active_atom) = conn.intern_atom(false, b"_NET_ACTIVE_WINDOW") else {
            return false;
        };
        let Ok(state_atom) = conn.intern_atom(false, b"_NET_WM_STATE") else {
            return false;
        };
        let Ok(fs_atom) = conn.intern_atom(false, b"_NET_WM_STATE_FULLSCREEN") else {
            return false;
        };
        let Ok(active_reply) = active_atom.reply() else {
            return false;
        };
        let Ok(state_reply) = state_atom.reply() else {
            return false;
        };
        let Ok(fs_reply) = fs_atom.reply() else {
            return false;
        };

        let Ok(active_prop) = conn.get_property(
            false,
            screen.root,
            active_reply.atom,
            AtomEnum::WINDOW,
            0,
            1,
        ) else {
            return false;
        };
        let Ok(active_res) = active_prop.reply() else {
            return false;
        };
        let Some(window_id) = active_res.value32().and_then(|mut v| v.next()) else {
            return false;
        };
        if window_id == 0 {
            return false;
        }

        let Ok(state_prop) =
            conn.get_property(false, window_id, state_reply.atom, AtomEnum::ATOM, 0, 64)
        else {
            return false;
        };
        let Ok(state_res) = state_prop.reply() else {
            return false;
        };
        state_res
            .value32()
            .map(|mut atoms| atoms.any(|a| a == fs_reply.atom))
            .unwrap_or(false)
    }
}

#[cfg(windows)]
mod win {
    use std::ffi::c_void;

    use windows::core::PCWSTR;
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};
    use windows::Win32::UI::Shell::{
        SHQueryUserNotificationState, QUNS_BUSY, QUNS_PRESENTATION_MODE,
        QUNS_RUNNING_D3D_FULL_SCREEN,
    };

    /// `WNF_SHEL_QUIETHOURS_ACTIVE_PROFILE_CHANGED`: 0 when Do Not Disturb is
    /// off, nonzero while it or a Focus session is on. Undocumented, so a read
    /// that fails counts as off.
    const QUIET_HOURS: u64 = 0x0D83_063E_A3BF_1C75;

    #[link(name = "ntdll")]
    extern "system" {
        fn NtQueryWnfStateData(
            state_name: *const u64,
            type_id: *const c_void,
            explicit_scope: *const c_void,
            change_stamp: *mut u32,
            buffer: *mut c_void,
            buffer_size: *mut u32,
        ) -> i32;
    }

    pub fn do_not_disturb() -> bool {
        let mut profile = 0u32;
        let mut size = std::mem::size_of::<u32>() as u32;
        let mut stamp = 0u32;
        // SAFETY: every pointer is to a live local; `size` bounds the write.
        let status = unsafe {
            NtQueryWnfStateData(
                &QUIET_HOURS,
                std::ptr::null(),
                std::ptr::null(),
                &mut stamp,
                (&mut profile as *mut u32).cast(),
                &mut size,
            )
        };
        status == 0 && size == 4 && profile != 0
    }

    /// A full-screen app, a game or presentation mode is in front. The first
    /// hour after login (`QUNS_QUIET_TIME`) does not count.
    pub fn full_screen() -> bool {
        // SAFETY: no arguments; the state is returned by value.
        let state = unsafe { SHQueryUserNotificationState() };
        matches!(
            state,
            Ok(QUNS_BUSY | QUNS_RUNNING_D3D_FULL_SCREEN | QUNS_PRESENTATION_MODE)
        )
    }

    /// Start `wav` and return; a cue already playing is cut off.
    pub fn play(wav: &'static [u8]) {
        // SAFETY: SND_MEMORY reads the WAV from the pointer, which is 'static,
        // so it outlives the asynchronous playback.
        unsafe {
            let _ = PlaySoundW(
                PCWSTR(wav.as_ptr().cast()),
                None,
                SND_MEMORY | SND_ASYNC | SND_NODEFAULT,
            );
        }
    }
}
