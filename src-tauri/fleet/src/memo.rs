//! Reading a folder every tick without re-reading its unchanged files. A
//! file's value is kept against the stamp its directory entry shows (length,
//! modification and change times, file id), so a pass over the folder opens
//! only the files written since the last one. On Windows one directory query
//! returns every entry's stamp (no call per file); on Unix each costs one
//! `fstatat` in place of an open, a read and a close.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How long after its last change a file is read again on every pass. Two
/// writes closer together than the file system's timestamp granularity can
/// leave the stamp as it was (git's "racily clean" entries), so a value is
/// kept only once its file has been still for longer than any granularity it
/// may have: FAT keeps times to 2 s. It assumes the writer and the reader
/// share a clock, as they do on one machine.
pub const RACY: Duration = Duration::from_secs(2);

/// The time a pass compares stamps against. Tests read it `RACY` plus a
/// second ahead: writing a file sets its change time to now, so a file a
/// test has just written or aged counts as still, as it would 3 s later.
/// A test of the racy rule on real files sets `REAL_CLOCK` on its thread.
pub fn now() -> SystemTime {
    let now = SystemTime::now();
    #[cfg(test)]
    if !REAL_CLOCK.with(std::cell::Cell::get) {
        return now + RACY + Duration::from_secs(1);
    }
    now
}

#[cfg(test)]
thread_local! {
    pub(crate) static REAL_CLOCK: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// A regular file's length, modification time, change time and id. The
/// change time is what tells a file rewritten under the same length and
/// modification time (`cp -p`, `touch -r`, a restore): writing the data or
/// setting the times moves it, and only a backup tool sets it back. The id
/// tells a file replaced by rename. Unix: `st_ctime` and the inode, as git's
/// index keeps them. Windows: NTFS `ChangeTime` and the 64-bit file id.
/// NTFS copies a file's length and times into its directory entry only when
/// the file's last handle closes, so a file written in place through a handle
/// still open lists its old stamp until then. Every klepsydra writer of
/// file contents writes a temp file and renames it, which lists the new stamp
/// at once; the one in-place change, the fleet hook's `touch -c` of a session file,
/// moves only the time and closes at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub len: u64,
    pub modified: SystemTime,
    pub changed: SystemTime,
    pub id: u64,
}

impl Stamp {
    /// When the file last changed by either time.
    fn last(&self) -> SystemTime {
        self.modified.max(self.changed)
    }

    /// The stamp in `meta`, `None` for anything but a regular file (a
    /// symlink's own metadata included).
    #[cfg(unix)]
    pub fn of(meta: &std::fs::Metadata) -> Option<Self> {
        use std::os::unix::fs::MetadataExt;
        if !meta.is_file() {
            return None;
        }
        let changed = u64::try_from(meta.ctime())
            .ok()
            .and_then(|s| {
                let n = u32::try_from(meta.ctime_nsec()).ok()?;
                SystemTime::UNIX_EPOCH.checked_add(Duration::new(s, n))
            })
            .unwrap_or(SystemTime::UNIX_EPOCH);
        Some(Stamp {
            len: meta.len(),
            modified: meta.modified().ok()?,
            changed,
            id: meta.ino(),
        })
    }

    /// The stamp of the open file `file` (a regular file), as its directory
    /// entry would show it once nothing writes to it.
    #[cfg(unix)]
    pub fn of_file(file: &std::fs::File) -> Option<Self> {
        Stamp::of(&file.metadata().ok()?)
    }

    #[cfg(windows)]
    pub fn of_file(file: &std::fs::File) -> Option<Self> {
        win::stamp_of(file)
    }

    #[cfg(not(any(unix, windows)))]
    pub fn of_file(file: &std::fs::File) -> Option<Self> {
        let meta = file.metadata().ok()?;
        let modified = meta.modified().ok()?;
        meta.is_file().then_some(Stamp {
            len: meta.len(),
            modified,
            changed: modified,
            id: 0,
        })
    }
}

/// What a directory entry is, never following a link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Dir,
    /// A symlink, junction, FIFO, socket or device.
    Other,
}

