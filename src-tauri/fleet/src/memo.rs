//! Reading a folder every tick without re-reading its unchanged files. A
//! file's value is kept against the length and modification time its
//! directory entry shows, so a pass over the folder opens only the files
//! written since the last one. Listing a folder already carries those two
//! fields on Windows (no call per file); on Unix each costs one `fstatat`
//! in place of an open, a read and a close.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How long after its last write a file is read again on every pass. Two
/// writes closer together than the file system's timestamp granularity can
/// leave the length and time as they were (git's "racily clean" entries),
/// so a value is kept only once its file has been still for longer than any
/// granularity it may have: FAT keeps times to 2 s.
pub const RACY: Duration = Duration::from_secs(2);

/// A regular file's length and modification time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub len: u64,
    pub modified: SystemTime,
}

impl Stamp {
    /// The stamp in `meta`, `None` for anything but a regular file (a
    /// symlink's own metadata included).
    pub fn of(meta: &std::fs::Metadata) -> Option<Self> {
        if !meta.is_file() {
            return None;
        }
        Some(Stamp {
            len: meta.len(),
            modified: meta.modified().ok()?,
        })
    }

    /// A directory entry's stamp, without following a symlink.
    pub fn of_entry(entry: &std::fs::DirEntry) -> Option<Self> {
        Stamp::of(&entry.metadata().ok()?)
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
    /// `now`. An error is returned and never kept, so the next pass reads
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
            if let Some((stamp, value)) = memo.kept.remove(path) {
                if stamp == listed {
                    memo.seen.insert(path.to_path_buf(), (stamp, value.clone()));
                    return Ok(value);
                }
            }
        }
        memo.reads += 1;
        let (value, held) = read()?;
        let still = |s: &Stamp| now.duration_since(s.modified).is_ok_and(|d| d > RACY);
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
            modified: SystemTime::UNIX_EPOCH + Duration::from_secs(secs),
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
    fn a_symlink_or_folder_has_no_stamp() {
        let dir = crate::scan::tests::Scratch::new("memo-stamp");
        dir.write("f", "x");
        let f = std::fs::symlink_metadata(dir.0.join("f")).unwrap();
        assert_eq!(Stamp::of(&f).map(|s| s.len), Some(1));
        assert_eq!(Stamp::of(&std::fs::symlink_metadata(&dir.0).unwrap()), None);
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.0.join("f"), dir.0.join("l")).unwrap();
            let l = std::fs::read_dir(&dir.0)
                .unwrap()
                .flatten()
                .find(|e| e.file_name() == "l")
                .unwrap();
            assert_eq!(Stamp::of_entry(&l), None);
        }
    }
}
