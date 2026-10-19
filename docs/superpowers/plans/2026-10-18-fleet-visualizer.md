# Fleet Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every running Claude Code session beside the usage gauge: how many are up, where each works, which need AJ and why, and what each was last asked and said, at close to no cost while nothing changes.

**Architecture:** A bash and jq hook, registered async on nine Claude Code events, keeps one JSON file per session in the overlay's data dir, and the status line adds a heartbeat file. A Rust crate free of Tauri, in the app's Cargo workspace, reads that folder (a notify watcher plus a 5 s re-read), decides each session's status, orders the sessions, and a hub hands each snapshot to the webviews over Tauri channels. The gauge window shows a strip of portraits; a second window, made on the first click, shows a card per session with a jump back to its Windows Terminal tab through UI Automation. Data flows one way: hook to file, file to reader, reader to webview.

**Tech Stack:** Bash 5, jq 1.7 and flock (the hooks, WSL side); Rust 2021, Tauri 2.12, serde, notify 8.2, windows 0.62; ES modules and CSS with no framework, tested with `node --test`; DiceBear 9.4.2 and Pillow 13.0.0 at asset-generation time only; shellcheck through `uvx --from shellcheck-py`.

**Spec:** `docs/superpowers/specs/2026-10-18-fleet-visualizer-design.md`

**Checked before writing:** every code block below was applied to a scratch copy of this worktree in this order. Each test step failed as its Expected line says, each implementation step passed, each commit left the tree clean, and at every Windows check `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` passed on Windows. Task 16's screenshots were taken from the finished copy, and Task 17's live memory sample was taken with the same script while klepsydra ran (122.6 MB).

## Global Constraints

- It never shows a confident wrong status. Every status carries its age.
- Nothing on the Windows side starts a process, and nothing crosses into WSL to ask for state. State arrives as files.
- Jump to terminal uses Windows UI Automation, an in-process API.
- It adds one window at most beyond the gauge, and that window exists only after the first click.
- AJ keeps his workflow: ordinary Windows Terminal tabs, one `claude` each. Nothing has to be launched through klepsydra.
- keryx owns all audio. The visualizer makes no sound.
- While nothing changes, it must cost close to nothing.
- Each guard in the rejected-ideas table is written and passing before any feature code exists.
- Data flows one way: hook to file, file to reader, reader to webview.
- Every fleet hook is registered with `async: true`; it prints nothing and always exits 0.
- The hook writes only when a field changed. Each write goes to a temp file in the same directory, then `mv` replaces the session file.
- It never records tool input beyond the tool name and an edited file's path.
- Prompt and reply: the first 300 characters.
- A prompt starting `<task-notification>` (a background subagent's report) sets `working` but keeps the last prompt; pasted text arrives inside `<pasted_content>` and must not match.
- The hook never runs `git`; it reads `.git` directly, as keryx's `source_name` does. A worktree resolves to its main checkout's name plus its own name; the branch comes from `HEAD`.
- "Where now" is the repo of the last edit, or of `cwd` when nothing was edited yet. "Touched" keeps the last six other repos with their last times.
- Heartbeat: written at most once per 10 s unless the name changed; `statusLine.refreshInterval: 30`.
- Silent: a beat more than 90 s old (three missed 30 s heartbeats) with nothing newer, shown as "no word for <age>", never as "working".
- The reader re-reads every 5 s, matching the gauge's `POLL_MS`, and ignores `.tmp` files.
- A file with an unknown `v`, or a malformed one, is skipped and logged once; the rest of the fleet renders.
- An `ended` card stays 10 minutes.
- Prune at `SessionStart` only: the Claude process is gone (pid missing, or start time changed) and the last event is over 24 hours old; only `fleet/<uuid>.json` and `fleet/<uuid>.beat`, inside an absolute `KLEPSYDRA_DIR` named `dev.ajsoftworks.klepsydra`.
- If the fleet directory does not exist, the strip is empty and the gauge renders as before.
- Order: `needs_you` (longest wait first), `error`, `working`, `done` (newest first), `new`, `silent`, `ended`. A session that starts needing AJ moves to the front.
- A portrait is 28 px at 100%, scaled from the gauge's `--scale`.
- Badges carry shape, symbol, text and colour together: needs you `#E69F00` diamond `!`; error `#D55E00` square `×`; working `#0072B2` circle `…`; done `#009E73` circle `✓`; not started, silent and ended grey outline circles `○`, `?`, `–`. Each meets 3:1 against the strip's backdrop.
- One pulse when a session starts needing AJ, then a static badge; no pulse under `prefers-reduced-motion`.
- Ages read `2m`, `1h`, `3d`. A card's "updated" line appears once its newest field is older than 5 minutes.
- Each portrait is a button named like "Hephaestus, needs you, approve Bash, 2 minutes". The wall has a polite live region for state changes.
- The portrait is chosen from identity only, never from state.
- The wall is a normal window: resizable, not always on top, its position remembered by the window-state plugin, created from an async command on the first click and after that hidden and shown, never destroyed; three columns of cards at 1920 px, reflowing below.
- Faces: the ten portraits cut to 96 px and 192 px WebP; Lorelei faces from `@dicebear/core@9.4.2` and `@dicebear/lorelei@9.4.2` (exact versions) for every Kokoro voice plus 24 fallbacks; every file under `src/fleet/faces/` listed in `faces/LICENSES.json` with its source and license. The frontend loads no library and fetches nothing at run time.
- Memory: klepsydra's working set at 5 minutes and at 8 hours, in the release checklist; the release is blocked if it grew more than 10%.
- Repo conventions: comments only where they help the reader execute; no em-dashes in docs; every CSS size in the gauge window goes through `--scale`; fleet Rust goes in new modules, not `main.rs`; Python through `uv`, never pip; commit only the named paths (`git commit -m ... -- <paths>`) with no attribution lines; never stage `COMMITS.md`.

## Review Focus

1. A `PostToolUse` that is not the asker's (a parallel tool in the same turn, or a background subagent's tool) clears "needs you" while AJ is still being asked. Tests in Task 4: `another tool finishing leaves it waiting`, `a subagent's tool finishing leaves it waiting`, `the main thread's tool does not clear a subagent's request`.
2. Claude Code starts each async hook as its own process, so one session's events race on one file and an update is lost. Test in Task 4: `parallel events: no update lost` (twelve concurrent edits); Task 4 step 6 shows it fails without the lock.
3. WSL's clock drifts from Windows' after the host sleeps, so ages read wrong and a dead session can hide from the silent rule. Tests in Task 8: `a_writer_clock_ten_minutes_ahead_is_put_back`, `a_writer_clock_behind_is_put_forward_and_cannot_hide_silence`; in Task 11, a time ahead of the clock reads `<1m`.
4. Jump matches by title containment, so a name inside another tab's title, two sessions with one generated title, or the status glyph before a title could jump to the wrong tab. Tests in Task 12: `a_name_inside_two_titles_is_refused_not_guessed`, `two_sessions_with_one_title_are_refused`, `the_tab_titled_with_the_name_after_a_glyph`.
5. The hook meets sessions mid-life: installed while they run, resumed after their file was pruned, `/compact`'s `SessionStart`, a late event after `SessionEnd`. Tests in Task 4: `installed mid-session: created from any event`, `resumed: done, since it has a prompt`, `compaction keeps the state`, `a late event cannot revive it`, `an end for an unknown session writes nothing`.

## Where this plan reads the spec