/// One entry of a folder listing: its name, kind, modification time (for a
/// file or folder), and stamp when it is a regular file whose stamp the
/// listing gave.
#[derive(Clone, Debug)]
pub struct Listed {
    pub name: OsString,
    pub kind: Kind,
    pub modified: Option<SystemTime>,
    pub stamp: Option<Stamp>,
}

/// Every entry of `dir` but `.` and `..`, with the stamps a pass compares.
/// An entry whose type cannot be read is left out.
#[cfg(windows)]
pub fn list(dir: &Path) -> std::io::Result<Vec<Listed>> {
    win::list(dir)
}

#[cfg(not(windows))]
pub fn list(dir: &Path) -> std::io::Result<Vec<Listed>> {
    list_std(dir)
}

/// `list` through std's `read_dir`. On Unix each file or folder costs one
/// `fstatat` (not following a link); elsewhere entries carry no stamp, so
/// every pass reads them.
fn list_std(dir: &Path) -> std::io::Result<Vec<Listed>> {
    Ok(std::fs::read_dir(dir)?
        .flatten()
        .filter_map(|e| {
            let t = e.file_type().ok()?;
            let kind = if t.is_file() {
                Kind::File
            } else if t.is_dir() {
                Kind::Dir
            } else {
                Kind::Other
            };
            // One fstatat on Unix, not following a link.
            let meta = (kind != Kind::Other).then(|| e.metadata().ok()).flatten();
            #[cfg(unix)]
            let stamp = (kind == Kind::File)
                .then(|| meta.as_ref().and_then(Stamp::of))
                .flatten();
            #[cfg(not(unix))]
            let stamp = None;
            Some(Listed {
                name: e.file_name(),
                kind,
                modified: meta.and_then(|m| m.modified().ok()),
                stamp,
            })
        })
        .collect())
}

#[cfg(windows)]
mod win {
    use super::{Kind, Listed, Stamp};
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;
    use std::time::{Duration, SystemTime};
    use windows_sys::Win32::Foundation::{ERROR_INVALID_PARAMETER, ERROR_NO_MORE_FILES, HANDLE};
    use windows_sys::Win32::Storage::FileSystem::{
        FileBasicInfo, FileIdBothDirectoryInfo, FileIdBothDirectoryRestartInfo,
        GetFileInformationByHandle, GetFileInformationByHandleEx, BY_HANDLE_FILE_INFORMATION,
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_BASIC_INFO,
        FILE_FLAG_BACKUP_SEMANTICS, FILE_ID_BOTH_DIR_INFO,
    };

    /// A FILETIME (100 ns ticks since 1601) as a SystemTime.
    fn time(t: i64) -> SystemTime {
        const TO_UNIX: i64 = 116_444_736_000_000_000;
        let ticks = t.saturating_sub(TO_UNIX);
        let at = |d: Duration, after: bool| {
            if after {
                SystemTime::UNIX_EPOCH.checked_add(d)
            } else {
                SystemTime::UNIX_EPOCH.checked_sub(d)
            }
        };
        let d = Duration::from_nanos(ticks.unsigned_abs().saturating_mul(100));
        at(d, ticks >= 0).unwrap_or(SystemTime::UNIX_EPOCH)
    }

    /// A reparse point that names another file (a symlink or junction), as
    /// std's `FileType::is_symlink` reads it; other tags (cloud or dedup
    /// placeholders) are the file itself.
    pub(super) fn is_link(attributes: u32, tag: u32) -> bool {
        attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && tag & 0x2000_0000 != 0
    }

