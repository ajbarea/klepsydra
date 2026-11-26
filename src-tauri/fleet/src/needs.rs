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

/// `text`'s lines, each with its own line ending: `\r\n`, `\n` or a lone
/// `\r`, as markdown-it (and so the wall) counts lines.
fn lines(text: &str) -> Vec<&str> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < b.len() {
        let end = match b[i] {
            b'\n' => i + 1,
            b'\r' if b.get(i + 1) == Some(&b'\n') => i + 2,
            b'\r' => i + 1,
            _ => {
                i += 1;
                continue;
            }
        };
        out.push(&text[start..end]);
        start = end;
        i = end;
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

/// A line without its ending.
fn bare(line: &str) -> &str {
    line.strip_suffix("\r\n")
        .or_else(|| line.strip_suffix('\n'))
        .or_else(|| line.strip_suffix('\r'))
        .unwrap_or(line)
}

/// The block's lines as the wall sent them, less a final empty line.
fn block_lines(block: &str) -> Vec<&str> {
    let mut v: Vec<&str> = lines(block).into_iter().map(bare).collect();
    while v.last().is_some_and(|l| l.trim().is_empty()) {
        v.pop();
    }
    v
}

/// A line's indent in columns, a tab to the next multiple of four.
fn indent(line: &str) -> usize {
    line.chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .fold(0, |n, c| if c == '\t' { n / 4 * 4 + 4 } else { n + 1 })
}

/// Whether the item whose first line is `first` ends before `next`: the end
/// of the file, a blank line, a heading, or a list item no deeper than it.
/// Anything else (a nested line, a lazy continuation) is still the item's.
fn ends_before(first: &str, next: Option<&str>) -> bool {
    let Some(next) = next.map(bare) else {
        return true;
    };
    next.trim().is_empty()
        || (indent(next) <= 3 && next.trim_start().starts_with('#'))
        || (is_item(next) && indent(next) <= indent(first))
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

/// Every place `want` stands in `have`, line for line.
fn matches<'a>(have: &'a [&str], want: &'a [&str]) -> impl Iterator<Item = usize> + 'a {
    let last = if want.is_empty() || want.len() > have.len() {
        0
    } else {
        have.len() - want.len() + 1
    };
    (0..last).filter(move |&i| {
        have[i..i + want.len()]
            .iter()
            .zip(want)
            .all(|(h, w)| bare(h) == *w)
    })
}

/// Where `want` first stands in `have`, line for line.
fn find(have: &[&str], want: &[&str]) -> Option<usize> {
    matches(have, want).next()
}

/// Where the item `want` stands in `have`: the copy at `line` (the wall's
/// reading), else the one nearest it, else (no line) the first; refused when
/// two are as near, or when the copy found is only the start of a longer item.
fn locate(have: &[&str], want: &[&str], line: Option<usize>) -> Option<usize> {
    let found: Vec<usize> = matches(have, want).collect();
    let at = match line {
        None => *found.first()?,
        Some(l) => {
            let best = *found.iter().min_by_key(|&&i| i.abs_diff(l))?;
            let d = best.abs_diff(l);
            if found.iter().filter(|&&i| i.abs_diff(l) == d).count() > 1 {
                return None;
            }
            best
        }
    };
    ends_before(want[0], have.get(at + want.len()).copied()).then_some(at)
}

/// `text` without the item `block` (see `locate`; `line` is where the wall
/// read it), and how to put it back. Refused when `block` is not a list item
/// or is not a whole item in `text` line for line.
pub fn remove(text: &str, block: &str, line: Option<usize>) -> Result<(String, Undo), String> {
    let want = block_lines(block);
    if !want.first().is_some_and(|l| is_item(l)) {
        return Err(NOT_ITEM.into());
    }
    let have = lines(text);
    let at = locate(&have, &want, line).ok_or(GONE)?;
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
) -> Result<(T, String), String> {
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
            return Ok((out, text));
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
        // The new file keeps the old one's permissions (a private 0600 stays private).
        if let Ok(meta) = std::fs::metadata(path) {
            let _ = std::fs::set_permissions(&tmp, meta.permissions());
        }
        if read_text(path, MAX_BYTES).ok().as_deref() != Some(text.as_str()) {
            let _ = std::fs::remove_file(&tmp);
            continue;
        }
        return std::fs::rename(&tmp, path)
            .map(|()| (out, new))
            .map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                format!("The Needs you file could not be saved: {e}")
            });
    }
    Err(BUSY.into())
}

