//! The tray's Ping, Windows only: a short cue when a session needs AJ or
//! finishes, played here rather than in a webview so it sounds with the wall
//! closed and no autoplay gate applies.

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
    if !win::do_not_disturb() && !win::full_screen() {
        win::play(wav(cue));
    }
}

/// Play `cue` whatever the desktop says: AJ just asked to hear it.
pub fn preview(cue: Cue) {
    win::play(wav(cue));
}

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