    pub(super) fn stamp_of(file: &std::fs::File) -> Option<Stamp> {
        let h = file.as_raw_handle() as HANDLE;
        let mut by: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: `h` is an open handle owned by `file`; `by` is a correctly
        // sized out-parameter.
        if unsafe { GetFileInformationByHandle(h, &mut by) } == 0 {
            return None;
        }
        let mut basic = FILE_BASIC_INFO::default();
        // SAFETY: as above; the size passed is `basic`'s own.
        let ok = unsafe {
            GetFileInformationByHandleEx(
                h,
                FileBasicInfo,
                (&raw mut basic).cast(),
                std::mem::size_of::<FILE_BASIC_INFO>() as u32,
            )
        };
        if ok == 0 || by.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
            return None;
        }
        Some(Stamp {
            len: (u64::from(by.nFileSizeHigh) << 32) | u64::from(by.nFileSizeLow),
            modified: time(basic.LastWriteTime),
            changed: time(basic.ChangeTime),
            id: (u64::from(by.nFileIndexHigh) << 32) | u64::from(by.nFileIndexLow),
        })
    }

    pub(super) fn list(dir: &Path) -> std::io::Result<Vec<Listed>> {
        // Backup semantics opens a folder; read access includes listing it.
        let handle = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(dir)?;
        let h = handle.as_raw_handle() as HANDLE;
        // u64 cells keep the buffer 8-byte aligned, as the entries need.
        let mut buf = vec![0u64; 8 * 1024];
        let bytes = (buf.len() * 8) as u32;
        let mut out = Vec::new();
        let mut class = FileIdBothDirectoryRestartInfo;
        loop {
            // SAFETY: `h` is an open folder handle; `buf` is `bytes` long.
            let ok =
                unsafe { GetFileInformationByHandleEx(h, class, buf.as_mut_ptr().cast(), bytes) };
            if ok == 0 {
                let e = std::io::Error::last_os_error();
                if e.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                    return Ok(out);
                }
                // A file system that refuses the query (some network shares;
                // Go's os.ReadDir met the same, golang/go#61907): std's
                // listing, unstamped, so every pass reads. One that answers
                // with file id 0 (MS-FSCC: no 64-bit ids, as on FAT) never
                // matches its handle's id, so nothing is kept: slower, never
                // stale.
                if class == FileIdBothDirectoryRestartInfo
                    && e.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32)
                {
                    return super::list_std(dir);
                }
                return Err(e);
            }
            class = FileIdBothDirectoryInfo;
            let base = buf.as_ptr().cast::<u8>();
            let head = std::mem::size_of::<FILE_ID_BOTH_DIR_INFO>();
            let name_at = std::mem::offset_of!(FILE_ID_BOTH_DIR_INFO, FileName);
            let bad =
                || std::io::Error::new(std::io::ErrorKind::InvalidData, "bad directory entry");
            let mut at = 0usize;
            loop {
                // A file system driver could return a broken chain: every
                // entry and name must lie inside the buffer.
                if at + head > bytes as usize {
                    return Err(bad());
                }
                // SAFETY: `at + head` is inside `buf`, and `at` is 8-byte
                // aligned (the call aligns each entry; checked below).
                let e = unsafe { base.add(at).cast::<FILE_ID_BOTH_DIR_INFO>().read() };
                let units = e.FileNameLength as usize / 2;
                if at + name_at + units * 2 > bytes as usize {
                    return Err(bad());
                }
                // SAFETY: the name's bytes lie inside `buf` (checked above)
                // and are u16-aligned, as `at` and `name_at` are even.
                let name = unsafe {
                    std::slice::from_raw_parts(base.add(at + name_at).cast::<u16>(), units)
                };
                if name != [b'.' as u16] && name != [b'.' as u16, b'.' as u16] {
                    // EaSize holds the reparse tag for a reparse point.
                    let kind = if is_link(e.FileAttributes, e.EaSize) {
                        Kind::Other
                    } else if e.FileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
                        Kind::Dir
                    } else {
                        Kind::File
                    };
                    let stamp = (kind == Kind::File).then(|| Stamp {
                        len: e.EndOfFile as u64,
                        modified: time(e.LastWriteTime),
                        changed: time(e.ChangeTime),
                        id: e.FileId as u64,
                    });
                    out.push(Listed {
                        name: OsString::from_wide(name),
                        kind,
                        modified: (kind != Kind::Other).then(|| time(e.LastWriteTime)),
                        stamp,
                    });
                }
                let next = e.NextEntryOffset as usize;
                if next == 0 {
                    break;
                }
                if !next.is_multiple_of(8) {
                    return Err(bad());
                }
                at += next;
            }
        }
    }
}