/// What Done returns: how to undo it, and the file as written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Done {
    pub undo: Undo,
    pub text: String,
}

/// Mark the item `block`, which starts at line `line` as the wall read the
/// file, done in the file at `path`: its lines leave the file.
pub fn mark_done(path: &Path, block: &str, line: Option<usize>) -> Result<Done, String> {
    rewrite(path, |text| remove(text, block, line)).map(|(undo, text)| Done { undo, text })
}

/// Put back the item `undo` names in the file at `path`; the file as written.
pub fn undo_done(path: &Path, undo: &Undo) -> Result<String, String> {
    rewrite(path, |text| restore(text, undo).map(|t| (t, ()))).map(|((), text)| text)
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
        let (out, undo) = remove(FILE, block, None).unwrap();
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
        let (out, _) = remove(FILE, "- 📋 **Three:** third\n\n", None).unwrap();
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
            assert_eq!(remove(FILE, block, None).unwrap_err(), GONE, "{block}");
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
            assert_eq!(
                remove(FILE, block, None).unwrap_err(),
                NOT_ITEM,
                "{block:?}"
            );
        }
        for ok in ["* x", "+ x", "1. x", "2) x", "  - x", "-\tx"] {
            assert!(is_item(ok), "{ok}");
        }
    }

    #[test]
    fn crlf_files_keep_their_line_endings() {
        let crlf = FILE.replace('\n', "\r\n");
        let (out, undo) = remove(&crlf, "- 📋 **One:** first", None).unwrap();
        assert!(
            !out.contains("One") && !out.replace("\r\n", "").contains('\n'),
            "{out:?}"
        );
        assert_eq!(restore(&out, &undo).unwrap(), crlf);
    }

    #[test]
    fn the_first_of_two_identical_items_goes() {
        let text = "- 📋 a\n- 📋 b\n- 📋 a\n";
        let (out, undo) = remove(text, "- 📋 a", None).unwrap();
        assert_eq!(out, "- 📋 b\n- 📋 a\n");
        assert_eq!((undo.at, undo.after.as_deref()), (0, None));
        assert_eq!(restore(&out, &undo).unwrap(), text);
    }

    #[test]
    fn undo_follows_its_neighbour_when_the_file_moved_and_keeps_others_edits() {
        let (out, undo) = remove(FILE, "- 📋 **Three:** third", None).unwrap();
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
        let (out, undo) = remove(FILE, "- 📋 **Three:** third", None).unwrap();
        assert_eq!(undo.after.as_deref(), Some("  more of two"));
        let gone = out.replace("  more of two\n", "");
        let back = restore(&gone, &undo).unwrap();
        let at: Vec<&str> = back.lines().collect();
        assert_eq!(at[undo.at], "- 📋 **Three:** third", "{back}");
    }

    #[test]
    fn undo_twice_adds_the_item_once() {
        let (out, undo) = remove(FILE, "- 📋 **One:** first", None).unwrap();
        let once = restore(&out, &undo).unwrap();
        assert_eq!(restore(&once, &undo).unwrap(), once);
    }

    #[test]
    fn undo_at_the_end_of_a_file_without_a_final_newline() {
        let text = "- 📋 a\n- 📋 b";
        let (out, undo) = remove(text, "- 📋 b", None).unwrap();
        assert_eq!(out, "- 📋 a\n");
        assert_eq!(restore(&out, &undo).unwrap(), "- 📋 a\n- 📋 b\n");
        // The neighbour is the file's last line, now without its newline.
        let (_, undo) = remove("- 📋 a\n- 📋 b\n", "- 📋 b", None).unwrap();
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
        let done = mark_done(&path, "- 📋 **One:** first", None).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains("**One:**"), "{after}");
        undo_done(&path, &done.undo).unwrap();
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
        assert_eq!(mark_done(&path, "- 📋 nope", None).unwrap_err(), GONE);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), FILE);
        assert!(mark_done(&dir.0.join("missing.md"), "- 📋 x", None)
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
            remove(text, "- 📋 **One:** first", None)
        })
        .unwrap()
        .0;
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
            remove(text, "- 📋 **One:** first", None)
        })
        .unwrap_err();
        assert_eq!((err.as_str(), n.get()), (BUSY, TRIES));
        assert!(std::fs::read_to_string(&path).unwrap().contains("**One:**"));
    }

    #[test]
    fn done_takes_the_twin_at_its_line_not_the_first() {
        let text = "## A\n- 📋 a\n## B\n- 📋 a\n";
        let (out, undo) = remove(text, "- 📋 a", Some(3)).unwrap();
        assert_eq!(out, "## A\n- 📋 a\n## B\n");
        assert_eq!(restore(&out, &undo).unwrap(), text);
        // A line added above since the wall read it leaves the twins as near: no guess.
        let moved = format!("x\n{text}");
        assert_eq!(remove(&moved, "- 📋 a", Some(3)).unwrap_err(), GONE);
        // One copy only: found wherever it moved.
        let (out, _) = remove("x\ny\n- 📋 b\n", "- 📋 b", Some(0)).unwrap();
        assert_eq!(out, "x\ny\n");
    }

    #[test]
    fn done_never_takes_the_first_line_of_a_longer_item() {
        let text = "- 📋 Call Bob\n  - details A\n- 📋 Call Bob\n";
        let (out, _) = remove(text, "- 📋 Call Bob", Some(2)).unwrap();
        assert_eq!(out, "- 📋 Call Bob\n  - details A\n");
        // The longer item has the line asked for: it is not this block, so nothing goes.
        assert_eq!(remove(text, "- 📋 Call Bob", Some(0)).unwrap_err(), GONE);
        // A lazy continuation line is the item's too.
        assert_eq!(
            remove("- 📋 a\nmore of a\n- 📋 b\n", "- 📋 a", Some(0)).unwrap_err(),
            GONE
        );
        // Two twins as far from the line asked for: no guess.
        assert_eq!(
            remove("- 📋 a\n- 📋 x\n- 📋 a\n", "- 📋 a", Some(1)).unwrap_err(),
            GONE
        );
        // What ends an item: a blank line, a sibling, a heading, the end of the file.
        for after in ["\n", "- 📋 b\n", "## H\n", ""] {
            let t = format!("- 📋 a\n{after}");
            assert!(remove(&t, "- 📋 a", Some(0)).is_ok(), "{t:?}");
        }
    }

    #[test]
    fn a_lone_carriage_return_ends_a_line_as_it_does_for_the_wall() {
        let text = "- 📋 a\rb\n- 📋 c\n- 📋 d\n";
        let (out, undo) = remove(text, "- 📋 c", Some(2)).unwrap();
        assert_eq!(out, "- 📋 a\rb\n- 📋 d\n");
        assert_eq!(restore(&out, &undo).unwrap(), text);
        let (out, _) = remove(text, "- 📋 a\nb", Some(0)).unwrap();
        assert_eq!(out, "- 📋 c\n- 📋 d\n");
    }

    #[test]
    fn done_and_undo_return_the_file_as_written() {
        let dir = Scratch::new("needs-text");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let done = mark_done(&path, "- 📋 **One:** first", Some(3)).unwrap();
        assert_eq!(done.text, std::fs::read_to_string(&path).unwrap());
        assert_eq!(undo_done(&path, &done.undo).unwrap(), FILE);
    }

    #[cfg(unix)]
    #[test]
    fn done_keeps_the_file_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = Scratch::new("needs-mode");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        mark_done(&path, "- 📋 **One:** first", Some(3)).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_not_written_through() {
        let dir = Scratch::new("needs-link");
        let real = dir.0.join("real.md");
        std::fs::write(&real, FILE).unwrap();
        let path = dir.0.join("needs-you.md");
        std::os::unix::fs::symlink(&real, &path).unwrap();
        assert!(mark_done(&path, "- 📋 **One:** first", None)
            .unwrap_err()
            .contains("not a regular file"));
        assert_eq!(std::fs::read_to_string(&real).unwrap(), FILE);
    }
}
