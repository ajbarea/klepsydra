//! Marking a Needs you item done from the wall (#386, with #86's write
//! rules). The markdown file stays the source of truth: Done removes the
//! item's exact lines (its nested lines too) as the wall last read them, and
//! Undo puts those lines back after the line that preceded them. Nothing else
//! in the file is touched, so an agent's edit elsewhere survives both. The
//! write is an atomic replace, and the file is read again just before the
//! rename: a file that changed in between is edited afresh, never
//! overwritten with a stale copy.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::bounded::{read_text, Refused};
use crate::queue::MAX_BYTES;

/// What Undo needs to put an item back: its lines, the line above them when
/// it was removed, and where it stood.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Undo {
    pub block: String,
    pub after: Option<String>,
    pub at: usize,
}

/// How many times a write is tried while other writers keep changing the file.
const TRIES: usize = 3;
/// The longest link the wall opens.
pub const URL_MAX: usize = 2048;

pub const GONE: &str =
    "That item is no longer in the Needs you file as shown (edited or already done); nothing was written.";
const NOT_ITEM: &str = "Only a list item can be marked done.";
const BUSY: &str =
    "The Needs you file kept changing while it was saved; nothing was written. Try again.";

/// `text`'s lines, each with its own line ending.
fn lines(text: &str) -> Vec<&str> {
    text.split_inclusive('\n').collect()
}

/// A line without its ending.
fn bare(line: &str) -> &str {
    line.strip_suffix('\n')
        .map_or(line, |l| l.strip_suffix('\r').unwrap_or(l))
}

/// The block's lines as the wall sent them, less a final empty line.
fn block_lines(block: &str) -> Vec<&str> {
    let mut v: Vec<&str> = block
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();
    while v.last().is_some_and(|l| l.trim().is_empty()) {
        v.pop();
    }
    v
}

/// A markdown list item's first line: a bullet or a number, then a space.
fn is_item(line: &str) -> bool {
    let t = line.trim_start();
    if let Some(rest) = t.strip_prefix(['-', '*', '+']) {
        return rest.starts_with(' ') || rest.starts_with('\t');
    }
    let digits = t.bytes().take_while(u8::is_ascii_digit).count();
    (1..=9).contains(&digits)
        && t[digits..].starts_with(['.', ')'])
        && t[digits + 1..].starts_with([' ', '\t'])
}

/// Where `want` first stands in `have`, line for line.
fn find(have: &[&str], want: &[&str]) -> Option<usize> {
    if want.is_empty() || want.len() > have.len() {
        return None;
    }
    (0..=have.len() - want.len()).find(|&i| {
        have[i..i + want.len()]
            .iter()
            .zip(want)
            .all(|(h, w)| bare(h) == *w)
    })
}

/// `text` without `block`, and how to put it back. Refused when `block` is
/// not a list item or is not in `text` line for line.
pub fn remove(text: &str, block: &str) -> Result<(String, Undo), String> {
    let want = block_lines(block);
    if !want.first().is_some_and(|l| is_item(l)) {
        return Err(NOT_ITEM.into());
    }
    let have = lines(text);
    let at = find(&have, &want).ok_or(GONE)?;
    let mut out = String::with_capacity(text.len());
    for (i, l) in have.iter().enumerate() {
        if !(at..at + want.len()).contains(&i) {
            out.push_str(l);
        }
    }
    let undo = Undo {
        block: want.join("\n"),
        after: at.checked_sub(1).map(|i| bare(have[i]).to_string()),
        at,
    };
    Ok((out, undo))
}