/// Values kept per path, each with the stamp its file had when read.
#[derive(Debug)]
pub struct Memo<T> {
    kept: HashMap<PathBuf, (Stamp, T)>,
    /// Paths met in the pass under way; the rest are dropped when it ends.
    seen: HashMap<PathBuf, (Stamp, T)>,
    reads: u64,
}

impl<T> Default for Memo<T> {
    fn default() -> Self {
        Memo {
            kept: HashMap::new(),
            seen: HashMap::new(),
            reads: 0,
        }
    }
}

impl<T: Clone> Memo<T> {
    /// Start a pass over the folders read. Values for paths the pass does not
    /// ask for are dropped when it ends, so the memo holds no more than the
    /// last listing.
    pub fn pass(&mut self) -> Pass<'_, T> {
        Pass { memo: self }
    }

    /// How many times a value was read rather than kept.
    pub fn reads(&self) -> u64 {
        self.reads
    }

    /// Values held between passes.
    #[cfg(test)]
    pub fn kept(&self) -> usize {
        self.kept.len() + self.seen.len()
    }
}

/// One pass of a reader over its folders.
pub struct Pass<'a, T: Clone> {
    memo: &'a mut Memo<T>,
}

impl<T: Clone> Pass<'_, T> {
    /// `path`'s value. `listed` is the stamp its directory entry shows. The
    /// value kept for that stamp is returned without reading; otherwise
    /// `read` runs, returning the value and the stamp of the handle it read
    /// through. That value is kept only when both stamps agree (the entry
    /// listed is the file read) and the file had been still for `RACY` at
    /// `now` by both its times. An error is returned and never kept, so the
    /// next pass reads
    /// again.
    pub fn get<E>(
        &mut self,
        path: &Path,
        listed: Option<Stamp>,
        now: SystemTime,
        read: impl FnOnce() -> Result<(T, Option<Stamp>), E>,
    ) -> Result<T, E> {
        let memo = &mut *self.memo;
        if let Some(listed) = listed {
            // Asked twice in one pass (two names for one folder): the first
            // answer stands.
            if let Some((stamp, value)) = memo.seen.get(path) {
                if *stamp == listed {
                    return Ok(value.clone());
                }
            }
            if let Some((stamp, value)) = memo.kept.remove(path) {
                if stamp == listed {
                    memo.seen.insert(path.to_path_buf(), (stamp, value.clone()));
                    return Ok(value);
                }
            }
        }
        memo.reads += 1;
        let (value, held) = read()?;
        let still = |s: &Stamp| now.duration_since(s.last()).is_ok_and(|d| d > RACY);
        if let (Some(listed), Some(held)) = (listed, held) {
            if listed == held && still(&held) {
                memo.seen.insert(path.to_path_buf(), (held, value.clone()));
            }
        }
        Ok(value)
    }
}

