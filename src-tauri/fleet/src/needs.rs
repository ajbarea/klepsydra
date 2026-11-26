//! Marking a Needs you item done from the wall (#386, with #86's write
//! rules). The markdown file stays the source of truth, and the wall's parser
//! (markdown-it) alone decides where an item starts and ends: Done names the
//! file as the wall rendered it, the item's lines and the line they start on,
//! and removes exactly those lines only while the file is still that text. A
//! file an agent changed since is refused, never guessed at; the wall shows
//! the new text and the item can be marked again. Undo puts the lines back
//! where they stood, or after their old neighbour if the file moved on.
//! Nothing else in the file is touched. The write is an atomic replace, and
//! the file is read again just before the rename: a file that changed in
//! between is edited afresh, never overwritten with a stale copy.

use std::hash::{Hash, Hasher};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::bounded::{read_text, Refused};
use crate::queue::MAX_BYTES;

/// What Undo needs to put an item back: its lines, the line above them when
/// it was removed, where it stood, and the file's fingerprint just after Done.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Undo {
    pub block: String,
    pub after: Option<String>,
    pub at: usize,
    #[serde(default)]
    pub done: String,
}

/// How many times a write is tried while other writers keep changing the file.
const TRIES: usize = 3;
/// The longest link the wall opens.
pub const URL_MAX: usize = 2048;

pub const CHANGED: &str =
    "The Needs you file changed since the wall showed it, so nothing was written. The wall shows it as it is now; mark the item again.";
pub const GONE: &str =
    "That item is not in the Needs you file where the wall showed it; nothing was written.";
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

/// A markdown list item's first line: a bullet or a number, then a space or
/// the line's end (an empty item).
fn is_item(line: &str) -> bool {
    let t = line.trim_start();
    let after = |rest: &str| rest.is_empty() || rest.starts_with([' ', '\t']);
    if let Some(rest) = t.strip_prefix(['-', '*', '+']) {
        return after(rest);
    }
    let digits = t.bytes().take_while(u8::is_ascii_digit).count();
    (1..=9).contains(&digits) && t[digits..].starts_with(['.', ')']) && after(&t[digits + 1..])
}

/// Whether `want` stands in `have` at `at`, line for line.
fn stands_at(have: &[&str], want: &[&str], at: usize) -> bool {
    at + want.len() <= have.len()
        && have[at..at + want.len()]
            .iter()
            .zip(want)
            .all(|(h, w)| bare(h) == *w)
}

/// A short fingerprint of a file's text, to tell Undo whether it moved on.
fn fingerprint(text: &str) -> String {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut h);
    format!("{:016x}-{}", h.finish(), text.len())
}

/// `text` without the item `block`, which the wall read at line `line` of
/// `seen`, and how to put it back. Refused when the file is no longer `seen`,
/// when `block` is not a list item, or when it is not at `line`.
pub fn remove(text: &str, seen: &str, block: &str, line: usize) -> Result<(String, Undo), String> {
    if text != seen {
        return Err(CHANGED.into());
    }
    let want = block_lines(block);
    if !want.first().is_some_and(|l| is_item(l)) {
        return Err(NOT_ITEM.into());
    }
    let have = lines(text);
    if !stands_at(&have, &want, line) {
        return Err(GONE.into());
    }
    let mut out = String::with_capacity(text.len() + 1);
    for (i, l) in have.iter().enumerate() {
        if !(line..line + want.len()).contains(&i) {
            // A lone `\r` then a line starting `\n` would fuse into one CRLF ending and lose a line.
            if out.ends_with('\r') && l.starts_with('\n') {
                out.push('\n');
            }
            out.push_str(l);
        }
    }
    let undo = Undo {
        block: want.join("\n"),
        after: line.checked_sub(1).map(|i| bare(have[i]).to_string()),
        at: line,
        done: fingerprint(&out),
    };
    Ok((out, undo))
}