/// `text` with the undone block back after the line that stood above it
/// (its nearest copy to where the block was), else at its old place. A block
/// already standing there is not added twice.
pub fn restore(text: &str, undo: &Undo) -> Result<String, String> {
    let want = block_lines(&undo.block);
    if !want.first().is_some_and(|l| is_item(l)) {
        return Err(NOT_ITEM.into());
    }
    let have = lines(text);
    let pos = match &undo.after {
        None => 0,
        Some(a) => have
            .iter()
            .enumerate()
            .filter(|(_, l)| bare(l) == a)
            .map(|(j, _)| j + 1)
            .min_by_key(|&p| p.abs_diff(undo.at))
            .unwrap_or_else(|| undo.at.min(have.len())),
    };
    if pos + want.len() <= have.len() && find(&have[pos..pos + want.len()], &want) == Some(0) {
        return Ok(text.to_string());
    }
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut out = String::with_capacity(text.len() + undo.block.len() + want.len() * 2);
    for l in &have[..pos] {
        out.push_str(l);
    }
    if pos > 0 && !have[pos - 1].ends_with('\n') {
        out.push_str(eol);
    }
    for l in &want {
        out.push_str(l);
        out.push_str(eol);
    }
    for l in &have[pos..] {
        out.push_str(l);
    }
    Ok(out)
}

/// Whether `url` is an https address of plain URL characters, short enough
/// to hand to the desktop: no space, quote, backslash or control character.
pub fn safe_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    url.len() <= URL_MAX
        && !host.is_empty()
        && url
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&()*+,;=%".contains(&b))
}

/// `url` when it is safe and written in `text`, the file the wall shows;
/// else why it is not opened.
pub fn link_in<'a>(text: &str, url: &'a str) -> Result<&'a str, String> {
    if !safe_url(url) {
        return Err("Only an https link is opened; copy this one instead.".into());
    }
    if !text.contains(url) {
        return Err("That link is not in the Needs you file as written; copy it instead.".into());
    }
    Ok(url)
}

fn why(r: &Refused) -> String {
    match r {
        Refused::Missing => "There is no Needs you file at its path.".into(),
        Refused::NotFile => {
            "The Needs you path is not a regular file, so it is not written.".into()
        }
        Refused::TooLarge => "The Needs you file is too large to edit here.".into(),
        Refused::NotUtf8 => "The Needs you file is not UTF-8 text, so it is not written.".into(),
        Refused::Unreadable(e) => format!("The Needs you file could not be read: {e}"),
    }
}

/// Read the file at `path`, edit it with `edit`, and put the result in its
/// place atomically, checking just before the rename that nobody wrote it
/// since the read; a changed file is edited afresh, up to `TRIES` times.
/// `edit` returning the text unchanged writes nothing.
pub fn rewrite<T>(
    path: &Path,
    edit: impl Fn(&str) -> Result<(String, T), String>,
) -> Result<T, String> {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or("The Needs you path names no file.")?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let tmp = path.with_file_name(format!(".{name}.klepsydra-{nonce}.tmp"));
    for _ in 0..TRIES {
        let text = read_text(path, MAX_BYTES).map_err(|r| why(&r))?;
        let (new, out) = edit(&text)?;
        if new == text {
            return Ok(out);
        }
        // A new file, never one already there: a link planted at the name is removed, not written through.
        match std::fs::remove_file(&tmp) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                return Err(format!("The Needs you file could not be saved: {e}"))
            }
            _ => {}
        }
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .and_then(|mut f| {
                std::io::Write::write_all(&mut f, new.as_bytes())?;
                f.sync_all()
            })
            .map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                format!("The Needs you file could not be saved: {e}")
            })?;
        if read_text(path, MAX_BYTES).ok().as_deref() != Some(text.as_str()) {
            let _ = std::fs::remove_file(&tmp);
            continue;
        }
        return std::fs::rename(&tmp, path).map(|()| out).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            format!("The Needs you file could not be saved: {e}")
        });
    }
    Err(BUSY.into())
}

/// Mark the item `block` done in the file at `path`: its lines leave the file.
pub fn mark_done(path: &Path, block: &str) -> Result<Undo, String> {
    rewrite(path, |text| remove(text, block))
}