impl<T: Clone> Drop for Pass<'_, T> {
    fn drop(&mut self) {
        self.memo.kept = std::mem::take(&mut self.memo.seen);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(len: u64, secs: u64) -> Stamp {
        Stamp {
            len,
            modified: at(secs),
            changed: at(secs),
            id: 1,
        }
    }

    const NOW: u64 = 1_800_000_000;

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    /// One pass over `files` (path, listed stamp, value a read finds),
    /// returning the values and how many were read.
    fn pass(memo: &mut Memo<u32>, files: &[(&str, Stamp, u32)], now: u64) -> (Vec<u32>, u64) {
        let before = memo.reads();
        let mut p = memo.pass();
        let got = files
            .iter()
            .map(|&(path, listed, v)| {
                p.get(Path::new(path), Some(listed), at(now), || {
                    Ok::<_, ()>((v, Some(listed)))
                })
                .unwrap()
            })
            .collect();
        drop(p);
        (got, memo.reads() - before)
    }

    #[test]
    fn an_unchanged_file_is_read_once() {
        let mut m = Memo::default();
        let files = [("a", stamp(10, NOW - 60), 1), ("b", stamp(20, NOW - 60), 2)];
        assert_eq!(pass(&mut m, &files, NOW), (vec![1, 2], 2));
        assert_eq!(pass(&mut m, &files, NOW + 5), (vec![1, 2], 0));
    }

    #[test]
    fn a_new_length_or_time_is_read_again() {
        let mut m = Memo::default();
        pass(&mut m, &[("a", stamp(10, NOW - 60), 1)], NOW);
        assert_eq!(
            pass(&mut m, &[("a", stamp(11, NOW - 60), 2)], NOW),
            (vec![2], 1)
        );
        assert_eq!(
            pass(&mut m, &[("a", stamp(11, NOW - 59), 3)], NOW),
            (vec![3], 1)
        );
        // Even an older time: a file put back from a backup.
        assert_eq!(
            pass(&mut m, &[("a", stamp(11, NOW - 600), 4)], NOW),
            (vec![4], 1)
        );
    }

    #[test]
    fn a_file_written_within_racy_is_read_every_pass() {
        let mut m = Memo::default();
        let fresh = [("a", stamp(10, NOW - 1), 1)];
        assert_eq!(pass(&mut m, &fresh, NOW).1, 1);
        // A second write in the same tick, same length: read, not kept.
        assert_eq!(
            pass(&mut m, &[("a", stamp(10, NOW - 1), 2)], NOW),
            (vec![2], 1)
        );
        // Kept only once still for longer than RACY: 2 s is not yet.
        assert_eq!(pass(&mut m, &fresh, NOW + 1).1, 1);
        assert_eq!(pass(&mut m, &fresh, NOW + 2).1, 1);
        assert_eq!(pass(&mut m, &fresh, NOW + 3).1, 0);
        // A time ahead of the clock is never still.
        let ahead = [("b", stamp(1, NOW + 100), 1)];
        assert_eq!(pass(&mut m, &ahead, NOW).1, 1);
        assert_eq!(pass(&mut m, &ahead, NOW).1, 1);
    }

    #[test]
    fn a_value_is_kept_only_under_a_stamp_the_listing_showed() {
        // The file changed between the listing and the read: the handle's
        // stamp is not one any listing has shown, so the value is not kept,
        // and a later listing showing that stamp reads the file again.
        let mut m: Memo<u32> = Memo::default();
        let (listed, held) = (stamp(10, NOW - 60), stamp(12, NOW - 50));
        let mut p = m.pass();
        let v = p.get(Path::new("a"), Some(listed), at(NOW), || {
            Ok::<_, ()>((7, Some(held)))
        });
        assert_eq!(v, Ok(7));
        drop(p);
        assert_eq!(pass(&mut m, &[("a", held, 8)], NOW), (vec![8], 1));
    }

    #[test]
    fn an_error_or_an_unstamped_entry_is_never_kept() {
        let mut m: Memo<u32> = Memo::default();
        let listed = stamp(10, NOW - 60);
        for _ in 0..2 {
            let mut p = m.pass();
            assert_eq!(
                p.get(
                    Path::new("a"),
                    Some(listed),
                    at(NOW),
                    || Err::<(u32, _), _>("no")
                ),
                Err("no")
            );
            let got = p.get(Path::new("b"), None, at(NOW), || {
                Ok::<_, ()>((1, Some(listed)))
            });
            assert_eq!(got, Ok(1));
        }
        assert_eq!(m.reads(), 4);
    }

    #[test]
    fn a_path_left_out_of_a_pass_is_forgotten() {
        let mut m = Memo::default();
        let a = ("a", stamp(10, NOW - 60), 1);
        let b = ("b", stamp(10, NOW - 60), 2);
        pass(&mut m, &[a, b], NOW);
        pass(&mut m, &[a], NOW);
        assert_eq!(m.kept.len(), 1);
        // b is back: read again, not served from before it went.
        assert_eq!(pass(&mut m, &[a, b], NOW), (vec![1, 2], 1));
    }

    #[test]
    fn a_change_time_newer_than_the_write_time_keeps_it_racy() {
        // `cp -p` or `touch -r` just now: the write time is old, the change
        // time is not, so the file is read every pass until both are still.
        let mut m = Memo::default();
        let restored = Stamp {
            changed: at(NOW - 1),
            ..stamp(10, NOW - 600)
        };
        let files = [("a", restored, 1)];
        assert_eq!(pass(&mut m, &files, NOW).1, 1);
        assert_eq!(pass(&mut m, &files, NOW + 2).1, 1);
        assert_eq!(pass(&mut m, &files, NOW + 3).1, 0);
    }

    #[test]
    fn each_part_of_the_stamp_is_compared() {
        let base = stamp(10, NOW - 600);
        let others = [
            Stamp { len: 11, ..base },
            Stamp {
                modified: at(NOW - 601),
                ..base
            },
            Stamp {
                changed: at(NOW - 601),
                ..base
            },
            Stamp { id: 2, ..base },
        ];
        for (i, other) in others.into_iter().enumerate() {
            let mut m = Memo::default();
            pass(&mut m, &[("a", base, 1)], NOW);
            assert_eq!(
                pass(&mut m, &[("a", other, 2)], NOW),
                (vec![2], 1),
                "part {i}"
            );
        }
    }

    #[test]
    fn a_listing_stamps_regular_files_alone_and_matches_their_handles() {
        let dir = crate::scan::tests::Scratch::new("memo-stamp");
        dir.write("f", "xyz");
        std::fs::create_dir(dir.0.join("d")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.0.join("f"), dir.0.join("l")).unwrap();
        let mut l = list(&dir.0).unwrap();
        l.sort_by(|a, b| a.name.cmp(&b.name));
        let names: Vec<_> = l
            .iter()
            .map(|e| (e.name.to_str().unwrap(), e.kind))
            .collect();
        let want = [("d", Kind::Dir), ("f", Kind::File), ("l", Kind::Other)];
        let want = &want[..if cfg!(unix) { 3 } else { 2 }];
        assert_eq!(names, want);
        let f = l.iter().find(|e| e.name == "f").unwrap();
        assert_eq!(f.stamp.map(|s| s.len), Some(3));
        assert!(l
            .iter()
            .filter(|e| e.name != "f")
            .all(|e| e.stamp.is_none()));
        // The handle's stamp is the listing's, or no value would ever be kept.
        let held = Stamp::of_file(&std::fs::File::open(dir.0.join("f")).unwrap());
        assert_eq!(held, f.stamp);
        #[cfg(unix)]
        assert_eq!(Stamp::of_file(&std::fs::File::open(&dir.0).unwrap()), None);
    }

    /// Windows' listing calls a junction or symlink a link and any other
    /// reparse point (a cloud placeholder) the file itself, as std's
    /// `is_symlink` does. Tags from MS-FSCC 2.1.2.1.
    #[cfg(windows)]
    #[test]
    fn only_a_name_surrogate_reparse_point_is_a_link() {
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT as R;
        let (junction, symlink, cloud) = (0xA000_0003, 0xA000_000C, 0x9000_001A);
        assert!(win::is_link(R, junction));
        assert!(win::is_link(R, symlink));
        assert!(!win::is_link(R, cloud));
        // EaSize is a length, not a tag, without the reparse attribute.
        assert!(!win::is_link(0, junction));
    }

    #[test]
    fn a_file_written_in_place_lists_its_new_stamp_once_its_writer_closes() {
        use std::io::Write;
        let dir = crate::scan::tests::Scratch::new("memo-held");
        dir.write("f", "abc");
        let stamp_of = |d: &Path| list(d).unwrap().into_iter().find(|e| e.name == "f")?.stamp;
        let before = stamp_of(&dir.0);
        let mut w = std::fs::OpenOptions::new()
            .append(true)
            .open(dir.0.join("f"))
            .unwrap();
        w.write_all(b"def").unwrap();
        w.sync_all().unwrap();
        drop(w);
        let after = stamp_of(&dir.0);
        assert_ne!(after, before);
        assert_eq!(after.map(|s| s.len), Some(6));
        let held = Stamp::of_file(&std::fs::File::open(dir.0.join("f")).unwrap());
        assert_eq!(held, after);
    }
}
