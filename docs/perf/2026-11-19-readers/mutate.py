import subprocess
import sys
import os

root = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "../../../src-tauri/fleet"
)
M = [
    (
        "kept value never served",
        "src/memo.rs",
        "                if stamp == listed {",
        "                if false && stamp == listed {",
    ),
    (
        "stamp not compared",
        "src/memo.rs",
        "                if stamp == listed {",
        "                if true || stamp == listed {",
    ),
    (
        "racy rule off",
        "src/memo.rs",
        ".is_ok_and(|d| d > RACY)",
        ".is_ok_and(|_| true)",
    ),
    (
        "listed vs held not compared",
        "src/memo.rs",
        "            if listed == held && still(&held) {",
        "            if still(&held) {",
    ),
    (
        "pass end keeps nothing",
        "src/memo.rs",
        "        self.memo.kept = std::mem::take(&mut self.memo.seen);",
        "        self.memo.seen.clear();",
    ),
    (
        "pass end forgets nothing",
        "src/memo.rs",
        "        self.memo.kept = std::mem::take(&mut self.memo.seen);",
        "        let s = std::mem::take(&mut self.memo.seen); self.memo.kept.extend(s);",
    ),
    (
        "reader rescans afresh",
        "src/watch.rs",
        "        let listing = self.scanner.scan(&self.fleet);",
        "        let listing = { self.scanner = Scanner::default(); self.scanner.scan(&self.fleet) };",
    ),
    (
        "usage reader made per read",
        "src/usage.rs",
        "        let now = crate::memo::now();\n        let mut pass = self.memo.pass();",
        "        let now = crate::memo::now();\n        self.memo = Memo::default();\n        let mut pass = self.memo.pass();",
    ),
    (
        "change time not stamped",
        "src/memo.rs",
        "            changed,\n            id: meta.ino(),",
        "            changed: SystemTime::UNIX_EPOCH,\n            id: meta.ino(),",
    ),
    # Equivalent on Linux: every replace (rename, recreate, `ln -f`) moves
    # the inode's ctime, which the stamp already holds, so no test can tell
    # it apart. winmutate.sh's "listing file id dropped" is killed on NTFS.
    (
        "file id not stamped",
        "src/memo.rs",
        "            id: meta.ino(),",
        "            id: 0,",
        "equivalent",
    ),
    (
        "still by the write time alone",
        "src/memo.rs",
        "        self.modified.max(self.changed)",
        "        self.modified",
    ),
    (
        "second ask in a pass reads again",
        "src/memo.rs",
        "            if let Some((stamp, value)) = memo.seen.get(path) {",
        "            if let Some((stamp, value)) = memo.seen.get(path).filter(|_| false) {",
    ),
    (
        "listing stamp follows links (dir type)",
        "src/memo.rs",
        "        if !meta.is_file() {\n            return None;",
        "        if meta.is_symlink() {\n            return None;",
    ),
    (
        "listing gives no stamps",
        "src/memo.rs",
        "            let stamp = (kind == Kind::File)\n                .then(|| meta.as_ref().and_then(Stamp::of))\n                .flatten();",
        "            let stamp: Option<Stamp> = None;\n            let _ = &meta;",
    ),
    (
        "usage: listed stamp dropped (always None)",
        "src/usage.rs",
        "            Some((e.modified?, dir.join(&e.name), e.stamp))",
        "            Some((e.modified?, dir.join(&e.name), None))",
    ),
]


def run():
    return subprocess.run(
        ["cargo", "test", "-q", "--lib"],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=600,
    )


# The unmutated code must pass first, or every mutant reads as killed.
base = run()
if base.returncode != 0:
    sys.exit(
        "baseline fails: fix the tests before reading any mutant\n"
        + (base.stdout + base.stderr)[-2000:]
    )
print("baseline: pass", flush=True)
for name, f, old, new, *expect in M:
    p = os.path.join(root, f)
    orig = open(p).read()
    assert orig.count(old) == 1, (name, orig.count(old))
    open(p, "w").write(orig.replace(old, new))
    try:
        r = run()
        out = r.stdout + r.stderr
        fails = [
            ln.strip()
            for ln in out.splitlines()
            if ln.startswith("    ") and "::" in ln and " " not in ln.strip()
        ]
        verdict = "KILLED" if r.returncode != 0 else "SURVIVED"
        if expect:
            verdict = "EQUIVALENT, survived as expected" if r.returncode == 0 else "KILLED (expected equivalent)"
        print(f"{verdict}: {name} :: {', '.join(sorted(set(fails)))[:300]}", flush=True)
    finally:
        open(p, "w").write(orig)
