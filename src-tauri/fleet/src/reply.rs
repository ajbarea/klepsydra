//! keryx's reply clips: each session's latest spoken reply as one WAV at
//! `<klepsydra dir>/replies/<session id>.wav` (keryx `docs/reply-clips.md`).
//! keryx writes them; klepsydra only reads.

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::session::is_session_id;

pub const FOLDER: &str = "replies";
/// A clip larger than this is not read: ten minutes of keryx's 24 kHz mono.
pub const MAX_BYTES: u64 = 32 * 1024 * 1024;
/// A RIFF/WAVE header alone, with no sound after it.
const HEADER_BYTES: u64 = 44;

/// The clip's path for `session`, or None for an id that is not a session's.
fn path(dir: &Path, session: &str) -> Option<PathBuf> {
    let folder = dir.join(FOLDER);
    // A symlinked folder is not keryx's (it makes `replies/` itself).
    if !std::fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
        return None;
    }
    is_session_id(session).then(|| folder.join(format!("{session}.wav")))
}

/// When `session`'s clip was last written, in epoch seconds; None without a
/// clip, or for a symlink, an empty clip or one over `MAX_BYTES`.
pub fn written_at(dir: &Path, session: &str) -> Option<i64> {
    let meta = std::fs::symlink_metadata(path(dir, session)?).ok()?;
    if !meta.is_file() || meta.len() <= HEADER_BYTES || meta.len() > MAX_BYTES {
        return None;
    }
    let at = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    i64::try_from(at.as_secs()).ok()
}

/// `session`'s clip, read through one handle and held to `MAX_BYTES`; None
/// where `written_at` would be.
pub fn read(dir: &Path, session: &str) -> Option<Vec<u8>> {
    let path = path(dir, session)?;
    if !std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file()) {
        return None;
    }
    let file = File::open(&path).ok()?;
    if !file.metadata().is_ok_and(|m| m.is_file()) {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
    let len = bytes.len() as u64;
    (len > HEADER_BYTES
        && len <= MAX_BYTES
        && bytes.starts_with(b"RIFF")
        && bytes[8..12] == *b"WAVE")
        .then_some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::{Scratch, A};

    fn wav(samples: usize) -> Vec<u8> {
        let data = (samples * 2) as u32;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + data).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes()); // PCM
        b.extend_from_slice(&1u16.to_le_bytes()); // mono
        b.extend_from_slice(&24_000u32.to_le_bytes());
        b.extend_from_slice(&48_000u32.to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&data.to_le_bytes());
        b.resize(b.len() + samples * 2, 0);
        b
    }

    #[test]
    fn a_sessions_clip_is_read_with_its_time() {
        let dir = Scratch::new("reply-read");
        std::fs::create_dir_all(dir.0.join(FOLDER)).unwrap();
        let clip = wav(240);
        std::fs::write(dir.0.join(FOLDER).join(format!("{A}.wav")), &clip).unwrap();
        assert_eq!(read(&dir.0, A), Some(clip));
        assert!(written_at(&dir.0, A).is_some_and(|t| t > 1_700_000_000));
    }

    #[test]
    fn no_clip_a_bad_id_or_a_bad_file_reads_as_none() {
        let dir = Scratch::new("reply-none");
        assert_eq!(read(&dir.0, A), None, "no folder");
        std::fs::create_dir_all(dir.0.join(FOLDER)).unwrap();
        assert_eq!(
            (read(&dir.0, A), written_at(&dir.0, A)),
            (None, None),
            "no clip"
        );
        for id in ["", "../fleet/x", "not-a-session", &format!("{A}/../{A}")] {
            assert_eq!(read(&dir.0, id), None, "{id}");
        }
        let file = dir.0.join(FOLDER).join(format!("{A}.wav"));
        std::fs::write(&file, b"RIFF").unwrap();
        assert_eq!(
            (read(&dir.0, A), written_at(&dir.0, A)),
            (None, None),
            "a header and less"
        );
        let mut not_wave = wav(240);
        not_wave[8..12].copy_from_slice(b"AVI ");
        std::fs::write(&file, not_wave).unwrap();
        assert_eq!(read(&dir.0, A), None, "not a WAVE");
        std::fs::remove_file(&file).unwrap();
        std::fs::create_dir(&file).unwrap();
        assert_eq!(
            (read(&dir.0, A), written_at(&dir.0, A)),
            (None, None),
            "a folder"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_clip_or_folder_is_not_read() {
        let dir = Scratch::new("reply-link");
        std::fs::create_dir_all(dir.0.join("elsewhere")).unwrap();
        std::fs::write(dir.0.join("elsewhere").join(format!("{A}.wav")), wav(240)).unwrap();
        std::os::unix::fs::symlink(dir.0.join("elsewhere"), dir.0.join(FOLDER)).unwrap();
        assert_eq!(
            (read(&dir.0, A), written_at(&dir.0, A)),
            (None, None),
            "folder"
        );
        std::fs::remove_file(dir.0.join(FOLDER)).unwrap();
        std::fs::create_dir(dir.0.join(FOLDER)).unwrap();
        std::os::unix::fs::symlink(
            dir.0.join("elsewhere").join(format!("{A}.wav")),
            dir.0.join(FOLDER).join(format!("{A}.wav")),
        )
        .unwrap();
        assert_eq!(
            (read(&dir.0, A), written_at(&dir.0, A)),
            (None, None),
            "clip"
        );
    }
}