/// Put back the item `undo` names in the file at `path`.
pub fn undo_done(path: &Path, undo: &Undo) -> Result<(), String> {
    rewrite(path, |text| restore(text, undo).map(|t| (t, ())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::Scratch;

    const FILE: &str = "# Needs you\n\n## Today\n- 📋 **One:** first\n- 📋 **Two:** second\n  - 📋 nested step [a](https://example.com/a)\n  more of two\n- 📋 **Three:** third\n\n## Later\n- 📋 **Four:** fourth\n";

    #[test]
    fn done_removes_the_item_and_its_nested_lines_only() {
        let block =
            "- 📋 **Two:** second\n  - 📋 nested step [a](https://example.com/a)\n  more of two";
        let (out, undo) = remove(FILE, block).unwrap();
        assert_eq!(
            out,
            "# Needs you\n\n## Today\n- 📋 **One:** first\n- 📋 **Three:** third\n\n## Later\n- 📋 **Four:** fourth\n"
        );
        assert_eq!(undo.at, 4);
        assert_eq!(undo.after.as_deref(), Some("- 📋 **One:** first"));
        assert_eq!(
            restore(&out, &undo).unwrap(),
            FILE,
            "undo puts back that block alone"
        );
    }

    #[test]
    fn a_trailing_blank_line_in_the_block_is_not_part_of_it() {
        let (out, _) = remove(FILE, "- 📋 **Three:** third\n\n").unwrap();
        assert!(
            out.contains("first\n- 📋 **Two:**") && out.contains("of two\n\n## Later"),
            "{out}"
        );
    }

    #[test]
    fn an_item_no_longer_in_the_file_is_refused() {
        for block in [
            "- 📋 **Two:** second, edited",
            "- 📋 **Two:** second\n  more of two",
            "- 📋 **Five:** none",
        ] {
            assert_eq!(remove(FILE, block).unwrap_err(), GONE, "{block}");
        }
    }

    #[test]
    fn only_a_list_item_is_removed() {
        for block in [
            "## Today",
            "",
            "\n",
            "# Needs you",
            "-no space",
            "12345678901. x",
            "plain line",
        ] {
            assert_eq!(remove(FILE, block).unwrap_err(), NOT_ITEM, "{block:?}");
        }
        for ok in ["* x", "+ x", "1. x", "2) x", "  - x", "-\tx"] {
            assert!(is_item(ok), "{ok}");
        }
    }

    #[test]
    fn crlf_files_keep_their_line_endings() {
        let crlf = FILE.replace('\n', "\r\n");
        let (out, undo) = remove(&crlf, "- 📋 **One:** first").unwrap();
        assert!(
            !out.contains("One") && !out.replace("\r\n", "").contains('\n'),
            "{out:?}"
        );
        assert_eq!(restore(&out, &undo).unwrap(), crlf);
    }

    #[test]
    fn the_first_of_two_identical_items_goes() {
        let text = "- 📋 a\n- 📋 b\n- 📋 a\n";
        let (out, undo) = remove(text, "- 📋 a").unwrap();
        assert_eq!(out, "- 📋 b\n- 📋 a\n");
        assert_eq!((undo.at, undo.after.as_deref()), (0, None));
        assert_eq!(restore(&out, &undo).unwrap(), text);
    }

    #[test]
    fn undo_follows_its_neighbour_when_the_file_moved_and_keeps_others_edits() {
        let (out, undo) = remove(FILE, "- 📋 **Three:** third").unwrap();
        // An agent adds a line at the top and edits Four meanwhile.
        let edited = format!("NEW TOP\n{}", out.replace("fourth", "fourth, edited"));
        let back = restore(&edited, &undo).unwrap();
        assert_eq!(
            back,
            format!("NEW TOP\n{}", FILE.replace("fourth", "fourth, edited"))
        );
    }

    #[test]
    fn undo_with_its_neighbour_gone_goes_back_to_its_old_place() {
        let (out, undo) = remove(FILE, "- 📋 **Three:** third").unwrap();
        assert_eq!(undo.after.as_deref(), Some("  more of two"));
        let gone = out.replace("  more of two\n", "");
        let back = restore(&gone, &undo).unwrap();
        let at: Vec<&str> = back.lines().collect();
        assert_eq!(at[undo.at], "- 📋 **Three:** third", "{back}");
    }

    #[test]
    fn undo_twice_adds_the_item_once() {
        let (out, undo) = remove(FILE, "- 📋 **One:** first").unwrap();
        let once = restore(&out, &undo).unwrap();
        assert_eq!(restore(&once, &undo).unwrap(), once);
    }

    #[test]
    fn undo_at_the_end_of_a_file_without_a_final_newline() {
        let text = "- 📋 a\n- 📋 b";
        let (out, undo) = remove(text, "- 📋 b").unwrap();
        assert_eq!(out, "- 📋 a\n");
        assert_eq!(restore(&out, &undo).unwrap(), "- 📋 a\n- 📋 b\n");
        // The neighbour is the file's last line, now without its newline.
        let (_, undo) = remove("- 📋 a\n- 📋 b\n", "- 📋 b").unwrap();
        assert_eq!(restore("- 📋 a", &undo).unwrap(), "- 📋 a\n- 📋 b\n");
    }

    #[test]
    fn links_open_only_when_https_plain_and_in_the_file() {
        let text = "see [x](https://example.com/a?b=1&c=2#d) and [y](http://example.com/)";
        assert_eq!(
            link_in(text, "https://example.com/a?b=1&c=2#d"),
            Ok("https://example.com/a?b=1&c=2#d")
        );
        for bad in [
            "http://example.com/",
            "https://",
            "https:///x",
            "file:///C:/Windows/System32/calc.exe",
            "javascript:alert(1)",
            "ms-msdt:/id",
            "https://example.com/a b",
            "https://example.com/\"x",
            "https://example.com/'x",
            "https://example.com/\\x",
            "https://example.com/é",
            " https://example.com/",
        ] {
            assert!(link_in(text, bad).is_err(), "{bad}");
        }
        assert!(
            link_in(text, "https://example.com/other").is_err(),
            "not in the file"
        );
        assert!(!safe_url(&format!("https://e.com/{}", "a".repeat(URL_MAX))));
    }

    #[test]
    fn mark_done_writes_the_file_and_undo_restores_it() {
        let dir = Scratch::new("needs-done");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let undo = mark_done(&path, "- 📋 **One:** first").unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains("**One:**"), "{after}");
        undo_done(&path, &undo).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), FILE);
        let left: Vec<_> = std::fs::read_dir(&dir.0)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(
            left,
            vec![std::ffi::OsString::from("needs-you.md")],
            "no temp file left"
        );
    }

    #[test]
    fn mark_done_refuses_a_missing_item_and_leaves_the_file() {
        let dir = Scratch::new("needs-gone");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        assert_eq!(mark_done(&path, "- 📋 nope").unwrap_err(), GONE);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), FILE);
        assert!(mark_done(&dir.0.join("missing.md"), "- 📋 x")
            .unwrap_err()
            .contains("no Needs you file"));
    }

    #[test]
    fn a_write_between_the_read_and_the_rename_is_kept() {
        let dir = Scratch::new("needs-race");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let calls = std::cell::Cell::new(0);
        let out = rewrite(&path, |text| {
            calls.set(calls.get() + 1);
            if calls.get() == 1 {
                // Another writer saves after our read, before our rename.
                std::fs::write(&path, format!("{text}- 📋 added by an agent\n")).unwrap();
            }
            remove(text, "- 📋 **One:** first")
        })
        .unwrap();
        assert_eq!(calls.get(), 2, "edited afresh");
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("added by an agent") && !after.contains("**One:**"),
            "{after}"
        );
        assert_eq!(out.at, 3);
    }

    #[test]
    fn a_file_that_never_settles_is_not_written() {
        let dir = Scratch::new("needs-busy");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let n = std::cell::Cell::new(0);
        let err = rewrite(&path, |text| {
            n.set(n.get() + 1);
            std::fs::write(&path, format!("{text}x\n")).unwrap();
            remove(text, "- 📋 **One:** first")
        })
        .unwrap_err();
        assert_eq!((err.as_str(), n.get()), (BUSY, TRIES));
        assert!(std::fs::read_to_string(&path).unwrap().contains("**One:**"));
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_not_written_through() {
        let dir = Scratch::new("needs-link");
        let real = dir.0.join("real.md");
        std::fs::write(&real, FILE).unwrap();
        let path = dir.0.join("needs-you.md");
        std::os::unix::fs::symlink(&real, &path).unwrap();
        assert!(mark_done(&path, "- 📋 **One:** first")
            .unwrap_err()
            .contains("not a regular file"));
        assert_eq!(std::fs::read_to_string(&real).unwrap(), FILE);
    }
}
