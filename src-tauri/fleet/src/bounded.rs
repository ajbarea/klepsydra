//! Reading a small text file another program writes: a regular file only,
//! never a symlink, FIFO or folder, and never more than a cap.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::Path;

/// Why a file was not read.
#[derive(Debug)]
pub enum Refused {
    Missing,
    /// A folder, a symlink, a FIFO or a device.
    NotFile,
    TooLarge,
    Unreadable(std::io::Error),
    NotUtf8,
}

/// Open `path` without following a symlink and, on Unix, without blocking on
/// a FIFO swapped in after the type check.
fn open(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    options.open(path)
}

/// The text of the regular file at `path`, at most `max` bytes. The type is
/// checked before opening, so a FIFO is never opened and a symlink never
/// followed, and again on the open handle, so a swap between the two is
/// refused too.
pub fn read_text(path: &Path, max: u64) -> Result<String, Refused> {
    let gone = |e: &std::io::Error| e.kind() == std::io::ErrorKind::NotFound;
    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if gone(&e) => return Err(Refused::Missing),
        Err(e) => return Err(Refused::Unreadable(e)),
    };
    if !meta.is_file() {
        return Err(Refused::NotFile);
    }
    if meta.len() > max {
        return Err(Refused::TooLarge);
    }
    let file = match open(path) {
        Ok(f) => f,
        Err(e) if gone(&e) => return Err(Refused::Missing),
        #[cfg(unix)]
        Err(e) if e.raw_os_error() == Some(libc::ELOOP) => return Err(Refused::NotFile),
        Err(e) => return Err(Refused::Unreadable(e)),
    };
    let held = file.metadata().map_err(Refused::Unreadable)?;
    if !held.is_file() {
        return Err(Refused::NotFile);
    }
    // One byte past the cap tells a file that grew since the check.
    let mut bytes = Vec::new();
    file.take(max + 1)
        .read_to_end(&mut bytes)
        .map_err(Refused::Unreadable)?;
    if bytes.len() as u64 > max {
        return Err(Refused::TooLarge);
    }
    String::from_utf8(bytes).map_err(|_| Refused::NotUtf8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    fn refused(r: Result<String, Refused>) -> String {
        match r {
            Ok(t) => format!("text {t:?}"),
            Err(Refused::Unreadable(_)) => "Unreadable".into(),
            Err(e) => format!("{e:?}"),
        }
    }

    #[test]
    fn a_regular_file_under_the_cap_reads_whole() {
        let dir = Scratch::new("bounded-ok");
        dir.write("q.md", "# Queue\n");
        assert_eq!(
            refused(read_text(&dir.0.join("q.md"), 8)),
            "text \"# Queue\\n\""
        );
    }

    #[test]
    fn each_refusal_says_why() {
        let dir = Scratch::new("bounded-why");
        assert_eq!(refused(read_text(&dir.0.join("none.md"), 64)), "Missing");
        dir.write("big.md", "123456789");
        assert_eq!(refused(read_text(&dir.0.join("big.md"), 8)), "TooLarge");
        std::fs::create_dir(dir.0.join("folder.md")).unwrap();
        assert_eq!(refused(read_text(&dir.0.join("folder.md"), 64)), "NotFile");
        std::fs::write(dir.0.join("latin1.md"), [0x63, 0x61, 0x66, 0xe9]).unwrap();
        assert_eq!(refused(read_text(&dir.0.join("latin1.md"), 64)), "NotUtf8");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_never_followed() {
        let dir = Scratch::new("bounded-link");
        dir.write("real.md", "x");
        std::os::unix::fs::symlink(dir.0.join("real.md"), dir.0.join("q.md")).unwrap();
        assert_eq!(refused(read_text(&dir.0.join("q.md"), 64)), "NotFile");
        // The open itself refuses one, should it be swapped in after the check.
        let err = open(&dir.0.join("q.md")).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(libc::ELOOP));
    }

    #[cfg(unix)]
    #[test]
    fn a_fifo_is_refused_without_blocking() {
        let dir = Scratch::new("bounded-fifo");
        let fifo = dir.0.join("q.md");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: `c` is a valid NUL-terminated string that outlives the call.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let checked = refused(read_text(&fifo, 64));
            // Opened directly, as a swap after the check would be, it neither
            // blocks nor reads as a file.
            let held = open(&fifo).and_then(|f| f.metadata()).map(|m| m.is_file());
            let _ = tx.send((checked, held.ok()));
        });
        let got = rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("returned");
        assert_eq!(got, ("NotFile".to_string(), Some(false)));
    }
}