- The reader is a workspace crate, `src-tauri/fleet`, with only the Tauri glue in `src-tauri/src/fleet.rs`: WSL has no WebKitGTK headers, so only a crate free of Tauri can be tested there.
- Snapshots reach the webviews over a Tauri `Channel` handed to the `fleet_subscribe` command, not a global event: a channel needs no capability file, while `listen` would need `core:event:default` granted to both windows.
- The default display name (`my-app-3f`) reaches no hook and no status line: `SessionStart` carries `session_title` only for a custom name, and the default name does not populate the status line's `session_name`. The file's `name` holds `session_title`; the card and Jump use the beat's `session_name`; a session with neither is named by its launch folder.
- `NotebookEdit` names its file `tool_input.notebook_path`, not `file_path`; the hook reads either.
- The hook fixtures follow the hooks reference's documented payloads field for field (2026-10) rather than captures; the live check in Task 17 confirms the real payloads end to end against the session files.
- `PostToolUse` clears "needs you" only for the tool and thread (main, or a subagent's `agent_id`) that asked.
- Silent needs both the beat and the session file to be over 90 s old. Read literally, "whose last event is older still" would leave a session whose last write followed its last beat "working" forever.
- A keryx blend voice (`af_heart(0.5)+af_bella(0.5)`, handed out once all 14 pool voices are held) gets a fallback face chosen by a hash of the voice, and the name "Heart and Bella".
- kourai's code casts Puck `am_adam`, Mneme `af_nicole`, Dokimasia `af_jessica` and Cupid `af_sky`; none is in keryx's rotation pool, so the pool rule gives `am_puck` (as the spec names), `bf_isabella`, `af_aoede` and `af_heart`.
- The session file adds `needs` (who asked, for which tool), `where.by`, `ended` and `written_at` (for clock skew) to the spec's example.
- Badge contrast is measured against a ring in the panel colour drawn round every badge, which is its adjacent colour on any desktop. Without the ring, the panel over a white desktop is `#3e3e3e`, against which `#0072B2` is 2.1:1.
- Every portrait carries its status badge; only the needs-you badge pulses.
- The repo had no release checklist; Task 17 adds README `## Releasing`.

## File Structure

Fleet hook (WSL side):
- `hooks/klepsydra-fleet.sh`: turns each hook event into the session file; where, identity, the lock, pruning.
- `hooks/test_fleet.sh`: its tests, the keryx parity check, the README settings block check.
- `hooks/fixtures/*.json`, `hooks/fixtures/lagging-transcript.jsonl`: one input per event type.
- `statusline/klepsydra-statusline.sh`: adds the heartbeat; shares the data-dir block with the hook, byte for byte.
- `statusline/test_statusline.sh`, `statusline/fixtures/named-session.json`: heartbeat tests.

Fleet reader (Rust):
- `src-tauri/Cargo.toml`: makes `src-tauri` a workspace; adds `klepsydra-fleet` and, on Windows, `windows`.
- `src-tauri/fleet/Cargo.toml`, `src-tauri/fleet/src/lib.rs`: the crate.
- `src-tauri/fleet/src/session.rs`: the v1 session file and the beat line.
- `src-tauri/fleet/src/view.rs`: status, silence, clock skew, order; the snapshot a webview receives.
- `src-tauri/fleet/src/scan.rs`: reads the folder; reports each bad file once.
- `src-tauri/fleet/src/watch.rs`: the watcher and the 5 s re-read.
- `src-tauri/fleet/src/hub.rs`: who follows the fleet; the card the wall shows next.
- `src-tauri/fleet/src/tabs.rs`: which terminal tab is a session's.
- `src-tauri/src/fleet.rs`: Tauri glue: the reader thread, `fleet_subscribe`, `open_wall`.
- `src-tauri/src/jump.rs`: `jump_to_terminal` through UI Automation (Windows only).
- `src-tauri/src/geometry.rs`: adds `hit_area` and `contains`.
- `src-tauri/src/main.rs`: wires the above; the pointer watcher also takes the strip.

Frontend:
- `src/fleet/model.js`: everything the strip and the wall show, free of the DOM.
- `src/fleet/strip.js`: draws the strip in the gauge window.
- `src/wall.html`, `src/fleet/wall.js`, `src/fleet/wall.css`: the card wall.
- `src/fleet/badge.css`: badge colours, shapes and the one pulse, shared by both windows.
- `src/fleet/face.js`: picks the 96 px or 192 px face file.
- `src/fleet/cast.json`: voice to character, the Lorelei voices, the fallback count.
- `src/fleet/faces/`: every face, and `LICENSES.json`.
- `src/index.html`, `src/style.css`, `src/main.js`: the gauge window gains `#frame` and `#strip`.
- `src/guards.test.js`: the rejected-ideas guards.
- `src/fleet-model.test.js`, `src/fleet-cast.test.js`, `src/fleet-style.test.js`: model, cast and style tests.

Scripts and docs:
- `scripts/render-faces.sh`, `scripts/render-lorelei.mjs`, `scripts/cut-portraits.py`: make the faces once.
- `scripts/measure-memory.sh`, `scripts/test_measure_memory.sh`: the release memory rule.
- `scripts/fleet-status.sh`: prints the session files for the live check.
- `scripts/build-windows.sh`: adds `--check`; `scripts/build-linux.sh`, `.gitignore`, `scripts/visual-check.sh`: the strip and wall in the harness.
- `.github/workflows/ci.yml`: hook and memory tests, shellcheck over `hooks/`, workspace-wide cargo.
- `README.md`, `IMPL.md`, `ROADMAP.md`, `.claude/skill-context.md`.

## Tasks

### Task 1: Static guards for the rejected ideas

**Files:**

- Create: `src/guards.test.js`
- Create: `src/fleet/faces/LICENSES.json`

**Interfaces:**

- **Consumes:** `src-tauri/tauri.conf.json` (`app.windows[].label`); every `.rs` under `src-tauri/src/` and `src-tauri/fleet/src/`; every `.js`, `.mjs` and `.html` under `src/` except `*.test.js`; every `.css` under `src/`; `src-tauri/Cargo.toml`, `src-tauri/fleet/Cargo.toml` (once it exists), `package.json`.
- **Produces:** `src/guards.test.js` exporting `filesUnder(dir: string, exts: string[], root?: string): string[]`, `spawns(text: string): string[]`, `mentionsWsl(text: string): boolean`, `makesSound(text: string): string[]`, `loopsForever(css: string): boolean`, `animatesWithoutReducedMotion(css: string): boolean`, `unlicensed(dir: string): { missing: string[], stale: string[] }`. `src/fleet/faces/LICENSES.json`: `{ "<path under faces/>": { "source": string, "license": string } }`, empty for now; Task 7 fills it.

- [ ] **Step 1: Write the guards**

Each guard scans the whole app (Rust, frontend, CSS, manifests), not only fleet files, so none can pass by finding nothing to read; the first test fails if the scan comes back empty. Each detector also gets a planted violation it must catch.

Create `src/guards.test.js`:

```js
// Guards for the fleet visualizer's rejected ideas. Each one scans the whole
// app, not only fleet files, so a guard cannot pass by finding nothing to read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

/** Repo-relative paths of the files under `dir` with one of `exts`; none when `dir` is absent. */
export function filesUnder(dir, exts, root = ROOT) {
  const abs = join(root, dir);
  if (!existsSync(abs)) return [];
  return readdirSync(abs, { recursive: true })
    .map((f) => join(abs, f))
    .filter((f) => statSync(f).isFile() && exts.includes(extname(f)))
    .map((f) => relative(root, f).split(sep).join("/"));
}

const read = (f) => readFileSync(join(ROOT, f), "utf8");
const stripCssComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, "");

const RUST = [...filesUnder("src-tauri/src", [".rs"]), ...filesUnder("src-tauri/fleet/src", [".rs"])];
const FRONTEND = filesUnder("src", [".js", ".mjs", ".html"]).filter((f) => !f.endsWith(".test.js"));
const CSS = filesUnder("src", [".css"]);
const MANIFESTS = ["src-tauri/Cargo.toml", "src-tauri/fleet/Cargo.toml", "package.json"].filter((f) =>
  existsSync(join(ROOT, f)),
);

// Starting a process, from Rust or from the webview.
const SPAWN = [
  /Command::new/,
  /std::process/,
  /process::Command/,
  /tauri[-_]plugin[-_]shell/,
  /plugin[-:]shell/,
  /__TAURI__\.shell/,
  /child_process/,
  /CreateProcess/,
  /ShellExecute/,
];
export const spawns = (text) => SPAWN.filter((re) => re.test(text)).map(String);

export const mentionsWsl = (text) => /wsl/i.test(text);

const SOUND = [/\bAudio\b/, /AudioContext/, /speechSynthesis/i, /SpeechSynthesis/, /<audio\b/i, /\.play\(\)/];
export const makesSound = (text) => SOUND.filter((re) => re.test(text)).map(String);

export const loopsForever = (css) => /\binfinite\b/.test(stripCssComments(css));

/** CSS that animates must also turn the animation off under reduced motion. */
export function animatesWithoutReducedMotion(css) {
  const body = stripCssComments(css);
  const animates = /@keyframes\b/.test(body) || /animation(-name)?\s*:\s*(?!none\b)[\w-]/.test(body);
  return animates && !/@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)/.test(body);
}

/** Files under a faces dir with no LICENSES.json entry naming a source and a license, and entries with no file. */
export function unlicensed(dir) {
  const licenses = JSON.parse(readFileSync(join(dir, "LICENSES.json"), "utf8"));
  const files = readdirSync(dir, { recursive: true })
    .filter((f) => statSync(join(dir, f)).isFile())
    .map((f) => f.split(sep).join("/"))
    .filter((f) => f !== "LICENSES.json");
  const named = (e) => typeof e?.source === "string" && e.source.trim() && typeof e?.license === "string" && e.license.trim();
  return {
    missing: files.filter((f) => !named(licenses[f])),
    stale: Object.keys(licenses).filter((k) => !files.includes(k)),
  };
}

test("the guards read real sources", () => {
  assert.ok(RUST.includes("src-tauri/src/main.rs"), "Rust sources not found");
  assert.ok(FRONTEND.includes("src/main.js"), "frontend sources not found");
  assert.ok(CSS.includes("src/style.css"), "CSS not found");
});

test("nothing starts a process", () => {
  for (const f of [...RUST, ...FRONTEND, ...MANIFESTS]) assert.deepEqual(spawns(read(f)), [], f);
});

test("the spawn check catches each way of starting one", () => {
  for (const planted of [
    'std::process::Command::new("wsl.exe")',
    "use std::process;",
    'tauri-plugin-shell = "2"',
    "window.__TAURI__.shell.open(url)",
    'import { exec } from "node:child_process";',
  ]) {
    assert.notDeepEqual(spawns(planted), [], planted);
  }
});

test("nothing names wsl", () => {
  for (const f of [...RUST, ...FRONTEND]) assert.equal(mentionsWsl(read(f)), false, f);
  assert.equal(mentionsWsl('let x = "C:\\\\Windows\\\\System32\\\\wsl.exe";'), true);
});

test("the frontend makes no sound", () => {
  for (const f of FRONTEND) assert.deepEqual(makesSound(read(f)), [], f);
  for (const planted of ["new Audio(src)", "speechSynthesis.speak(u)", "<audio src=x>", "ctx = new AudioContext()"]) {
    assert.notDeepEqual(makesSound(planted), [], planted);
  }
});

test("no CSS animation runs forever, and every animation stops under reduced motion", () => {
  for (const f of CSS) {
    assert.equal(loopsForever(read(f)), false, f);
    assert.equal(animatesWithoutReducedMotion(read(f)), false, f);
  }
  assert.equal(loopsForever(".x { animation: pulse 1s infinite; }"), true);
  assert.equal(loopsForever("/* infinite */ .x { color: red; }"), false);
  assert.equal(animatesWithoutReducedMotion(".x { animation: pulse 1s 1; }"), true);
  assert.equal(
    animatesWithoutReducedMotion(".x { animation: pulse 1s 1; } @media (prefers-reduced-motion: reduce) { .x { animation: none; } }"),
    false,
  );
});

test("every face has a license entry, and every entry a face", () => {
  assert.deepEqual(unlicensed(join(ROOT, "src/fleet/faces")), { missing: [], stale: [] });
});

test("the license check catches an unlisted face and a stale entry", () => {
  const dir = mkdtempSync(join(tmpdir(), "faces-"));
  mkdirSync(join(dir, "kourai"));
  writeFileSync(join(dir, "kourai", "puck-96.webp"), "");
  writeFileSync(join(dir, "gone.svg"), "");
  writeFileSync(
    join(dir, "LICENSES.json"),
    JSON.stringify({ "gone.svg": { source: "x", license: "" }, "old.svg": { source: "x", license: "MIT" } }),
  );
  assert.deepEqual(unlicensed(dir), { missing: ["gone.svg", "kourai/puck-96.webp"].sort(), stale: ["old.svg"] });
});

test("the gauge is the only window declared, and nothing else is made always on top", () => {
  const conf = JSON.parse(read("src-tauri/tauri.conf.json"));
  assert.deepEqual(conf.app.windows.map((w) => w.label), ["main"]);
  for (const f of RUST) assert.doesNotMatch(read(f), /always_on_top\(\s*true\s*\)/, f);
});
```

- [ ] **Step 2: Run the guards and watch the license guard fail**

Run:

```bash
node --test src/guards.test.js
```

Expected: FAIL: `every face has a license entry, and every entry a face` throws `ENOENT: no such file or directory, open '.../src/fleet/faces/LICENSES.json'`. The other 8 tests pass: today's code already obeys every guard.

- [ ] **Step 3: Create the empty license register**

Create `src/fleet/faces/LICENSES.json`:

```json
{}
```

- [ ] **Step 4: Run the guards again**

Run:

```bash
node --test src/*.test.js
```

Expected: PASS: 63 tests, the 9 guards among them.

- [ ] **Step 5: Commit**

```bash
git add src/guards.test.js src/fleet/faces/LICENSES.json && git commit -m "test: guard the fleet's rejected ideas before any feature code" -- src/guards.test.js src/fleet/faces/LICENSES.json
```

### Task 2: Fleet hook: where a session works

**Files:**

- Create: `hooks/test_fleet.sh`
- Create: `hooks/klepsydra-fleet.sh`
- Modify: `statusline/klepsydra-statusline.sh` (lines 14, 22, 29-32)
- Modify: `.github/workflows/ci.yml` (lines 37-38)

**Interfaces:**

- **Consumes:** keryx's `source_name(cwd: str) -> str` in `$KERYX_SRC/keryx/hook.py` (default `$HOME/ajsoftworks/keryx/src`), run with `python3 -I` for a parity check that is skipped, with a printed line, when keryx is not on the machine.
- **Produces:** `hooks/klepsydra-fleet.sh`, sourceable without running anything (a `[[ "${BASH_SOURCE[0]}" == "$0" ]]` guard), which sets `KLEPSYDRA_DIR` exactly as the statusline does and defines `UUID_RE` and:
  - `git_where PATH`: sets the globals `where_repo`, `where_worktree`, `where_branch` (empty strings when none). A linked worktree gives the main checkout's folder name as `where_repo` and the worktree's folder as `where_worktree`; a submodule gives its own folder; a path outside any repo gives its own last component.
  - `branch_of GITDIR`: sets `where_branch` from `GITDIR/HEAD`: the branch after `refs/heads/`, or the first 7 characters of a detached commit.
- `hooks/test_fleet.sh` with `check NAME GOT WANT`, the scratch dir `$work`, and the repos under `$work/repos` that later tasks reuse.
- The block between `# --- klepsydra dir` and `# --- end klepsydra dir ---` is byte-identical in the hook and the statusline, and a test holds it so (the two scripts are installed as separate files, so they cannot share one).

- [ ] **Step 1: Write the failing test**

The repos are made by git itself, so the layouts are real: a main checkout with a linked worktree, a superproject with a submodule, a detached HEAD, and a folder outside any repo.

Create `hooks/test_fleet.sh`:

```bash
#!/usr/bin/env bash
# Fixture-driven tests for the fleet hook. Run: bash hooks/test_fleet.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/klepsydra-fleet.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

# shellcheck source=hooks/klepsydra-fleet.sh
source "$hook"

echo "where"

# Repos laid out by git itself: a main checkout with a linked worktree, a
# superproject with a submodule, and a folder outside any repo.
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main \
  -c protocol.file.allow=always "$@"; }
repos="$work/repos"
mkdir -p "$repos/loose/notes"
for r in klepsydra ideas subsrc; do
  g init -q "$repos/$r" && g -C "$repos/$r" commit -q --allow-empty -m init
done
g -C "$repos/klepsydra" worktree add -q -b feat/fleet-visualizer "$repos/klepsydra/.claude/worktrees/fleet"
mkdir -p "$repos/klepsydra/src/deep" "$repos/klepsydra/.claude/worktrees/fleet/src"
g -C "$repos/ideas" submodule add -q "$repos/subsrc" vendor/subsrc >/dev/null 2>&1
g -C "$repos/subsrc" checkout -q --detach

where() { git_where "$1"; printf '%s|%s|%s' "$where_repo" "$where_worktree" "$where_branch"; }
# The branch as git reports it, or a detached commit's first 7 characters.
git_branch() { git -C "$1" symbolic-ref --short -q HEAD || git -C "$1" rev-parse --short=7 HEAD; }

check "plain repo" "$(where "$repos/klepsydra")" "klepsydra||main"
check "repo subdir" "$(where "$repos/klepsydra/src/deep")" "klepsydra||main"
check "linked worktree" "$(where "$repos/klepsydra/.claude/worktrees/fleet")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "worktree subdir" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "file not written yet" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src/new.rs")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "submodule" "$(where "$repos/ideas/vendor/subsrc")" \
  "subsrc||$(git_branch "$repos/ideas/vendor/subsrc")"
check "detached HEAD" "$(where "$repos/subsrc")" "subsrc||$(git_branch "$repos/subsrc")"
check "outside any repo" "$(where "$repos/loose/notes")" "notes||"
check "filesystem root" "$(where /)" "||"

# keryx names the same repos; when its source is here, ask it directly.
keryx_src=${KERYX_SRC:-$HOME/ajsoftworks/keryx/src}
if [[ -f "$keryx_src/keryx/hook.py" ]]; then
  for p in klepsydra klepsydra/src/deep klepsydra/.claude/worktrees/fleet ideas/vendor/subsrc subsrc loose/notes; do
    got=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from keryx.hook import source_name; print(source_name(sys.argv[2]))' \
      "$keryx_src" "$repos/$p")
    git_where "$repos/$p"
    check "keryx agrees: $p" "$where_repo" "$got"
  done
else
  echo "  skip keryx parity: no keryx source at $keryx_src"
fi

block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block present" "$([[ -n "$(block "$hook")" ]] && echo yes)" "yes"
check "sourceable from a set -e script" \
  "$(KLEPSYDRA_DIR=/x/dev.ajsoftworks.klepsydra bash -ec 'source "$1"; echo "$KLEPSYDRA_DIR"' _ "$hook")" \
  "/x/dev.ajsoftworks.klepsydra"
check "dir block identical in the statusline" "$(block "$hook")" "$(block "$here/../statusline/klepsydra-statusline.sh")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run it**

Run:

```bash
bash hooks/test_fleet.sh
```

Expected: FAIL: `source` reports `hooks/klepsydra-fleet.sh: No such file or directory`, every `where` check fails with `git_where: command not found`, and `dir block present` fails.

- [ ] **Step 3: Write the hook's where resolution**

Create `hooks/klepsydra-fleet.sh`:

```bash
#!/usr/bin/env bash
# Claude Code hook for the klepsydra fleet strip. Keeps one JSON file per
# session in <KLEPSYDRA_DIR>/fleet: its state, where it works, and what it was
# last asked and last said. Registered with "async": true on the events listed
# in README.md, so Claude Code never waits for it. It prints nothing and always
# exits 0.

set -uo pipefail

# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
# The overlay's app-local-data dir, named for the bundle identifier in
# src-tauri/tauri.conf.json. Not the install dir: the uninstaller's "delete app
# data" reaches only this one, and a per-machine install cannot be written to.
# Under WSL the overlay is a Windows app, so the hook writes across to it. On
# Linux, Tauri honours XDG_DATA_HOME only when it is absolute, and so must we,
# or the readings land under whatever directory Claude Code is running in.
if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  osrelease=""
  { read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null  # builtin: no process per run
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
  else
    data_home="$HOME/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi
# --- end klepsydra dir ---

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Sets where_repo, where_worktree and where_branch for `path` (empty when
# none), reading .git directly as keryx's source_name does, so no git process
# runs. A worktree is named by its main checkout, a submodule by its own folder,
# and a path outside any repo by its own name.
git_where() { # path
  local here=${1%/} folder dotgit link gitdir common main
  where_repo="" where_worktree="" where_branch=""
  [[ -n $here ]] || here=/
  if [[ $here != /* ]]; then where_repo=${here##*/}; return; fi
  folder=$here
  while :; do
    dotgit=$folder/.git
    if [[ -d $dotgit ]]; then
      where_repo=${folder##*/}
      branch_of "$dotgit"
      return
    elif [[ -f $dotgit ]]; then
      link=""
      { IFS= read -r link <"$dotgit"; } 2>/dev/null
      where_repo=${folder##*/}
      [[ $link == gitdir:* ]] || return
      gitdir=${link#gitdir:}
      gitdir=${gitdir#"${gitdir%%[![:space:]]*}"}
      [[ $gitdir == /* ]] || gitdir=$folder/$gitdir
      if [[ -f $gitdir/commondir ]]; then
        common=""
        { IFS= read -r common <"$gitdir/commondir"; } 2>/dev/null
        [[ $common == /* ]] || common=$gitdir/$common
        if main=$(cd "$common" 2>/dev/null && pwd -P); then
          main=${main%/*}
          where_repo=${main##*/}
          where_worktree=${folder##*/}
        fi
      fi
      branch_of "$gitdir"
      return
    fi
    [[ $folder == / ]] && break
    folder=${folder%/*}
    [[ -n $folder ]] || folder=/
  done
  where_repo=${here##*/}
}

# Sets where_branch from a git dir's HEAD: the branch, else a detached commit's
# first 7 characters.
branch_of() { # gitdir
  local head=""
  { IFS= read -r head <"$1/HEAD"; } 2>/dev/null
  case $head in
    "ref: refs/heads/"*) where_branch=${head#ref: refs/heads/} ;;
    "ref: "*) where_branch=${head#ref: } ;;
    *) where_branch=${head:0:7} ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exit 0
fi
```

- [ ] **Step 4: Mark the same block in the statusline**

In `statusline/klepsydra-statusline.sh`, before:

```bash
# The overlay's app-local-data dir, named for the bundle identifier in
```

insert:

```bash
# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
2>/dev/null  # builtin: runs every render
```

with:

```bash
2>/dev/null  # builtin: no process per run
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
  fi
fi

input=$(cat)
```

with:

```bash
  fi
fi
# --- end klepsydra dir ---

input=$(cat)
```

- [ ] **Step 5: Run the hook tests, the statusline tests and shellcheck**

shellcheck is not installed in WSL; `uvx` runs the same binary CI uses. Until Task 4's `main` reads the globals `git_where` sets, shellcheck reports them as assigned but unused (SC2034), so this task and the next exclude that one check; Task 4 runs shellcheck without exclusions.

Run:

```bash
chmod +x hooks/klepsydra-fleet.sh && bash hooks/test_fleet.sh && bash statusline/test_statusline.sh && uvx --from shellcheck-py shellcheck -e SC2034 hooks/*.sh statusline/*.sh scripts/*.sh
```

Expected: PASS: `18 passed, 0 failed` for the hook (the six `keryx agrees` checks run when keryx is at `~/ajsoftworks/keryx/src`, else one `skip keryx parity` line and 12 passed), `55 passed, 0 failed` for the statusline, and no shellcheck output.

- [ ] **Step 6: Run the fleet hook tests in CI and lint hooks/**

In `.github/workflows/ci.yml`, replace:

```yaml
      - name: Shell lint
        run: shellcheck statusline/*.sh scripts/*.sh
```

with:

```yaml
      # The fleet hook is the only writer of a session's state, so its fixtures
      # cover the shapes that would otherwise show a wrong status.
      - name: Fleet hook tests
        run: bash hooks/test_fleet.sh
      - name: Shell lint
        run: shellcheck hooks/*.sh statusline/*.sh scripts/*.sh
```

- [ ] **Step 7: Commit**

```bash
git add hooks/klepsydra-fleet.sh hooks/test_fleet.sh && git commit -m "feat(fleet): resolve a session's repo, worktree and branch from .git" -- hooks/klepsydra-fleet.sh hooks/test_fleet.sh statusline/klepsydra-statusline.sh .github/workflows/ci.yml
```

### Task 3: Fleet hook: identity from keryx's terminal hold

**Files:**

- Modify: `hooks/test_fleet.sh` (line 71)
- Modify: `hooks/klepsydra-fleet.sh` (lines 30, 88)

**Interfaces:**

- **Consumes:** `/proc/<pid>/stat`, `/proc/<pid>/comm`, `/proc/<pid>/cmdline`; keryx's `~/.cache/keryx/voices.json` (`${XDG_CACHE_HOME:-$HOME/.cache}/keryx/voices.json`), shape `{"homes": {repo: {"voice": str, "seen": float}}, "holders": {"<pid>:<starttime>": {"voice": str, "seen": float}}}`. A voice is a Kokoro id (`am_michael`) or a blend label (`af_heart(0.5)+af_bella(0.5)`).
- **Produces** (in `hooks/klepsydra-fleet.sh`):
  - `PROC_ROOT` (default `/proc`, overridden by `KLEPSYDRA_PROC`) and `VOICES` (overridden by `KERYX_VOICES`).
  - `proc_stat PID`: fills the caller's array `stat` with the fields after the command name (`[0]` state, `[1]` ppid, `[19]` start time); returns 1 when the pid is gone.
  - `is_claude PID`: true for `comm` `claude`/`claude-code`, or an argv[0..1] path with a `claude`/`claude-code` component (keryx's rule).
  - `claude_ancestor PID`: sets the globals `found_pid`, `found_start` to the nearest Claude Code process at or above PID (keryx's `terminal_id`), else both empty and return 1.
  - `holder_voice PID START`: prints the voice keryx holds for `PID:START`, or nothing.

- [ ] **Step 1: Write the failing test**

A fake `/proc` covers a Claude Code parent, a shell whose name holds `) (` the way a real `comm` can, an npm install found by argv, and a process with no Claude Code above it.

In `hooks/test_fleet.sh`, before:

```bash
block() {
```

insert:

```bash
echo "identity"

# A /proc tree: pid, parent, name, start time, state, then argv.
mkproc() {
  local d="$work/proc/$1"
  mkdir -p "$d"
  printf '%s (%s) %s %s 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100\n' \
    "$1" "$3" "${5:-S}" "$2" "$4" >"$d/stat"
  printf '%s\n' "$3" >"$d/comm"
  if (( $# > 5 )); then printf '%s\0' "${@:6}" >"$d/cmdline"; else : >"$d/cmdline"; fi
}
mkproc 1 0 systemd 1
mkproc 500 1 claude 8717628 S claude
mkproc 550 500 'sh) (x' 8717700 S /bin/sh -c "$hook"
mkproc 600 550 klepsydra-fleet 8717701 S bash "$hook"
mkproc 700 1 node 9000000 S node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
mkproc 710 700 bash 9000001 S bash "$hook"
mkproc 800 1 bash 9100000 S bash
mkproc 810 800 bash 9100001 S bash "$hook"
PROC_ROOT="$work/proc"

ancestor() { claude_ancestor "$1"; printf '%s:%s' "$found_pid" "$found_start"; }
check "nearest claude above the hook" "$(ancestor 600)" "500:8717628"
check "an npm install found by its argv" "$(ancestor 710)" "700:9000000"
check "no claude above" "$(ancestor 810)" ":"
check "a missing pid" "$(ancestor 999)" ":"

printf '{"homes":{"klepsydra":{"voice":"am_michael","seen":1}},"holders":{"500:8717628":{"voice":"am_michael","seen":1},"700:9000000":{"voice":"af_heart(0.5)+af_bella(0.5)","seen":1}}}\n' >"$work/voices.json"
VOICES="$work/voices.json"
check "the holder's voice" "$(holder_voice 500 8717628)" "am_michael"
check "a blend is a voice too" "$(holder_voice 700 9000000)" "af_heart(0.5)+af_bella(0.5)"
check "no hold, no voice" "$(holder_voice 500 1)" ""
VOICES="$work/missing.json"
check "no keryx, no voice" "$(holder_voice 500 8717628)" ""

```

- [ ] **Step 2: Run it**

Run:

```bash
bash hooks/test_fleet.sh
```

Expected: FAIL: `20 passed, 6 failed`. The checks that expect a Claude Code process or a voice fail with `claude_ancestor: command not found` or `holder_voice: command not found`; the where and dir-block checks pass, as do the two that expect no voice.

- [ ] **Step 3: Write the process walk and the voice lookup**

In `hooks/klepsydra-fleet.sh`, after:

```bash
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
```

insert:

```bash
PROC_ROOT=${KLEPSYDRA_PROC:-/proc} # tests point these at a fake /proc and voices.json
VOICES=${KERYX_VOICES:-${XDG_CACHE_HOME:-$HOME/.cache}/keryx/voices.json}
```

In `hooks/klepsydra-fleet.sh`, before:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
```

insert:

```bash
# Fields of /proc/<pid>/stat after the command name, into `stat`: [0] is the
# state, [1] the parent pid, [19] the start time. The name sits in parentheses
# and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code ]] && return 0
    done
  done
  return 1
}

# Sets found_pid and found_start to the nearest Claude Code process at or
# above `pid`: keryx's key for a terminal (pid:starttime in voices.json).
claude_ancestor() { # pid
  local pid=$1 i
  local -a stat=()
  found_pid="" found_start=""
  for ((i = 0; i < 32; i++)); do
    proc_stat "$pid" || return 1
    if is_claude "$pid"; then
      found_pid=$pid found_start=${stat[19]}
      return 0
    fi
    pid=${stat[1]}
    (( pid >= 1 )) || return 1
  done
  return 1
}

# The voice keryx holds for a terminal, or nothing without keryx or a hold.
holder_voice() { # pid start
  [[ -r $VOICES ]] || return 0
  jq -r --arg h "$1:$2" '.holders[$h].voice // empty | strings' "$VOICES" 2>/dev/null
}

```

- [ ] **Step 4: Run the tests and shellcheck**

Run:

```bash
bash hooks/test_fleet.sh && uvx --from shellcheck-py shellcheck -e SC2034 hooks/*.sh
```

Expected: PASS: `26 passed, 0 failed` (20 without keryx), no shellcheck output (SC2034 is still excluded, as in Task 2).

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(fleet): find a session's Claude Code process and its keryx voice" -- hooks/klepsydra-fleet.sh hooks/test_fleet.sh
```

### Task 4: Fleet hook: the session file

**Files:**

- Create: `hooks/fixtures/session-start.json`
- Create: `hooks/fixtures/user-prompt.json`
- Create: `hooks/fixtures/task-notification.json`
- Create: `hooks/fixtures/pasted-content.json`
- Create: `hooks/fixtures/permission-request.json`
- Create: `hooks/fixtures/pre-tool-question.json`
- Create: `hooks/fixtures/pre-tool-plan.json`
- Create: `hooks/fixtures/notification-elicitation.json`
- Create: `hooks/fixtures/notification-permission.json`
- Create: `hooks/fixtures/post-tool-bash.json`
- Create: `hooks/fixtures/post-tool-edit.json`
- Create: `hooks/fixtures/post-tool-notebook.json`
- Create: `hooks/fixtures/stop.json`
- Create: `hooks/fixtures/lagging-transcript.jsonl`
- Create: `hooks/fixtures/stop-failure.json`
- Create: `hooks/fixtures/session-end.json`
- Create: `hooks/fixtures/malformed.json`
- Modify: `hooks/test_fleet.sh` (lines 6, 106)
- Modify: `hooks/klepsydra-fleet.sh` (lines 32, 142-144)

**Interfaces:**

- **Consumes:** Claude Code hook input on stdin (hooks reference, 2026-10): common `session_id`, `cwd`, `hook_event_name`, `agent_id` (subagents only); `SessionStart.source` (`startup|resume|clear|compact|fork`), `.session_title` (custom name only); `UserPromptSubmit.prompt`; `PermissionRequest.tool_name`; `PreToolUse.tool_name`; `Notification.notification_type`; `PostToolUse.tool_name`, `.tool_input.file_path` (Edit, Write), `.tool_input.notebook_path` (NotebookEdit); `Stop.last_assistant_message`; `StopFailure.error`, `.error_details`, `.last_assistant_message`; `SessionEnd.reason`. Uses `git_where`, `claude_ancestor`, `holder_voice` (Tasks 2-3).
- **Produces:** the hook's `main`, run when the script is executed, and `<KLEPSYDRA_DIR>/fleet/<session_id>.json`, v1 (all times epoch seconds by the writer's clock, integers):
  `{"v": 1, "session_id": str, "name": str|null, "started_at": int, "launch_dir": str|null, "claude": {"pid": int, "start": int}|null, "voice": str|null, "state": "new"|"working"|"needs_you"|"done"|"error"|"ended", "reason": str|null, "needs": {"by": str, "tool": str|null}|null, "state_at": int, "where": {"repo": str, "worktree": str|null, "branch": str|null, "by": "cwd"|"edit", "at": int}|null, "touched": [{"repo": str, "at": int}], "prompt": {"text": str, "at": int}|null, "reply": {"text": str, "at": int}|null, "error": str|null, "ended": {"reason": str, "at": int}|null, "written_at": int}`.
  Constants `LOCK`, `PROMPT_CHARS=300`, `EVENTS` (the nine registered events); `write_atomic FILE TEXT`; the jq program `APPLY` (old file text in `$old`, event on stdin, context in `--arg`s).
- **Reasons** written: `approve <tool_name>`, `question`, `approve plan`, the `error` type with `_` as spaces (`rate limit`), and for `ended`: `cleared`, `resumed elsewhere`, `logged out`, `exited`, `stopped`.

- [ ] **Step 1: Add the event fixtures**

One file per event type, field for field from the hooks reference's payloads (2026-10); `permission-request.json`, `post-tool-bash.json` and `post-tool-edit.json` carry `SECRET` strings in tool input and output that must never reach a session file, and `lagging-transcript.jsonl` is a transcript whose last reply is stale.

Create `hooks/fixtures/session-start.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}
```

Create `hooks/fixtures/user-prompt.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"i just want to be able to VIZ them, one glance at the screen"}
```

Create `hooks/fixtures/task-notification.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>a1b2</task-id>\n<status>completed</status>\n<summary>Agent \"Explore\" completed</summary>\n</task-notification>"}
```

Create `hooks/fixtures/pasted-content.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"why did this fire? <pasted_content><task-notification><status>completed</status></task-notification></pasted_content>"}
```

Create `hooks/fixtures/permission-request.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"curl -H 'Authorization: Bearer SECRET-TOKEN-123' https://example.com","description":"Fetch the page"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"curl:*"}],"behavior":"allow","destination":"localSettings"}]}
```

Create `hooks/fixtures/pre-tool-question.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layout?","options":[{"label":"Strip"},{"label":"Wall"}]}]},"tool_use_id":"toolu_01ASK"}
```

Create `hooks/fixtures/pre-tool-plan.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"plan","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"1. Write the guards"},"tool_use_id":"toolu_01PLAN"}
```

Create `hooks/fixtures/notification-elicitation.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","hook_event_name":"Notification","message":"The memory server needs your input","title":"Input needed","notification_type":"elicitation_dialog"}
```

Create `hooks/fixtures/notification-permission.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}
```

Create `hooks/fixtures/post-tool-bash.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"curl -H 'Authorization: Bearer SECRET-TOKEN-123' https://example.com","description":"Fetch the page"},"tool_response":{"stdout":"SECRET-OUTPUT","stderr":"","interrupted":false},"tool_use_id":"toolu_01BASH","duration_ms":220}
```

Create `hooks/fixtures/post-tool-edit.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"acceptEdits","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/home/aj/repo/src/main.rs","old_string":"SECRET-OLD","new_string":"SECRET-NEW","replace_all":false},"tool_response":{"filePath":"/home/aj/repo/src/main.rs","oldString":"SECRET-OLD","newString":"SECRET-NEW"},"tool_use_id":"toolu_01EDIT","duration_ms":12}
```

Create `hooks/fixtures/post-tool-notebook.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","permission_mode":"acceptEdits","hook_event_name":"PostToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/home/aj/repo/nb/explore.ipynb","cell_id":"c1","new_source":"print(1)","edit_mode":"replace"},"tool_response":{},"tool_use_id":"toolu_01NB","duration_ms":15}
```

Create `hooks/fixtures/stop.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"HOOK_FIXTURES/lagging-transcript.jsonl","cwd":"/home/aj/repo","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"That works with no model calls: the hook writes one file per session and the overlay reads them.","background_tasks":[],"session_crons":[]}
```

Create `hooks/fixtures/lagging-transcript.jsonl`:

```json
{"type":"user","message":{"role":"user","content":"earlier"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"STALE REPLY FROM THE TRANSCRIPT"}]}}
```

Create `hooks/fixtures/stop-failure.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}
```

Create `hooks/fixtures/session-end.json`:

```json
{"session_id":"11111111-2222-4333-8444-555555555555","transcript_path":"/home/aj/.claude/projects/-home-aj-repo/11111111-2222-4333-8444-555555555555.jsonl","cwd":"/home/aj/repo","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
```

Create `hooks/fixtures/malformed.json`:

```json
not json {{{
```

- [ ] **Step 2: Write the failing tests**

These cover every row of the spec's event table and the guards that belong to the hook: not started, `PermissionRequest` sets needs you (and the `permission_prompt` notification writes nothing), Stop reads only `last_assistant_message`, identity stays while where moves across three repos, and `<task-notification>` keeps AJ's prompt. They also cover the Review Focus cases below: another tool's or a subagent's `PostToolUse`, twelve concurrent hook processes, and a hook first meeting a session mid-life.

In `hooks/test_fleet.sh`, after:

```bash
hook="$here/klepsydra-fleet.sh"
```

insert:

```bash
fixtures="$here/fixtures"
```

In `hooks/test_fleet.sh`, before:

```bash
block() {
```

insert:

```bash
echo "session file"

S=11111111-2222-4333-8444-555555555555
dir="$work/dev.ajsoftworks.klepsydra"
file="$dir/fleet/$S.json"
now=1792353000
wt="$repos/klepsydra/.claude/worktrees/fleet"

# Fire one fixture event at the hook, edited by an optional jq filter, as
# Claude Code would from the terminal held by pid 500.
fire() { # fixture [filter] [VAR=value...]
  local fixture=$1 filter=${2:-.}
  shift; (( $# )) && shift
  jq -c --arg cwd "$wt" "if .cwd then .cwd = \$cwd else . end | $filter" "$fixtures/$fixture" |
    env KLEPSYDRA_DIR="$dir" KLEPSYDRA_NOW="$now" KLEPSYDRA_PROC="$work/proc" KLEPSYDRA_PID=600 \
      KERYX_VOICES="$work/voices.json" XDG_RUNTIME_DIR="$work" "$@" bash "$hook"
}
field() { jq -c "$1" "$file"; }
mtime() { stat -c %Y "$file"; }

out=$(fire session-start.json); rc=$?
check "start: exit 0" "$rc" "0"
check "start: prints nothing" "$out" ""
check "start: not started" "$(field '[.v, .state, .reason, .state_at, .started_at]')" "[1,\"new\",null,$now,$now]"
check "start: launch dir" "$(field .launch_dir)" "\"$wt\""
check "start: claude" "$(field .claude)" '{"pid":500,"start":8717628}'
check "start: voice" "$(field .voice)" '"am_michael"'
check "start: where" "$(field '.where | [.repo, .worktree, .branch, .by, .at]')" \
  "[\"klepsydra\",\"fleet\",\"feat/fleet-visualizer\",\"cwd\",$now]"
check "start: nothing asked yet" "$(field '[.prompt, .reply, .needs, .error, .ended]')" "[null,null,null,null,null]"

touch -d @1 "$file"
now=1792353005 fire notification-permission.json
check "permission_prompt notification: no write" "$(mtime)" "1"
now=1792353005 fire post-tool-bash.json
check "a tool in the same place: no write" "$(mtime)" "1"

now=1792353010
fire user-prompt.json
check "prompt: working" "$(field '[.state, .state_at]')" "[\"working\",$now]"
check "prompt: stored" "$(field .prompt)" \
  "{\"text\":\"i just want to be able to VIZ them, one glance at the screen\",\"at\":$now}"

now=1792353020
fire task-notification.json
check "subagent report: still working" "$(field .state)" '"working"'
check "subagent report: keeps AJ's prompt" "$(field .prompt.at)" "1792353010"
fire pasted-content.json
check "pasted text quoting a report is AJ's prompt" "$(field '.prompt.text | startswith("why did this fire?")')" "true"

long=$(printf 'x%.0s' {1..290})$(printf '🙂%.0s' {1..20})
fire user-prompt.json ".prompt = \"$long\""
check "prompt: first 300 characters" "$(field '.prompt.text | length')" "300"
check "prompt: cut on a character, not a byte" "$(field '.prompt.text | endswith("🙂")')" "true"

now=1792353030
fire permission-request.json
check "permission request: needs you" "$(field '[.state, .reason, .state_at]')" "[\"needs_you\",\"approve Bash\",$now]"
check "permission request: prints nothing, so decides nothing" "$(fire permission-request.json)" ""
check "tool input never recorded" "$(grep -c SECRET "$file")" "0"

now=1792353040
fire post-tool-bash.json '.tool_name = "Read"'
check "another tool finishing leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.agent_id = "agent-7" | .agent_type = "Explore"'
check "a subagent's tool finishing leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json
check "its own tool finishing clears it" "$(field '[.state, .reason, .needs]')" '["working",null,null]'
check "tool output never recorded" "$(grep -c SECRET "$file")" "0"

fire pre-tool-question.json
check "question" "$(field '[.state, .reason]')" '["needs_you","question"]'
fire post-tool-bash.json '.tool_name = "AskUserQuestion"'
check "answered" "$(field .state)" '"working"'
fire pre-tool-plan.json
check "plan" "$(field '[.state, .reason]')" '["needs_you","approve plan"]'
fire post-tool-bash.json '.tool_name = "ExitPlanMode"'
check "plan approved" "$(field .state)" '"working"'
fire notification-elicitation.json
check "MCP elicitation" "$(field '[.state, .reason]')" '["needs_you","question"]'
fire post-tool-bash.json '.tool_name = "mcp__memory__store"'
check "elicitation answered" "$(field .state)" '"working"'
fire permission-request.json '.agent_id = "agent-7"'
check "a subagent can need you" "$(field '[.state, .needs]')" '["needs_you",{"by":"agent-7","tool":"Bash"}]'
fire post-tool-bash.json
check "the main thread's tool does not clear a subagent's request" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.agent_id = "agent-7"'
check "the subagent's own tool does" "$(field .state)" '"working"'

now=1792353050
fire stop.json ".transcript_path = \"$fixtures/lagging-transcript.jsonl\""
check "stop: done" "$(field '[.state, .state_at]')" "[\"done\",$now]"
check "stop: the reply from last_assistant_message" "$(field .reply.text)" \
  '"That works with no model calls: the hook writes one file per session and the overlay reads them."'
check "stop: never the lagging transcript" "$(grep -c STALE "$file")" "0"
check "the hook never opens the transcript" "$(grep -c transcript_path "$hook")" "0"
fire stop.json '.last_assistant_message = ""'
check "stop with no text keeps the last reply" "$(field '.reply.at')" "$now"

now=1792353060
fire stop-failure.json
check "failure: error" "$(field '[.state, .reason, .error]')" '["error","rate limit","API Error: Rate limit reached"]'
fire user-prompt.json
check "the next prompt clears the error" "$(field '[.state, .error]')" '["working",null]'

echo "where moves, identity stays"
now=1792353100
fire post-tool-edit.json ".tool_input.file_path = \"$repos/ideas/README.md\""
check "an edit moves where" "$(field '.where | [.repo, .by, .at]')" "[\"ideas\",\"edit\",$now]"
check "the old place is touched" "$(field '.touched')" "[{\"repo\":\"klepsydra\",\"at\":$now}]"
now=1792353110
fire post-tool-notebook.json ".tool_input.notebook_path = \"$repos/loose/notes/nb.ipynb\""
check "a notebook edit moves where" "$(field '.where.repo')" '"notes"'
fire user-prompt.json ".cwd = \"$repos/subsrc\""
check "after an edit, cwd does not move where" "$(field '.where.repo')" '"notes"'
check "identity unchanged across three repos" "$(field '[.voice, .claude.pid]')" '["am_michael",500]'
check "touched, newest first" "$(field '[.touched[].repo]')" '["ideas","klepsydra"]'
for i in 1 2 3 4 5 6 7; do
  mkdir -p "$repos/r$i/.git"
  now=$((1792353200 + i)) fire post-tool-edit.json ".tool_input.file_path = \"$repos/r$i/f\""
done
check "touched keeps six" "$(field '[.touched[].repo]')" '["r6","r5","r4","r3","r2","r1"]'
# shellcheck disable=SC2016  # a jq variable
check "where is not touched" "$(field '.where.repo as $w | [.touched[].repo] | index($w)')" "null"

printf '{"holders":{"500:8717628":{"voice":"bf_emma","seen":2}}}\n' >"$work/voices.json"
fire post-tool-bash.json
check "a voice keryx changes is copied" "$(field .voice)" '"bf_emma"'
rm "$work/voices.json"
fire user-prompt.json
check "keryx gone keeps the voice" "$(field .voice)" '"bf_emma"'

echo "lifecycle"
now=1792353300
fire session-end.json
check "end" "$(field '[.state, .reason, .ended]')" "[\"ended\",\"exited\",{\"reason\":\"prompt_input_exit\",\"at\":$now}]"
touch -d @1 "$file"
fire post-tool-bash.json '.tool_name = "Read"'
check "a late event cannot revive it" "$(mtime)" "1"
now=1792353400 fire session-start.json '.source = "resume"'
check "resumed: done, since it has a prompt" "$(field '[.state, .ended]')" '["done",null]'
fire user-prompt.json
now=1792353410 fire session-start.json '.source = "compact"'
check "compaction keeps the state" "$(field .state)" '"working"'

rm -f "$file"
now=1792353500 fire user-prompt.json
check "installed mid-session: created from any event" "$(field '[.state, .started_at, .prompt.at]')" \
  '["working",1792353500,1792353500]'
rm -f "$file"
fire session-end.json
check "an end for an unknown session writes nothing" "$([[ -e $file ]] && echo written || echo none)" "none"

fire session-start.json '.session_title = "fleet-plan"'
check "a custom title names it" "$(field .name)" '"fleet-plan"'

echo "bad input"
out=$(KLEPSYDRA_DIR="$dir" XDG_RUNTIME_DIR="$work" bash "$hook" <"$fixtures/malformed.json"); rc=$?
check "malformed: exit 0" "$rc" "0"
check "malformed: silent" "$out" ""
fire user-prompt.json '.session_id = "../../evil"'
check "a session id that is not a uuid writes nothing" "$(find "$work" -name 'evil*' | wc -l)" "0"
out=$(fire user-prompt.json '.' KLEPSYDRA_DIR=/proc/nonexistent); rc=$?
check "unwritable dir: exit 0" "$rc" "0"
check "no tmp litter" "$(find "$dir" -name '*.tmp' | wc -l)" "0"

echo "concurrency"
rm -f "$file"
now=1792354000 fire session-start.json
for i in $(seq 1 12); do mkdir -p "$repos/c$i/.git"; done
for i in $(seq 1 12); do
  now=$((1792354000 + i)) fire post-tool-edit.json ".tool_input.file_path = \"$repos/c$i/f\"" &
done
wait
check "parallel events: the file parses" "$(jq -e .v "$file" >/dev/null && echo ok)" "ok"
check "parallel events: no update lost" "$(field '.touched | length')" "6"
check "parallel events: where and touched are seven repos" \
  "$(field '[.where.repo] + [.touched[].repo] | unique | length')" "7"

```

- [ ] **Step 3: Run them**

Run:

```bash
bash hooks/test_fleet.sh
```

Expected: FAIL: `34 passed, 57 failed`. The hook only exits 0, so no session file is written: `jq` reports `Could not open .../11111111-2222-4333-8444-555555555555.json` and every check that reads the file fails. The where, identity and dir-block checks pass, and so do the few that expect nothing written.

- [ ] **Step 4: Write the event handling**

One lock for all sessions' hooks, since Claude Code starts each async hook as its own process. `needs` remembers who asked and for which tool, so only that tool's `PostToolUse` from the same thread clears it.

In `hooks/klepsydra-fleet.sh`, after:

```bash
VOICES=${KERYX_VOICES:-${XDG_CACHE_HOME:-$HOME/.cache}/keryx/voices.json}
```

insert:

```bash
# Every session's hooks run as separate processes, so writes take one lock.
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-fleet-$UID.lock
PROMPT_CHARS=300
# The events README.md registers this hook on; any other is ignored.
EVENTS="SessionStart UserPromptSubmit PermissionRequest PreToolUse Notification PostToolUse Stop StopFailure SessionEnd"
```

In `hooks/klepsydra-fleet.sh`, before:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
```

insert:

```bash
# The session file after one event, as compact JSON, or nothing when no field
# changed. `$old` is the current file's text (empty for none).
read -r -d '' APPLY <<'JQ' || true  # read returns 1 at the end of input
def clip: if type == "string" and length > 0 then .[0:$chars] else null end;
def text: if type == "string" and length > 0 then . else null end;
def ended_as: {clear: "cleared", resume: "resumed elsewhere", logout: "logged out",
               prompt_input_exit: "exited", other: "stopped"}[.] // gsub("_"; " ");

. as $ev
| $ev.hook_event_name as $event
| ($ev.agent_id // "") as $agent
| ($old | try fromjson catch null
   | if type == "object" and .v == 1 and .session_id == $ev.session_id then . else null end) as $was
| if $was == null and $event == "SessionEnd" then empty
  elif $was.state == "ended" and $event != "SessionStart" then empty
  else
  ($was // {v: 1, session_id: $ev.session_id, name: null, started_at: $now,
            launch_dir: ($ev.cwd | text), claude: null, voice: null,
            state: "new", reason: null, needs: null, state_at: $now,
            where: null, touched: [], prompt: null, reply: null, error: null,
            ended: null, written_at: $now}) as $s
  | $s
  | .name = (($ev.session_title | text) // .name)
  | .claude = (.claude // (if $pid != "" then {pid: ($pid | tonumber), start: ($start | tonumber)} else null end))
  | .voice = (($voice | text) // .voice)

  # Where: the last edit's repo, or the cwd's until something is edited.
  | (if $repo != "" and ($by == "edit" or .where == null or .where.by == "cwd")
     then {repo: $repo, worktree: ($worktree | text), branch: ($branch | text)}
     else null end) as $w
  | if $w == null then .
    elif .where != null and (.where | {repo, worktree, branch}) == $w then .where.by = (if $by == "edit" then "edit" else .where.by end)
    else
      (if .where != null and .where.repo != $w.repo
       then .touched = ([{repo: .where.repo, at: $now}]
                        + (.touched | map(select(.repo != $s.where.repo and .repo != $w.repo))))[0:6]
       else . end)
      | .where = $w + {by: $by, at: $now}
    end

  # State, with what it needs from AJ and who asked.
  | (if $event == "SessionStart" then
       if $was == null then {state: "new", reason: null}
       elif $ev.source == "compact" then {state: .state, reason: .reason}
       else {state: (if .prompt then "done" else "new" end), reason: null} end
     elif $event == "UserPromptSubmit" then {state: "working", reason: null}
     elif $event == "PermissionRequest" then
       {state: "needs_you", reason: "approve \($ev.tool_name // "a tool")", needs: {by: $agent, tool: $ev.tool_name}}
     elif $event == "PreToolUse" and $ev.tool_name == "AskUserQuestion" then
       {state: "needs_you", reason: "question", needs: {by: $agent, tool: "AskUserQuestion"}}
     elif $event == "PreToolUse" and $ev.tool_name == "ExitPlanMode" then
       {state: "needs_you", reason: "approve plan", needs: {by: $agent, tool: "ExitPlanMode"}}
     elif $event == "Notification" and $ev.notification_type == "elicitation_dialog" then
       {state: "needs_you", reason: "question", needs: {by: $agent, tool: null}}
     elif $event == "PostToolUse" and .state == "needs_you" and (.needs.by // "") == $agent
          and (.needs.tool == null or .needs.tool == $ev.tool_name) then
       {state: "working", reason: null}
     elif $event == "Stop" then {state: "done", reason: null}
     elif $event == "StopFailure" then {state: "error", reason: (($ev.error // "unknown") | gsub("_"; " "))}
     elif $event == "SessionEnd" then {state: "ended", reason: (($ev.reason // "other") | ended_as)}
     else {state: .state, reason: .reason} end) as $t
  | (if $t.state != .state or $t.reason != .reason then .state_at = $now else . end)
  | .needs = (if $t.state != "needs_you" then null else ($t.needs // .needs) end)
  | .state = $t.state
  | .reason = $t.reason

  # What AJ asked and what came back. A background subagent's report arrives
  # as a prompt starting <task-notification>; it is not AJ's.
  | if $event == "UserPromptSubmit" then
      .error = null
      | if ($ev.prompt // "" | test("^\\s*<task-notification>")) then .
        else .prompt = (($ev.prompt | clip) as $p | if $p then {text: $p, at: $now} else .prompt end) end
    elif $event == "Stop" then
      (($ev.last_assistant_message | clip) as $r | if $r then .reply = {text: $r, at: $now} else . end)
    elif $event == "StopFailure" then
      .error = (($ev.last_assistant_message // $ev.error_details // $ev.error) | clip)
    elif $event == "SessionEnd" then .ended = {reason: ($ev.reason // "other"), at: $now}
    elif $event == "SessionStart" and $ev.source != "compact" then .ended = null
    else . end

  | if $was != null and (del(.written_at) == ($was | del(.written_at))) then empty
    else .written_at = $now end
  end
JQ

# Replace the file with `text` through a temp file in the same directory, so a
# reader never sees half of it.
write_atomic() { # file text
  local tmp="$1.$$.tmp"
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

main() {
  local input fields session event cwd edited now file old new lock voice="" by=cwd
  input=$(cat)
  fields=$(jq -r '
    def s: if type == "string" then gsub("[\u001f\n]"; " ") else "" end;
    [ (.session_id | s), (.hook_event_name | s), (.cwd | s),
      (if .hook_event_name == "PostToolUse" and (.tool_name | IN("Edit", "Write", "NotebookEdit"))
       then ((.tool_input.file_path // .tool_input.notebook_path) | s) else "" end)
    ] | join("\u001f")' <<<"$input" 2>/dev/null) || return 0
  IFS=$'\x1f' read -r session event cwd edited <<<"$fields"
  [[ $session =~ $UUID_RE && " $EVENTS " == *" $event "* ]] || return 0

  now=${KLEPSYDRA_NOW:-}
  [[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
  if [[ -n $edited ]]; then
    by=edit
    git_where "${edited%/*}"
  else
    git_where "$cwd"
  fi
  if claude_ancestor "${KLEPSYDRA_PID:-$$}"; then
    voice=$(holder_voice "$found_pid" "$found_start")
  fi

  local fleet=$KLEPSYDRA_DIR/fleet
  mkdir -p "$fleet" 2>/dev/null || return 0
  { exec {lock}>>"$LOCK"; } 2>/dev/null || return 0
  flock -w 5 "$lock" || return 0

  file=$fleet/$session.json
  old=""
  [[ -f $file ]] && { old=$(<"$file"); } 2>/dev/null
  new=$(jq -c --arg old "$old" --argjson now "$now" --argjson chars "$PROMPT_CHARS" \
    --arg repo "$where_repo" --arg worktree "$where_worktree" --arg branch "$where_branch" \
    --arg by "$by" \
    --arg voice "$voice" --arg pid "$found_pid" --arg start "$found_start" \
    "$APPLY" <<<"$input" 2>/dev/null) || new=""
  [[ -n $new ]] && write_atomic "$file" "$new"
  return 0
}

```

In `hooks/klepsydra-fleet.sh`, replace:

```bash
then
  exit 0
fi
```

with:

```bash
then
  main >/dev/null 2>&1
  exit 0
fi
```

- [ ] **Step 5: Run the tests and shellcheck**

Run:

```bash
bash hooks/test_fleet.sh && uvx --from shellcheck-py shellcheck hooks/*.sh
```

Expected: PASS: `91 passed, 0 failed` (85 without keryx), no shellcheck output.

- [ ] **Step 6: Confirm the concurrency test needs the lock**

Comment out the `flock -w 5 "$lock" || return 0` line, run `bash hooks/test_fleet.sh`, and expect `FAIL parallel events: no update lost` and `FAIL parallel events: where and touched are seven repos`. Restore the line and expect all checks to pass again.

- [ ] **Step 7: Commit**

```bash
git add hooks/fixtures/session-start.json hooks/fixtures/user-prompt.json hooks/fixtures/task-notification.json hooks/fixtures/pasted-content.json hooks/fixtures/permission-request.json hooks/fixtures/pre-tool-question.json hooks/fixtures/pre-tool-plan.json hooks/fixtures/notification-elicitation.json hooks/fixtures/notification-permission.json hooks/fixtures/post-tool-bash.json hooks/fixtures/post-tool-edit.json hooks/fixtures/post-tool-notebook.json hooks/fixtures/stop.json hooks/fixtures/lagging-transcript.jsonl hooks/fixtures/stop-failure.json hooks/fixtures/session-end.json hooks/fixtures/malformed.json && git commit -m "feat(fleet): write one session file per Claude Code session from its hook events" -- hooks/klepsydra-fleet.sh hooks/test_fleet.sh hooks/fixtures
```

### Task 5: Fleet hook: pruning dead sessions

**Files:**

- Modify: `hooks/test_fleet.sh` (lines 23, 286)
- Modify: `hooks/klepsydra-fleet.sh` (lines 147, 280-281)

**Interfaces:**

- **Consumes:** `proc_stat` (Task 3), `UUID_RE`, `LOCK` (Task 4), the session file's `claude`, `started_at`, `state_at`, `where.at`, `prompt.at`, `reply.at`, `ended.at`.
- **Produces:** `claude_alive PID START` (true while that process runs with that start time and is not a zombie); `PRUNE_AFTER=86400`; `prune_fleet DIR NOW`: returns 1 and deletes nothing when `DIR` is empty, relative, not named `dev.ajsoftworks.klepsydra`, `NOW` is not a number, or `DIR/fleet` is a symlink; else deletes `DIR/fleet/<uuid>.json` (and its `.beat`) whose process is gone, whose newest time is over a day old and whose beat is over a day old, and `<uuid>.beat` files with no session file that are over a day old. It never follows or deletes a symlink. `main` calls it after writing on `SessionStart`.

- [ ] **Step 1: Write the refusal tests first**

Every refusal runs against a fleet that holds files the prune would otherwise delete, and checks that nothing changed. The deletion cases follow: gone and old (deleted), a live process, a reused pid, recent, a fresh heartbeat, orphan beats old and fresh, non-uuid names, an unreadable file, a symlink, a zombie. The test points the hook's lock and prune stamp at the scratch dir.

In `hooks/test_fleet.sh`, after:

```bash
source "$hook"
```

insert:

```bash
LOCK="$work/klepsydra-fleet.lock" # the lock and the prune stamp stay in the scratch dir
```

In `hooks/test_fleet.sh`, before:

```bash
block() {
```

insert:

```bash
echo "pruning"
# Sessions in a scratch data dir, each a pid:start, a last event, and a beat age.
pd="$work/prune/dev.ajsoftworks.klepsydra"
pnow=1792400000
day=86400
mksession() { # id pid start last-event [beat-mtime]
  printf '{"v":1,"session_id":"%s","claude":{"pid":%s,"start":%s},"started_at":%s,"state_at":%s}\n' \
    "$1" "$2" "$3" "$4" "$4" >"$pd/fleet/$1.json"
  if [[ -n ${5:-} ]]; then printf 'name\t1\n' >"$pd/fleet/$1.beat"; touch -d "@$5" "$pd/fleet/$1.beat"; fi
}
id() { printf '%08d-0000-4000-8000-000000000000' "$1"; }
reset_prune() {
  rm -rf "$work/prune"
  mkdir -p "$pd/fleet"
  mksession "$(id 1)" 999 1 $((pnow - 2 * day))                  # gone, old: deleted
  mksession "$(id 2)" 500 8717628 $((pnow - 3 * day))            # live claude: kept
  mksession "$(id 3)" 500 1234 $((pnow - 3 * day))               # pid reused: deleted
  mksession "$(id 4)" 999 1 $((pnow - 3600))                     # gone, recent: kept
  mksession "$(id 5)" 999 1 $((pnow - 2 * day)) $((pnow - 60))   # beat still fresh: kept
  mksession "$(id 6)" 999 1 $((pnow - 2 * day)) $((pnow - 2 * day))  # gone, old, old beat: both deleted
  printf 'n\t1\n' >"$pd/fleet/$(id 7).beat"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 7).beat"  # orphan, old
  printf 'n\t1\n' >"$pd/fleet/$(id 8).beat"                       # orphan, fresh
  touch -d "@$pnow" "$pd/fleet/$(id 8).beat"
  printf '{"v":1}' >"$pd/fleet/notes.json"; touch -d @1 "$pd/fleet/notes.json"  # not a session
  printf 'x' >"$pd/fleet/abc.beat"; touch -d @1 "$pd/fleet/abc.beat"
  printf 'not json' >"$pd/fleet/$(id 9).json"; touch -d @1 "$pd/fleet/$(id 9).json"  # unreadable
  ln -s "$pd/fleet/$(id 2).json" "$pd/fleet/$(id 10).json"           # a link
}
names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
listing() { names "$pd/fleet"; }
mkproc 501 1 claude 4321 Z claude
reset_prune
before=$(listing)

# Refusals first: none of these may delete anything.
prune_fleet "" "$pnow"; rc=$?
check "unset dir: refused" "$rc|$(listing)" "1|$before"
prune_fleet "prune/dev.ajsoftworks.klepsydra" "$pnow"; rc=$?
check "relative dir: refused" "$rc|$(listing)" "1|$before"
mkdir -p "$work/other/fleet" && cp "$pd/fleet/$(id 1).json" "$work/other/fleet/"
prune_fleet "$work/other" "$pnow"; rc=$?
check "wrong name: refused" "$rc|$(names "$work/other/fleet")" "1|$(id 1).json "
mv "$pd/fleet" "$work/real-fleet" && ln -s "$work/real-fleet" "$pd/fleet"
prune_fleet "$pd" "$pnow"; rc=$?
check "linked fleet dir: refused" "$rc|$(names "$work/real-fleet")" "1|$before"
rm "$pd/fleet" && mv "$work/real-fleet" "$pd/fleet"
prune_fleet "$pd" "not-a-time"; rc=$?
check "no clock: refused" "$rc|$(listing)" "1|$before"

prune_fleet "$pd/" "$pnow"; rc=$?
check "prune ran" "$rc" "0"
check "kept: live, recent, fresh beat, non-sessions, unreadable, link" "$(listing)" \
  "$(id 2).json $(id 4).json $(id 5).beat $(id 5).json $(id 8).beat $(id 9).json $(id 10).json abc.beat notes.json "
check "the linked file's target survives" "$(jq -r .session_id "$pd/fleet/$(id 2).json")" "$(id 2)"

reset_prune
mksession "$(id 11)" 501 4321 $((pnow - 2 * day))
prune_fleet "$pd" "$pnow"
check "a zombie is gone" "$([[ -e $pd/fleet/$(id 11).json ]] && echo kept || echo deleted)" "deleted"

reset_prune
fire session-start.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$pnow"
check "session start prunes" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "deleted"
check "session start writes its own file first" "$(jq -r .state "$pd/fleet/$(id 12).json")" "new"
reset_prune
fire user-prompt.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$pnow"
check "other events do not prune" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "kept"

```

- [ ] **Step 2: Run them**

Run:

```bash
bash hooks/test_fleet.sh
```

Expected: FAIL: `94 passed, 9 failed`. `prune_fleet` does not exist yet, so each refusal reports rc `127` where `1` is wanted (nothing is deleted), the deletion checks fail, and `session start prunes` finds the dead session's file still there.

- [ ] **Step 3: Write the prune**

In `hooks/klepsydra-fleet.sh`, before:

```bash
# The session file after one event
```

insert:

```bash
# Whether the Claude Code process recorded as `pid start` still runs. A zombie
# has exited, and a pid with another start time is someone else's.
claude_alive() { # pid start
  local -a stat=()
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  proc_stat "$1" || return 1
  [[ ${stat[0]} != Z && ${stat[19]} == "$2" ]]
}

# Delete the files of sessions whose Claude Code process is gone and whose
# last event is more than a day old, and heartbeats a day old with no session
# file. Only <uuid>.json and <uuid>.beat directly inside <dir>/fleet, and only
# when `dir` is the overlay's own absolute data dir.
PRUNE_AFTER=86400
prune_fleet() { # dir now
  local dir=${1%/} now=$2 fleet ref f id pid start last
  [[ -n $dir ]] || return 1
  [[ $dir == /* ]] || return 1
  [[ ${dir##*/} == dev.ajsoftworks.klepsydra ]] || return 1
  [[ $now =~ ^[0-9]+$ ]] || return 1
  fleet=$dir/fleet
  [[ -L $fleet ]] && return 1
  [[ -d $fleet ]] || return 0
  # Heartbeat mtimes are compared against a file stamped a day before now.
  ref=${LOCK%.lock}.ref
  touch -d "@$((now - PRUNE_AFTER))" "$ref" 2>/dev/null || return 1
  for f in "$fleet"/*.json; do
    id=${f##*/}
    id=${id%.json}
    [[ $id =~ $UUID_RE && -f $f && ! -L $f ]] || continue
    IFS=$'\t' read -r pid start last < <(jq -r '[(.claude.pid // 0), (.claude.start // 0),
      ([.started_at, .state_at, .where.at, .prompt.at, .reply.at, .ended.at] | map(numbers) | max // 0)]
      | map(floor | tostring) | join("\t")' "$f" 2>/dev/null) || continue
    [[ $last =~ ^[0-9]+$ ]] || continue
    (( now - last > PRUNE_AFTER )) || continue
    [[ -f $fleet/$id.beat && $fleet/$id.beat -nt $ref ]] && continue
    claude_alive "$pid" "$start" && continue
    rm -f -- "$f"
    [[ -L $fleet/$id.beat ]] || rm -f -- "$fleet/$id.beat"
  done
  for f in "$fleet"/*.beat; do
    id=${f##*/}
    id=${id%.beat}
    [[ $id =~ $UUID_RE && -f $f && ! -L $f && ! -e $fleet/$id.json && $f -ot $ref ]] || continue
    rm -f -- "$f"
  done
  return 0
}

```

In `hooks/klepsydra-fleet.sh`, replace:

```bash
  [[ -n $new ]] && write_atomic "$file" "$new"
  return 0
```

with:

```bash
  [[ -n $new ]] && write_atomic "$file" "$new"
  [[ $event == SessionStart ]] && prune_fleet "$KLEPSYDRA_DIR" "$now"
  return 0
```

- [ ] **Step 4: Run the tests and shellcheck**

Run:

```bash
bash hooks/test_fleet.sh && uvx --from shellcheck-py shellcheck hooks/*.sh
```

Expected: PASS: `103 passed, 0 failed` (97 without keryx), no shellcheck output.

- [ ] **Step 5: Confirm each refusal is load-bearing**

Replace the line `[[ ${dir##*/} == dev.ajsoftworks.klepsydra ]] || return 1` with `:` and run `bash hooks/test_fleet.sh`: expect `FAIL wrong name: refused`. Restore it, then do the same with `[[ -L $fleet ]] && return 1` (expect `FAIL linked fleet dir: refused`) and `[[ $dir == /* ]] || return 1` (expect `FAIL relative dir: refused`). Restore and expect all checks to pass.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(fleet): prune the files of sessions whose process is gone" -- hooks/klepsydra-fleet.sh hooks/test_fleet.sh
```

### Task 6: Statusline heartbeat

**Files:**

- Create: `statusline/fixtures/named-session.json`
- Modify: `statusline/test_statusline.sh` (line 218)
- Modify: `statusline/klepsydra-statusline.sh` (lines 2-7, 34, 56, 58, 75-76, 88-89)

**Interfaces:**

- **Consumes:** the statusline input's `session_id` and `session_name` (statusline docs, 2026-10: the custom name or the AI-generated title, absent until one exists; the terminal tab shows the same value).
- **Produces:** `<KLEPSYDRA_DIR>/fleet/<session_id>.beat`, one line `<name>\t<epoch seconds / 10>\n`, rewritten only when the line changes (at most once per 10 s, at once on a rename), and only for a UUID `session_id`. Tabs, CR and LF in the name become spaces. Its modification time is the heartbeat. `KLEPSYDRA_NOW` overrides the clock, which also replaces the script's `$(date +%s)` process.

- [ ] **Step 1: Add a fixture with a session name**

Create `statusline/fixtures/named-session.json`:

```json
{"session_id":"cb9fa591-1514-44d1-a31c-eba4a7cb41ed","session_name":"Plan the fleet visualizer","cwd":"/home/ajbar/ajsoftworks","model":{"id":"claude-opus-5","display_name":"Opus 5"},
 "context_window":{"total_input_tokens":42000,"context_window_size":200000,"used_percentage":21.4,"remaining_percentage":78.6},
 "rate_limits":{"five_hour":{"used_percentage":73.2,"resets_at":1789000000},
                "seven_day":{"used_percentage":12.9,"resets_at":1789400000}}}
```

- [ ] **Step 2: Write the failing tests**

In `statusline/test_statusline.sh`, before:

```bash
# --- default destination must track
```

insert:

```bash
# --- the fleet heartbeat ----------------------------------------------------
# One line per session: its name (the terminal tab title) and the 10 s bucket
# it was written in. A render in the same bucket with the same name writes
# nothing; refreshInterval re-renders every 30 s, so a live session beats.
B=cb9fa591-1514-44d1-a31c-eba4a7cb41ed
beat="$work/out/fleet/$B.beat"
named=$(cat "$fixtures/named-session.json")
beat_run() { # epoch-seconds [json]
  CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$work/out" KLEPSYDRA_NOW="$1" bash "$script" <<<"${2:-$named}"
}
tab=$'\t'
rm -rf "$work/out"
display=$(beat_run 1792353001)
check "beat: still echoes"        "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "beat: name and bucket"     "$(cat "$beat")" "Plan the fleet visualizer${tab}179235300"
touch -d @1 "$beat"
beat_run 1792353009 >/dev/null
check "beat: same bucket, no write" "$(stat -c %Y "$beat")" "1"
beat_run 1792353010 >/dev/null
check "beat: next bucket, rewritten" "$(cat "$beat")" "Plan the fleet visualizer${tab}179235301"
touch -d @1 "$beat"
beat_run 1792353011 "$(jq -c '.session_name = "fleet-plan"' <<<"$named")" >/dev/null
check "beat: a rename writes at once" "$(cat "$beat")" "fleet-plan${tab}179235301"
beat_run 1792353020 "$(jq -c 'del(.session_name)' <<<"$named")" >/dev/null
check "beat: no name yet"          "$(cat "$beat")" "${tab}179235302"
beat_run 1792353030 "$(jq -c '.session_name = "a\tb\nc"' <<<"$named")" >/dev/null
check "beat: tabs and newlines flattened" "$(cat "$beat")" "a b c${tab}179235303"
rm -rf "$work/out"
beat_run 1792353040 "$(jq -c 'del(.rate_limits)' <<<"$named")" >/dev/null
check "beat: written without rate limits" "$([[ -f $beat ]] && echo yes)" "yes"
rm -rf "$work/out"
run full.json team >/dev/null
check "beat: none for a session id that is not a uuid" "$(find "$work/out" -name '*.beat' | wc -l)" "0"
check "beat: no tmp litter" "$(find "$work/out" -name '*.tmp' | wc -l)" "0"

```

- [ ] **Step 3: Run them**

Run:

```bash
bash statusline/test_statusline.sh
```

Expected: FAIL: `58 passed, 7 failed`. `beat: name and bucket` and the other checks that read the beat fail (`cat: .../fleet/cb9fa591-1514-44d1-a31c-eba4a7cb41ed.beat: No such file or directory`); `beat: still echoes`, the uuid and tmp checks, and the 55 existing checks pass.

- [ ] **Step 4: Write the heartbeat**

In `statusline/klepsydra-statusline.sh`, replace:

```bash
# Claude Code statusLine command. Reads the session JSON on stdin, publishes the
# rate-limit windows to a file the klepsydra overlay polls, and echoes a compact
# readout back to the terminal.
#
# Wire it up in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh" }
```

with:

```bash
# Claude Code statusLine command. Reads the session JSON on stdin, publishes the
# rate-limit windows to a file the klepsydra overlay polls, writes the session's
# heartbeat for the fleet strip, and echoes a compact readout back to the
# terminal.
#
# Wire it up in ~/.claude/settings.json (README.md has the whole block):
#   "statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh",
#                   "refreshInterval": 30 }
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
input=$(cat)
```

with:

```bash
input=$(cat)
now=${KLEPSYDRA_NOW:-}
[[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
# context readout, the account id, the session id.
```

with:

```bash
# context readout, the account id, the session id, the session name.
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
  --argjson now "$(date +%s)" --argjson acct "$account"
```

with:

```bash
  --argjson now "$now" --argjson acct "$account"
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
  $acct.id,
  $session
```

with:

```bash
  $acct.id,
  $session,
  ( $root.session_name // "" | tostring | gsub("[\t\r\n]"; " ") )
```

In `statusline/klepsydra-statusline.sh`, replace:

```bash
  IFS= read -r session
} <<<"$parsed"

```

with:

```bash
  IFS= read -r session
  IFS= read -r name
} <<<"$parsed"

# The fleet strip's heartbeat: the session's name (its terminal tab title) and
# the 10 s bucket it was written in. Rewritten only when either changes, so a
# render costs a read and at most one write per 10 s.
if [[ $session =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  beat="$KLEPSYDRA_DIR/fleet/$session.beat"
  beat_line="$name"$'\t'"$((now / 10))"
  was=""
  { IFS= read -r was <"$beat"; } 2>/dev/null
  if [[ "$was" != "$beat_line" ]] && mkdir -p "${beat%/*}" 2>/dev/null; then
    tmp="$beat.$$.tmp"
    if printf '%s\n' "$beat_line" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$beat" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

```

- [ ] **Step 5: Run the statusline tests and shellcheck**

Run:

```bash
bash statusline/test_statusline.sh && bash hooks/test_fleet.sh && uvx --from shellcheck-py shellcheck hooks/*.sh statusline/*.sh
```

Expected: PASS: `65 passed, 0 failed` for the statusline and `103 passed, 0 failed` for the hook (its dir-block check reads the statusline), no shellcheck output.

- [ ] **Step 6: Commit**

```bash
git add statusline/fixtures/named-session.json && git commit -m "feat(fleet): write a heartbeat with the session name from the status line" -- statusline/klepsydra-statusline.sh statusline/test_statusline.sh statusline/fixtures/named-session.json
```

### Task 7: Face assets and the cast

**Files:**

- Create: `src/fleet/cast.json`
- Create: `src/fleet-cast.test.js`
- Create: `scripts/render-lorelei.mjs`
- Create: `scripts/cut-portraits.py`
- Create: `scripts/render-faces.sh`
- Create: `src/fleet/faces/` (generated: `kourai/*.webp`, `lorelei/*.svg`, `fallback/*.svg`; `LICENSES.json` filled)

**Interfaces:**

- **Consumes:** kourai-khryseai's `assets/avatars/vn/<name>_neutral.png` (ten 640x640 portraits: aidos aletheia cupid dokimasia hephaestus kallos metis mneme puck techne; MIT); `@dicebear/core@9.4.2` and `@dicebear/lorelei@9.4.2` (installed into a temp dir only); Pillow 13.0.0 through `uv`.
- **Produces:**
  - `src/fleet/cast.json`: `{"v": 1, "characters": {"<voice id>": {"name": str, "face": "<portrait name>", "gender": "f"|"m"}}, "lorelei": ["<voice id>", ...54], "fallbacks": 24}`.
  - Faces under `src/fleet/faces/`: `kourai/<name>-96.webp`, `kourai/<name>-192.webp`, `lorelei/<voice id>.svg` for all 54 Kokoro voices, `fallback/00.svg` to `fallback/23.svg`, each with a `LICENSES.json` entry.
  - `scripts/render-faces.sh [kourai-dir]`, `scripts/render-lorelei.mjs <modules-dir> <faces-dir>`, `scripts/cut-portraits.py <kourai-dir> <faces-dir>`.
- **The cast** (gender-matched, one keryx rotation-pool voice each): Hephaestus `am_michael`, Puck `am_puck`, Metis `af_sarah`, Kallos `af_bella`, Techne `bf_emma`, Aidos `af_kore`, Aletheia `af_nova`, Mneme `bf_isabella`, Dokimasia `af_aoede`, Cupid `af_heart`. Uncast pool voices (`bm_george`, `am_fenrir`, `bm_fable`, `af_alloy`) and any other Kokoro voice get a Lorelei face.

- [ ] **Step 1: Write the cast**

The voice list is the 54 voices in Kokoro v1.0's `voices-v1.0.bin`, the file keryx loads (keryx has no static list; it asks the model file at run time). Any of them can be a terminal's voice through keryx's `voice` setting, so each gets a face.

Create `src/fleet/cast.json`:

```json
{
  "v": 1,
  "characters": {
    "af_heart": { "name": "Cupid", "face": "cupid", "gender": "f" },
    "am_michael": { "name": "Hephaestus", "face": "hephaestus", "gender": "m" },
    "bf_emma": { "name": "Techne", "face": "techne", "gender": "f" },
    "af_bella": { "name": "Kallos", "face": "kallos", "gender": "f" },
    "bf_isabella": { "name": "Mneme", "face": "mneme", "gender": "f" },
    "am_puck": { "name": "Puck", "face": "puck", "gender": "m" },
    "af_aoede": { "name": "Dokimasia", "face": "dokimasia", "gender": "f" },
    "af_kore": { "name": "Aidos", "face": "aidos", "gender": "f" },
    "af_sarah": { "name": "Metis", "face": "metis", "gender": "f" },
    "af_nova": { "name": "Aletheia", "face": "aletheia", "gender": "f" }
  },
  "lorelei": [
    "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
    "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
    "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
    "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis",
    "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune",
    "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni",
    "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"
  ],
  "fallbacks": 24
}
```

- [ ] **Step 2: Write the failing cast test**

Create `src/fleet-cast.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
const faces = new URL("./fleet/faces/", import.meta.url);
const exists = (file) => existsSync(new URL(file, faces));

// keryx's rotation pool (keryx src/keryx/voices.py POOL, 0.9.0): the only
// voices keryx hands a terminal unasked.
const POOL = [
  "af_heart", "am_michael", "bf_emma", "bm_george", "af_bella", "am_fenrir", "bf_isabella",
  "bm_fable", "am_puck", "af_aoede", "af_kore", "af_sarah", "af_alloy", "af_nova",
];
// Every voice in Kokoro v1.0's voices-v1.0.bin, the file keryx loads; any of
// them can be a terminal's voice through keryx's `voice` setting.
const KOKORO = [
  "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
  "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
  "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
  "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis",
  "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune",
  "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni",
  "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
];
const PORTRAITS = ["aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne"];

test("the ten kourai characters each have one pool voice of their gender", () => {
  const entries = Object.entries(cast.characters);
  assert.deepEqual(entries.map(([, c]) => c.face).sort(), PORTRAITS);
  assert.equal(new Set(entries.map(([, c]) => c.name)).size, 10);
  for (const [voice, c] of entries) {
    assert.ok(POOL.includes(voice), `${voice} is not in keryx's pool`);
    assert.equal(voice[1], c.gender, `${c.name} cast against gender`);
  }
});

test("kourai's named Kokoro seeds are kept", () => {
  assert.equal(cast.characters.am_michael.name, "Hephaestus");
  assert.equal(cast.characters.am_puck.name, "Puck");
});

test("every Kokoro voice has a Lorelei face, and every face file exists", () => {
  assert.deepEqual([...cast.lorelei].sort(), KOKORO);
  for (const voice of cast.lorelei) assert.ok(exists(`lorelei/${voice}.svg`), voice);
  for (const c of Object.values(cast.characters)) {
    for (const size of [96, 192]) assert.ok(exists(`kourai/${c.face}-${size}.webp`), `${c.face} ${size}`);
  }
  assert.equal(cast.fallbacks, 24);
  for (let i = 0; i < cast.fallbacks; i++) assert.ok(exists(`fallback/${String(i).padStart(2, "0")}.svg`), String(i));
});
```

- [ ] **Step 3: Run it**

Run:

```bash
node --test src/fleet-cast.test.js
```

Expected: FAIL: `every Kokoro voice has a Lorelei face, and every face file exists` fails on `af_alloy` (no `lorelei/af_alloy.svg` yet); the two cast tests pass.

- [ ] **Step 4: Write the face scripts**

Create `scripts/render-lorelei.mjs`:

```js
// Renders the fleet's DiceBear Lorelei faces into src/fleet/faces, with a
// LICENSES.json entry for each: one per Kokoro voice in cast.json, and the
// fallbacks. Run through scripts/render-faces.sh, which installs the pinned
// DiceBear packages into a temp dir and passes it here.
// Usage: node scripts/render-lorelei.mjs <dir holding node_modules> <faces dir>
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const VERSION = "9.4.2";
const ARTWORK = "DiceBear Lorelei by Lisa Wischofsky (https://www.figma.com/community/file/1198749693280469639)";
// Light grounds, so the line art reads against the dark strip.
const BACKGROUNDS = ["b6e3f4", "c0aede", "d1d4f9", "ffd5dc", "ffdfbf"];

const [modules, faces] = process.argv.slice(2);
if (!modules || !faces) {
  console.error("usage: node scripts/render-lorelei.mjs <dir holding node_modules> <faces dir>");
  process.exit(2);
}
const load = (pkg) => import(pathToFileURL(join(modules, "node_modules", pkg, "lib", "index.js")).href);
const { createAvatar } = await load("@dicebear/core");
const lorelei = await load("@dicebear/lorelei");
for (const pkg of ["core", "lorelei"]) {
  const { version } = JSON.parse(readFileSync(join(modules, "node_modules", "@dicebear", pkg, "package.json"), "utf8"));
  if (version !== VERSION) throw new Error(`@dicebear/${pkg} is ${version}, want ${VERSION}`);
}

const cast = JSON.parse(readFileSync(new URL("../src/fleet/cast.json", import.meta.url), "utf8"));
const licensesPath = join(faces, "LICENSES.json");
const licenses = JSON.parse(readFileSync(licensesPath, "utf8"));
const pad = (n) => String(n).padStart(2, "0");

function render(file, seed) {
  const svg = createAvatar(lorelei, { seed, backgroundColor: BACKGROUNDS }).toString();
  mkdirSync(join(faces, file, ".."), { recursive: true });
  writeFileSync(join(faces, file), `${svg}\n`);
  licenses[file] = {
    source: `${ARTWORK}, rendered with @dicebear/core@${VERSION} and @dicebear/lorelei@${VERSION} from seed "${seed}"`,
    license: "CC0-1.0",
  };
}

for (const voice of cast.lorelei) render(`lorelei/${voice}.svg`, voice);
for (let i = 0; i < cast.fallbacks; i++) render(`fallback/${pad(i)}.svg`, `klepsydra-fallback-${pad(i)}`);

const sorted = Object.fromEntries(Object.entries(licenses).sort(([a], [b]) => a.localeCompare(b)));
writeFileSync(licensesPath, `${JSON.stringify(sorted, null, 2)}\n`);
console.log(`rendered ${cast.lorelei.length} voice faces and ${cast.fallbacks} fallbacks`);
```

Create `scripts/cut-portraits.py`:

```python
"""Cut the ten kourai-khryseai portraits to the fleet's faces: the head of each
640 px neutral portrait, as 96 px and 192 px WebP, with a LICENSES.json entry
for each file.

Usage: uv run --no-project --with pillow==13.0.0 python -I scripts/cut-portraits.py <kourai-khryseai> <faces dir>
"""

import json
import sys
from pathlib import Path

from PIL import Image

NAMES = ("aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne")
# (left, top, right, bottom) of the head in the 640 px portrait. Hephaestus
# stands right of centre at his anvil.
HEAD = {name: (180, 20, 460, 300) for name in NAMES} | {"hephaestus": (250, 20, 530, 300)}
SIZES = (96, 192)
SOURCE = (
    "kourai-khryseai assets/avatars/vn/{name}_neutral.png "
    "(https://github.com/ajbarea/kourai-khryseai), head cropped and scaled to {size} px"
)
LICENSE = "MIT (kourai-khryseai LICENSE, Copyright (c) 2026 AJ Barea)"


def main(kourai: Path, faces: Path) -> None:
    licenses_path = faces / "LICENSES.json"
    licenses = json.loads(licenses_path.read_text())
    (faces / "kourai").mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        portrait = Image.open(kourai / "assets" / "avatars" / "vn" / f"{name}_neutral.png").convert("RGB")
        if portrait.size != (640, 640):
            raise SystemExit(f"{name}: expected 640x640, got {portrait.size}")
        head = portrait.crop(HEAD[name])
        for size in SIZES:
            file = f"kourai/{name}-{size}.webp"
            head.resize((size, size), Image.Resampling.LANCZOS).save(faces / file, "WEBP", quality=82, method=6)
            licenses[file] = {"source": SOURCE.format(name=name, size=size), "license": LICENSE}
    licenses_path.write_text(json.dumps(dict(sorted(licenses.items())), indent=2) + "\n")
    print(f"cut {len(NAMES)} portraits at {', '.join(map(str, SIZES))} px")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
```

Create `scripts/render-faces.sh`:

```bash
#!/usr/bin/env bash
# Regenerates every face under src/fleet/faces: the ten kourai-khryseai
# portraits and the DiceBear Lorelei faces, each with its LICENSES.json entry.
# Run once and commit the results; the app loads no library at run time.
# Usage: bash scripts/render-faces.sh [path/to/kourai-khryseai]
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
kourai=${1:-$HOME/ajsoftworks/kourai-khryseai}
faces="$repo/src/fleet/faces"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> DiceBear 9.4.2 into $tmp"
npm install --prefix "$tmp" --no-save --no-fund --no-audit --ignore-scripts \
  @dicebear/core@9.4.2 @dicebear/lorelei@9.4.2 >/dev/null
node "$repo/scripts/render-lorelei.mjs" "$tmp" "$faces"

echo "==> kourai portraits from $kourai"
uv run --no-project --with pillow==13.0.0 python -I "$repo/scripts/cut-portraits.py" "$kourai" "$faces"
```

- [ ] **Step 5: Render the faces**

This needs the network once, for npm, and kourai-khryseai at `~/ajsoftworks/kourai-khryseai` (or pass its path).

Run:

```bash
bash scripts/render-faces.sh
```

Expected: Prints `rendered 54 voice faces and 24 fallbacks` and `cut 10 portraits at 96, 192 px`; `src/fleet/faces` holds 98 faces and `LICENSES.json` 98 entries (about 820 KB).

- [ ] **Step 6: Look at them**

Open `src/fleet/faces/kourai/hephaestus-192.webp` and two or three Lorelei faces: each portrait shows the head and shoulders, Hephaestus included (his crop is shifted right), and each Lorelei face sits on a light ground.

- [ ] **Step 7: Run every node test and shellcheck**

Run:

```bash
node --test src/*.test.js && uvx --from shellcheck-py shellcheck scripts/*.sh
```

Expected: PASS: 66 tests, among them the 3 cast tests and the license guard (every face has a `LICENSES.json` entry with a source and a license, and no entry is stale).

- [ ] **Step 8: Commit**

```bash
git add src/fleet/cast.json src/fleet-cast.test.js scripts/render-lorelei.mjs scripts/cut-portraits.py scripts/render-faces.sh src/fleet/faces && git commit -m "feat(fleet): cast keryx voices to kourai portraits and render every face once" -- src/fleet/cast.json src/fleet-cast.test.js scripts/render-lorelei.mjs scripts/cut-portraits.py scripts/render-faces.sh src/fleet/faces
```

### Task 8: Fleet reader crate: session files and what they show

**Files:**

- Modify: `src-tauri/Cargo.toml` (lines 5, 14)
- Create: `src-tauri/fleet/Cargo.toml`
- Create: `src-tauri/fleet/src/lib.rs`
- Create: `src-tauri/fleet/src/session.rs`
- Create: `src-tauri/fleet/src/view.rs`
- Modify: `.github/workflows/ci.yml` (lines 92, 95, 96-99)
- Modify: `scripts/build-windows.sh` (lines 2-5, 24)
- Modify: `src-tauri/Cargo.lock` (by cargo)

**Interfaces:**

- **Consumes:** the session file v1 (Task 4) and the beat line (Task 6).
- **Produces:** a Cargo workspace in `src-tauri` (members `.` and `fleet`) and the crate `klepsydra-fleet` (`klepsydra_fleet` in Rust), free of Tauri so `cargo test -p klepsydra-fleet` runs in WSL:
  - `session`: `VERSION: u64 = 1`; `enum State { New, Working, NeedsYou, Done, Error, Ended }` (serde `snake_case`); `struct Place { repo: String, worktree: Option<String>, branch: Option<String>, at: i64 }`; `struct Touched { repo: String, at: i64 }`; `struct Said { text: String, at: i64 }`; `struct Ended { reason: String, at: i64 }`; `struct SessionFile { session_id, name, launch_dir, voice, state, reason, state_at, place (JSON "where"), touched, prompt, reply, error, ended, written_at: Option<i64> }`; `enum Rejected { Version(String), Malformed(String), WrongId }` (Display: `unknown version 2`, `malformed: ...`, `session_id does not match the file name`); `parse(text: &str, stem: &str) -> Result<SessionFile, Rejected>`; `beat_name(text: &str) -> Option<String>`; `is_session_id(stem: &str) -> bool`.
  - `view`: `SILENT_AFTER: i64 = 90`; `ENDED_FOR: i64 = 600`; `enum Status { NeedsYou, Error, Working, Done, New, Silent, Ended }` (declaration order is the display order); `struct Entry { file: SessionFile, modified: i64, beat: Option<(i64, Option<String>)> }` (`modified` and the beat's time are file mtimes, this machine's clock); `struct View`; `struct Snapshot { sessions: Vec<View> }`; `view(entry: &Entry, now: i64) -> Option<View>`; `snapshot(entries: &[Entry], now: i64) -> Snapshot`.
  - What a webview receives: `{"sessions": [{"session_id": str, "name": str|null, "launch_dir": str|null, "voice": str|null, "status": "needs_you"|"error"|"working"|"done"|"new"|"silent"|"ended", "reason": str|null, "status_at": int, "where": {"repo": str, "worktree": str|null, "branch": str|null, "at": int}|null, "touched": [{"repo": str, "at": int}], "prompt": {"text": str, "at": int}|null, "reply": {"text": str, "at": int}|null, "error": str|null, "updated_at": int}]}`; every time is on this machine's clock, `name` is the beat's name over the file's, and a silent session's `status_at` is its last word.
- **Rules:** silent when neither the beat nor the file changed for more than 90 s (any state but ended); ended sessions leave 10 minutes after `ended.at`; the hook's clock is put on this machine's by `modified - written_at` when they differ by more than 2 s; order is needs you (longest wait first), error, working, done (newest first), not started, silent, ended, then newest first, then session id.
- `scripts/build-windows.sh --check` runs `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` on the Windows staging copy.

- [ ] **Step 1: Make the workspace and the crate**

In `src-tauri/Cargo.toml`, after:

```toml
edition = "2021"
```

insert:

```toml

[workspace]
members = [".", "fleet"]
```

In `src-tauri/Cargo.toml`, after:

```toml
serde_json = "1"
```

insert:

```toml
klepsydra-fleet = { path = "fleet" }
```

Create `src-tauri/fleet/Cargo.toml`:

```toml
[package]
name = "klepsydra-fleet"
version = "0.1.0"
description = "Reads the fleet strip's session files, free of Tauri so it tests anywhere"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

Create `src-tauri/fleet/src/lib.rs`:

```rust
//! The fleet strip's reader: session files in, an ordered list of sessions
//! out. Kept free of Tauri so its tests run on any machine.

pub mod session;
pub mod view;
```

- [ ] **Step 2: Write the failing tests**

Among them the guard from the rejected-ideas table: a session whose heartbeat stopped shows silent with the age of its last word, never working. The clock-skew tests are a Review Focus item.

Create `src-tauri/fleet/src/session.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";

    fn file(extra: &str) -> String {
        format!(r#"{{"v":1,"session_id":"{ID}","state":"working","state_at":100{extra}}}"#)
    }

    #[test]
    fn a_file_the_hook_writes_parses() {
        let text = r#"{"v":1,"session_id":"cb9fa591-1514-44d1-a31c-eba4a7cb41ed","name":null,
          "started_at":90,"launch_dir":"/home/aj/ajsoftworks","claude":{"pid":2231,"start":8717628},
          "voice":"am_michael","state":"needs_you","reason":"approve Bash",
          "needs":{"by":"","tool":"Bash"},"state_at":106,
          "where":{"repo":"klepsydra","worktree":"fleet","branch":"feat/fleet-visualizer","by":"edit","at":105},
          "touched":[{"repo":"ideas","at":95}],"prompt":{"text":"viz them","at":100},
          "reply":{"text":"That works","at":99},"error":null,"ended":null,"written_at":106}"#;
        let f = parse(text, ID).unwrap();
        assert_eq!(f.state, State::NeedsYou);
        assert_eq!(f.reason.as_deref(), Some("approve Bash"));
        assert_eq!(f.place.unwrap().worktree.as_deref(), Some("fleet"));
        assert_eq!(
            f.touched,
            vec![Touched {
                repo: "ideas".into(),
                at: 95
            }]
        );
        assert_eq!(f.written_at, Some(106));
    }

    #[test]
    fn an_unknown_version_is_rejected_whatever_else_it_holds() {
        let text = format!(r#"{{"v":2,"session_id":"{ID}","state":"teleporting"}}"#);
        assert_eq!(parse(&text, ID), Err(Rejected::Version("2".into())));
        let text = format!(r#"{{"session_id":"{ID}","state":"working","state_at":1}}"#);
        assert_eq!(parse(&text, ID), Err(Rejected::Version("missing".into())));
    }

    #[test]
    fn malformed_files_are_rejected() {
        assert!(matches!(
            parse("{\"v\":1,", ID),
            Err(Rejected::Malformed(_))
        ));
        assert!(matches!(
            parse(&file(r#","state":"x""#), ID),
            Err(Rejected::Malformed(_))
        ));
        assert!(matches!(
            parse(
                &format!(r#"{{"v":1,"session_id":"{ID}","state":"done"}}"#),
                ID
            ),
            Err(Rejected::Malformed(_))
        ));
    }

    #[test]
    fn a_file_must_be_named_for_its_session() {
        let other = "00000000-0000-4000-8000-000000000000";
        assert_eq!(parse(&file(""), other), Err(Rejected::WrongId));
    }

    #[test]
    fn beat_names() {
        assert_eq!(
            beat_name("Plan the fleet\t179235300\n").as_deref(),
            Some("Plan the fleet")
        );
        assert_eq!(beat_name("\t179235300\n"), None);
        assert_eq!(beat_name(""), None);
    }

    #[test]
    fn session_ids_are_uuids() {
        assert!(is_session_id(ID));
        assert!(is_session_id("CB9FA591-1514-44D1-A31C-EBA4A7CB41ED"));
        assert!(!is_session_id("abc-123"));
        assert!(!is_session_id("cb9fa591-1514-44d1-a31c-eba4a7cb41ed.json"));
        assert!(!is_session_id("cb9fa591x1514-44d1-a31c-eba4a7cb41ed"));
        assert!(!is_session_id("../../../../../../../../../../../etc"));
    }
}
```

Create `src-tauri/fleet/src/view.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_792_353_000;

    fn file(id: &str, state: State, state_at: i64) -> SessionFile {
        SessionFile {
            session_id: id.into(),
            name: None,
            launch_dir: Some("/home/aj/ajsoftworks".into()),
            voice: Some("am_michael".into()),
            state,
            reason: None,
            state_at,
            place: None,
            touched: vec![],
            prompt: None,
            reply: None,
            error: None,
            ended: None,
            written_at: Some(state_at),
        }
    }

    /// A session whose file last changed at `state_at` and which beat at `beat`.
    fn entry(id: &str, state: State, state_at: i64, beat: i64) -> Entry {
        Entry {
            file: file(id, state, state_at),
            modified: state_at,
            beat: Some((beat, Some(format!("tab {id}")))),
        }
    }

    fn ids(s: &Snapshot) -> Vec<&str> {
        s.sessions.iter().map(|v| v.session_id.as_str()).collect()
    }

    #[test]
    fn a_session_whose_heartbeat_stopped_is_silent_never_working() {
        let e = entry("a", State::Working, NOW - 600, NOW - 91);
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status, Status::Silent);
        assert_eq!(v.status_at, NOW - 91, "silent since the last word");
        assert_eq!(v.reason, None);
    }

    #[test]
    fn a_live_heartbeat_keeps_the_state() {
        let e = entry("a", State::Working, NOW - 600, NOW - 30);
        let v = view(&e, NOW).unwrap();
        assert_eq!((v.status, v.status_at), (Status::Working, NOW - 600));
    }

    #[test]
    fn a_recent_event_keeps_a_session_from_silence_even_without_a_beat() {
        let mut e = entry("a", State::NeedsYou, NOW - 20, 0);
        e.beat = None;
        assert_eq!(view(&e, NOW).unwrap().status, Status::NeedsYou);
        e.file.state_at = NOW - 200;
        e.modified = NOW - 200;
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
    }

    #[test]
    fn an_event_after_the_last_beat_still_falls_silent() {
        let e = entry("a", State::Working, NOW - 95, NOW - 120);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Silent);
    }

    #[test]
    fn an_ended_session_stays_ten_minutes_and_is_never_silent() {
        let mut e = entry("a", State::Ended, NOW - 300, NOW - 300);
        assert_eq!(view(&e, NOW).unwrap().status, Status::Ended);
        e.file.state_at = NOW - 601;
        e.modified = NOW - 601;
        assert_eq!(view(&e, NOW), None);
    }

    #[test]
    fn not_started_is_its_own_status() {
        let e = entry("a", State::New, NOW - 10, NOW - 5);
        assert_eq!(view(&e, NOW).unwrap().status, Status::New);
    }

    #[test]
    fn the_beat_names_the_session_over_the_file() {
        let mut e = entry("a", State::Done, NOW - 10, NOW - 5);
        e.file.name = Some("custom".into());
        assert_eq!(view(&e, NOW).unwrap().name.as_deref(), Some("tab a"));
        e.beat = Some((NOW - 5, None));
        assert_eq!(view(&e, NOW).unwrap().name.as_deref(), Some("custom"));
    }

    #[test]
    fn a_writer_clock_ten_minutes_ahead_is_put_back() {
        // The hook's clock ahead of this one: every stored time reads 600 s late.
        let mut e = entry("a", State::NeedsYou, NOW - 120 + 600, NOW - 10);
        e.modified = NOW - 120;
        e.file.prompt = Some(Said {
            text: "go".into(),
            at: NOW - 130 + 600,
        });
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status_at, NOW - 120);
        assert_eq!(v.prompt.unwrap().at, NOW - 130);
    }

    #[test]
    fn a_writer_clock_behind_is_put_forward_and_cannot_hide_silence() {
        let mut e = entry("a", State::Working, NOW - 900 - 3600, NOW - 900);
        e.modified = NOW - 900;
        let v = view(&e, NOW).unwrap();
        assert_eq!(v.status, Status::Silent);
        assert_eq!(v.status_at, NOW - 900);
    }

    #[test]
    fn a_two_second_disagreement_is_not_skew() {
        let mut e = entry("a", State::Done, NOW - 100, NOW - 5);
        e.modified = NOW - 98;
        assert_eq!(view(&e, NOW).unwrap().status_at, NOW - 100);
    }

    #[test]
    fn updated_is_the_newest_field() {
        let mut e = entry("a", State::Working, NOW - 400, NOW - 5);
        e.file.reply = Some(Said {
            text: "r".into(),
            at: NOW - 350,
        });
        e.file.prompt = Some(Said {
            text: "p".into(),
            at: NOW - 300,
        });
        assert_eq!(view(&e, NOW).unwrap().updated_at, NOW - 300);
    }

    #[test]
    fn order_needs_you_longest_wait_first_then_by_status() {
        let entries = vec![
            entry("ended", State::Ended, NOW - 60, NOW - 60),
            entry("done-old", State::Done, NOW - 500, NOW - 5),
            entry("needs-new", State::NeedsYou, NOW - 10, NOW - 5),
            entry("silent", State::Working, NOW - 300, NOW - 200),
            entry("new", State::New, NOW - 20, NOW - 5),
            entry("working", State::Working, NOW - 40, NOW - 5),
            entry("done-new", State::Done, NOW - 50, NOW - 5),
            entry("error", State::Error, NOW - 70, NOW - 5),
            entry("needs-old", State::NeedsYou, NOW - 80, NOW - 5),
        ];
        assert_eq!(
            ids(&snapshot(&entries, NOW)),
            vec![
                "needs-old",
                "needs-new",
                "error",
                "working",
                "done-new",
                "done-old",
                "new",
                "silent",
                "ended"
            ]
        );
    }

    #[test]
    fn a_session_that_starts_needing_aj_moves_to_the_front() {
        let mut entries = vec![
            entry("a", State::Working, NOW - 40, NOW - 5),
            entry("b", State::Done, NOW - 50, NOW - 5),
        ];
        assert_eq!(ids(&snapshot(&entries, NOW)), vec!["a", "b"]);
        entries[1] = entry("b", State::NeedsYou, NOW - 1, NOW - 1);
        assert_eq!(ids(&snapshot(&entries, NOW)), vec!["b", "a"]);
    }

    #[test]
    fn the_snapshot_serialises_as_the_webview_reads_it() {
        let mut e = entry("a", State::NeedsYou, NOW - 120, NOW - 5);
        e.file.reason = Some("approve Bash".into());
        let json = serde_json::to_value(snapshot(&[e], NOW)).unwrap();
        let s = &json["sessions"][0];
        assert_eq!(s["status"], "needs_you");
        assert_eq!(s["reason"], "approve Bash");
        assert_eq!(s["status_at"], NOW - 120);
        assert_eq!(s["where"], serde_json::Value::Null);
        assert_eq!(s["name"], "tab a");
    }
}
```

- [ ] **Step 3: Run them**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet
```

Expected: FAIL to compile: `error[E0433]: cannot find type `State` in this scope`, `error[E0425]: cannot find function `snapshot` in this scope`, and more like them.

- [ ] **Step 4: Write the session file and the views**

In `src-tauri/fleet/src/session.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
//! One session file, as the fleet hook writes it, and its heartbeat.

use serde::{Deserialize, Serialize};

/// The only session-file version this reader understands.
pub const VERSION: u64 = 1;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    New,
    Working,
    NeedsYou,
    Done,
    Error,
    Ended,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Place {
    pub repo: String,
    #[serde(default)]
    pub worktree: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    pub at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Touched {
    pub repo: String,
    pub at: i64,
}

/// A prompt or a reply, with when it was stored.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Said {
    pub text: String,
    pub at: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Ended {
    pub reason: String,
    pub at: i64,
}

/// `<session_id>.json`. Times are the writer's clock, in epoch seconds.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SessionFile {
    pub session_id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub launch_dir: Option<String>,
    #[serde(default)]
    pub voice: Option<String>,
    pub state: State,
    #[serde(default)]
    pub reason: Option<String>,
    pub state_at: i64,
    #[serde(default, rename = "where")]
    pub place: Option<Place>,
    #[serde(default)]
    pub touched: Vec<Touched>,
    #[serde(default)]
    pub prompt: Option<Said>,
    #[serde(default)]
    pub reply: Option<Said>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub ended: Option<Ended>,
    #[serde(default)]
    pub written_at: Option<i64>,
}

/// Why a session file was skipped.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Rejected {
    Version(String),
    Malformed(String),
    WrongId,
}

impl std::fmt::Display for Rejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Rejected::Version(v) => write!(f, "unknown version {v}"),
            Rejected::Malformed(e) => write!(f, "malformed: {e}"),
            Rejected::WrongId => write!(f, "session_id does not match the file name"),
        }
    }
}

/// Parse `<stem>.json`. Any `v` but 1 is rejected before the fields are read,
/// so a newer hook's file never half-renders.
pub fn parse(text: &str, stem: &str) -> Result<SessionFile, Rejected> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| Rejected::Malformed(e.to_string()))?;
    match value.get("v") {
        Some(v) if v.as_u64() == Some(VERSION) => {}
        Some(v) => return Err(Rejected::Version(v.to_string())),
        None => return Err(Rejected::Version("missing".into())),
    }
    let file: SessionFile =
        serde_json::from_value(value).map_err(|e| Rejected::Malformed(e.to_string()))?;
    if file.session_id != stem {
        return Err(Rejected::WrongId);
    }
    Ok(file)
}

/// The name in a `<session_id>.beat` line: the terminal tab's title, which the
/// statusline writes before a tab and the 10 s bucket. None while it has none.
pub fn beat_name(text: &str) -> Option<String> {
    let line = text.lines().next()?;
    let name = line.split('\t').next()?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// Whether `stem` is a Claude Code session id: a UUID, as the hook requires.
pub fn is_session_id(stem: &str) -> bool {
    stem.len() == 36
        && stem.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

```

In `src-tauri/fleet/src/view.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
//! What the strip and the wall show for each session: its status with that
//! status's time, in the order AJ reads them.

use serde::Serialize;

use crate::session::{Place, Said, SessionFile, State, Touched};

/// No heartbeat and no event for this long, and a session is silent: three
/// missed 30 s statusline refreshes.
pub const SILENT_AFTER: i64 = 90;
/// How long an ended session stays on the strip and the wall.
pub const ENDED_FOR: i64 = 600;
/// Clocks closer than this are taken to agree; the hook stamps a file a
/// moment before it lands.
const SKEW_SLACK: i64 = 2;

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    NeedsYou,
    Error,
    Working,
    Done,
    New,
    Silent,
    Ended,
}

impl Status {
    fn rank(self) -> u8 {
        self as u8
    }
}

/// One session file as found on disk.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub file: SessionFile,
    /// When the file last changed, by this machine's clock.
    pub modified: i64,
    /// The heartbeat: when it last changed, and the name it carries.
    pub beat: Option<(i64, Option<String>)>,
}

/// A session as the webview receives it. Every time is by this machine's
/// clock, in epoch seconds.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct View {
    pub session_id: String,
    pub name: Option<String>,
    pub launch_dir: Option<String>,
    pub voice: Option<String>,
    pub status: Status,
    pub reason: Option<String>,
    pub status_at: i64,
    #[serde(rename = "where")]
    pub place: Option<Place>,
    pub touched: Vec<Touched>,
    pub prompt: Option<Said>,
    pub reply: Option<Said>,
    pub error: Option<String>,
    pub updated_at: i64,
}

#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct Snapshot {
    pub sessions: Vec<View>,
}

/// Seconds to add to the hook's times to put them on this machine's clock.
/// The hook stamps `written_at` just before it writes, and the filesystem
/// stamps the write by this machine's clock, so the difference is how far the
/// two clocks disagree (a Linux guest's drifts after the host sleeps).
fn skew(entry: &Entry) -> i64 {
    match entry.file.written_at {
        Some(w) if (entry.modified - w).abs() > SKEW_SLACK => entry.modified - w,
        _ => 0,
    }
}

/// What to show for one session at `now`, or None once it has ended long enough ago.
pub fn view(entry: &Entry, now: i64) -> Option<View> {
    let f = &entry.file;
    let shift = skew(entry);
    let at = |t: i64| t + shift;
    let state_at = at(f.state_at);
    if f.state == State::Ended {
        let ended = f.ended.as_ref().map_or(state_at, |e| at(e.at));
        if now - ended > ENDED_FOR {
            return None;
        }
    }
    // The last word of any kind: a heartbeat, or a change to the file.
    let last_word = entry
        .beat
        .as_ref()
        .map_or(entry.modified, |b| b.0.max(entry.modified));
    let silent = f.state != State::Ended && now - last_word > SILENT_AFTER;
    let (status, reason, status_at) = if silent {
        (Status::Silent, None, last_word)
    } else {
        let status = match f.state {
            State::New => Status::New,
            State::Working => Status::Working,
            State::NeedsYou => Status::NeedsYou,
            State::Done => Status::Done,
            State::Error => Status::Error,
            State::Ended => Status::Ended,
        };
        (status, f.reason.clone(), state_at)
    };
    let shift_said = |s: &Option<Said>| {
        s.as_ref().map(|s| Said {
            text: s.text.clone(),
            at: at(s.at),
        })
    };
    let place = f.place.as_ref().map(|p| Place {
        at: at(p.at),
        ..p.clone()
    });
    let prompt = shift_said(&f.prompt);
    let reply = shift_said(&f.reply);
    let updated_at = [
        Some(state_at),
        place.as_ref().map(|p| p.at),
        prompt.as_ref().map(|s| s.at),
        reply.as_ref().map(|s| s.at),
        f.ended.as_ref().map(|e| at(e.at)),
    ]
    .into_iter()
    .flatten()
    .max()
    .unwrap_or(state_at);
    let beat_name = entry.beat.as_ref().and_then(|b| b.1.clone());
    Some(View {
        session_id: f.session_id.clone(),
        name: beat_name.or_else(|| f.name.clone()),
        launch_dir: f.launch_dir.clone(),
        voice: f.voice.clone(),
        status,
        reason,
        status_at,
        place,
        touched: f
            .touched
            .iter()
            .map(|t| Touched {
                repo: t.repo.clone(),
                at: at(t.at),
            })
            .collect(),
        prompt,
        reply,
        error: f.error.clone(),
        updated_at,
    })
}

/// Every session to show, needing AJ first, the longest wait leading; then
/// errors, work in progress, finished work newest first, not started,
/// silent and ended.
pub fn snapshot(entries: &[Entry], now: i64) -> Snapshot {
    let mut sessions: Vec<View> = entries.iter().filter_map(|e| view(e, now)).collect();
    sessions.sort_by(|a, b| {
        a.status
            .rank()
            .cmp(&b.status.rank())
            .then_with(|| match a.status {
                Status::NeedsYou => a.status_at.cmp(&b.status_at),
                _ => b.status_at.cmp(&a.status_at),
            })
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    Snapshot { sessions }
}

```

- [ ] **Step 5: Run the tests, rustfmt and clippy**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings
```

Expected: PASS: 20 tests (6 session, 14 view); rustfmt and clippy print nothing.

- [ ] **Step 6: Check workspaces in CI and on Windows**

In `.github/workflows/ci.yml`, replace:

```yaml
        run: cargo fmt --check
```

with:

```yaml
        run: cargo fmt --all --check
```

In `.github/workflows/ci.yml`, replace:

```yaml
        run: cargo clippy --all-targets -- -D warnings
```

with:

```yaml
        run: cargo clippy --workspace --all-targets -- -D warnings
```

In `.github/workflows/ci.yml`, replace:

```yaml
      # The job keeps its name: branch protection requires it by that name.
      - name: cargo test
        working-directory: src-tauri
        run: cargo test
```

with:

```yaml
      # The job keeps its name: branch protection requires it by that name.
      - name: cargo test
        working-directory: src-tauri
        run: cargo test --workspace
```

In `scripts/build-windows.sh`, replace:

```bash
# Builds the Windows binary. Source of truth stays in the WSL repo; Cargo runs
# against a native NTFS staging copy, because building on a \\wsl$ UNC path is
# slow and prone to link failures. The staging target/ dir persists, so repeat
# builds are incremental.
```

with:

```bash
# Builds the Windows binary. Source of truth stays in the WSL repo; Cargo runs
# against a native NTFS staging copy, because building on a \\wsl$ UNC path is
# slow and prone to link failures. The staging target/ dir persists, so repeat
# builds are incremental. With --check it runs clippy and the tests there
# instead, for the code that compiles only on Windows.
```

In `scripts/build-windows.sh`, before:

```bash
echo "==> installing frontend tooling"
```

insert:

```bash
if [[ ${1:-} == --check ]]; then
  echo "==> cargo clippy and cargo test, on Windows"
  powershell.exe -NoProfile -Command "$tools; cd '$stage_win\\src-tauri'; cargo clippy --workspace --all-targets -- -D warnings; if (\$LASTEXITCODE) { exit \$LASTEXITCODE }; cargo test --workspace; exit \$LASTEXITCODE"
  exit $?
fi

```

- [ ] **Step 7: Check the app crate on Windows**

The app crate needs WebKitGTK headers to compile on Linux, and WSL has none, so it is checked on the Windows staging copy (CI checks both). The local test run first also brings `Cargo.lock` up to date in WSL, since the Windows run only updates the staging copy.

Run:

```bash
(cd src-tauri && cargo test -p klepsydra-fleet) && bash scripts/build-windows.sh --check
```

Expected: PASS: the fleet tests in WSL; then on Windows, no clippy warning and `cargo test --workspace` passing the app's geometry tests and every fleet crate test.

- [ ] **Step 8: Commit**

```bash
git add src-tauri/fleet/Cargo.toml src-tauri/fleet/src/lib.rs src-tauri/fleet/src/session.rs src-tauri/fleet/src/view.rs && git commit -m "feat(fleet): parse session files and decide what each session shows" -- src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/fleet .github/workflows/ci.yml scripts/build-windows.sh
```

### Task 9: Fleet reader crate: reading and watching the directory

**Files:**

- Modify: `src-tauri/fleet/Cargo.toml` (line 9)
- Modify: `src-tauri/fleet/src/lib.rs` (lines 4, 5)
- Create: `src-tauri/fleet/src/scan.rs`
- Create: `src-tauri/fleet/src/watch.rs`
- Modify: `src-tauri/Cargo.lock` (by cargo)

**Interfaces:**

- **Consumes:** `session::{parse, beat_name, is_session_id}`, `view::{Entry, Snapshot, snapshot}` (Task 8); `notify` 8.2 (`recommended_watcher`, `RecursiveMode::NonRecursive`).
- **Produces:**
  - `scan`: `struct Problem { file: String, what: String }`; `struct Listing { entries: Vec<Entry>, problems: Vec<Problem> }`; `scan(fleet: &Path) -> Listing` (only `<uuid>.json` and `<uuid>.beat` regular files; anything else passed over silently; a missing directory is an empty fleet); `struct Reporter` with `fresh(&mut self, problems: &[Problem]) -> Vec<Problem>` (each problem once until it clears).
  - `watch`: `POLL: Duration` (5 s); `struct Reader` with `new(klepsydra_dir: &Path) -> Reader` (follows `<klepsydra_dir>/fleet`, which may not exist yet) and `step(&mut self, timeout: Duration, now: impl Fn() -> i64) -> (Option<Snapshot>, Vec<Problem>)` (waits up to `timeout` for a watcher event on a `.json` or `.beat` path, then re-reads; returns the snapshot only when it differs from the last one returned); `unix_now() -> i64`.

- [ ] **Step 1: Add notify and the modules**

In `src-tauri/fleet/Cargo.toml`, after:

```toml
serde_json = "1"
```

insert:

```toml
notify = "8.2"
```

In `src-tauri/fleet/src/lib.rs`, before:

```rust
pub mod session;
```

insert:

```rust
pub mod scan;
```

In `src-tauri/fleet/src/lib.rs`, after:

```rust
pub mod view;
```

insert:

```rust
pub mod watch;
```

- [ ] **Step 2: Write the failing tests**

The watcher test writes a temp file and renames it over a session file, as the hook does, and requires the reader to wake well inside the 5 s poll. A file with an unknown `v` must be reported once across reads, not on every poll.

Create `src-tauri/fleet/src/scan.rs`:

```rust
#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    pub const A: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
    pub const B: &str = "0f8e2c1d-9a3b-4c5d-8e7f-a1b2c3d4e5f6";

    /// A scratch directory removed on drop.
    pub struct Scratch(pub PathBuf);

    impl Scratch {
        pub fn new(name: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            let dir = std::env::temp_dir().join(format!("klepsydra-fleet-{name}-{nanos}"));
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }
        pub fn write(&self, name: &str, text: &str) {
            std::fs::write(self.0.join(name), text).unwrap();
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    pub fn session(id: &str, state: &str) -> String {
        format!(r#"{{"v":1,"session_id":"{id}","state":"{state}","state_at":100}}"#)
    }

    #[test]
    fn sessions_and_their_beats_are_read() {
        let dir = Scratch::new("read");
        dir.write(&format!("{A}.json"), &session(A, "working"));
        dir.write(&format!("{A}.beat"), "Plan the fleet\t179235300\n");
        dir.write(&format!("{B}.json"), &session(B, "done"));
        let l = scan(&dir.0);
        assert!(l.problems.is_empty());
        assert_eq!(l.entries.len(), 2);
        let a = l.entries.iter().find(|e| e.file.session_id == A).unwrap();
        assert_eq!(
            a.beat.as_ref().unwrap().1.as_deref(),
            Some("Plan the fleet")
        );
        assert!(a.modified > 1_700_000_000);
        let b = l.entries.iter().find(|e| e.file.session_id == B).unwrap();
        assert_eq!(b.beat, None);
    }

    #[test]
    fn files_that_are_not_sessions_are_passed_over_silently() {
        let dir = Scratch::new("strays");
        dir.write(&format!("{A}.json.4242.tmp"), "{half");
        dir.write("notes.json", "not a session");
        dir.write("klepsydra-fleet.lock", "");
        dir.write(&format!("{A}.beat.9.tmp"), "x");
        std::fs::create_dir(dir.0.join(format!("{B}.json"))).unwrap();
        let l = scan(&dir.0);
        assert!(l.entries.is_empty());
        assert!(l.problems.is_empty());
    }

    #[test]
    fn a_bad_file_is_skipped_and_the_rest_still_read() {
        let dir = Scratch::new("bad");
        dir.write(&format!("{A}.json"), r#"{"v":2,"session_id":"x"}"#);
        dir.write(&format!("{B}.json"), &session(B, "done"));
        let l = scan(&dir.0);
        assert_eq!(l.entries.len(), 1);
        assert_eq!(
            l.problems,
            vec![Problem {
                file: format!("{A}.json"),
                what: "unknown version 2".into()
            }]
        );
    }

    #[test]
    fn a_missing_directory_is_an_empty_fleet() {
        let l = scan(Path::new("/nonexistent/klepsydra/fleet"));
        assert!(l.entries.is_empty() && l.problems.is_empty());
    }

    #[test]
    fn each_problem_is_reported_once() {
        let p = Problem {
            file: "x.json".into(),
            what: "unknown version 2".into(),
        };
        let broken = vec![p.clone()];
        let mut r = Reporter::default();
        assert_eq!(r.fresh(&broken), broken);
        assert_eq!(r.fresh(&broken), vec![]);
        assert_eq!(r.fresh(&broken), vec![]);
        assert_eq!(r.fresh(&[]), vec![]);
        assert_eq!(r.fresh(&broken), broken, "broken again after a fix");
    }
}
```

Create `src-tauri/fleet/src/watch.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::tests::{session, Scratch, A};
    use crate::view::Status;
    use std::time::Instant;

    fn reader(name: &str) -> (Scratch, Reader) {
        let root = Scratch::new(name);
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        let r = Reader::new(&root.0);
        (root, r)
    }

    #[test]
    fn the_first_read_reports_even_an_empty_fleet() {
        let (_root, mut r) = reader("first");
        let (snap, problems) = r.step(Duration::ZERO, unix_now);
        assert_eq!(snap, Some(Snapshot::default()));
        assert!(problems.is_empty());
    }

    #[test]
    fn a_new_session_arrives_well_before_the_poll() {
        let (root, mut r) = reader("arrive");
        r.step(Duration::ZERO, unix_now);
        let fleet = root.0.join("fleet");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            let tmp = fleet.join(format!("{A}.json.77.tmp"));
            std::fs::write(&tmp, session(A, "working")).unwrap();
            std::fs::rename(&tmp, fleet.join(format!("{A}.json"))).unwrap();
        });
        let started = Instant::now();
        let (snap, _) = r.step(POLL, unix_now);
        writer.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "woke by the watcher, not the poll"
        );
        assert_eq!(snap.unwrap().sessions.len(), 1);
    }

    #[test]
    fn nothing_changed_returns_nothing() {
        let (root, mut r) = reader("same");
        root.write(&format!("fleet/{A}.json"), &session(A, "done"));
        assert!(r.step(Duration::ZERO, unix_now).0.is_some());
        root.write(&format!("fleet/{A}.json.5.tmp"), "{half");
        assert_eq!(r.step(Duration::from_millis(300), unix_now).0, None);
    }

    #[test]
    fn time_alone_can_change_the_snapshot() {
        let (root, mut r) = reader("time");
        root.write(&format!("fleet/{A}.json"), &session(A, "working"));
        let t = unix_now();
        let first = r.step(Duration::ZERO, || t).0.unwrap();
        assert_eq!(first.sessions[0].status, Status::Working);
        let later = r.step(Duration::ZERO, || t + 120).0.unwrap();
        assert_eq!(later.sessions[0].status, Status::Silent);
    }

    #[test]
    fn a_fleet_dir_made_later_is_picked_up() {
        let root = Scratch::new("later");
        let mut r = Reader::new(&root.0);
        assert_eq!(
            r.step(Duration::ZERO, unix_now).0,
            Some(Snapshot::default())
        );
        std::fs::create_dir_all(root.0.join("fleet")).unwrap();
        root.write(&format!("fleet/{A}.json"), &session(A, "new"));
        assert_eq!(
            r.step(Duration::ZERO, unix_now).0.unwrap().sessions.len(),
            1
        );
    }

    #[test]
    fn a_bad_file_is_reported_once_across_reads() {
        let (root, mut r) = reader("once");
        root.write(&format!("fleet/{A}.json"), r#"{"v":3}"#);
        assert_eq!(r.step(Duration::ZERO, unix_now).1.len(), 1);
        assert_eq!(r.step(Duration::ZERO, unix_now).1.len(), 0);
    }
}
```

- [ ] **Step 3: Run them**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet
```

Expected: FAIL to compile: `error[E0425]: cannot find function `scan` in this scope`, `cannot find value `unix_now``, `cannot find type `Duration``, and more like them.

- [ ] **Step 4: Write the scan and the reader**

In `src-tauri/fleet/src/scan.rs`, before:

```rust
#[cfg(test)]
pub(crate) mod tests {
```

insert:

```rust
//! Reading a fleet directory: every session file and heartbeat in it, and the
//! files that had to be skipped.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::UNIX_EPOCH;

use crate::session::{beat_name, is_session_id, parse};
use crate::view::Entry;

/// A file skipped, and why.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Problem {
    pub file: String,
    pub what: String,
}

#[derive(Debug, Default)]
pub struct Listing {
    pub entries: Vec<Entry>,
    pub problems: Vec<Problem>,
}

fn modified(meta: &std::fs::Metadata) -> Option<i64> {
    let t = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    i64::try_from(t.as_secs()).ok()
}

/// Every `<uuid>.json` in `fleet` with its `<uuid>.beat`. Anything else there
/// (temp files mid-write, the hook's lock, stray files) is not a session and is
/// passed over without a word. A missing directory is an empty fleet.
pub fn scan(fleet: &Path) -> Listing {
    let mut out = Listing::default();
    let Ok(dir) = std::fs::read_dir(fleet) else {
        return out;
    };
    let mut files = Vec::new();
    let mut beats: HashMap<String, (i64, Option<String>)> = HashMap::new();
    for item in dir.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        let Some((stem, ext)) = name.rsplit_once('.') else {
            continue;
        };
        if !is_session_id(stem) || !matches!(ext, "json" | "beat") {
            continue;
        }
        let Ok(meta) = item.metadata() else { continue };
        let Some(mtime) = modified(&meta).filter(|_| meta.is_file()) else {
            continue;
        };
        if ext == "beat" {
            let text = std::fs::read_to_string(item.path()).unwrap_or_default();
            beats.insert(stem.to_string(), (mtime, beat_name(&text)));
        } else {
            files.push((stem.to_string(), name, mtime, item.path()));
        }
    }
    for (stem, name, mtime, path) in files {
        let parsed = std::fs::read_to_string(&path)
            .map_err(|e| format!("unreadable: {e}"))
            .and_then(|text| parse(&text, &stem).map_err(|e| e.to_string()));
        match parsed {
            Ok(file) => out.entries.push(Entry {
                file,
                modified: mtime,
                beat: beats.remove(&stem),
            }),
            Err(what) => out.problems.push(Problem { file: name, what }),
        }
    }
    out.entries
        .sort_by(|a, b| a.file.session_id.cmp(&b.file.session_id));
    out
}

/// Reports each skipped file once, not on every re-read; a file that recovers
/// and breaks again is reported again.
#[derive(Debug, Default)]
pub struct Reporter {
    seen: HashSet<Problem>,
}

impl Reporter {
    pub fn fresh(&mut self, problems: &[Problem]) -> Vec<Problem> {
        let now: HashSet<Problem> = problems.iter().cloned().collect();
        let mut new: Vec<Problem> = now.difference(&self.seen).cloned().collect();
        new.sort_by(|a, b| a.file.cmp(&b.file));
        self.seen = now;
        new
    }
}

```

In `src-tauri/fleet/src/watch.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
//! Following a fleet directory: a filesystem watcher for prompt updates, and a
//! re-read every `POLL` as a safety net and to let ages pass into silence.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::scan::{scan, Problem, Reporter};
use crate::view::{snapshot, Snapshot};

/// The safety-net re-read, matching the gauge's POLL_MS.
pub const POLL: Duration = Duration::from_secs(5);

/// Whether a change to `path` can change the fleet. Temp files are written
/// then renamed over a session file, and the rename is what counts.
fn counts(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("json" | "beat")
    )
}

pub struct Reader {
    fleet: PathBuf,
    tx: Sender<()>,
    rx: Receiver<()>,
    watcher: Option<RecommendedWatcher>,
    reporter: Reporter,
    last: Option<Snapshot>,
}

impl Reader {
    /// A reader for `<klepsydra_dir>/fleet`, which may not exist yet.
    pub fn new(klepsydra_dir: &Path) -> Self {
        let (tx, rx) = channel();
        Reader {
            fleet: klepsydra_dir.join("fleet"),
            tx,
            rx,
            watcher: None,
            reporter: Reporter::default(),
            last: None,
        }
    }

    /// Watch the directory once it exists; drop the watch if it goes away, so
    /// a recreated directory is watched afresh.
    fn attach(&mut self) {
        if !self.fleet.is_dir() {
            self.watcher = None;
            return;
        }
        if self.watcher.is_some() {
            return;
        }
        let tx = self.tx.clone();
        let made = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok_and(|e| e.paths.iter().any(|p| counts(p))) {
                let _ = tx.send(());
            }
        });
        self.watcher = made.ok().and_then(|mut w| {
            w.watch(&self.fleet, RecursiveMode::NonRecursive).ok()?;
            Some(w)
        });
    }

    /// Wait up to `timeout` for a change, then re-read. Returns the snapshot
    /// when it differs from the last one returned, and the problems not
    /// reported before.
    pub fn step(
        &mut self,
        timeout: Duration,
        now: impl Fn() -> i64,
    ) -> (Option<Snapshot>, Vec<Problem>) {
        self.attach();
        if let Err(RecvTimeoutError::Disconnected) = self.rx.recv_timeout(timeout) {
            self.watcher = None;
        }
        while self.rx.try_recv().is_ok() {}
        let listing = scan(&self.fleet);
        let problems = self.reporter.fresh(&listing.problems);
        let snap = snapshot(&listing.entries, now());
        if self.last.as_ref() == Some(&snap) {
            return (None, problems);
        }
        self.last = Some(snap.clone());
        (Some(snap), problems)
    }
}

/// Seconds since the epoch by this machine's clock.
pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

```

- [ ] **Step 5: Run the tests, rustfmt and clippy**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings
```

Expected: PASS: 31 tests; the watcher test returns in well under 3 s; rustfmt and clippy print nothing.

- [ ] **Step 6: Commit**

```bash
git add src-tauri/fleet/src/scan.rs src-tauri/fleet/src/watch.rs && git commit -m "feat(fleet): read the fleet directory and follow it with a watcher and a 5 s re-read" -- src-tauri/Cargo.lock src-tauri/fleet
```

### Task 10: The fleet hub and the reader thread

**Files:**

- Modify: `src-tauri/fleet/src/lib.rs` (line 4)
- Create: `src-tauri/fleet/src/hub.rs`
- Create: `src-tauri/src/fleet.rs`
- Modify: `src-tauri/src/main.rs` (lines 3, 755, 766-767, 859)

**Interfaces:**

- **Consumes:** `watch::{Reader, POLL, unix_now}` (Task 9); `klepsydra_dir(app)` in `main.rs` (the same data dir as the gauge's readings).
- **Produces:**
  - `klepsydra_fleet::hub`: `trait Sink: Send { fn send(&self, message: serde_json::Value) -> bool; }`; `struct Hub<S>` with `Default`, `publish(&self, snapshot: Value)`, `subscribe(&self, label: &str, sink: S)` (sends the latest snapshot, then a card waiting for that window; replaces the window's old sink), `focus(&self, label: &str, id: &str)` (sends `{"focus": id}` now if that window follows, else when it subscribes).
  - `src-tauri/src/fleet.rs`: `struct Webview(Channel<Value>)` implementing `Sink`; `type Fleet = Hub<Webview>` (managed state); command `fleet_subscribe(window: WebviewWindow, fleet: State<Fleet>, on_message: Channel<Value>)`; `start(app: &AppHandle, dir: Option<PathBuf>)` (a thread looping `Reader::step`, logging each problem once with `eprintln!` and publishing each new snapshot).
  - From JS: `const channel = new window.__TAURI__.core.Channel(); channel.onmessage = fn; window.__TAURI__.core.invoke("fleet_subscribe", { onMessage: channel })`. Messages are `{"sessions": [...]}` (Task 8's shape) or `{"focus": "<session_id>"}`. Channels need no capability file: Tauri exempts `plugin:__TAURI_CHANNEL__|fetch` from the ACL, and the app's own commands are open to local webviews while it has no ACL manifest (tauri 2.12.1 `webview/mod.rs`).

- [ ] **Step 1: Write the failing hub tests**

In `src-tauri/fleet/src/lib.rs`, before:

```rust
pub mod scan;
```

insert:

```rust
pub mod hub;
```

Create `src-tauri/fleet/src/hub.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A sink that records what it got, and can be closed.
    #[derive(Clone, Default)]
    struct Probe {
        got: Arc<Mutex<Vec<Value>>>,
        closed: Arc<Mutex<bool>>,
    }

    impl Sink for Probe {
        fn send(&self, message: Value) -> bool {
            if *self.closed.lock().unwrap() {
                return false;
            }
            self.got.lock().unwrap().push(message);
            true
        }
    }

    impl Probe {
        fn got(&self) -> Vec<Value> {
            self.got.lock().unwrap().clone()
        }
    }

    fn snap(n: u64) -> Value {
        json!({ "sessions": [], "n": n })
    }

    #[test]
    fn every_window_gets_each_snapshot() {
        let hub: Hub<Probe> = Hub::default();
        let (main, wall) = (Probe::default(), Probe::default());
        hub.subscribe("main", main.clone());
        hub.subscribe("wall", wall.clone());
        hub.publish(snap(1));
        assert_eq!(main.got(), vec![snap(1)]);
        assert_eq!(wall.got(), vec![snap(1)]);
    }

    #[test]
    fn a_late_window_starts_with_the_latest_snapshot() {
        let hub: Hub<Probe> = Hub::default();
        hub.publish(snap(1));
        hub.publish(snap(2));
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        assert_eq!(wall.got(), vec![snap(2)]);
    }

    #[test]
    fn a_reload_replaces_the_window_sink() {
        let hub: Hub<Probe> = Hub::default();
        let (old, new) = (Probe::default(), Probe::default());
        hub.subscribe("main", old.clone());
        hub.subscribe("main", new.clone());
        hub.publish(snap(1));
        assert!(old.got().is_empty());
        assert_eq!(new.got(), vec![snap(1)]);
    }

    #[test]
    fn a_closed_window_is_dropped() {
        let hub: Hub<Probe> = Hub::default();
        let gone = Probe::default();
        hub.subscribe("wall", gone.clone());
        *gone.closed.lock().unwrap() = true;
        hub.publish(snap(1));
        *gone.closed.lock().unwrap() = false;
        hub.publish(snap(2));
        assert!(gone.got().is_empty());
    }

    #[test]
    fn a_card_waits_for_the_wall_to_subscribe() {
        let hub: Hub<Probe> = Hub::default();
        hub.publish(snap(1));
        hub.focus("wall", "abc");
        let main = Probe::default();
        hub.subscribe("main", main.clone());
        assert_eq!(main.got(), vec![snap(1)], "the card is the wall's alone");
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        assert_eq!(wall.got(), vec![snap(1), json!({ "focus": "abc" })]);
    }

    #[test]
    fn a_card_goes_straight_to_a_following_wall() {
        let hub: Hub<Probe> = Hub::default();
        let wall = Probe::default();
        hub.subscribe("wall", wall.clone());
        hub.focus("wall", "abc");
        assert_eq!(wall.got(), vec![json!({ "focus": "abc" })]);
    }
}
```

- [ ] **Step 2: Run them**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet
```

Expected: FAIL to compile: `error[E0405]: cannot find trait `Sink` in this scope`, `cannot find type `Hub``, `cannot find type `Value``.

- [ ] **Step 3: Write the hub**

In `src-tauri/fleet/src/hub.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
//! Who follows the fleet: one sink per webview window, the latest snapshot for
//! a window that subscribes late, and the card the wall should show next.

use std::sync::Mutex;

use serde_json::{json, Value};

/// Somewhere a message can go; false once it is gone (a closed webview).
pub trait Sink: Send {
    fn send(&self, message: Value) -> bool;
}

pub struct Hub<S> {
    subs: Mutex<Vec<(String, S)>>,
    last: Mutex<Option<Value>>,
    /// A card waiting for its window to subscribe: (window label, session id).
    pending: Mutex<Option<(String, String)>>,
}

impl<S> Default for Hub<S> {
    fn default() -> Self {
        Hub {
            subs: Mutex::new(Vec::new()),
            last: Mutex::new(None),
            pending: Mutex::new(None),
        }
    }
}

impl<S: Sink> Hub<S> {
    /// Send a new snapshot to every window, dropping the ones that are gone.
    pub fn publish(&self, snapshot: Value) {
        if let Ok(mut last) = self.last.lock() {
            *last = Some(snapshot.clone());
        }
        if let Ok(mut subs) = self.subs.lock() {
            subs.retain(|(_, s)| s.send(snapshot.clone()));
        }
    }

    /// Window `label` follows the fleet from now on, starting with the latest
    /// snapshot and any card waiting to be shown there. A window that
    /// subscribes again (a reload) replaces its old sink.
    pub fn subscribe(&self, label: &str, sink: S) {
        if let Some(snapshot) = self.last.lock().ok().and_then(|l| l.clone()) {
            sink.send(snapshot);
        }
        let card = self.pending.lock().ok().and_then(|mut p| {
            p.take_if(|(for_label, _)| for_label == label)
                .map(|(_, id)| id)
        });
        if let Some(id) = card {
            sink.send(json!({ "focus": id }));
        }
        if let Ok(mut subs) = self.subs.lock() {
            subs.retain(|(l, _)| l != label);
            subs.push((label.to_string(), sink));
        }
    }

    /// Show session `id`'s card in window `label`: now if it is following,
    /// else as soon as it subscribes.
    pub fn focus(&self, label: &str, id: &str) {
        let sent = self.subs.lock().is_ok_and(|subs| {
            subs.iter()
                .find(|(l, _)| l == label)
                .is_some_and(|(_, s)| s.send(json!({ "focus": id })))
        });
        if !sent {
            if let Ok(mut p) = self.pending.lock() {
                *p = Some((label.to_string(), id.to_string()));
            }
        }
    }
}

```

- [ ] **Step 4: Run the tests, rustfmt and clippy**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings
```

Expected: PASS: 37 tests; rustfmt and clippy print nothing.

- [ ] **Step 5: Run the reader in the app**

Create `src-tauri/src/fleet.rs`:

```rust
//! The fleet strip's Tauri side: runs the reader on its own thread and hands
//! each new snapshot to every webview that subscribed.

use std::path::PathBuf;
use std::time::Duration;

use klepsydra_fleet::hub::{Hub, Sink};
use klepsydra_fleet::watch::{unix_now, Reader, POLL};
use serde_json::Value;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager};

/// A webview's end of the fleet.
pub struct Webview(Channel<Value>);

impl Sink for Webview {
    fn send(&self, message: Value) -> bool {
        self.0.send(message).is_ok()
    }
}

/// Who follows the fleet, managed as app state.
pub type Fleet = Hub<Webview>;

/// A webview asks for snapshots: the latest at once, then each new one.
#[tauri::command]
pub fn fleet_subscribe(
    window: tauri::WebviewWindow,
    fleet: tauri::State<'_, Fleet>,
    on_message: Channel<Value>,
) {
    fleet.subscribe(window.label(), Webview(on_message));
}

/// Follow `<dir>/fleet` for as long as the app runs. Each skipped file is
/// logged once, and the rest of the fleet still renders.
pub fn start(app: &AppHandle, dir: Option<PathBuf>) {
    let Some(dir) = dir else {
        return;
    };
    let app = app.clone();
    std::thread::spawn(move || {
        let mut reader = Reader::new(&dir);
        let mut wait = Duration::ZERO;
        loop {
            let (snapshot, problems) = reader.step(wait, unix_now);
            for p in problems {
                eprintln!("klepsydra: skipped fleet/{}: {}", p.file, p.what);
            }
            if let Some(v) = snapshot.and_then(|s| serde_json::to_value(s).ok()) {
                app.state::<Fleet>().publish(v);
            }
            wait = POLL;
        }
    });
}
```

In `src-tauri/src/main.rs`, before:

```rust
mod geometry;
```

insert:

```rust
mod fleet;
```

In `src-tauri/src/main.rs`, after:

```rust
        .manage(Grip::default())
```

insert:

```rust
        .manage(fleet::Fleet::default())
```

In `src-tauri/src/main.rs`, replace:

```rust
            set_tray_level
        ])
```

with:

```rust
            set_tray_level,
            fleet::fleet_subscribe
        ])
```

In `src-tauri/src/main.rs`, after:

```rust
            watch_grip(app.handle().clone());
```

insert:

```rust
            fleet::start(app.handle(), klepsydra_dir(app.handle()));
```

- [ ] **Step 6: Check the app crate on Windows**

The app crate needs WebKitGTK headers to compile on Linux, and WSL has none, so it is checked on the Windows staging copy (CI checks both). The local test run first also brings `Cargo.lock` up to date in WSL, since the Windows run only updates the staging copy.

Run:

```bash
(cd src-tauri && cargo test -p klepsydra-fleet) && bash scripts/build-windows.sh --check
```

Expected: PASS: the fleet tests in WSL; then on Windows, no clippy warning and `cargo test --workspace` passing the app's geometry tests and every fleet crate test.

- [ ] **Step 7: Commit**

```bash
git add src-tauri/fleet/src/hub.rs src-tauri/src/fleet.rs && git commit -m "feat(fleet): hand each fleet snapshot to the webviews that subscribe" -- src-tauri/fleet src-tauri/src/fleet.rs src-tauri/src/main.rs
```

### Task 11: Frontend model

**Files:**

- Create: `src/fleet-model.test.js`
- Create: `src/fleet/model.js`

**Interfaces:**

- **Consumes:** a snapshot's sessions (Task 8's JSON); `src/fleet/cast.json` (Task 7).
- **Produces** `src/fleet/model.js` (no DOM, no Tauri):
  - `STATUS: { [status]: { label, shape: "diamond"|"square"|"circle"|"ring", symbol, tone: "needs"|"error"|"working"|"done"|"quiet" } }`, `statusOf(status)`, `SHOW_UPDATED_AFTER_MS` (5 min).
  - `shortAge(ms) -> "<1m"|"2m"|"1h"|"3d"` (negative is `<1m`), `longAge(ms) -> "2 minutes"`.
  - `statusParts(s, nowMs, age = shortAge) -> string[]`, `statusLine(s, nowMs) -> "needs you \u00b7 approve Bash \u00b7 2m"` (silent: `silent \u00b7 no word for 4m`).
  - `voiceName(voice)`, `hash(text) -> uint32` (FNV-1a), `identity(s, cast) -> { name, voice, face, face2x }` (cast character, else Lorelei for a rendered voice, else fallback `NN` by hash of the voice or the session id; never reads `status`).
  - `accessibleName(s, cast, nowMs) -> "Hephaestus, needs you, approve Bash, 2 minutes"`.
  - `statuses(sessions) -> Map<id, status>`, `startedNeeding(before, sessions) -> Set<id>`, `announcements(before, sessions, cast) -> string[]` (both empty on the first look, when `before` is undefined).
  - `whereText(where)`, `updatedText(s, nowMs) -> "updated 7m ago"|null`, `badgeSvg(status) -> string` (SVG built only from the `STATUS` table).
  - `stripItems(sessions, cast, nowMs, before) -> [{ id, status, label, face, face2x, pulse }]`, `card(s, cast, nowMs) -> { id, name, voice, session, face, face2x, status, statusLine, where, touched, prompt, reply, error, updated, jump: { enabled, why }, label }`, `columnsAt(width, { min, gap, pad })`.

- [ ] **Step 1: Write the failing tests**

These hold the frontend guards from the rejected-ideas table: every status line carries its age, a stopped heartbeat reads silent never working, the portrait is the same in every state, one pulse and then a static badge. The ordering test checks the model keeps the reader's order, since ordering lives in one place, the reader.

Create `src/fleet-model.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  STATUS, shortAge, longAge, statusLine, voiceName, hash, identity, accessibleName,
  statuses, startedNeeding, announcements, whereText, updatedText, badgeSvg, stripItems, card,
} from "./fleet/model.js";

const NOW = 1_792_353_000_000; // fixed clock, ms
const ago = (s) => NOW / 1000 - s;
const CAST = {
  characters: { am_michael: { name: "Hephaestus", face: "hephaestus" } },
  lorelei: ["am_fenrir", "am_michael"],
  fallbacks: 24,
};
const session = (over = {}) => ({
  session_id: "cb9fa591-1514-44d1-a31c-eba4a7cb41ed",
  name: "Plan the fleet visualizer",
  launch_dir: "/home/aj/ajsoftworks",
  voice: "am_michael",
  status: "needs_you",
  reason: "approve Bash",
  status_at: ago(120),
  where: { repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer", at: ago(130) },
  touched: [{ repo: "ideas", at: ago(7200) }],
  prompt: { text: "i just want to be able to VIZ them", at: ago(200) },
  reply: { text: "That works with no model calls", at: ago(210) },
  error: null,
  updated_at: ago(120),
  ...over,
});

test("ages read at a glance, and a clock ahead reads as now", () => {
  assert.equal(shortAge(30_000), "<1m");
  assert.equal(shortAge(2 * 60_000), "2m");
  assert.equal(shortAge(60 * 60_000), "1h");
  assert.equal(shortAge(3 * 86_400_000), "3d");
  assert.equal(shortAge(-600_000), "<1m");
  assert.equal(longAge(2 * 60_000), "2 minutes");
  assert.equal(longAge(60 * 60_000), "1 hour");
  assert.equal(longAge(-5), "under a minute");
});

test("every status line carries its age", () => {
  for (const status of Object.keys(STATUS)) {
    const line = statusLine(session({ status, reason: null, status_at: ago(180) }), NOW);
    assert.match(line, /3m/, status);
  }
  assert.equal(statusLine(session(), NOW), "needs you \u00b7 approve Bash \u00b7 2m");
});

test("a session whose heartbeat stopped reads silent with how long, never working", () => {
  const s = session({ status: "silent", reason: null, status_at: ago(240) });
  assert.equal(statusLine(s, NOW), "silent \u00b7 no word for 4m");
  assert.doesNotMatch(statusLine(s, NOW), /working/);
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, silent, no word for 4 minutes");
});

test("a session with no prompt yet is not started", () => {
  assert.equal(statusLine(session({ status: "new", reason: null, status_at: ago(60) }), NOW), "not started \u00b7 1m");
});

test("badges carry shape, symbol and tone for every status", () => {
  const shapes = new Set();
  for (const [status, st] of Object.entries(STATUS)) {
    const svg = badgeSvg(status);
    assert.match(svg, new RegExp(`tone-${st.tone} shape-${st.shape}`), status);
    assert.match(svg, new RegExp(`>${st.symbol}</text>`), status);
    assert.match(svg, /aria-hidden="true"/);
    shapes.add(`${st.shape}${st.symbol}`);
  }
  assert.equal(shapes.size, Object.keys(STATUS).length, "no two statuses look alike");
  assert.match(badgeSvg("needs_you"), /<path class="shape"/, "needs you is the diamond");
});

test("accessible names say who, what and how long", () => {
  assert.equal(accessibleName(session(), CAST, NOW), "Hephaestus, needs you, approve Bash, 2 minutes");
});

test("identity: a cast voice is its character", () => {
  assert.deepEqual(identity(session(), CAST), {
    name: "Hephaestus",
    voice: "Michael",
    face: "fleet/faces/kourai/hephaestus-96.webp",
    face2x: "fleet/faces/kourai/hephaestus-192.webp",
  });
});

test("identity: another voice is its Lorelei face and capitalised name", () => {
  const who = identity(session({ voice: "am_fenrir" }), CAST);
  assert.deepEqual([who.name, who.face], ["Fenrir", "fleet/faces/lorelei/am_fenrir.svg"]);
});

test("identity: a blend or an unrendered voice falls back by a hash of the voice", () => {
  const blend = "af_bella(0.7)+af_heart(0.3)";
  const who = identity(session({ voice: blend }), CAST);
  assert.equal(who.name, "Bella and Heart");
  assert.equal(who.face, `fleet/faces/fallback/${String(hash(blend) % 24).padStart(2, "0")}.svg`);
  assert.equal(identity(session({ voice: blend, session_id: "x" }), CAST).face, who.face, "same voice, same face");
  assert.equal(voiceName("am_fenrir"), "Fenrir");
});

test("identity: no voice falls back by a hash of the session, named by the session", () => {
  const a = identity(session({ voice: null }), CAST);
  assert.equal(a.name, "Plan the fleet visualizer");
  assert.match(a.face, /^fleet\/faces\/fallback\/\d\d\.svg$/);
  assert.equal(identity(session({ voice: null, name: null }), CAST).name, "ajsoftworks");
  const faces = new Set(Array.from({ length: 500 }, (_, i) => identity(session({ voice: null, session_id: `s${i}` }), CAST).face));
  assert.equal(faces.size, 24, "every fallback face is reachable");
});

test("the portrait never changes with state", () => {
  for (const voice of ["am_michael", "am_fenrir", "af_bella(0.5)+af_heart(0.5)", null]) {
    const faces = new Set(Object.keys(STATUS).map((status) => identity(session({ voice, status }), CAST).face));
    assert.equal(faces.size, 1, String(voice));
  }
});

test("one pulse when a session starts needing AJ, none on the first look", () => {
  const working = [session({ status: "working" })];
  const needing = [session()];
  assert.equal(stripItems(needing, CAST, NOW, undefined)[0].pulse, false);
  assert.equal(stripItems(needing, CAST, NOW, statuses(working))[0].pulse, true);
  assert.equal(stripItems(needing, CAST, NOW, statuses(needing))[0].pulse, false, "then static");
  assert.deepEqual([...startedNeeding(statuses([]), needing)], [needing[0].session_id], "a new session that needs AJ");
});

test("the strip keeps the reader's order", () => {
  const list = ["c", "a", "b"].map((id) => session({ session_id: id, voice: null, name: id }));
  assert.deepEqual(stripItems(list, CAST, NOW).map((i) => i.id), ["c", "a", "b"]);
});

test("the wall announces changes, not the first look", () => {
  const before = statuses([session({ status: "working" })]);
  assert.deepEqual(announcements(undefined, [session()], CAST), []);
  assert.deepEqual(announcements(before, [session()], CAST), ["Hephaestus, needs you, approve Bash"]);
  assert.deepEqual(announcements(statuses([session()]), [session()], CAST), []);
});

test("where, touched and updated", () => {
  assert.equal(whereText(session().where), "klepsydra \u00b7 fleet \u00b7 feat/fleet-visualizer");
  assert.equal(whereText({ repo: "notes", worktree: null, branch: null, at: 1 }), "notes");
  assert.equal(whereText(null), "");
  assert.equal(updatedText(session({ updated_at: ago(299) }), NOW), null);
  assert.equal(updatedText(session({ updated_at: ago(420) }), NOW), "updated 7m ago");
});

test("a card holds what the wall shows", () => {
  const c = card(session(), CAST, NOW);
  assert.equal(c.name, "Hephaestus");
  assert.equal(c.voice, "Michael");
  assert.equal(c.session, "Plan the fleet visualizer");
  assert.equal(c.statusLine, "needs you \u00b7 approve Bash \u00b7 2m");
  assert.deepEqual(c.touched, ["ideas \u00b7 2h"]);
  assert.equal(c.prompt, "i just want to be able to VIZ them");
  assert.equal(c.reply, "That works with no model calls");
  assert.deepEqual(c.jump, { enabled: true, why: null });
  assert.deepEqual(card(session({ name: null }), CAST, NOW).jump, { enabled: false, why: "no session name yet" });
  assert.deepEqual(card(session({ status: "ended" }), CAST, NOW).jump, { enabled: false, why: "session ended" });
  assert.equal(card(session({ status: "error", error: "API Error: Rate limit reached" }), CAST, NOW).error,
    "API Error: Rate limit reached");
  assert.equal(card(session({ error: "old" }), CAST, NOW).error, null, "only an error shows its error");
});

test("the model reads the cast the app ships", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
  assert.equal(identity(session(), cast).name, "Hephaestus");
});
```

- [ ] **Step 2: Run them**

Run:

```bash
node --test src/fleet-model.test.js
```

Expected: FAIL: `ERR_MODULE_NOT_FOUND`, cannot find module `src/fleet/model.js`.

- [ ] **Step 3: Write the model**

Create `src/fleet/model.js`:

```js
// What the fleet strip and wall show for each session, kept free of the DOM
// so it can be unit tested. Sessions arrive from the reader already ordered.

// Each status's badge: shape, symbol and tone carry it together with the
// label, so no one of them is needed alone.
export const STATUS = {
  needs_you: { label: "needs you", shape: "diamond", symbol: "!", tone: "needs" },
  error: { label: "error", shape: "square", symbol: "\u00d7", tone: "error" },
  working: { label: "working", shape: "circle", symbol: "\u2026", tone: "working" },
  done: { label: "done", shape: "circle", symbol: "\u2713", tone: "done" },
  new: { label: "not started", shape: "ring", symbol: "\u25cb", tone: "quiet" },
  silent: { label: "silent", shape: "ring", symbol: "?", tone: "quiet" },
  ended: { label: "ended", shape: "ring", symbol: "\u2013", tone: "quiet" },
};
const UNKNOWN = { label: "unknown", shape: "ring", symbol: "?", tone: "quiet" };
export const statusOf = (status) => STATUS[status] ?? UNKNOWN;

// A card says when it last changed once that is older than this.
export const SHOW_UPDATED_AFTER_MS = 5 * 60 * 1000;

const FACES = "fleet/faces";
const ageMs = (atSec, nowMs) => nowMs - Number(atSec) * 1000;

/** "2m", "1h", "3d"; "<1m" under a minute. A time ahead of the clock is now. */
export function shortAge(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  if (mins < 1) return "<1m";
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  if (h < 24) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

/** The same age in words, for accessible names: "2 minutes". */
export function longAge(ms) {
  const mins = Math.floor(Math.max(0, ms) / 60000);
  const unit = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
  if (mins < 1) return "under a minute";
  if (mins < 60) return unit(mins, "minute");
  const h = Math.floor(mins / 60);
  if (h < 24) return unit(h, "hour");
  return unit(Math.floor(h / 24), "day");
}

/** Label, reason and age. A silent session says how long since any word. */
export function statusParts(s, nowMs, age = shortAge) {
  const a = age(ageMs(s.status_at, nowMs));
  if (s.status === "silent") return [statusOf(s.status).label, `no word for ${a}`];
  return [statusOf(s.status).label, s.reason, a].filter(Boolean);
}

/** "needs you \u00b7 approve Bash \u00b7 2m" */
export const statusLine = (s, nowMs) => statusParts(s, nowMs).join(" \u00b7 ");

/** "am_fenrir" is "Fenrir"; a blend "af_bella(0.7)+af_heart(0.3)" is "Bella and Heart". */
export function voiceName(voice) {
  return String(voice)
    .split("+")
    .map((part) => {
      const label = part.replace(/\(.*$/, "").trim();
      const name = label.includes("_") ? label.slice(label.indexOf("_") + 1) : label;
      return name.charAt(0).toUpperCase() + name.slice(1);
    })
    .join(" and ");
}

/** FNV-1a over UTF-16 code units: a stable hash for picking a fallback face. */
export function hash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

const basename = (path) => (typeof path === "string" ? path.replace(/\/+$/, "").split("/").pop() : "");

/**
 * Who a session is, from its identity alone, never its state: the kourai
 * character cast for its keryx voice; else a Lorelei face for the voice; else
 * a fallback face picked by a hash of the voice (a blend) or of the session.
 */
export function identity(s, cast) {
  const voice = typeof s.voice === "string" && s.voice ? s.voice : null;
  const character = voice ? cast.characters[voice] : null;
  if (character) {
    const base = `${FACES}/kourai/${character.face}`;
    return { name: character.name, voice: voiceName(voice), face: `${base}-96.webp`, face2x: `${base}-192.webp` };
  }
  if (voice && cast.lorelei.includes(voice)) {
    const face = `${FACES}/lorelei/${voice}.svg`;
    return { name: voiceName(voice), voice: null, face, face2x: face };
  }
  const n = hash(voice ?? s.session_id) % cast.fallbacks;
  const face = `${FACES}/fallback/${String(n).padStart(2, "0")}.svg`;
  const name = voice ? voiceName(voice) : s.name || basename(s.launch_dir) || s.session_id.slice(0, 8);
  return { name, voice: null, face, face2x: face };
}

/** "Hephaestus, needs you, approve Bash, 2 minutes" */
export const accessibleName = (s, cast, nowMs) =>
  [identity(s, cast).name, ...statusParts(s, nowMs, longAge)].join(", ");

/** Each session's status by id, to compare the next snapshot against. */
export const statuses = (sessions) => new Map(sessions.map((s) => [s.session_id, s.status]));

/** Sessions that started needing AJ since `before`; none on the first look. */
export function startedNeeding(before, sessions) {
  if (!before) return new Set();
  return new Set(
    sessions
      .filter((s) => s.status === "needs_you" && before.get(s.session_id) !== "needs_you")
      .map((s) => s.session_id),
  );
}

/** What the wall's live region says about changes since `before`; nothing on the first look. */
export function announcements(before, sessions, cast) {
  if (!before) return [];
  return sessions
    .filter((s) => before.get(s.session_id) !== s.status)
    .map((s) => [identity(s, cast).name, statusOf(s.status).label, s.status === "silent" ? null : s.reason]
      .filter(Boolean)
      .join(", "));
}

/** "klepsydra \u00b7 fleet \u00b7 feat/fleet-visualizer" */
export const whereText = (w) => (w ? [w.repo, w.worktree, w.branch].filter(Boolean).join(" \u00b7 ") : "");

/** "updated 7m ago" once the newest field is over five minutes old. */
export function updatedText(s, nowMs) {
  const age = ageMs(s.updated_at, nowMs);
  return age > SHOW_UPDATED_AFTER_MS ? `updated ${shortAge(age)} ago` : null;
}

const SHAPES = {
  diamond: '<path class="shape" d="M8 1.2 14.8 8 8 14.8 1.2 8Z"/>',
  square: '<rect class="shape" x="2" y="2" width="12" height="12" rx="1.5"/>',
  circle: '<circle class="shape" cx="8" cy="8" r="6.6"/>',
  ring: '<circle class="shape" cx="8" cy="8" r="6"/>',
};

/** The badge for a status, as SVG markup; its words are in the owner's accessible name. */
export function badgeSvg(status) {
  const st = statusOf(status);
  return `<svg class="badge tone-${st.tone} shape-${st.shape}" viewBox="0 0 16 16" aria-hidden="true">`
    + `${SHAPES[st.shape]}<text class="ink" x="8" y="8.5" font-size="10">${st.symbol}</text></svg>`;
}

/** The strip's portraits, in the reader's order. `before` comes from `statuses` of the last render. */
export function stripItems(sessions, cast, nowMs, before) {
  const pulse = startedNeeding(before, sessions);
  return sessions.map((s) => {
    const who = identity(s, cast);
    return {
      id: s.session_id,
      status: s.status,
      label: accessibleName(s, cast, nowMs),
      face: who.face,
      face2x: who.face2x,
      pulse: pulse.has(s.session_id),
    };
  });
}

/** Whether the card can jump to the session's terminal, and why not. */
function jumpable(s) {
  if (s.status === "ended") return { enabled: false, why: "session ended" };
  if (!s.name) return { enabled: false, why: "no session name yet" };
  return { enabled: true, why: null };
}

/** One card on the wall. */
export function card(s, cast, nowMs) {
  const who = identity(s, cast);
  return {
    id: s.session_id,
    name: who.name,
    voice: who.voice,
    session: s.name ?? null,
    face: who.face,
    face2x: who.face2x,
    status: s.status,
    statusLine: statusLine(s, nowMs),
    where: whereText(s.where),
    touched: (s.touched ?? []).map((t) => `${t.repo} \u00b7 ${shortAge(ageMs(t.at, nowMs))}`),
    prompt: s.prompt?.text ?? null,
    reply: s.reply?.text ?? null,
    error: s.status === "error" ? s.error ?? null : null,
    updated: updatedText(s, nowMs),
    jump: jumpable(s),
    label: accessibleName(s, cast, nowMs),
  };
}

/** Columns that `repeat(auto-fill, minmax(min, 1fr))` makes in a viewport `width` wide. */
export function columnsAt(width, { min, gap, pad }) {
  return Math.max(1, Math.floor((width - 2 * pad + gap) / (min + gap)));
}
```

- [ ] **Step 4: Run every node test**

Run:

```bash
node --test src/*.test.js
```

Expected: PASS: 83 tests, the 17 model tests among them; the guards pass over the new file (no process, no `wsl`, no sound).

- [ ] **Step 5: Commit**

```bash
git add src/fleet/model.js src/fleet-model.test.js && git commit -m "feat(fleet): the strip's and wall's display logic, free of the DOM" -- src/fleet/model.js src/fleet-model.test.js
```

### Task 12: Jump to terminal

**Files:**

- Modify: `src-tauri/fleet/src/lib.rs` (line 6)
- Create: `src-tauri/fleet/src/tabs.rs`
- Modify: `src-tauri/Cargo.toml` (line 20)
- Create: `src-tauri/src/jump.rs`
- Modify: `src-tauri/src/main.rs` (lines 4, 769-770)
- Modify: `src-tauri/Cargo.lock` (by cargo)

**Interfaces:**

- **Consumes:** a session's `name` (the beat's, Task 6: Claude Code titles the terminal tab with the same value); Windows UI Automation through the `windows` 0.62 crate (`IUIAutomation`, `TreeScope_Children`/`TreeScope_Descendants`, `UIA_TabItemControlTypeId`, `IUIAutomationSelectionItemPattern::Select`, `SetForegroundWindow`, `FlashWindowEx`). Windows Terminal's window class is `CASCADIA_HOSTING_WINDOW_CLASS` (spike S1).
- **Produces:**
  - `klepsydra_fleet::tabs`: `enum TabMatch { None, One(usize), Many(usize) }`; `match_tab(name: &str, titles: &[String]) -> TabMatch` (titles containing the trimmed, case-sensitive name); `no_tab(name: &str) -> String`; `many_tabs(name: &str, n: usize) -> String`.
  - Command `jump_to_terminal(name: String) -> Result<String, String>` (async; UI Automation on a blocking thread with COM initialised MTA): selects the one matching tab and brings its window forward, else flashes its taskbar button; `Err` with `no_tab`/`many_tabs` text when there is not exactly one match; `Err("Jump to terminal works on Windows only.")` elsewhere. From JS: `invoke("jump_to_terminal", { name })`.

- [ ] **Step 1: Write the failing tests**

A name inside two titles, two sessions with one title, and the status glyph Claude Code puts before the title are Review Focus cases: Jump must refuse rather than guess.

In `src-tauri/fleet/src/lib.rs`, after:

```rust
pub mod session;
```

insert:

```rust
pub mod tabs;
```

Create `src-tauri/fleet/src/tabs.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn titles(t: &[&str]) -> Vec<String> {
        t.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_tab_titled_with_the_name_after_a_glyph() {
        let t = titles(&[
            "Klepsydra",
            "\u{2733} Plan the fleet visualizer",
            "FedAgents",
        ]);
        assert_eq!(match_tab("Plan the fleet visualizer", &t), TabMatch::One(1));
    }

    #[test]
    fn a_name_inside_two_titles_is_refused_not_guessed() {
        let t = titles(&["\u{2733} klepsydra", "\u{2733} klepsydra-e2"]);
        assert_eq!(match_tab("klepsydra", &t), TabMatch::Many(2));
        let t = titles(&["Fix tests", "Fix tests in CI"]);
        assert_eq!(match_tab("Fix tests", &t), TabMatch::Many(2));
    }

    #[test]
    fn two_sessions_with_one_title_are_refused() {
        let t = titles(&["\u{2733} Plan", "\u{2733} Plan"]);
        assert_eq!(match_tab("Plan", &t), TabMatch::Many(2));
    }

    #[test]
    fn no_tab_or_no_name_matches_nothing() {
        let t = titles(&["Klepsydra"]);
        assert_eq!(match_tab("FedAgents", &t), TabMatch::None);
        assert_eq!(
            match_tab("klepsydra", &t),
            TabMatch::None,
            "titles are matched as written"
        );
        assert_eq!(match_tab("  ", &t), TabMatch::None);
        assert_eq!(match_tab("x", &[]), TabMatch::None);
    }

    #[test]
    fn the_messages_name_the_session() {
        assert_eq!(
            no_tab("Plan"),
            "No Windows Terminal tab is titled \u{201c}Plan\u{201d}."
        );
        assert_eq!(
            many_tabs("Plan", 2),
            "2 Windows Terminal tabs contain \u{201c}Plan\u{201d}. Rename the session to jump to it."
        );
    }
}
```

- [ ] **Step 2: Run them**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet
```

Expected: FAIL to compile: `cannot find function `match_tab``, `cannot find type `TabMatch``.

- [ ] **Step 3: Write the match**

In `src-tauri/fleet/src/tabs.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
//! Which Windows Terminal tab is a session's. Claude Code titles the tab with
//! the session's name, after a status glyph, so a tab is the session's when
//! its title contains the name; anything but exactly one such tab is refused.

#[derive(Debug, PartialEq, Eq)]
pub enum TabMatch {
    None,
    One(usize),
    Many(usize),
}

/// The tab, among `titles`, whose title contains `name`.
pub fn match_tab(name: &str, titles: &[String]) -> TabMatch {
    let name = name.trim();
    if name.is_empty() {
        return TabMatch::None;
    }
    let hits: Vec<usize> = (0..titles.len())
        .filter(|&i| titles[i].contains(name))
        .collect();
    match hits.as_slice() {
        [] => TabMatch::None,
        [one] => TabMatch::One(*one),
        many => TabMatch::Many(many.len()),
    }
}

pub fn no_tab(name: &str) -> String {
    format!("No Windows Terminal tab is titled \u{201c}{name}\u{201d}.")
}

pub fn many_tabs(name: &str, n: usize) -> String {
    format!("{n} Windows Terminal tabs contain \u{201c}{name}\u{201d}. Rename the session to jump to it.")
}

```

- [ ] **Step 4: Run the tests, rustfmt and clippy**

Run:

```bash
cd src-tauri && cargo test -p klepsydra-fleet && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings
```

Expected: PASS: 42 tests; rustfmt and clippy print nothing.

- [ ] **Step 5: Write the UI Automation command**

In `src-tauri/Cargo.toml`, before:

```toml
[target.'cfg(target_os = "linux")'.dependencies]
```

insert:

```toml
[target.'cfg(windows)'.dependencies]
windows = { version = "0.62", features = [
  "Win32_Foundation",
  "Win32_System_Com",
  "Win32_System_Ole",
  "Win32_System_Variant",
  "Win32_UI_Accessibility",
  "Win32_UI_WindowsAndMessaging",
] }

```

Create `src-tauri/src/jump.rs`:

```rust
//! Jump to terminal: select the Windows Terminal tab titled with a session's
//! name and bring its window to the front, through UI Automation, an
//! in-process API. Which tab is decided by `klepsydra_fleet::tabs`, tested everywhere.

/// The outcome in a sentence for the card: Ok when the tab was selected,
/// Err when nothing was done.
#[tauri::command]
pub async fn jump_to_terminal(name: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || jump(&name))
        .await
        .map_err(|e| e.to_string())?
}

#[cfg(not(windows))]
fn jump(_name: &str) -> Result<String, String> {
    Err("Jump to terminal works on Windows only.".into())
}

#[cfg(windows)]
fn jump(name: &str) -> Result<String, String> {
    uia::jump(name)
}

#[cfg(windows)]
mod uia {
    use klepsydra_fleet::tabs::{many_tabs, match_tab, no_tab, TabMatch};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Variant::{VARIANT, VT_I4};
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationSelectionItemPattern,
        TreeScope_Children, TreeScope_Descendants, UIA_ControlTypePropertyId,
        UIA_SelectionItemPatternId, UIA_TabItemControlTypeId,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        FlashWindowEx, IsIconic, SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL,
        FLASHW_TIMERNOFG, SW_RESTORE,
    };

    /// Windows Terminal's top-level window class.
    const TERMINAL_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";

    /// Balances a CoInitializeEx that succeeded on this thread.
    struct Com;

    impl Drop for Com {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    struct Tab {
        window: IUIAutomationElement,
        item: IUIAutomationElement,
        title: String,
    }

    fn i4(value: i32) -> VARIANT {
        let mut v = VARIANT::default();
        unsafe {
            (*v.Anonymous.Anonymous).vt = VT_I4;
            (*v.Anonymous.Anonymous).Anonymous.lVal = value;
        }
        v
    }

    /// Every tab of every Windows Terminal window, with its title.
    fn tabs(uia: &IUIAutomation) -> windows::core::Result<Vec<Tab>> {
        let mut out = Vec::new();
        unsafe {
            let any = uia.CreateTrueCondition()?;
            let tab_item = uia.CreatePropertyCondition(
                UIA_ControlTypePropertyId,
                &i4(UIA_TabItemControlTypeId.0),
            )?;
            let windows = uia.GetRootElement()?.FindAll(TreeScope_Children, &any)?;
            for i in 0..windows.Length()? {
                let window = windows.GetElement(i)?;
                if window.CurrentClassName()? != TERMINAL_CLASS {
                    continue;
                }
                let items = window.FindAll(TreeScope_Descendants, &tab_item)?;
                for j in 0..items.Length()? {
                    let item = items.GetElement(j)?;
                    let title = item.CurrentName()?.to_string();
                    out.push(Tab {
                        window: window.clone(),
                        item,
                        title,
                    });
                }
            }
        }
        Ok(out)
    }

    pub fn jump(name: &str) -> Result<String, String> {
        let _com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .is_ok()
            .then_some(Com);
        let uia: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
                .map_err(|e| e.to_string())?;
        let tabs = tabs(&uia).map_err(|e| e.to_string())?;
        let titles: Vec<String> = tabs.iter().map(|t| t.title.clone()).collect();
        let tab = match match_tab(name, &titles) {
            TabMatch::None => return Err(no_tab(name)),
            TabMatch::Many(n) => return Err(many_tabs(name, n)),
            TabMatch::One(i) => &tabs[i],
        };
        unsafe {
            let select: IUIAutomationSelectionItemPattern = tab
                .item
                .GetCurrentPatternAs(UIA_SelectionItemPatternId)
                .map_err(|e| e.to_string())?;
            select.Select().map_err(|e| e.to_string())?;
            let hwnd = tab
                .window
                .CurrentNativeWindowHandle()
                .map_err(|e| e.to_string())?;
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
            if SetForegroundWindow(hwnd).as_bool() {
                return Ok(format!("Jumped to \u{201c}{}\u{201d}.", tab.title));
            }
            let flash = FLASHWINFO {
                cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                hwnd,
                dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                uCount: 0,
                dwTimeout: 0,
            };
            let _ = FlashWindowEx(&flash);
        }
        Ok("Windows kept the focus, so the terminal\u{2019}s taskbar button is flashing.".into())
    }
}
```

In `src-tauri/src/main.rs`, after:

```rust
mod geometry;
```

insert:

```rust
mod jump;
```

In `src-tauri/src/main.rs`, replace:

```rust
            fleet::fleet_subscribe
        ])
```

with:

```rust
            fleet::fleet_subscribe,
            jump::jump_to_terminal
        ])
```

- [ ] **Step 6: Check the app crate on Windows**

The app crate needs WebKitGTK headers to compile on Linux, and WSL has none, so it is checked on the Windows staging copy (CI checks both). The local test run first also brings `Cargo.lock` up to date in WSL, since the Windows run only updates the staging copy.

Run:

```bash
(cd src-tauri && cargo test -p klepsydra-fleet) && bash scripts/build-windows.sh --check
```

Expected: PASS: the fleet tests in WSL; then on Windows, no clippy warning and `cargo test --workspace` passing the app's geometry tests and every fleet crate test.

- [ ] **Step 7: Commit**

```bash
git add src-tauri/fleet/src/tabs.rs src-tauri/src/jump.rs && git commit -m "feat(fleet): jump to a session's Windows Terminal tab through UI Automation" -- src-tauri/fleet src-tauri/src/jump.rs src-tauri/src/main.rs src-tauri/Cargo.toml src-tauri/Cargo.lock
```

### Task 13: Card wall

**Files:**

- Create: `src/fleet-style.test.js`
- Create: `src/fleet/badge.css`
- Create: `src/fleet/wall.css`
- Create: `src/wall.html`
- Create: `src/fleet/face.js`
- Create: `src/fleet/wall.js`
- Modify: `src-tauri/src/fleet.rs` (lines 1-2, 11, 13; after line 56)
- Modify: `src-tauri/src/main.rs` (lines 770-771)

**Interfaces:**

- **Consumes:** `fleet_subscribe` and `Fleet` (Task 10), `jump_to_terminal` (Task 12), `model.js` (Task 11), `cast.json` and the faces (Task 7); the window-state plugin already registered in `main.rs` (position only, for every window).
- **Produces:**
  - `src/fleet/badge.css`: tokens `--badge-ring` (#141414, the panel colour), `--badge-needs` (#e69f00), `--badge-error` (#d55e00), `--badge-working` (#0072b2), `--badge-done` (#009e73), `--badge-quiet` (#9a9a9a), `--badge-ink-dark`, `--badge-ink-light`; rules `.tone-<tone> .shape|.ink`; `@keyframes badge-pulse` on `.pulse .badge` once, off under `prefers-reduced-motion`. No sizes: the holder sizes the badge.
  - `src/fleet/face.js`: `showFace(img: HTMLImageElement, face: string, face2x: string, cssPx: number)`.
  - `src/wall.html`, `src/fleet/wall.css` (tokens `--card-min: 560px`, `--card-gap: 16px`, `--wall-pad: 24px`, `--wall-face: 64px`), `src/fleet/wall.js` (subscribes, renders cards keyed by session id, shows `{"focus": id}`, announces changes in `#live`, calls `jump_to_terminal`).
  - Command `open_wall(app: AppHandle, focus: String) -> Result<(), String>` (async): queues the card with `Fleet::focus("wall", id)`, then shows the existing `wall` window, or builds it once (`WebviewUrl::App("wall.html")`, 1280x800, min 420x320, not always on top) and turns its close into a hide. `pub const WALL: &str = "wall"`. From JS: `invoke("open_wall", { focus: sessionId })`.

- [ ] **Step 1: Write the failing tests**

The contrast test reads the badge tokens and rules from `badge.css` itself, so a changed colour or ink is checked as written; each badge sits in a ring of the panel colour, and the quiet outline is also checked against the panel over a white desktop. The columns test reads the wall's tokens.

Create `src/fleet-style.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { columnsAt } from "./fleet/model.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const badgeCss = read("./fleet/badge.css");
const token = (css, name) => css.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim();

/** WCAG 2.2 relative luminance of "#rrggbb". */
function luminance(hex) {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** `rgba(r, g, b, a)` laid over an opaque "#rrggbb", as "#rrggbb". */
function over(rgba, hex) {
  const [r, g, b, a] = rgba.match(/[\d.]+/g).map(Number);
  const base = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return `#${[r, g, b].map((c, i) => Math.round(c * a + base[i] * (1 - a)).toString(16).padStart(2, "0")).join("")}`;
}

/** Each tone's shape fill and stroke and its ink, resolved through badge.css's tokens. */
function tones(css) {
  const value = (decl, prop) => decl.match(new RegExp(`${prop}:\\s*var\\((--[\\w-]+)\\)`))?.[1];
  const ring = token(css, "--badge-ring");
  const out = {};
  for (const [, tone, part, decl] of css.matchAll(/\.tone-(\w+) \.(shape|ink) \{([^}]*)\}/g)) {
    out[tone] ??= { fill: null, stroke: ring, ink: null };
    if (part === "shape") {
      out[tone].fill = token(css, value(decl, "fill"));
      if (value(decl, "stroke")) out[tone].stroke = token(css, value(decl, "stroke"));
    } else out[tone].ink = token(css, value(decl, "fill"));
  }
  return { ring, tones: out };
}

test("every badge meets 3:1 against the strip's backdrop, and its symbol against the badge", () => {
  const { ring, tones: all } = tones(badgeCss);
  assert.deepEqual(Object.keys(all).sort(), ["done", "error", "needs", "quiet", "working"]);
  // The ring is the panel's own colour: what every badge sits on.
  const panel = token(read("./style.css"), "--panel-bg");
  assert.equal(over(panel, ring), ring.toLowerCase(), "ring matches the panel over a dark desktop");
  const onWhite = over(panel, "#ffffff");
  for (const [tone, t] of Object.entries(all)) {
    const edge = tone === "quiet" ? t.stroke : t.fill;
    assert.ok(contrast(edge, ring) >= 3, `${tone} against the ring: ${contrast(edge, ring).toFixed(2)}`);
    if (tone === "quiet") {
      assert.ok(contrast(edge, onWhite) >= 3, `quiet outline over a light desktop: ${contrast(edge, onWhite).toFixed(2)}`);
    }
    assert.ok(contrast(t.ink, t.fill) >= 3, `${tone} symbol: ${contrast(t.ink, t.fill).toFixed(2)}`);
  }
});

test("the Okabe-Ito tones are the spec's", () => {
  assert.deepEqual(
    ["--badge-needs", "--badge-error", "--badge-working", "--badge-done"].map((t) => token(badgeCss, t)),
    ["#e69f00", "#d55e00", "#0072b2", "#009e73"],
  );
});

test("badges take their size from where they sit", () => {
  assert.doesNotMatch(badgeCss.replace(/\/\*[\s\S]*?\*\//g, ""), /\d+(\.\d+)?px/);
});

test("the wall fits three columns at 1920 px and reflows below", () => {
  const wallCss = read("./fleet/wall.css");
  const px = (name) => parseFloat(token(wallCss, name));
  const tokens = { min: px("--card-min"), gap: px("--card-gap"), pad: px("--wall-pad") };
  const SCROLLBAR = 17;
  assert.equal(columnsAt(1920 - SCROLLBAR, tokens), 3);
  assert.equal(columnsAt(1920, tokens), 3);
  assert.equal(columnsAt(1280 - SCROLLBAR, tokens), 2);
  assert.equal(columnsAt(800 - SCROLLBAR, tokens), 1);
});
```

- [ ] **Step 2: Run them**

Run:

```bash
node --test src/fleet-style.test.js
```

Expected: FAIL: the file cannot load, `ENOENT: no such file or directory, open '.../src/fleet/badge.css'`.

- [ ] **Step 3: Write the badge and wall styles**

Create `src/fleet/badge.css`:

```css
/* Fleet status badges, shared by the strip and the wall. Okabe-Ito tones, each
   inside a ring of the panel colour, so a badge keeps its contrast on any
   backdrop. Sizes come from the element that holds the badge. */
:root {
  --badge-ring: #141414;
  --badge-needs: #e69f00;
  --badge-error: #d55e00;
  --badge-working: #0072b2;
  --badge-done: #009e73;
  --badge-quiet: #9a9a9a;
  --badge-ink-dark: #000000;
  --badge-ink-light: #ffffff;
}

.badge { display: block; overflow: visible; }
.badge .shape { stroke: var(--badge-ring); stroke-width: 1.6; }
.badge .ink {
  font-family: ui-sans-serif, "Segoe UI", system-ui, sans-serif;
  font-weight: 700;
  text-anchor: middle;
  dominant-baseline: central;
}

.tone-needs .shape { fill: var(--badge-needs); }
.tone-needs .ink { fill: var(--badge-ink-dark); }
.tone-error .shape { fill: var(--badge-error); }
.tone-error .ink { fill: var(--badge-ink-dark); }
.tone-working .shape { fill: var(--badge-working); }
.tone-working .ink { fill: var(--badge-ink-light); }
.tone-done .shape { fill: var(--badge-done); }
.tone-done .ink { fill: var(--badge-ink-dark); }
.tone-quiet .shape { fill: var(--badge-ring); stroke: var(--badge-quiet); }
.tone-quiet .ink { fill: var(--badge-quiet); }

/* One pulse when a session starts needing AJ, then the badge holds still. */
@keyframes badge-pulse {
  0% { transform: scale(1); }
  40% { transform: scale(1.45); }
  100% { transform: scale(1); }
}
.pulse .badge { animation: badge-pulse 900ms ease-out 1; transform-origin: center; }
@media (prefers-reduced-motion: reduce) {
  .pulse .badge { animation: none; }
}
```

Create `src/fleet/wall.css`:

```css
/* The card wall: a normal, resizable window, so plain pixels rather than the
   gauge's zoom. Three columns at 1920 px wide; fewer below that. */
:root {
  --card-min: 560px;
  --card-gap: 16px;
  --wall-pad: 24px;
  --wall-face: 64px;
  --wall-bg: #141414;
  --card-bg: #1f1f1f;
  --card-focus: #e69f00;
  --text: #ededed;
  --text-dim: #9a9a9a;
  --font: ui-sans-serif, "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

html, body { background: var(--wall-bg); color: var(--text); font: 14px/1.4 var(--font); }

#wall {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(var(--card-min), 1fr));
  gap: var(--card-gap);
  padding: var(--wall-pad);
}

#empty { padding: var(--wall-pad); color: var(--text-dim); }
#empty[hidden] { display: none; }

.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
  white-space: nowrap;
}

.card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 16px;
  border-radius: 10px;
  background: var(--card-bg);
  outline: 2px solid transparent;
}
.card:focus { outline-color: var(--card-focus); }

.card header { display: flex; align-items: center; gap: 12px; }
.portrait { position: relative; flex: 0 0 auto; width: var(--wall-face); height: var(--wall-face); }
.portrait img { display: block; width: 100%; height: 100%; border-radius: 50%; }
.portrait .badge { position: absolute; right: -4px; bottom: -4px; width: 22px; height: 22px; }
.who { min-width: 0; }
.name { font-size: 18px; font-weight: 600; }
.small, .updated, .note { font-size: 12px; color: var(--text-dim); }

.where { font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.touched { display: flex; flex-wrap: wrap; gap: 6px; list-style: none; }
.touched:empty { display: none; }
.touched li { padding: 2px 8px; border-radius: 999px; background: #2a2a2a; font-size: 12px; color: var(--text-dim); }

.status { display: flex; align-items: center; gap: 8px; font-weight: 600; }
.status .badge { width: 18px; height: 18px; }
.error { color: var(--badge-error); overflow-wrap: anywhere; }
.error[hidden], .updated[hidden] { display: none; }

.said { display: flex; gap: 8px; color: var(--text-dim); }
.said .sign { flex: 0 0 auto; font-family: ui-monospace, "Cascadia Mono", monospace; }
.said .text {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  overflow-wrap: anywhere;
}
.said:has(.text:empty) { display: none; }

.actions { display: flex; align-items: center; gap: 12px; margin-top: 4px; }
.jump {
  padding: 6px 12px;
  border: 1px solid #3a3a3a;
  border-radius: 6px;
  background: #2a2a2a;
  color: var(--text);
  font: inherit;
  cursor: pointer;
}
.jump:hover:not(:disabled) { background: #333; }
.jump:focus-visible { outline: 2px solid var(--card-focus); outline-offset: 2px; }
.jump:disabled { color: var(--text-dim); cursor: default; }
```

- [ ] **Step 4: Run them again**

Run:

```bash
node --test src/fleet-style.test.js
```

Expected: PASS: 4 tests (the lowest margin is blue against the ring, 3.5:1; its white symbol is 5.2:1).

- [ ] **Step 5: Write the wall page**

Create `src/wall.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>klepsydra fleet</title>
<link rel="stylesheet" href="fleet/badge.css" />
<link rel="stylesheet" href="fleet/wall.css" />
</head>
<body>
  <main id="wall" aria-label="Claude Code sessions"></main>
  <p id="empty" hidden>No Claude Code sessions are running.</p>
  <p id="live" class="visually-hidden" aria-live="polite"></p>

  <template id="card-tpl">
    <article class="card" tabindex="-1">
      <header>
        <span class="portrait"><img alt="" sizes="64px" /><span class="corner"></span></span>
        <div class="who">
          <h2 class="name"></h2>
          <p class="small"></p>
        </div>
      </header>
      <p class="where"></p>
      <ul class="touched"></ul>
      <p class="status"><span class="mark"></span><span class="line"></span></p>
      <p class="error" hidden></p>
      <p class="said prompt"><span class="sign" aria-hidden="true">&gt;</span><span class="text"></span></p>
      <p class="said reply"><span class="sign" aria-hidden="true">&lt;</span><span class="text"></span></p>
      <p class="updated" hidden></p>
      <div class="actions">
        <button type="button" class="jump">Jump to terminal</button>
        <span class="note" role="status"></span>
      </div>
    </article>
  </template>

  <script type="module" src="fleet/wall.js"></script>
</body>
</html>
```

Create `src/fleet/face.js`:

```js
// Point an <img> at a session's face: the 96 px file, or the 192 px one where
// the face is drawn larger than 96 device pixels. SVG faces are one file.
export function showFace(img, face, face2x, cssPx) {
  img.sizes = `${Math.ceil(cssPx)}px`;
  img.srcset = face === face2x ? "" : `${face} 96w, ${face2x} 192w`;
  if (img.getAttribute("src") !== face2x) img.src = face2x;
}
```

Create `src/fleet/wall.js`:

```js
// The card wall: a card per Claude Code session, in the reader's order, with
// a way back to its terminal.
import cast from "./cast.json" with { type: "json" };
import { announcements, badgeSvg, card, statuses } from "./model.js";
import { showFace } from "./face.js";

const TICK_MS = 15_000; // ages re-render between snapshots, as on the gauge
const FACE_PX = 64; // --wall-face

const inTauri = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);
const wall = document.getElementById("wall");
const empty = document.getElementById("empty");
const live = document.getElementById("live");
const tpl = document.getElementById("card-tpl");

let sessions = [];
let before;
let pending = null; // a card to show once it exists

function setText(el, text) {
  el.textContent = text ?? "";
}

function paint(el, c) {
  el.dataset.id = c.id;
  el.setAttribute("aria-label", c.label);
  showFace(el.querySelector(".portrait img"), c.face, c.face2x, FACE_PX);
  setText(el.querySelector(".name"), c.name);
  setText(el.querySelector(".small"), [c.voice, c.session].filter(Boolean).join(" · "));
  setText(el.querySelector(".where"), c.where);
  const touched = el.querySelector(".touched");
  touched.replaceChildren(...c.touched.map((t) => Object.assign(document.createElement("li"), { textContent: t })));
  if (el.dataset.status !== c.status) {
    el.dataset.status = c.status;
    const svg = badgeSvg(c.status);
    el.querySelector(".corner").innerHTML = svg;
    el.querySelector(".mark").innerHTML = svg;
  }
  setText(el.querySelector(".status .line"), c.statusLine);
  const error = el.querySelector(".error");
  error.hidden = !c.error;
  setText(error, c.error);
  for (const [cls, text] of [["prompt", c.prompt], ["reply", c.reply]]) {
    const said = el.querySelector(`.${cls} .text`);
    setText(said, text);
    said.title = text ?? "";
  }
  const updated = el.querySelector(".updated");
  updated.hidden = !c.updated;
  setText(updated, c.updated);
  const jump = el.querySelector(".jump");
  const note = el.querySelector(".note");
  jump.disabled = !c.jump.enabled;
  jump.dataset.name = c.session ?? "";
  if (!c.jump.enabled) {
    setText(note, c.jump.why);
    note.dataset.why = "";
  } else if ("why" in note.dataset) {
    setText(note, "");
    delete note.dataset.why;
  }
}

function render() {
  const now = Date.now();
  empty.hidden = sessions.length > 0;
  const existing = new Map([...wall.children].map((el) => [el.dataset.id, el]));
  sessions.forEach((s, i) => {
    let el = existing.get(s.session_id);
    if (el) existing.delete(s.session_id);
    else el = tpl.content.firstElementChild.cloneNode(true);
    paint(el, card(s, cast, now));
    if (wall.children[i] !== el) wall.insertBefore(el, wall.children[i] ?? null);
  });
  for (const gone of existing.values()) gone.remove();
}

function show(id) {
  const el = [...wall.children].find((c) => c.dataset.id === id);
  if (!el) {
    pending = id;
    return;
  }
  pending = null;
  el.scrollIntoView({ block: "center" });
  el.focus({ preventScroll: true });
}

function receive(message) {
  if (Array.isArray(message?.sessions)) {
    const said = announcements(before, message.sessions, cast);
    if (said.length) live.textContent = said.join(". ");
    before = statuses(message.sessions);
    sessions = message.sessions;
    render();
    if (pending) show(pending);
  }
  if (typeof message?.focus === "string") show(message.focus);
}

wall.addEventListener("click", async (e) => {
  const button = e.target.closest(".jump");
  if (!button || button.disabled || !inTauri) return;
  const note = button.parentElement.querySelector(".note");
  button.disabled = true;
  note.textContent = "";
  try {
    note.textContent = await window.__TAURI__.core.invoke("jump_to_terminal", { name: button.dataset.name });
  } catch (err) {
    note.textContent = String(err);
  } finally {
    button.disabled = false;
  }
});

if (inTauri) {
  const channel = new window.__TAURI__.core.Channel();
  channel.onmessage = receive;
  window.__TAURI__.core.invoke("fleet_subscribe", { onMessage: channel }).catch(() => {});
} else {
  // Browser dev: serve src/ with a dev-fleet.json holding a snapshot.
  fetch("./dev-fleet.json", { cache: "no-store" })
    .then((res) => (res.ok ? res.json() : null))
    .then((snapshot) => {
      if (snapshot) receive(snapshot);
      const focus = new URLSearchParams(location.search).get("focus");
      if (focus) show(focus);
    })
    .catch(() => {});
}

setInterval(render, TICK_MS);
```

- [ ] **Step 6: Run every node test**

Run:

```bash
node --test src/*.test.js
```

Expected: PASS: 87 tests. The guards now read `wall.js` (no process, no `wsl`, no sound) and `badge.css`, whose one animation runs once and stops under reduced motion.

- [ ] **Step 7: Open the wall from the app**

In `src-tauri/src/fleet.rs`, replace:

```rust
//! The fleet strip's Tauri side: runs the reader on its own thread and hands
//! each new snapshot to every webview that subscribed.
```

with:

```rust
//! The fleet strip's Tauri side: runs the reader on its own thread, hands each
//! new snapshot to every webview that subscribed, and opens the card wall.
```

In `src-tauri/src/fleet.rs`, replace:

```rust
use tauri::{AppHandle, Manager};
```

with:

```rust
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
```

In `src-tauri/src/fleet.rs`, before:

```rust
/// A webview's end of the fleet.
```

insert:

```rust
/// The card wall's window label.
pub const WALL: &str = "wall";

```

Append to `src-tauri/src/fleet.rs`:

```rust

/// Show the card wall with session `focus`'s card in view. The wall is made
/// on the first call, from an async command since a window made in a sync one
/// deadlocks on Windows, and after that only hidden and shown, never closed.
#[tauri::command]
pub async fn open_wall(app: AppHandle, focus: String) -> Result<(), String> {
    app.state::<Fleet>().focus(WALL, &focus);
    if let Some(wall) = app.get_webview_window(WALL) {
        wall.show().map_err(|e| e.to_string())?;
        let _ = wall.unminimize();
        let _ = wall.set_focus();
        return Ok(());
    }
    let wall = WebviewWindowBuilder::new(&app, WALL, WebviewUrl::App("wall.html".into()))
        .title("klepsydra fleet")
        .inner_size(1280.0, 800.0)
        .min_inner_size(420.0, 320.0)
        .build()
        .map_err(|e| e.to_string())?;
    let handle = wall.clone();
    wall.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let _ = handle.hide();
        }
    });
    Ok(())
}
```

In `src-tauri/src/main.rs`, replace:

```rust
            fleet::fleet_subscribe,
            jump::jump_to_terminal
```

with:

```rust
            fleet::fleet_subscribe,
            fleet::open_wall,
            jump::jump_to_terminal
```

- [ ] **Step 8: Check the app crate on Windows**

The app crate needs WebKitGTK headers to compile on Linux, and WSL has none, so it is checked on the Windows staging copy (CI checks both). The local test run first also brings `Cargo.lock` up to date in WSL, since the Windows run only updates the staging copy.

Run:

```bash
(cd src-tauri && cargo test -p klepsydra-fleet) && bash scripts/build-windows.sh --check
```

Expected: PASS: the fleet tests in WSL; then on Windows, no clippy warning and `cargo test --workspace` passing the app's geometry tests and every fleet crate test.

- [ ] **Step 9: Commit**

```bash
git add src/fleet-style.test.js src/fleet/badge.css src/fleet/wall.css src/wall.html src/fleet/face.js src/fleet/wall.js && git commit -m "feat(fleet): the card wall, made on first open and only hidden after" -- src/fleet-style.test.js src/fleet/badge.css src/fleet/wall.css src/wall.html src/fleet/face.js src/fleet/wall.js src-tauri/src/fleet.rs src-tauri/src/main.rs
```

### Task 14: Strip hit area in the pointer watcher

**Files:**

- Modify: `src-tauri/src/geometry.rs` (lines 165-166, 420-421)
- Modify: `src-tauri/src/main.rs` (lines 24, 254-259, 266-270, 316-321, 624-643, 647-649, 690-711, 757)

**Interfaces:**

- **Consumes:** the watcher in `main.rs` (`watch_grip`, `Placed`, `Grip`), which makes the click-through window interactive only over the grip.
- **Produces:**
  - `geometry::hit_area(css: [f64; 4], origin: (f64, f64), size: (f64, f64), scale: f64, margin: f64, band: Option<f64>) -> (f64, f64, f64, f64)` and `geometry::contains(edges, x: f64, y: f64) -> bool`, std only and tested with `rustc --test`.
  - `struct Strip(Mutex<Option<[f64; 4]>>)` (managed state; None while the strip is hidden); `set_size(..., grip: Option<[f64; 4]>, strip: Option<[f64; 4]>)` and `set_grip(x, y, w, h, strip: Option<[f64; 4]>)` both store the strip's rectangle (CSS px from the window's top-left; JS key `strip`, `null` while hidden); `resize_band(g: Placed) -> Option<f64>` (Linux only).
  - The window takes the pointer over the grip or the strip; a drag still starts only on a press that begins on the grip. The strip's area stops short of tao's Linux resize band exactly as the grip's does.

- [ ] **Step 1: Write the failing geometry tests**

In `src-tauri/src/geometry.rs`, after:

```rust
        assert_eq!(home_rect(&h, 420.0, 58.0, &[]), None);
    }
```

insert:

```rust

    #[test]
    fn a_hit_area_is_placed_and_scaled_with_the_window() {
        let a = hit_area(
            [14.0, 10.0, 12.0, 30.0],
            (100.0, 200.0),
            (630.0, 96.0),
            1.5,
            0.0,
            None,
        );
        assert_eq!(a, (121.0, 215.0, 139.0, 260.0));
        assert!(contains(a, 121.0, 260.0));
        assert!(!contains(a, 120.9, 230.0));
    }

    #[test]
    fn a_margin_grows_the_area_each_way() {
        let a = hit_area(
            [14.0, 10.0, 12.0, 30.0],
            (0.0, 0.0),
            (630.0, 64.0),
            1.0,
            8.0,
            None,
        );
        assert_eq!(a, (6.0, 2.0, 34.0, 48.0));
    }

    #[test]
    fn a_band_keeps_the_strip_off_the_window_edges() {
        // The strip runs to the window's right edge; a press in the resize
        // band there must pass through, as for the grip.
        let a = hit_area(
            [430.0, 0.0, 200.0, 64.0],
            (0.0, 0.0),
            (630.0, 64.0),
            1.0,
            0.0,
            Some(6.0),
        );
        assert_eq!(a, (430.0, 6.0, 624.0, 58.0));
        assert!(!contains(a, 627.0, 30.0));
    }
```

- [ ] **Step 2: Run them**

geometry.rs is std only, so it compiles alone in WSL.

Run:

```bash
rustc --edition 2021 --test src-tauri/src/geometry.rs -o /tmp/geometry-tests && /tmp/geometry-tests
```

Expected: FAIL to compile: `error[E0425]: cannot find function `hit_area` in this scope` and `cannot find function `contains``.

- [ ] **Step 3: Write hit_area and contains**

In `src-tauri/src/geometry.rs`, before:

```rust
#[cfg(test)]
mod tests {
```

insert:

```rust
/// A rectangle the frontend reported, in CSS pixels from the window's
/// top-left, as physical desktop edges (left, top, right, bottom) for a window
/// at `origin` of `size` and display `scale`: grown by `margin` each way, then,
/// when `band` is given, kept that far inside the window's own edges.
pub fn hit_area(
    css: [f64; 4],
    origin: (f64, f64),
    size: (f64, f64),
    scale: f64,
    margin: f64,
    band: Option<f64>,
) -> (f64, f64, f64, f64) {
    let left = origin.0 + css[0] * scale - margin;
    let top = origin.1 + css[1] * scale - margin;
    let right = left + css[2] * scale + margin * 2.0;
    let bottom = top + css[3] * scale + margin * 2.0;
    match band {
        None => (left, top, right, bottom),
        Some(b) => (
            left.max(origin.0 + b),
            top.max(origin.1 + b),
            right.min(origin.0 + size.0 - b),
            bottom.min(origin.1 + size.1 - b),
        ),
    }
}

/// Whether (`x`, `y`) lies within edges from `hit_area`, edges included.
pub fn contains((left, top, right, bottom): (f64, f64, f64, f64), x: f64, y: f64) -> bool {
    x >= left && x <= right && y >= top && y <= bottom
}

```

- [ ] **Step 4: Run them again**

Run:

```bash
rustc --edition 2021 --test src-tauri/src/geometry.rs -o /tmp/geometry-tests && /tmp/geometry-tests
```

Expected: PASS: 24 tests (21 existing, 3 new).

- [ ] **Step 5: Let the watcher take the pointer over the strip**

In `src-tauri/src/main.rs`, after:

```rust
struct Grip(Mutex<Option<[f64; 4]>>);
```

insert:

```rust

/// The fleet strip, in the same terms as the grip; None while it is hidden.
/// The window takes the pointer over it too, so its portraits can be clicked.
#[derive(Default)]
struct Strip(Mutex<Option<[f64; 4]>>);
```

In `src-tauri/src/main.rs`, replace:

```rust
/// The frontend reports the size its panel needs (CSS pixels): a row per
/// account window, times the zoom, with the grip's new rectangle. `pin` marks
/// a zoom: the content under the pointer, read now rather than when the wheel
/// event fired, stays under it, so the grip does too. Otherwise the window
/// grows away from the screen edges it sits nearest. Either way it is kept
/// wholly on its monitor.
```

with:

```rust
/// The frontend reports the size its panel needs (CSS pixels): a row per
/// account window, times the zoom, and the fleet strip beside it, with the
/// grip's and the strip's new rectangles. `pin` marks a zoom: the content
/// under the pointer, read now rather than when the wheel event fired, stays
/// under it, so the grip does too. Otherwise the window grows away from the
/// screen edges it sits nearest. Either way it is kept wholly on its monitor.
```

In `src-tauri/src/main.rs`, replace:

```rust
    grip: Option<[f64; 4]>,
) -> Result<(), String> {
    if let (Some(g), Ok(mut slot)) = (grip, window.state::<Grip>().0.lock()) {
        *slot = Some(g);
    }
```

with:

```rust
    grip: Option<[f64; 4]>,
    strip: Option<[f64; 4]>,
) -> Result<(), String> {
    if let (Some(g), Ok(mut slot)) = (grip, window.state::<Grip>().0.lock()) {
        *slot = Some(g);
    }
    if let Ok(mut slot) = window.state::<Strip>().0.lock() {
        *slot = strip;
    }
```

In `src-tauri/src/main.rs`, replace:

```rust
#[tauri::command]
fn set_grip(grip: tauri::State<'_, Grip>, x: f64, y: f64, w: f64, h: f64) {
    if let Ok(mut g) = grip.0.lock() {
        *g = Some([x, y, w, h]);
    }
}

```

with:

```rust
#[tauri::command]
fn set_grip(
    grip: tauri::State<'_, Grip>,
    strip_state: tauri::State<'_, Strip>,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    strip: Option<[f64; 4]>,
) {
    if let Ok(mut g) = grip.0.lock() {
        *g = Some([x, y, w, h]);
    }
    if let Ok(mut s) = strip_state.0.lock() {
        *s = strip;
    }
}

```

In `src-tauri/src/main.rs`, replace:

```rust
/// An undecorated resizable window gets tao's edge-resize band on Linux: a press
/// within it starts a window-manager resize. Stop the grip short of the band, so
/// a press there passes through instead. Windows is not resizable, so it has
/// no band.
fn clear_of_resize_band(
    g: Placed,
    (left, top, right, bottom): (f64, f64, f64, f64),
) -> (f64, f64, f64, f64) {
    const TAO_RESIZE_BORDER: f64 = 5.0; // tao's linux/event_loop.rs
    if !cfg!(target_os = "linux") {
        return (left, top, right, bottom);
    }
    let inset = (TAO_RESIZE_BORDER + 1.0) * g.scale;
    (
        left.max(g.x + inset),
        top.max(g.y + inset),
        right.min(g.x + g.w - inset),
        bottom.min(g.y + g.h - inset),
    )
}

```

with:

```rust
/// An undecorated resizable window gets tao's edge-resize band on Linux: a press
/// within it starts a window-manager resize. Hit areas stop short of the band,
/// so a press there passes through instead. Windows is not resizable, so it
/// has no band.
fn resize_band(g: Placed) -> Option<f64> {
    const TAO_RESIZE_BORDER: f64 = 5.0; // tao's linux/event_loop.rs
    cfg!(target_os = "linux").then_some((TAO_RESIZE_BORDER + 1.0) * g.scale)
}

```

In `src-tauri/src/main.rs`, replace:

```rust
/// the pointer and switch the whole window interactive only while it is over
/// the grab handle. Everywhere else the gauge stays click-through and never
/// eats a click.
```

with:

```rust
/// the pointer and switch the whole window interactive only while it is over
/// the grab handle or the fleet strip. Everywhere else the gauge stays
/// click-through and never eats a click.
```

In `src-tauri/src/main.rs`, replace:

```rust
            // Grip rect in physical desktop coordinates. While already
            // interactive the region is grown slightly, so a drag that outruns
            // the window by a pixel does not drop the mouse mid-move.
            let margin = if interactive { 8.0 } else { 0.0 };
            let left = g.x + rect[0] * g.scale - margin;
            let top = g.y + rect[1] * g.scale - margin;
            let (left, top, right, bottom) = clear_of_resize_band(
                *g,
                (
                    left,
                    top,
                    left + rect[2] * g.scale + margin * 2.0,
                    top + rect[3] * g.scale + margin * 2.0,
                ),
            );

            let inside =
                cursor.x >= left && cursor.x <= right && cursor.y >= top && cursor.y <= bottom;

            // Only a press that *starts* on the handle begins a drag, so
            // dragging something else across the gauge cannot grab it.
            if cursor.pressed && !was_pressed && inside {
```

with:

```rust
            // Hit areas in physical desktop coordinates. While already
            // interactive they are grown slightly, so a drag that outruns the
            // window by a pixel does not drop the mouse mid-move.
            let margin = if interactive { 8.0 } else { 0.0 };
            let strip = app.state::<Strip>().0.lock().ok().and_then(|s| *s);
            let area = |css: [f64; 4]| {
                geometry::hit_area(
                    css,
                    (g.x, g.y),
                    (g.w, g.h),
                    g.scale,
                    margin,
                    resize_band(*g),
                )
            };
            let on_grip = geometry::contains(area(rect), cursor.x, cursor.y);
            let on_strip = strip.is_some_and(|s| geometry::contains(area(s), cursor.x, cursor.y));
            let inside = on_grip || on_strip;

            // Only a press that *starts* on the handle begins a drag, so
            // dragging something else across the gauge cannot grab it.
            if cursor.pressed && !was_pressed && on_grip {
```

In `src-tauri/src/main.rs`, after:

```rust
        .manage(Grip::default())
```

insert:

```rust
        .manage(Strip::default())
```

- [ ] **Step 6: Check the app crate on Windows**

The app crate needs WebKitGTK headers to compile on Linux, and WSL has none, so it is checked on the Windows staging copy (CI checks both). The local test run first also brings `Cargo.lock` up to date in WSL, since the Windows run only updates the staging copy.

Run:

```bash
(cd src-tauri && cargo test -p klepsydra-fleet) && bash scripts/build-windows.sh --check
```

Expected: PASS: the fleet tests in WSL; then on Windows, no clippy warning and `cargo test --workspace` passing the app's geometry tests and every fleet crate test.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(fleet): take the pointer over the strip as well as the grip" -- src-tauri/src/geometry.rs src-tauri/src/main.rs
```

### Task 15: Face strip in the gauge window

**Files:**

- Modify: `src/fleet-style.test.js` (after line 81)
- Modify: `src/index.html` (lines 6, 8-9, 15-16)
- Modify: `src/style.css` (lines 34-36; after line 170)
- Create: `src/fleet/strip.js`
- Modify: `src/main.js` (lines 51, 65, 81-85, 87-108, 134-147, 175-176, 230-231, 234-235)

**Interfaces:**

- **Consumes:** `fleet_subscribe` (Task 10), `open_wall` (Task 13), `set_size`/`set_grip` with `strip` (Task 14), `model.js` (Task 11), `badge.css` and `face.js` (Task 13), `cast.json` (Task 7).
- **Produces:**
  - `src/fleet/strip.js`: `mountStrip(el: HTMLElement, { open: (id: string) => void }) -> render(sessions, nowMs?)`; hides `el` when there are no sessions; a portrait is a `<button class="face" data-id aria-label title>` with an `<img>` and a badge; the pulse class is removed on `animationend` so a reorder never replays it.
  - In the gauge window: `#frame` holds `#panel` and `#strip`; the window takes `#frame`'s size; tokens `--strip-gap: 8px`, `--face-size: 28px`, `--face-gap: 6px`, `--badge-size: 13px`, each multiplied by `--scale`.
  - `main.js` loads the strip with a dynamic `import()` inside `try`, so a strip failure leaves the gauge as it was, subscribes with a Channel, reads `./dev-fleet.json` in a plain browser, and exposes `window.__klepsydra.fleet(snapshot)` for the harness.

- [ ] **Step 1: Write the failing tests**

Append to `src/fleet-style.test.js`:

```js

test("a portrait is 28 px at 100%, and the strip's rules are in the zoomed stylesheet", () => {
  const css = read("./style.css");
  assert.equal(token(css, "--face-size"), "28px");
  for (const rule of ["#frame {", "#strip {", ".face {", ".face .badge {"]) assert.ok(css.includes(rule), rule);
});

test("the strip starts hidden, so the gauge looks as before until a fleet arrives", () => {
  assert.match(read("./index.html"), /<div id="strip"[^>]*\shidden>/);
  assert.match(read("./main.js"), /try \{\s*const \{ mountStrip \} = await import\("\.\/fleet\/strip\.js"\);/);
});
```

- [ ] **Step 2: Run them**

Run:

```bash
node --test src/fleet-style.test.js
```

Expected: FAIL: `a portrait is 28 px at 100%` (`--face-size` is undefined) and `the strip starts hidden` (no `#strip` in `index.html`); the 4 wall and badge tests pass.

- [ ] **Step 3: Lay out the strip beside the gauge**

In `src/index.html`, replace:

```html
<link rel="stylesheet" href="style.css" />
```

with:

```html
<link rel="stylesheet" href="style.css" />
<link rel="stylesheet" href="fleet/badge.css" />
```

In `src/index.html`, replace:

```html
<body>
  <div id="panel" data-state="waiting">
```

with:

```html
<body>
  <div id="frame">
  <div id="panel" data-state="waiting">
```

In `src/index.html`, replace:

```html
    <span id="zoom" aria-live="polite"></span>
  </div>
```

with:

```html
    <span id="zoom" aria-live="polite"></span>
  </div>
  <div id="strip" role="group" aria-label="Claude Code sessions" hidden></div>
  </div>
```

In `src/style.css`, replace:

```css
  --grip-dot-hover: #d0d0d0;
}
/* ───
```

with:

```css
  --grip-dot-hover: #d0d0d0;

  /* Fleet strip: a portrait per Claude Code session, right of the gauge. */
  --strip-gap: 8px;     /* between the gauge and the strip */
  --face-size: 28px;
  --face-gap: 6px;
  --badge-size: 13px;
}
/* ───
```

Append to `src/style.css`:

```css

/* The gauge and the fleet strip side by side; the window takes this size. */
#frame {
  display: flex;
  align-items: stretch;
  gap: calc(var(--strip-gap) * var(--scale));
  width: max-content;
}

#strip {
  display: flex;
  align-items: center;
  gap: calc(var(--face-gap) * var(--scale));
  padding: calc(var(--panel-pad-y) * var(--scale)) calc(var(--panel-pad-x) * var(--scale));
  background: var(--panel-bg);
  border-radius: calc(var(--panel-radius) * var(--scale));
  backdrop-filter: blur(12px);
}
#strip[hidden] { display: none; }

.face {
  position: relative;
  flex: 0 0 auto;
  width: calc(var(--face-size) * var(--scale));
  height: calc(var(--face-size) * var(--scale));
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: var(--track);
  cursor: pointer;
}
.face img { display: block; width: 100%; height: 100%; border-radius: 50%; }
.face .badge {
  position: absolute;
  right: calc(-3px * var(--scale));
  bottom: calc(-3px * var(--scale));
  width: calc(var(--badge-size) * var(--scale));
  height: calc(var(--badge-size) * var(--scale));
}
```

- [ ] **Step 4: Write the strip and load it from the gauge**

Create `src/fleet/strip.js`:

```js
// The fleet strip: a portrait per Claude Code session beside the gauge, each
// with its status badge. A click opens the card wall at that session.
import cast from "./cast.json" with { type: "json" };
import { badgeSvg, statuses, stripItems } from "./model.js";
import { showFace } from "./face.js";

/** Draw into `el`; returns render(sessions, nowMs). `open(id)` opens the wall. */
export function mountStrip(el, { open }) {
  let before;
  el.addEventListener("click", (e) => {
    const face = e.target.closest(".face");
    if (face) open(face.dataset.id);
  });
  // The pulse plays once; a re-order must not replay it.
  el.addEventListener("animationend", (e) => e.target.closest(".face")?.classList.remove("pulse"));

  return function render(sessions, nowMs = Date.now()) {
    const items = stripItems(sessions, cast, nowMs, before);
    before = statuses(sessions);
    el.hidden = items.length === 0;
    const root = getComputedStyle(document.documentElement);
    const px = parseFloat(root.getPropertyValue("--face-size")) * (parseFloat(root.getPropertyValue("--scale")) || 1);
    const existing = new Map([...el.children].map((b) => [b.dataset.id, b]));
    items.forEach((item, i) => {
      let b = existing.get(item.id);
      if (b) existing.delete(item.id);
      else {
        b = document.createElement("button");
        b.type = "button";
        b.className = "face";
        b.dataset.id = item.id;
        b.append(Object.assign(document.createElement("img"), { alt: "" }), document.createElement("span"));
      }
      b.setAttribute("aria-label", item.label);
      b.title = item.label;
      showFace(b.firstChild, item.face, item.face2x, px);
      if (b.dataset.status !== item.status) {
        b.dataset.status = item.status;
        b.lastChild.innerHTML = badgeSvg(item.status);
        if (item.status !== "needs_you") b.classList.remove("pulse");
      }
      if (item.pulse) b.classList.add("pulse");
      if (el.children[i] !== b) el.insertBefore(b, el.children[i] ?? null);
    });
    for (const gone of existing.values()) gone.remove();
  };
}
```

In `src/main.js`, replace:

```js
const panel = document.getElementById("panel");
```

with:

```js
const frame = document.getElementById("frame");
const panel = document.getElementById("panel");
const stripEl = document.getElementById("strip");
```

In `src/main.js`, replace:

```js
let zoomSave = 0;
```

with:

```js
let zoomSave = 0;
let fleetSessions = [];
let drawStrip = null;
```

In `src/main.js`, replace:

```js
/** The grab handle's rectangle, in CSS pixels from the window's top-left. */
function gripRect() {
  const r = grip.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height];
}

```

with:

```js
const rectOf = (el) => {
  const r = el.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height];
};
/** The grab handle's rectangle, in CSS pixels from the window's top-left. */
const gripRect = () => rectOf(grip);
/** The fleet strip's rectangle, or null while it is hidden. */
const stripRect = () => (stripEl.hidden ? null : rectOf(stripEl));

```

In `src/main.js`, replace:

```js
/**
 * Tell the window how big the panel is, so it never clips or gaps. `pin` marks
 * a zoom, which keeps the point under the pointer still. The grip's new
 * rectangle travels with the size, so the pointer watcher never pairs a new
 * position with an old grip.
 */
function syncSize(pin = false) {
  if (!inTauri) return;
  const r = panel.getBoundingClientRect();
  const w = Math.ceil(r.width);
  const h = Math.ceil(r.height);
  const size = `${w}x${h}`;
  if (w < 1 || h < 1 || (size === lastSize && !pin)) return;
  lastSize = size;
  const g = gripRect();
  lastGrip = g.join(",");
  window.__TAURI__.core
    .invoke("set_size", { width: w, height: h, pin, grip: g })
    .catch(() => {
      lastSize = ""; // not applied; the next render tries again
    });
}

```

with:

```js
/**
 * Tell the window how big the gauge and strip are, so it never clips or gaps.
 * `pin` marks a zoom, which keeps the point under the pointer still. The
 * grip's and strip's new rectangles travel with the size, so the pointer
 * watcher never pairs a new position with an old hit area.
 */
function syncSize(pin = false) {
  if (!inTauri) return;
  const r = frame.getBoundingClientRect();
  const w = Math.ceil(r.width);
  const h = Math.ceil(r.height);
  const size = `${w}x${h}`;
  if (w < 1 || h < 1 || (size === lastSize && !pin)) return;
  lastSize = size;
  const g = gripRect();
  const strip = stripRect();
  lastGrip = `${g.join(",")}|${strip ?? ""}`;
  window.__TAURI__.core
    .invoke("set_size", { width: w, height: h, pin, grip: g, strip })
    .catch(() => {
      lastSize = ""; // not applied; the next render tries again
    });
}

```

In `src/main.js`, replace:

```js
/**
 * Report where the grab handle sits. The backend cannot know the layout, and
 * hard-coding it here would silently desync the moment the CSS changes.
 */
function syncGrip() {
  if (!inTauri) return;
  const [x, y, w, h] = gripRect();
  const key = [x, y, w, h].join(",");
  if (w < 1 || h < 1 || key === lastGrip) return;
  lastGrip = key;
  window.__TAURI__.core.invoke("set_grip", { x, y, w, h }).catch(() => {
    lastGrip = "";
  });
}

```

with:

```js
/**
 * Report where the grab handle and the strip sit. The backend cannot know the
 * layout, and hard-coding it here would silently desync the moment the CSS
 * changes.
 */
function syncGrip() {
  if (!inTauri) return;
  const [x, y, w, h] = gripRect();
  const strip = stripRect();
  const key = `${[x, y, w, h].join(",")}|${strip ?? ""}`;
  if (w < 1 || h < 1 || key === lastGrip) return;
  lastGrip = key;
  window.__TAURI__.core.invoke("set_grip", { x, y, w, h, strip }).catch(() => {
    lastGrip = "";
  });
}

```

In `src/main.js`, replace:

```js
  document.title = rows.length ? `klepsydra ${formatPct(rows[0].pct)}` : "klepsydra";
  syncTray(rows);
```

with:

```js
  document.title = rows.length ? `klepsydra ${formatPct(rows[0].pct)}` : "klepsydra";
  drawStrip?.(fleetSessions, Date.now());
  syncTray(rows);
```

In `src/main.js`, replace:

```js
// Exposed so the visual-check harness can drive states without live files.
window.__klepsydra = { set(p) { lastPayload = p; render(); } };

```

with:

```js
/** Snapshots from the fleet reader; each one redraws the strip. */
function receiveFleet(message) {
  if (!Array.isArray(message?.sessions)) return;
  fleetSessions = message.sessions;
  render();
}

/**
 * Load the strip and follow the fleet. The strip is a module of its own, so a
 * failure there leaves the gauge as it was.
 */
async function startFleet() {
  try {
    const { mountStrip } = await import("./fleet/strip.js");
    drawStrip = mountStrip(stripEl, {
      open: (id) => inTauri && window.__TAURI__.core.invoke("open_wall", { focus: id }).catch(() => {}),
    });
  } catch {
    return;
  }
  if (inTauri) {
    const channel = new window.__TAURI__.core.Channel();
    channel.onmessage = receiveFleet;
    window.__TAURI__.core.invoke("fleet_subscribe", { onMessage: channel }).catch(() => {});
    return;
  }
  // Browser dev: serve src/ with a dev-fleet.json holding a snapshot.
  try {
    const res = await fetch("./dev-fleet.json", { cache: "no-store" });
    if (res.ok) receiveFleet(await res.json());
  } catch {
    // no fixture, no strip
  }
}

// Exposed so the visual-check harness can drive states without live files.
window.__klepsydra = {
  set(p) { lastPayload = p; render(); },
  fleet: receiveFleet,
};

```

In `src/main.js`, replace:

```js
applyZoom();
poll();
```

with:

```js
applyZoom();
startFleet();
poll();
```

- [ ] **Step 5: Run every node test**

Run:

```bash
node --test src/*.test.js
```

Expected: PASS: 89 tests: the 6 fleet style tests, the existing style test (every strip size follows `--scale`), and the guards over `strip.js` and `main.js`.

- [ ] **Step 6: Commit**

```bash
git add src/fleet/strip.js && git commit -m "feat(fleet): a portrait per session beside the gauge" -- src/fleet/strip.js src/fleet-style.test.js src/index.html src/style.css src/main.js
```

### Task 16: Visual harness for the strip and the wall

**Files:**

- Modify: `src/guards.test.js` (after line 142)
- Modify: `.gitignore` (line 4)
- Modify: `scripts/build-windows.sh` (line 17)
- Modify: `scripts/build-linux.sh` (lines 9-14)
- Modify: `scripts/visual-check.sh` (lines 15, 46-47, 57, 116)

**Interfaces:**

- **Consumes:** `window.__klepsydra.fleet` and `./dev-fleet.json` (Task 15), the wall's own `./dev-fleet.json` read (Task 13), the snapshot shape (Task 8).
- **Produces:** `src/dev-fleet.json` as harness input, written and deleted by `scripts/visual-check.sh`, ignored by git and kept out of both builds exactly as `src/dev-fixture.json` is; `shot NAME QUERY SIZE [PAGE]`; screenshots `11-fleet-strip`, `12-fleet-strip-zoom`, `13-fleet-wall-1920`, `14-fleet-wall-1280`.

- [ ] **Step 1: Write the failing guard**

Every place that keeps `src/dev-fixture.json` out of a build must keep `src/dev-fleet.json` out too.

Append to `src/guards.test.js`:

```js

test("harness input never ships", () => {
  const gitignore = read(".gitignore");
  const windows = read("scripts/build-windows.sh");
  const linux = read("scripts/build-linux.sh");
  for (const f of ["src/dev-fixture.json", "src/dev-fleet.json"]) {
    assert.match(gitignore, new RegExp(`^${f}$`, "m"), `.gitignore: ${f}`);
    assert.ok(windows.includes(`--exclude '${f}'`), `build-windows.sh: ${f}`);
    assert.ok(linux.includes(f), `build-linux.sh: ${f}`);
  }
});
```

- [ ] **Step 2: Run it**

Run:

```bash
node --test src/guards.test.js
```

Expected: FAIL: `harness input never ships` reports `.gitignore: src/dev-fleet.json`.

- [ ] **Step 3: Keep the fleet fixture out of git and both builds**

In `.gitignore`, replace:

```
src/dev-fixture.json
```

with:

```
src/dev-fixture.json
src/dev-fleet.json
```

In `scripts/build-windows.sh`, replace:

```bash
  --exclude 'src/dev-fixture.json' \
```

with:

```bash
  --exclude 'src/dev-fixture.json' --exclude 'src/dev-fleet.json' \
```

In `scripts/build-linux.sh`, replace:

```bash
# The Windows build excludes this harness input when staging; here the bundle
# would embed src/ as-is, so refuse rather than ship it.
if [[ -e src/dev-fixture.json ]]; then
  echo "src/dev-fixture.json is harness input; delete it before building" >&2
  exit 1
fi
```

with:

```bash
# The Windows build excludes the harness input when staging; here the bundle
# would embed src/ as-is, so refuse rather than ship it.
for harness in src/dev-fixture.json src/dev-fleet.json; do
  if [[ -e $harness ]]; then
    echo "$harness is harness input; delete it before building" >&2
    exit 1
  fi
done
```

- [ ] **Step 4: Run the guards again**

Run:

```bash
node --test src/guards.test.js
```

Expected: PASS: 10 guard tests.

- [ ] **Step 5: Shoot the strip and the wall**

In `scripts/visual-check.sh`, replace:

```bash
fixture="$here/src/dev-fixture.json"
```

with:

```bash
fixture="$here/src/dev-fixture.json"
fleet_fixture="$here/src/dev-fleet.json"
```

In `scripts/visual-check.sh`, replace:

```bash
shot() { # name, query, window-size
  local name=$1 query=${2:-} size=${3:-450,120}
```

with:

```bash
shot() { # name, query, window-size, page
  local name=$1 query=${2:-} size=${3:-450,120} page=${4:-index.html}
```

In `scripts/visual-check.sh`, replace:

```bash
    "http://127.0.0.1:$port/index.html$query" >/dev/null 2>&1 || true
```

with:

```bash
    "http://127.0.0.1:$port/$page$query" >/dev/null 2>&1 || true
```

In `scripts/visual-check.sh`, before:

```bash
echo "-> $win_out"
```

insert:

```bash
echo "fleet ->"
# A snapshot as the reader hands it over: one session per status, the cast,
# Lorelei and fallback faces among them.
fleet_session() { # id, voice, status, reason, age_sec, name
  jq -nc --arg id "$1" --arg voice "$2" --arg status "$3" --arg reason "$4" --argjson at "$((now - $5))" \
    --arg name "$6" 'def opt: if . == "" then null else . end;
    {session_id: $id, name: ($name | opt), launch_dir: "/home/aj/ajsoftworks",
      voice: ($voice | opt), status: $status, reason: ($reason | opt), status_at: $at,
      where: {repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer", at: $at},
      touched: [{repo: "ideas", at: ($at - 3600)}, {repo: "keryx", at: ($at - 9000)}],
      prompt: (if $status == "new" then null
               else {text: "i just want to be able to VIZ them, one glance at the screen and I know who needs me", at: ($at - 60)} end),
      reply: (if $status == "new" then null
              else {text: "That works with no model calls: the hook writes one file per session and the overlay reads them.", at: ($at - 30)} end),
      error: (if $status == "error" then "API Error: Rate limit reached" else null end), updated_at: $at}'
}
jq -s '{sessions: .}' \
  <(fleet_session 11111111-0000-4000-8000-000000000001 am_michael needs_you "approve Bash" 130 "Plan the fleet visualizer") \
  <(fleet_session 11111111-0000-4000-8000-000000000002 af_bella error "rate limit" 400 "Rebuild the deck") \
  <(fleet_session 11111111-0000-4000-8000-000000000003 bf_emma working "" 45 "Port the hook") \
  <(fleet_session 11111111-0000-4000-8000-000000000004 am_fenrir "done" "" 900 "Fix the CI pins") \
  <(fleet_session 11111111-0000-4000-8000-000000000005 "" new "" 20 "") \
  <(fleet_session 11111111-0000-4000-8000-000000000006 af_heart silent "" 300 "Draft the email") \
  <(fleet_session 11111111-0000-4000-8000-000000000007 am_puck ended "exited" 120 "Tidy worktrees") \
  >"$fleet_fixture"
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 46 9000),\"seven_day\":$(w 12 400000)}")"
shot 11-fleet-strip "" 1100,140
shot 12-fleet-strip-zoom "?zoom=4" 1500,260
shot 13-fleet-wall-1920 "" 1920,1100 wall.html
shot 14-fleet-wall-1280 "" 1280,1000 wall.html
rm -f "$fixture" "$fleet_fixture"

```

- [ ] **Step 6: Run the harness and look at the four new shots**

It drives Windows Chrome headless and writes to `%LOCALAPPDATA%\Temp\klepsydra-shots`.

Run:

```bash
bash scripts/visual-check.sh && uvx --from shellcheck-py shellcheck scripts/*.sh
```

Expected: Lists `11-fleet-strip.png` to `14-fleet-wall-1280.png` and no `only N of 30` error. In `11` the strip sits right of the gauge with seven portraits in the reader's order (Hephaestus with the orange diamond first, then Kallos, Techne, Fenrir, a fallback face, Cupid, Puck). `12` is the same at 146%. `13` shows three columns of cards at 1920 px; `14` shows two at 1280 px. The not-started card has no prompt and its Jump is disabled with "no session name yet"; the ended card's Jump says "session ended".

- [ ] **Step 7: Commit**

```bash
git commit -m "test(fleet): screenshot the strip and the wall, and keep their fixture out of builds" -- src/guards.test.js .gitignore scripts/build-windows.sh scripts/build-linux.sh scripts/visual-check.sh
```

### Task 17: Memory measurement and the release checklist

**Files:**

- Create: `scripts/test_measure_memory.sh`
- Create: `scripts/measure-memory.sh`
- Create: `scripts/fleet-status.sh`
- Modify: `.github/workflows/ci.yml` (line 40)
- Modify: `README.md` (after line 288)

**Interfaces:**

- **Consumes:** `powershell.exe` from WSL (`Get-CimInstance Win32_Process`: `ProcessId`, `ParentProcessId`, `WorkingSetSize`); the hook's `KLEPSYDRA_DIR` resolution (sourced from `hooks/klepsydra-fleet.sh`).
- **Produces:** `scripts/measure-memory.sh sample` (prints `<epoch>\t<MB>`; exit 3 when klepsydra.exe is not running), `check LOG` (exit 0 within 10%, 1 above, 2 when the log has fewer than two readings or they are less than 7 h 55 min apart; prints `100.0 MB -> 104.0 MB over 8.0 h: +4.0% (limit 10%)`), `run LOG` (samples at 5 min and 8 h, then checks); `scripts/test_measure_memory.sh`; `scripts/fleet-status.sh` (one line per session file: session, state, reason, voice, where, state age, beat name, beat age); README's `## Releasing` checklist with the live check and the memory rule.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_measure_memory.sh`:

```bash
#!/usr/bin/env bash
# Tests for the release memory check. Run: bash scripts/test_measure_memory.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

log() { printf '%s\t%s\n' "$@" >"$work/log"; }
verdict() { bash "$here/measure-memory.sh" check "$work/log" >/dev/null; echo $?; }

echo "memory check"
log 1000 120.0 $((1000 + 28500)) 131.9
check "9.9% growth passes" "$(verdict)" "0"
log 1000 120.0 $((1000 + 28500)) 132.1
check "10.1% growth blocks the release" "$(verdict)" "1"
log 1000 120.0 $((1000 + 28500)) 90.0
check "shrinking passes" "$(verdict)" "0"
log 1000 120.0 $((1000 + 3600)) 121.0
check "an hour apart cannot answer" "$(verdict)" "2"
printf '1000\t120.0\n' >"$work/log"
check "one reading cannot answer" "$(verdict)" "2"
check "the verdict line" "$(bash "$here/measure-memory.sh" check <(printf '0\t100.0\n28800\t104.0\n'))" \
  "100.0 MB -> 104.0 MB over 8.0 h: +4.0% (limit 10%)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run it**

Run:

```bash
bash scripts/test_measure_memory.sh
```

Expected: FAIL: every check reports `bash: .../scripts/measure-memory.sh: No such file or directory` (verdict `127`).

- [ ] **Step 3: Write the measurement**

Create `scripts/measure-memory.sh`:

```bash
#!/usr/bin/env bash
# klepsydra's memory on Windows: the working set of klepsydra.exe and every
# process under it (its WebView2 browser, renderers and GPU process). The
# release checklist in README.md reads it 5 minutes after launch and again at
# 8 hours; a release is blocked if the second is more than 10% above the first.
#
# Usage:
#   bash scripts/measure-memory.sh sample          one line: epoch seconds, MB
#   bash scripts/measure-memory.sh check LOG       compare the first and last lines
#   bash scripts/measure-memory.sh run LOG         start with klepsydra: sample at
#                                                  5 min and 8 h, then check
set -euo pipefail

FIRST_AT=$((5 * 60))
LAST_AT=$((8 * 3600))
GROWTH_LIMIT_PCT=10

# shellcheck disable=SC2016  # PowerShell source: its $ variables stay unexpanded.
WORKING_SET='
$all = Get-CimInstance Win32_Process
$ids = New-Object System.Collections.Generic.HashSet[uint32]
$all | Where-Object { $_.Name -eq "klepsydra.exe" } | ForEach-Object { [void]$ids.Add($_.ProcessId) }
if ($ids.Count -eq 0) { exit 3 }
do {
  $added = 0
  foreach ($p in $all) {
    if (-not $ids.Contains($p.ProcessId) -and $ids.Contains($p.ParentProcessId)) { [void]$ids.Add($p.ProcessId); $added++ }
  }
} while ($added -gt 0)
$bytes = ($all | Where-Object { $ids.Contains($_.ProcessId) } | Measure-Object -Property WorkingSetSize -Sum).Sum
[math]::Round($bytes / 1MB, 1)
'

sample() {
  local mb
  mb=$(powershell.exe -NoProfile -Command "$WORKING_SET" | tr -d '\r') || {
    echo "klepsydra.exe is not running" >&2
    return 3
  }
  printf '%s\t%s\n' "$(date +%s)" "$mb"
}

# Exit 0 when the last reading is within the limit of the first, 1 when it
# grew past it, 2 when the log cannot answer (too few readings, too short).
check() { # log
  awk -F'\t' -v span="$((LAST_AT - FIRST_AT))" -v limit="$GROWTH_LIMIT_PCT" '
    NF == 2 { if (n++ == 0) { t0 = $1; m0 = $2 } t1 = $1; m1 = $2 }
    END {
      if (n < 2) { print "need two readings, found " n; exit 2 }
      if (t1 - t0 < span) { printf "readings %d s apart; the check needs %d s\n", t1 - t0, span; exit 2 }
      growth = (m1 - m0) / m0 * 100
      printf "%.1f MB -> %.1f MB over %.1f h: %+.1f%% (limit %d%%)\n", m0, m1, (t1 - t0) / 3600, growth, limit
      exit growth > limit ? 1 : 0
    }' "$1"
}

case ${1:-} in
  sample) sample ;;
  check) check "${2:?log file}" ;;
  run)
    log=${2:?log file}
    : >"$log"
    sleep "$FIRST_AT"
    sample >>"$log"
    sleep "$((LAST_AT - FIRST_AT))"
    sample >>"$log"
    check "$log"
    ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run the test and one live sample**

The sample needs klepsydra running on Windows; skip it if it is not.

Run:

```bash
bash scripts/test_measure_memory.sh && bash scripts/measure-memory.sh sample
```

Expected: PASS: `6 passed, 0 failed`, then one line such as `1792361233	122.6` (MB, klepsydra.exe and its WebView2 processes).

- [ ] **Step 5: Write the fleet status helper**

It sources the hook for `KLEPSYDRA_DIR`, so the path matches what the hook writes.

Create `scripts/fleet-status.sh`:

```bash
#!/usr/bin/env bash
# The fleet as its session files have it, for the live check to compare with
# the strip and the wall: one line per session with its state, reason, voice,
# where it works, the state's age, and the heartbeat's name and age.
# Usage: bash scripts/fleet-status.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# The hook resolves KLEPSYDRA_DIR as Claude Code would run it.
# shellcheck source=hooks/klepsydra-fleet.sh
source "$repo/hooks/klepsydra-fleet.sh"
fleet="$KLEPSYDRA_DIR/fleet"
printf -v now '%(%s)T' -1

shopt -s nullglob
files=("$fleet"/*.json)
if (( ${#files[@]} == 0 )); then
  echo "no session files in $fleet"
  exit 0
fi
{
  printf 'session\tstate\treason\tvoice\twhere\tfor\tbeat\tbeat age\n'
  for f in "${files[@]}"; do
    beat=${f%.json}.beat
    name="-" age="-"
    if [[ -f $beat ]]; then
      IFS=$'\t' read -r name _ <"$beat" || true
      age="$(( now - $(stat -c %Y "$beat") ))s"
    fi
    jq -r --argjson now "$now" --arg name "${name:--}" --arg age "$age" '
      [ .session_id[0:8], .state, (.reason // "-"), (.voice // "-"),
        ([.where.repo, .where.worktree] | map(select(. != null)) | join("/") | if . == "" then "-" else . end),
        "\((($now - .state_at) / 60) | floor)m", $name, $age ] | @tsv' "$f" 2>/dev/null ||
      printf '%s\tunreadable\n' "${f##*/}"
  done
} | column -t -s $'\t'
```

- [ ] **Step 6: Try it**

Run:

```bash
bash scripts/fleet-status.sh
```

Expected: With no sessions: `no session files in .../dev.ajsoftworks.klepsydra/fleet`. With the hooks installed: one line per session, such as `11111111  needs_you  approve Bash  am_michael  klepsydra/fleet  2m  Plan the fleet visualizer  12s`.

- [ ] **Step 7: Run the memory test in CI, and write the checklist**

In `.github/workflows/ci.yml`, replace:

```yaml
        run: bash hooks/test_fleet.sh
```

with:

```yaml
        run: bash hooks/test_fleet.sh
      - name: Release memory check tests
        run: bash scripts/test_measure_memory.sh
```

Append to `README.md`:

```markdown

## Releasing

A release ships only when all three hold:

1. Every command under Tests passes, and CI is green on both platforms.
2. The live check. With the new build running, open eight Claude Code sessions
   in Windows Terminal tabs, each with the fleet hooks installed, and bring
   each to one state. For each, the strip and the card wall must show what
   `bash scripts/fleet-status.sh` prints for its file:
   - **not started:** start `claude` and type nothing.
   - **working:** ask for something long, such as running `sleep 300` in Bash.
   - **needs you, approve Bash:** in the default permission mode, ask for a
     command that prompts, and leave the prompt open.
   - **needs you, question:** ask Claude to ask you a multiple-choice question,
     and leave it open.
   - **done:** a prompt that finishes, such as "say hi".
   - **error:** a turn that ends on an API error, such as a prompt in a session
     started with `--model` naming a model the account cannot use.
   - **silent:** `kill -STOP <pid>` on one session's Claude Code process (the
     `claude.pid` in its session file). After 90 seconds it shows silent with
     its age; `kill -CONT <pid>` brings it back.
   - **ended:** `/exit` in one session. It shows ended, and leaves after 10
     minutes.

   Then click each portrait: the wall opens on that session's card. Press
   **Jump to terminal** on the approve-Bash card: its tab comes to the front,
   or its taskbar button flashes. Rename a session to another session's name
   and press Jump again: it says two tabs match and does nothing. Move the
   wall, quit klepsydra from the tray, start it again and open the wall: it
   opens where you left it.
3. Memory. Right after starting klepsydra, run
   `bash scripts/measure-memory.sh run /tmp/klepsydra-memory.log` in a WSL
   terminal and leave both running for 8 hours with the fleet in use. It
   samples klepsydra's working set, WebView2 processes included, at 5 minutes
   and at 8 hours. The release is blocked if the second reading is more than
   10% above the first. Record both readings in the release's ROADMAP entry.
```

- [ ] **Step 8: Lint**

Run:

```bash
uvx --from shellcheck-py shellcheck hooks/*.sh statusline/*.sh scripts/*.sh && ! grep -nP '\x{2014}' README.md
```

Expected: No shellcheck output, and no em-dash in README.md.

- [ ] **Step 9: Commit**

```bash
git add scripts/measure-memory.sh scripts/test_measure_memory.sh scripts/fleet-status.sh && git commit -m "test(fleet): measure memory growth for releases, and a release checklist with the live check" -- scripts/measure-memory.sh scripts/test_measure_memory.sh scripts/fleet-status.sh .github/workflows/ci.yml README.md
```

### Task 18: Install block, docs and the last guard

**Files:**

- Modify: `hooks/test_fleet.sh` (line 355)
- Modify: `src/guards.test.js` (after line 153)
- Modify: `README.md` (lines 17, 100-111, 182-183, 201-204, 231, 233-238, 260-261, 284-288)
- Modify: `IMPL.md` (lines 1-53)
- Modify: `ROADMAP.md` (lines 10-11, 15, 19, 21)
- Modify: `.claude/skill-context.md` (lines 14-15, 19, 22-23, 43-45, 58, 60, 73-74, 101, 102, 103-104)

**Interfaces:**

- **Consumes:** everything above.
- **Produces:** README's settings block between `<!-- fleet-settings:start -->` and `<!-- fleet-settings:end -->` (one JSON object with `statusLine.refreshInterval: 30` and the nine hook events, each `async: true`), held by `hooks/test_fleet.sh` against the hook's `EVENTS`; README sections for the strip, install, refresh, restyling and tests; IMPL.md rewritten for this slice; a ROADMAP entry; skill-context facts; a guard test that the guards read every fleet source.

- [ ] **Step 1: Write the failing tests**

The install-block test ties what users paste to what the hook handles, so a README edit cannot silently drop an event or the `async` flag. The reach test fails if a fleet file moves out of the guards' sight.

In `hooks/test_fleet.sh`, before:

```bash
block() {
```

insert:

````bash
echo "install block"
# README.md's settings block is what users paste; it must register every
# event the hook handles, each async, with the statusline's 30 s heartbeat.
settings=$(sed -n '/<!-- fleet-settings:start -->/,/<!-- fleet-settings:end -->/p' "$here/../README.md" |
  grep -v -e '^<!--' -e '^```')
check "settings: parses" "$(jq -e 'type' <<<"$settings" 2>/dev/null)" '"object"'
check "settings: heartbeat every 30 s" "$(jq '.statusLine.refreshInterval' <<<"$settings")" "30"
check "settings: the events" "$(jq -c '.hooks | keys' <<<"$settings")" \
  '["Notification","PermissionRequest","PostToolUse","PreToolUse","SessionEnd","SessionStart","Stop","StopFailure","UserPromptSubmit"]'
check "settings: every fleet hook is async" \
  "$(jq '[.hooks[][].hooks[]] | length > 0 and all(.async == true and (.command | endswith("/klepsydra-fleet.sh")))' <<<"$settings")" "true"
check "settings: questions and plans only" "$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$settings")" "AskUserQuestion|ExitPlanMode"
check "settings: an MCP server's request for input" "$(jq -r '.hooks.Notification[0].matcher' <<<"$settings")" "elicitation_dialog"
check "the hook handles exactly the events registered" \
  "$(tr ' ' '\n' <<<"$EVENTS" | LC_ALL=C sort | paste -sd, -)" "$(jq -r '.hooks | keys | join(",")' <<<"$settings")"

````

Append to `src/guards.test.js`:

```js

test("the guards reach every fleet source", () => {
  for (const f of [
    "src-tauri/src/fleet.rs",
    "src-tauri/src/jump.rs",
    "src-tauri/fleet/src/lib.rs",
    "src-tauri/fleet/src/session.rs",
    "src-tauri/fleet/src/view.rs",
    "src-tauri/fleet/src/scan.rs",
    "src-tauri/fleet/src/watch.rs",
    "src-tauri/fleet/src/tabs.rs",
  ]) assert.ok(RUST.includes(f), f);
  for (const f of ["src/fleet/model.js", "src/fleet/strip.js", "src/fleet/wall.js", "src/fleet/face.js", "src/wall.html"]) {
    assert.ok(FRONTEND.includes(f), f);
  }
  for (const f of ["src/fleet/badge.css", "src/fleet/wall.css"]) assert.ok(CSS.includes(f), f);
});
```

- [ ] **Step 2: Run them**

Run:

```bash
bash hooks/test_fleet.sh
```

Expected: FAIL: `settings: parses` and the other install-block checks (README has no fleet block yet). `node --test src/guards.test.js` passes the reach test already, since every fleet file exists.

- [ ] **Step 3: Write the README**

In `README.md`, replace:

```markdown
to be in front. The bar fills blue to yellow to red as the window is consumed.
```

with:

```markdown
to be in front. The bar fills blue to yellow to red as the window is consumed.
With several Claude Code sessions open, a portrait for each sits beside the
bar, and the ones waiting on you come first.
```

In `README.md`, replace:

````markdown
**1. Publish the numbers.** Copy the hook and point Claude Code at it:

```bash
cp statusline/klepsydra-statusline.sh ~/.claude/
chmod +x ~/.claude/klepsydra-statusline.sh
```

Then in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh" }
```
````

with:

````markdown
**1. Publish the numbers and the sessions.** Copy both hooks and point Claude
Code at them:

```bash
cp statusline/klepsydra-statusline.sh hooks/klepsydra-fleet.sh ~/.claude/
chmod +x ~/.claude/klepsydra-statusline.sh ~/.claude/klepsydra-fleet.sh
```

Then merge this into `~/.claude/settings.json` (into each config dir's
`settings.json` if you run two logins):

<!-- fleet-settings:start -->
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/klepsydra-statusline.sh",
    "refreshInterval": 30
  },
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PreToolUse": [{ "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "Notification": [{ "matcher": "elicitation_dialog", "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }]
  }
}
```
<!-- fleet-settings:end -->

Every fleet hook is `async`, so Claude Code never waits for it, and none
prints anything, so the permission hook never answers a prompt. For the gauge
alone, keep `statusLine` and leave out `hooks`.
````

In `README.md`, replace:

```markdown
remembers where you put it. Everything except that handle is click-through, so
the gauge never intercepts a click meant for the window underneath.
```

with:

```markdown
remembers where you put it. Everything except that handle and the fleet
strip is click-through, so the gauge never intercepts a click meant for the
window underneath.
```

In `README.md`, replace:

```markdown
background thread watches the pointer and makes the window interactive only
while it is over the handle. The frontend
reports the handle's rectangle rather than the backend hard-coding it, so
restyling cannot desync the two.
```

with:

```markdown
background thread watches the pointer and makes the window interactive only
while it is over the handle or the fleet strip. The frontend reports both
rectangles rather than the backend hard-coding them, so restyling cannot
desync the two.
```

In `README.md`, before:

```markdown
## How often it refreshes
```

insert:

```markdown
## The fleet strip

With several Claude Code sessions open, klepsydra shows a portrait for each to
the right of the gauge, with a badge for its status. Each badge has its own
shape, symbol and colour, from the Okabe-Ito palette:

| Badge | Status | Means |
|---|---|---|
| orange diamond `!` | needs you | a permission, a question, a plan or an MCP server's request is waiting |
| vermillion square `×` | error | the last turn ended on an API error |
| blue circle `…` | working | a prompt is being answered |
| green circle `✓` | done | the last turn finished |
| grey ring `○` | not started | no prompt yet |
| grey ring `?` | silent | no heartbeat and no event for 90 seconds; the session may be gone |
| grey ring `–` | ended | the session ended; it leaves after 10 minutes |

Sessions that need you come first, the longest wait leading, then errors,
work in progress, finished work, and the rest. A session that starts needing
you pulses once, unless the system asks for reduced motion. Every status
shows its age, in the portrait's tooltip and on its card.

Click a portrait to open the card wall at that session. It is an ordinary
window, made on the first click and only hidden after that. Each card shows
the session's face and name, where it works now (repo, worktree, branch) and
the other repos it touched, its status with the reason and age, and the last
prompt (`>`) and reply (`<`), two lines each with the full text on hover.

**Jump to terminal** selects the Windows Terminal tab titled with the
session's name and brings its window to the front. If Windows keeps the
focus, the tab's taskbar button flashes instead. With no such tab, or more
than one, it says so and does nothing.

A session's face follows its keryx voice, so it stays the same while the
session moves between repos. Ten voices are cast as the kourai-khryseai
characters and show their portraits. Any other voice shows a DiceBear Lorelei
face and the voice's name, and a session without keryx gets one of 24 Lorelei
faces picked by its session id. A face never changes with the status. The
faces are files in `src/fleet/faces`, each listed in `LICENSES.json`, and the
overlay loads no library and fetches nothing.

The fleet hook writes `<app data dir>/fleet/<session>.json`: the state, where
the session works, the first 300 characters of your last prompt and of the
last reply, and the error text of a failed turn. It records no tool input
beyond the tool's name and an edited file's path. The status line adds
`<session>.beat`, the session's name, at most once per 10 seconds. At each
session start the hook deletes the files of sessions whose Claude Code process
is gone and whose last event is more than a day old.

The overlay starts no process and asks WSL for nothing: it watches the folder
and re-reads it every 5 seconds. A file it cannot read is skipped and logged
once, and the rest of the fleet still shows. keryx does the speaking; the
strip makes no sound.

```

In `README.md`, replace:

```markdown
The status line is event-driven: Claude Code runs it as you work, and the hook
publishes whenever a render carries a new reading. The overlay needs no
`refreshInterval`: a periodic re-run repeats the session's last API response,
and the hook publishes nothing for it. The overlay re-reads the files every 5
seconds, and the countdown ticks every 15 seconds off `resets_at`, so it stays
right even when nothing is publishing.
```

with:

```markdown
The status line is event-driven: Claude Code runs it as you work, and the hook
publishes whenever a render carries a new reading. `refreshInterval: 30` also
re-runs it every 30 seconds, idle or not. The usage reading ignores those
re-runs, since each repeats the session's last API response, but each writes
the session's heartbeat for the fleet strip, at most once per 10 seconds. The
overlay re-reads the files every 5 seconds, and the countdown ticks every 15
seconds off `resets_at`, so it stays right even when nothing is publishing.
```

In `README.md`, replace:

```markdown
interpolation) and `bands` (flat colours that switch at thresholds). Edit,
rebuild, done.
```

with:

```markdown
interpolation) and `bands` (flat colours that switch at thresholds). Edit,
rebuild, done.

The fleet strip's sizes sit in the same block. Its badge colours are in
`src/fleet/badge.css`, where a test holds each to 3:1 contrast, and the card
wall's tokens open `src/fleet/wall.css`.
```

In `README.md`, replace:

````markdown
```bash
bash statusline/test_statusline.sh   # hook, against recorded payload shapes
node --test src/*.test.js            # ramp, countdown, reading age, reconciliation
bash scripts/visual-check.sh         # screenshots every state
```
````

with:

````markdown
```bash
bash statusline/test_statusline.sh       # usage hook and heartbeat, against recorded payloads
bash hooks/test_fleet.sh                 # fleet hook: states, where, identity, pruning, settings
bash scripts/test_measure_memory.sh      # the release memory check
node --test src/*.test.js                # ramp, countdown, reconciliation, fleet model, faces, guards
(cd src-tauri && cargo test -p klepsydra-fleet)   # fleet reader
bash scripts/build-windows.sh --check    # clippy and every Rust test, on Windows
bash scripts/visual-check.sh             # screenshots every state, the strip and wall included
```

The app crate needs WebKitGTK headers to compile on Linux, so in WSL only the
fleet crate's tests run locally; `--check` and CI cover the rest.
````

- [ ] **Step 4: Run the tests**

Run:

```bash
bash hooks/test_fleet.sh && node --test src/*.test.js
```

Expected: PASS: `110 passed, 0 failed` (104 without keryx), and 91 node tests.

- [ ] **Step 5: Rewrite IMPL.md, and add the ROADMAP entry and the skill-context facts**

Put today's date (`date +%F`) where the ROADMAP entry says `DATE`.

In `IMPL.md`, replace:

```markdown
# IMPL

Current slice: a gauge you can size, park and read from across a desk.

## Done
- Scroll on the grip zooms the whole gauge in 10% integer levels, 75% to
  236%, kept in `prefs.json` in the app data dir; a badge shows the size for
  800ms. Wheel maths in `src/zoom.js`: at most one step per event and per
  80ms, a notch-sized delta steps at once, smaller ones (touchpads)
  accumulate, and a fling cannot bank more than one step. 9 tests.
- Every CSS size is multiplied by `--scale`, and a test fails on any px size,
  or px token, outside the tokens that is not. The panel sets its own width and the window
  follows, as it already did for height. Bars 6px to 10px.
- `set_size` replaces `set_height`. A zoom pins the content under the live
  cursor (read when the resize runs, not when the wheel event fired), and an
  edge flush with the monitor stays flush; other size changes grow away from
  the nearest monitor edges; the first sizing after launch restores the last
  rect by its edges, so a gauge docked on the taskbar stays docked whatever
  its rows; the result is clamped to the monitor's full bounds. Move and
  resize are one SetWindowPos on Windows. On X11, where both land
  asynchronously, the rect last requested stands in for 500ms.
- Tray "Set home here" saves the window rect and its monitor (name, bounds,
  scale). "Reset position" finds that monitor by bounds, then name, then
  nearness; keeps home's corner nearest the edges, rescaled if the resolution
  changed; positions for the size the gauge will have at the destination's
  scale; and clamps. The move keeps the current size, since Windows rescales
  on arrival. A prefs file that exists but cannot be read is never
  overwritten. Placement maths in `src-tauri/src/geometry.rs`, std only. 21
  tests, run in CI.
- The grip rectangle travels with each resize, and the watcher re-reads its
  cached placement at once, so the next wheel notch still lands on the grip.
  It saves the position once moves settle, not per notch.

## Verified, not inferred
- Windows probe (synthetic wheel through the OS input stack, cursor parked
  over a throwaway build): every notch on the grip arrived (deltaY +-100,
  pixel mode); three on the bar passed through to the window beneath; 30-unit
  deltas arrived as 25px; Ctrl+wheel did not trigger WebView2's page zoom.
  Grip armed in 8-30ms (20 of 20), disarmed in 2-33ms.
- Geometry and zoom suites pass locally (`rustc --test`, `node --test`).

## Open
- Mixed-DPI monitors not exercised: a reset across scales relies on Windows
  rescaling the window on arrival.
- Not yet run on X11; scroll there is expected to work (wheel goes to the
  window under the pointer) but unverified.
- Depends on Windows' "Scroll inactive windows" setting (on by default).
- Track #2f2f2f against the panel is 1.3:1; the fill carries the contrast.

## Verify
    node --test src/*.test.js
    (cd src-tauri && cargo test && cargo clippy --all-targets -- -D warnings)
    bash scripts/visual-check.sh
```

with:

```markdown
# IMPL

Current slice: the fleet strip and card wall, so one glance shows how many
Claude Code sessions are up, where each works, which need AJ and why, and what
each was last asked and said.

## Done
- ✅ `hooks/klepsydra-fleet.sh`, async on nine events: one file per session,
  written only on change through a same-directory temp file, under one lock
  for all hook processes. Where comes from `.git` as keryx reads it; identity
  from keryx's hold on the Claude Code process. A need is cleared only by the
  asker's own tool. Dead sessions are pruned at start, inside an absolute
  `dev.ajsoftworks.klepsydra` dir only.
- ✅ Heartbeat from the status line, at most once per 10 s, and
  `refreshInterval: 30`.
- ✅ `src-tauri/fleet`, a crate free of Tauri: v1 parsing, silent after 90 s
  with no word, the hook's clock skew corrected from `written_at`, ordering,
  a notify watcher with a 5 s re-read, each bad file logged once, the hub.
- ✅ Strip in the gauge window, card wall made on the first click, Jump to
  terminal through UI Automation.
- ✅ Ten kourai portraits cast to keryx pool voices; Lorelei faces for all 54
  Kokoro voices and 24 fallbacks, each licensed in `LICENSES.json`.
- ✅ A guard for every rejected idea in the spec.

## Verified, not inferred
- 📋 Live check with eight sessions (README, Releasing).
- 📋 Jump to terminal takes the foreground after a click in the wall.
- 📋 A click on a portrait reaches the webview of the click-through window
  (the grip's wheel did; a click is new).
- 📋 Working set at 5 minutes and at 8 hours.

## Open
- The default display name (`my-app-3f`) reaches no hook and no status line,
  so a session with no voice and no name is named by its launch folder.
- A denied permission dismissed with Esc keeps "needs you" until the next
  prompt, its age showing.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
```

In `ROADMAP.md`, replace:

```markdown
panel dims only while it has nothing to show. Dimming was dropped because
the account you are not on is always hours old, and it has to stay legible.
```

with:

```markdown
panel dims only while it has nothing to show. Dimming was dropped because
the account you are not on is always hours old, and it has to stay legible.
The fleet strip holds to the same rule: every status shows its age, and a
session that stops answering reads as silent, never as working.
```

In `ROADMAP.md`, replace:

```markdown
- Prune session files nobody needs (every window ended, account dropped).
```

with:

```markdown
- Prune session files nobody needs (every window ended, account dropped).
- Run the fleet strip's live check with eight sessions and take its 8-hour
  memory reading (README, Releasing).
```

In `ROADMAP.md`, replace:

```markdown
- Optional: compact mode that drops the label and countdown to a bare bar.
```

with:

```markdown
- Optional: compact mode that drops the label and countdown to a bare bar.
- A product version of the fleet strip (heuresis verdict `later`, 2026-10-18).
```

In `ROADMAP.md`, replace:

```markdown
## Completed
```

with:

```markdown
## Completed
- DATE: Added the fleet strip and card wall. A hook writes one file per
  Claude Code session and the status line adds a heartbeat; the overlay
  shows a portrait per session beside the gauge, whoever needs AJ first,
  with a card wall a click away and a jump back to the session's terminal.
  Every status shows its age, and a session that stops answering reads as
  silent. Polling `claude agents --json` was ruled out: 0.38 to 0.57 s and
  about 170 MB per call (measured 2026-10-18).
```

In `.claude/skill-context.md`, replace:

```markdown
- language: JavaScript (frontend, `src/`), Rust (shell, `src-tauri/`), Bash
  (the hook and the build scripts)
```

with:

```markdown
- language: JavaScript (frontend, `src/`), Rust (shell, `src-tauri/`), Bash
  (the two hooks and the build scripts)
```

In `.claude/skill-context.md`, replace:

```markdown
- package_root: `src/` (frontend), `src-tauri/src/main.rs` (single Rust file)
```

with:

```markdown
- package_root: `src/` (frontend), `src-tauri/src/` (the Tauri shell),
  `src-tauri/fleet/` (the fleet reader, a workspace crate free of Tauri),
  `hooks/` (the fleet hook)
```

In `.claude/skill-context.md`, replace:

```markdown
  (`x11rb`) only for Linux. Windows development happens in WSL; `scripts/build-windows.sh` stages to native NTFS
  because Cargo on a `\\wsl$` UNC path is slow and prone to link failures.
```

with:

```markdown
  (`x11rb`) only for Linux. Windows development happens in WSL; `scripts/build-windows.sh` stages to native NTFS
  because Cargo on a `\\wsl$` UNC path is slow and prone to link failures.
  Jump to terminal (UI Automation) also compiles only for Windows, and WSL
  has no WebKitGTK headers, so the app crate is checked with
  `bash scripts/build-windows.sh --check`; the fleet crate tests anywhere.
```

In `.claude/skill-context.md`, replace:

```markdown
- `shellcheck statusline/*.sh scripts/*.sh`
- `cd src-tauri && cargo fmt --check`
- `cd src-tauri && cargo clippy --all-targets -- -D warnings`
```

with:

```markdown
- `shellcheck hooks/*.sh statusline/*.sh scripts/*.sh` (in WSL:
  `uvx --from shellcheck-py shellcheck ...`)
- `cd src-tauri && cargo fmt --all --check`
- `cd src-tauri && cargo clippy --workspace --all-targets -- -D warnings`
  (in WSL: `-p klepsydra-fleet`, and `bash scripts/build-windows.sh --check`)
```

In `.claude/skill-context.md`, after:

```markdown
  the multi-account and unwritable cases are built in the script itself.
```

insert:

```markdown
- `bash hooks/test_fleet.sh`: the fleet hook's states, where, identity,
  pruning (every refusal first) and the README settings block.
- `bash scripts/test_measure_memory.sh`: the release memory rule.
- `cd src-tauri && cargo test -p klepsydra-fleet`: the fleet reader.
```

In `.claude/skill-context.md`, replace:

```markdown
### do_not_run (interactive / long-running / platform-bound)

```

with:

```markdown
### do_not_run (interactive / long-running / platform-bound)

- `scripts/render-faces.sh`: regenerates the committed faces; needs npm
  network access and kourai-khryseai.
- `scripts/measure-memory.sh run`: takes 8 hours.
```

In `.claude/skill-context.md`, replace:

```markdown
- `Gauge logic + statusLine hook` runs on `ubuntu-latest` with Node 22: unit
  tests, hook tests, shellcheck, and the install-directory guard.
```

with:

```markdown
- `Gauge logic + statusLine hook` runs on `ubuntu-latest` with Node 24: unit
  tests, both hooks' tests, the release memory check's tests, shellcheck, and
  the install-directory guard.
```

In `.claude/skill-context.md`, replace:

```markdown
- include: `src/`, `src-tauri/src/`, `statusline/`, `scripts/`
```

with:

```markdown
- include: `src/`, `src-tauri/src/`, `src-tauri/fleet/src/`, `hooks/`,
  `statusline/`, `scripts/`
```

In `.claude/skill-context.md`, replace:

```markdown
- exclude: `node_modules/`, `src-tauri/target/`, `src-tauri/icons/`, `assets/`
```

with:

```markdown
- exclude: `node_modules/`, `src-tauri/target/`, `src-tauri/icons/`, `assets/`,
  `src/fleet/faces/` (generated by `scripts/render-faces.sh`)
```

In `.claude/skill-context.md`, replace:

```markdown
- `src/dev-fixture.json` is harness input for `visual-check.sh`, excluded from
  the Windows build on purpose.
```

with:

```markdown
- `src/dev-fixture.json` and `src/dev-fleet.json` are harness input for
  `visual-check.sh`, excluded from both builds on purpose.
```

- [ ] **Step 6: Check the docs for em-dashes and the whole suite once more**

Run:

```bash
! grep -nP '\x{2014}' README.md IMPL.md ROADMAP.md && bash hooks/test_fleet.sh && bash statusline/test_statusline.sh && bash scripts/test_measure_memory.sh && node --test src/*.test.js && (cd src-tauri && cargo test -p klepsydra-fleet)
```

Expected: No em-dash lines, and every suite passes.

- [ ] **Step 7: Commit**

```bash
git commit -m "docs(fleet): install block, strip and wall docs, and the guard that the guards see every fleet file" -- README.md IMPL.md ROADMAP.md .claude/skill-context.md hooks/test_fleet.sh src/guards.test.js
```

## Spec coverage

| Spec section | Tasks |
|---|---|
| Rejected ideas and their guards | 1 (static guards); 4 (identity while where moves, Stop and the transcript, PermissionRequest, not started); 8 and 11 (silent with its age); 11 (portrait the same in every state); 13 (one pulse, reduced motion); 17 (memory) |
| Fleet hook: events, where, identity, writes | 2, 3, 4 |
| Session file and beat file | 4, 6 |
| Fleet reader | 8, 9, 10 |
| Face strip | 14, 15 |
| Card wall and Jump to terminal | 12, 13 |
| Identity: faces and names | 7, 11 |
| Visual and interaction design | 11, 13, 15, 16 |
| Lifecycle and errors | 5, 8, 9, 15 |
| Spike results S1, S2, S3 | 12; 4; 8 |
| Testing, including the live check | every task; 17 |