/// `text` with the undone block back: where it stood when the file is as
/// Done left it, else after the line that stood above it (its nearest copy
/// to where the block was), else at its old place.
pub fn restore(text: &str, undo: &Undo) -> Result<String, String> {
    let want = block_lines(&undo.block);
    if !want.first().is_some_and(|l| is_item(l)) {
        return Err(NOT_ITEM.into());
    }
    let have = lines(text);
    let pos = if fingerprint(text) == undo.done {
        undo.at.min(have.len())
    } else {
        match &undo.after {
            None => 0,
            Some(a) => have
                .iter()
                .enumerate()
                .filter(|(_, l)| bare(l) == a)
                .map(|(j, _)| j + 1)
                .min_by_key(|&p| p.abs_diff(undo.at))
                .unwrap_or_else(|| undo.at.min(have.len())),
        }
    };
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut out = String::with_capacity(text.len() + undo.block.len() + want.len() * 2);
    for l in &have[..pos] {
        out.push_str(l);
    }
    if pos > 0 && !have[pos - 1].ends_with(['\n', '\r']) {
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
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        // Created with the old file's mode, so a private 0600 file is never readable to others, even briefly.
        #[cfg(unix)]
        if let Ok(meta) = std::fs::metadata(path) {
            use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
            opts.mode(meta.permissions().mode() & 0o7777);
        }
        opts.open(&tmp)
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

/// Mark the item `block`, which starts at line `line` of `seen` (the file as
/// the wall rendered it), done in the file at `path`: its lines leave the file.
pub fn mark_done(path: &Path, seen: &str, block: &str, line: usize) -> Result<Done, String> {
    rewrite(path, |text| remove(text, seen, block, line)).map(|(undo, text)| Done { undo, text })
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
    const TWO: &str =
        "- 📋 **Two:** second\n  - 📋 nested step [a](https://example.com/a)\n  more of two";

    fn done(text: &str, block: &str, line: usize) -> Result<(String, Undo), String> {
        remove(text, text, block, line)
    }

    #[test]
    fn done_removes_the_item_and_its_nested_lines_only() {
        let (out, undo) = done(FILE, TWO, 4).unwrap();
        assert_eq!(
            out,
            "# Needs you\n\n## Today\n- 📋 **One:** first\n- 📋 **Three:** third\n\n## Later\n- 📋 **Four:** fourth\n"
        );
        assert_eq!(
            (undo.at, undo.after.as_deref()),
            (4, Some("- 📋 **One:** first"))
        );
        assert_eq!(
            restore(&out, &undo).unwrap(),
            FILE,
            "undo puts back that block alone"
        );
    }

    #[test]
    fn a_trailing_blank_line_in_the_block_is_not_part_of_it() {
        let (out, _) = done(FILE, "- 📋 **Three:** third\n\n", 7).unwrap();
        assert!(out.contains("of two\n\n## Later"), "{out}");
    }

    #[test]
    fn a_file_changed_since_the_wall_read_it_is_refused() {
        // An agent added a line above, or edited the item: the wall's lines and line no longer hold.
        let moved = format!("x\n{FILE}");
        assert_eq!(remove(&moved, FILE, TWO, 4).unwrap_err(), CHANGED);
        assert_eq!(remove(&moved, FILE, TWO, 5).unwrap_err(), CHANGED);
        // Shown afresh, the same item goes from its new line.
        let (out, _) = remove(&moved, &moved, TWO, 5).unwrap();
        assert!(!out.contains("**Two:**") && out.starts_with("x\n"), "{out}");
    }

    #[test]
    fn an_item_not_at_its_line_is_refused() {
        for (block, line) in [
            ("- 📋 **Two:** second, edited", 4),
            ("- 📋 **Two:** second", 3),
            (TWO, 3),
            ("- 📋 **Five:** none", 4),
            (TWO, 99),
        ] {
            assert_eq!(
                done(FILE, block, line).unwrap_err(),
                GONE,
                "{block} at {line}"
            );
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
            assert_eq!(done(FILE, block, 0).unwrap_err(), NOT_ITEM, "{block:?}");
        }
        for ok in [
            "* x", "+ x", "1. x", "2) x", "  - x", "-\tx", "-", "- ", "1.",
        ] {
            assert!(is_item(ok), "{ok:?}");
        }
        let (out, _) = done("- a\n-\n- b\n", "-", 1).unwrap();
        assert_eq!(out, "- a\n- b\n", "an empty item goes too");
    }

    #[test]
    fn crlf_files_keep_their_line_endings() {
        let crlf = FILE.replace('\n', "\r\n");
        let (out, undo) = done(&crlf, "- 📋 **One:** first", 3).unwrap();
        assert!(
            !out.contains("One") && !out.replace("\r\n", "").contains('\n'),
            "{out:?}"
        );
        assert_eq!(restore(&out, &undo).unwrap(), crlf);
    }

    #[test]
    fn a_lone_carriage_return_ends_a_line_as_it_does_for_the_wall() {
        let text = "- 📋 a\rb\n- 📋 c\n- 📋 d\n";
        let (out, undo) = done(text, "- 📋 c", 2).unwrap();
        assert_eq!(out, "- 📋 a\rb\n- 📋 d\n");
        assert_eq!(restore(&out, &undo).unwrap(), "- 📋 a\rb\n- 📋 c\n- 📋 d\n");
        let (out, _) = done(text, "- 📋 a\nb", 0).unwrap();
        assert_eq!(out, "- 📋 c\n- 📋 d\n");
    }

    #[test]
    fn a_lone_carriage_return_before_a_blank_line_keeps_the_blank_line() {
        let (out, undo) = done("* c\r-\n\n> q\n", "-", 1).unwrap();
        assert_eq!(out, "* c\r\n\n> q\n", "the blank line stays its own line");
        assert_eq!(
            lines(&restore(&out, &undo).unwrap())
                .iter()
                .map(|l| bare(l))
                .collect::<Vec<_>>(),
            ["* c", "-", "", "> q"]
        );
    }

    #[test]
    fn twins_go_by_their_line_and_come_back_to_it() {
        let text = "## Today\n- 📋 a\n- 📋 a\n- 📋 b\n";
        for line in [1, 2] {
            let (out, undo) = done(text, "- 📋 a", line).unwrap();
            assert_eq!(out, "## Today\n- 📋 a\n- 📋 b\n");
            assert_eq!(
                restore(&out, &undo).unwrap(),
                text,
                "undo of twin {line} puts it back"
            );
        }
    }

    #[test]
    fn undo_follows_its_neighbour_when_the_file_moved_and_keeps_others_edits() {
        let (out, undo) = done(FILE, "- 📋 **Three:** third", 7).unwrap();
        let edited = format!("NEW TOP\n{}", out.replace("fourth", "fourth, edited"));
        assert_eq!(
            restore(&edited, &undo).unwrap(),
            format!("NEW TOP\n{}", FILE.replace("fourth", "fourth, edited"))
        );
    }

    #[test]
    fn undo_with_its_neighbour_gone_goes_back_to_its_old_place() {
        let (out, undo) = done(FILE, "- 📋 **Three:** third", 7).unwrap();
        assert_eq!(undo.after.as_deref(), Some("  more of two"));
        let back = restore(&out.replace("  more of two\n", ""), &undo).unwrap();
        let at: Vec<&str> = back.lines().collect();
        assert_eq!(at[undo.at], "- 📋 **Three:** third", "{back}");
    }

    #[test]
    fn undo_at_the_end_of_a_file_without_a_final_newline() {
        let (out, undo) = done("- 📋 a\n- 📋 b", "- 📋 b", 1).unwrap();
        assert_eq!(out, "- 📋 a\n");
        assert_eq!(restore(&out, &undo).unwrap(), "- 📋 a\n- 📋 b\n");
        let (_, undo) = done("- 📋 a\n- 📋 b\n", "- 📋 b", 1).unwrap();
        assert_eq!(restore("- 📋 a", &undo).unwrap(), "- 📋 a\n- 📋 b\n");
    }

    #[test]
    fn an_undo_token_from_an_older_build_still_restores() {
        let old: Undo =
            serde_json::from_str(r#"{"block":"- 📋 b","after":"- 📋 a","at":1}"#).unwrap();
        assert_eq!(restore("- 📋 a\n", &old).unwrap(), "- 📋 a\n- 📋 b\n");
    }

    /// A small deterministic generator, so the sweep below needs no crate.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self, n: usize) -> usize {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            (self.0 % n as u64) as usize
        }
    }

    #[test]
    fn any_lines_the_wall_names_go_alone_and_come_back_byte_for_byte() {
        let parts = [
            "- 📋 a", "- 📋 a", "  - sub", "  more", "", "## H", "1. n", "-", "---", "> q", "```",
            "text", "* c", "   - x",
        ];
        let eols = ["\n", "\r\n", "\r"];
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        let mut checked = 0;
        for _ in 0..3000 {
            let n = 1 + rng.next(12);
            let mut text = String::new();
            for _ in 0..n {
                text.push_str(parts[rng.next(parts.len())]);
                let mixed = rng.next(4) == 0;
                text.push_str(eols[rng.next(if mixed { 3 } else { 1 })]);
            }
            if rng.next(5) == 0 {
                text.pop(); // no final line ending
            }
            let have = lines(&text);
            for line in 0..have.len() {
                if !is_item(bare(have[line])) {
                    continue;
                }
                let len = 1 + rng.next(3).min(have.len() - line - 1);
                let block: Vec<&str> = have[line..line + len].iter().map(|l| bare(l)).collect();
                if block.last().is_some_and(|l| l.trim().is_empty()) {
                    continue; // the wall trims an item's trailing blank lines, so no block ends in one
                }
                let Ok((out, undo)) = done(&text, &block.join("\n"), line) else {
                    continue; // a block whose own last lines are blank is trimmed; not a wall block
                };
                let gone = line..line + block_lines(&block.join("\n")).len();
                let kept: Vec<&str> = (0..have.len())
                    .filter(|i| !gone.contains(i))
                    .map(|i| bare(have[i]))
                    .collect();
                assert_eq!(
                    lines(&out).iter().map(|l| bare(l)).collect::<Vec<_>>(),
                    kept,
                    "{text:?} line {line}"
                );
                let back = restore(&out, &undo).unwrap();
                assert_eq!(
                    lines(&back).iter().map(|l| bare(l)).collect::<Vec<_>>(),
                    have.iter().map(|l| bare(l)).collect::<Vec<_>>(),
                    "{text:?} line {line}"
                );
                checked += 1;
            }
        }
        assert!(checked > 5000, "{checked}");
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
        let d = mark_done(&path, FILE, "- 📋 **One:** first", 3).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains("**One:**"), "{after}");
        assert_eq!(d.text, after, "Done answers with the file as written");
        assert_eq!(undo_done(&path, &d.undo).unwrap(), FILE);
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
    fn mark_done_refuses_and_leaves_the_file() {
        let dir = Scratch::new("needs-gone");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        assert_eq!(mark_done(&path, FILE, "- 📋 nope", 3).unwrap_err(), GONE);
        assert_eq!(
            mark_done(&path, "older text", "- 📋 **One:** first", 3).unwrap_err(),
            CHANGED
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), FILE);
        assert!(mark_done(&dir.0.join("missing.md"), "", "- 📋 x", 0)
            .unwrap_err()
            .contains("no Needs you file"));
    }

    #[test]
    fn a_write_between_the_read_and_the_rename_is_kept_and_done_refused() {
        let dir = Scratch::new("needs-race");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let calls = std::cell::Cell::new(0);
        let err = rewrite(&path, |text| {
            calls.set(calls.get() + 1);
            if calls.get() == 1 {
                // Another writer saves after our read, before our rename.
                std::fs::write(&path, format!("{text}- 📋 added by an agent\n")).unwrap();
            }
            remove(text, FILE, "- 📋 **One:** first", 3)
        })
        .unwrap_err();
        assert_eq!(
            (calls.get(), err.as_str()),
            (2, CHANGED),
            "read afresh, then refused"
        );
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("added by an agent") && after.contains("**One:**"),
            "{after}"
        );
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
            Ok((format!("{text}OURS\n"), ()))
        })
        .unwrap_err();
        assert_eq!((err.as_str(), n.get()), (BUSY, TRIES));
        assert!(!std::fs::read_to_string(&path).unwrap().contains("OURS"));
    }

    #[test]
    fn done_and_undo_return_the_file_as_written() {
        let dir = Scratch::new("needs-text");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        let d = mark_done(&path, FILE, "- 📋 **One:** first", 3).unwrap();
        assert_eq!(d.text, std::fs::read_to_string(&path).unwrap());
        assert_eq!(undo_done(&path, &d.undo).unwrap(), FILE);
    }

    #[cfg(unix)]
    #[test]
    fn done_keeps_the_file_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = Scratch::new("needs-mode");
        let path = dir.0.join("needs-you.md");
        std::fs::write(&path, FILE).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        mark_done(&path, FILE, "- 📋 **One:** first", 3).unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_is_not_written_through() {
        let dir = Scratch::new("needs-link");
        let real = dir.0.join("real.md");
        std::fs::write(&real, FILE).unwrap();
        let path = dir.0.join("needs-you.md");
        std::os::unix::fs::symlink(&real, &path).unwrap();
        assert!(mark_done(&path, FILE, "- 📋 **One:** first", 3)
            .unwrap_err()
            .contains("not a regular file"));
        assert_eq!(std::fs::read_to_string(&real).unwrap(), FILE);
    }
}
