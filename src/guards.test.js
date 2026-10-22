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

const RUST = [
  ...filesUnder("src-tauri/src", [".rs"]),
  ...filesUnder("src-tauri/fleet/src", [".rs"]),
  ...filesUnder("src-tauri/fleet/examples", [".rs"]),
];
const FRONTEND = filesUnder("src", [".js", ".mjs", ".html"]).filter((f) => !f.endsWith(".test.js"));
const CSS = filesUnder("src", [".css"]);
const SHELL = [...filesUnder("hooks", [".sh", ".conf"]), ...filesUnder("statusline", [".sh"])];
const MANIFESTS = ["src-tauri/Cargo.toml", "src-tauri/fleet/Cargo.toml", "package.json"].filter((f) =>
  existsSync(join(ROOT, f)),
);
// Build script, capability grants and the Tauri config also decide what the app may start.
const CONFIG = [
  "src-tauri/build.rs",
  "src-tauri/tauri.conf.json",
  ...filesUnder("src-tauri/capabilities", [".json"]),
].filter((f) => existsSync(join(ROOT, f)));
const CARGO = MANIFESTS.filter((f) => f.endsWith("Cargo.toml"));

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
  /["']shell:/,
  /["']opener:/,
  /tauri[-_]plugin[-_]opener/,
];

/** Shell or opener plugins configured in a Tauri config; [] for text that is not JSON. */
export function processPlugins(text) {
  try {
    return Object.keys(JSON.parse(text).plugins ?? {}).filter((k) => /^(shell|opener)$/.test(k));
  } catch {
    return [];
  }
}
export const spawns = (text) => SPAWN.filter((re) => re.test(text)).map(String);

export const mentionsWsl = (text) => /wsl/i.test(text);

const SOUND = [
  /\bAudio\b/,
  /AudioContext/,
  /speechSynthesis/i,
  /<audio\b/i,
  /createElement\(\s*["']audio["']\s*\)/,
  /\.play\(/,
  /\bnew\s+Howl\b/,
  /\bnew\s+Notification\s*\(/,
  /HTMLMediaElement/,
];
export const makesSound = (text) => SOUND.filter((re) => re.test(text)).map(String);

// Native audio from Rust sources and Cargo manifests.
const NATIVE_SOUND = [
  /\b(rodio|cpal|kira|(snd)?PlaySound[AW]?|MessageBeep|Beep)\b/,
  /\b(waveOut\w*|mciSendString\w*|XAudio2\w*|IAudioClient\w*|IXAudio2\w*)\b/,
  /Media::(Audio|Playback|Core)\b|Win32_Media_Audio\b/,
];
export const makesNativeSound = (text) => NATIVE_SOUND.filter((re) => re.test(text)).map(String);

export const loopsForever = (css) => /\binfinite\b|iterations\s*:\s*Infinity/.test(stripCssComments(css));

const REDUCE = /@media(?![^{]*\bnot\b)[^{]*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)[^{]*\{/g;

/** Splits css into the bodies of its reduced-motion blocks and the rest. */
function splitReduce(css) {
  const bodies = [];
  let rest = "";
  let at = 0;
  for (const m of css.matchAll(REDUCE)) {
    if (m.index < at) continue;
    let depth = 1;
    let i = m.index + m[0].length;
    while (i < css.length && depth > 0) depth += css[i] === "{" ? 1 : css[i] === "}" ? -1 : 0, i++;
    bodies.push(css.slice(m.index + m[0].length, i - 1));
    rest += css.slice(at, m.index);
    at = i;
  }
  return { bodies, rest: rest + css.slice(at) };
}

// A selector starts after the last character that ends non-CSS text or a previous rule.
const rules = (css) =>
  [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].split(/[;>`'"]/).pop().trim(), decl: m[2] }));
const ANIMATES = /animation(-name)?\s*:\s*(?!none\b)[\w-]/;
const DISABLES = /animation(-name)?\s*:\s*none\b|animation-duration\s*:\s*0s\b|animation\s*:[^;}]*\b0s\b/;

/** CSS that animates must turn every animated selector off in a reduced-motion block. */
export function animatesWithoutReducedMotion(css) {
  const { bodies, rest } = splitReduce(stripCssComments(css));
  const animated = rules(rest).filter((r) => ANIMATES.test(r.decl));
  if (!animated.length) return /@keyframes\b/.test(rest) && !bodies.some((b) => DISABLES.test(b));
  const off = new Set(
    bodies.flatMap((b) => rules(b).filter((r) => DISABLES.test(r.decl)).flatMap((r) => r.sel.split(",").map((x) => x.trim()))),
  );
  return !animated.every((r) => r.sel.split(",").every((x) => off.has(x.trim()) || off.has("*")));
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
    missing: files.filter((f) => !named(licenses[f])).sort(),
    stale: Object.keys(licenses).filter((k) => !files.includes(k)).sort(),
  };
}

/** Labels of every window beyond "main": config entries, Rust builders and JS constructors ("?" when not literal). */
export function extraWindows({ conf = {}, rust = [], js = [] }) {
  const labels = (conf.app?.windows ?? []).map((w) => w.label).filter((l) => l !== "main");
  const site = "(?:WebviewWindowBuilder::(?:new|from_config)|WebviewWindow::builder|\\bWindowBuilder::new)\\b";
  for (const t of rust) {
    labels.push(...[...t.matchAll(new RegExp(site + '\\(\\s*[^,]+,\\s*"([^"]+)"', "g"))].map((m) => m[1]));
    const sites = (t.match(new RegExp(site, "g")) ?? []).length;
    const literal = (t.match(new RegExp(site + '\\(\\s*[^,]+,\\s*"', "g")) ?? []).length;
    labels.push(...Array(sites - literal).fill("?"));
  }
  for (const t of js) {
    labels.push(...[...t.matchAll(/new\s+WebviewWindow\(\s*["']([^"']+)["']/g)].map((m) => m[1]));
    const sites = (t.match(/new\s+WebviewWindow\(/g) ?? []).length;
    const literal = (t.match(/new\s+WebviewWindow\(\s*["']/g) ?? []).length;
    labels.push(...Array(sites - literal).fill("?"));
  }
  return labels;
}

/** True when more than one extra window exists, or the one extra is not the wall. */
export const tooManyWindows = (inputs) => {
  const extra = extraWindows(inputs);
  return extra.length > 1 || (extra.length === 1 && extra[0] !== "wall");
};

/** Calls or config that put a window other than the configured "main" always on top. */
export function alwaysOnTopOutsideMain({ conf = {}, code = [] }) {
  const hits = (conf.app?.windows ?? []).filter((w) => w.label !== "main" && w.alwaysOnTop === true).map((w) => w.label);
  for (const t of code) {
    hits.push(...(t.match(/(set_)?always_on_top\(\s*true\s*\)/g) ?? []));
    hits.push(...(t.match(/setAlwaysOnTop\(\s*(?!false\s*\))[^)]*\)/g) ?? []));
  }
  return hits;
}

test("the guards read real sources", () => {
  assert.ok(RUST.includes("src-tauri/src/main.rs"), "Rust sources not found");
  assert.ok(FRONTEND.includes("src/main.js"), "frontend sources not found");
  assert.ok(CSS.includes("src/style.css"), "CSS not found");
});

// The launcher is the one file allowed to start a process and name wsl.
const LAUNCHER = "src-tauri/src/launch.rs";

/** Ways the launcher could hand wsl.exe a shell, or hide which program it starts. */
const launcherHazards = (text) =>
  [/"--"/, /"-c"/, /^\s*use\b[^;]*\bas\s+\w+\s*;/m].filter((re) => re.test(text)).map(String);

// A dev-only binary that is never linked into the app. It may name the exit
// code type, which is the one thing here that is not starting a process.
const EXIT_CODE_BINARIES = ["src-tauri/fleet/src/bin/ledger-verify.rs"];
const withoutExitCode = (text) => text.replaceAll("std::process::ExitCode", "");

test("only the launcher starts a process", () => {
  assert.ok(RUST.includes(LAUNCHER), `${LAUNCHER} not found`);
  for (const f of [...RUST, ...FRONTEND, ...MANIFESTS, ...CONFIG].filter((f) => f !== LAUNCHER)) {
    const text = read(f);
    assert.deepEqual(spawns(EXIT_CODE_BINARIES.includes(f) ? withoutExitCode(text) : text), [], f);
  }
  for (const f of EXIT_CODE_BINARIES) assert.ok(RUST.includes(f), `${f} not found`);
});

test("the exit-code allowance covers nothing else that starts a process", () => {
  assert.deepEqual(spawns(withoutExitCode("use std::process::ExitCode;")), []);
  for (const planted of ["std::process::Command::new(x)", "use std::process::{Command, ExitCode};", "std::process::exit(1)"]) {
    assert.notDeepEqual(spawns(withoutExitCode(planted)), [], planted);
  }
});

test("the launcher starts only wsl.exe on Windows or /bin/bash on Linux, from their fixed paths", () => {
  const src = read(LAUNCHER);
  assert.deepEqual([...src.matchAll(/Command::new\(([^)]*)\)/g)].map((m) => m[1].trim()), ["WSL_EXE", "BASH_EXE"]);
  assert.match(src, /pub const WSL_EXE: &str = r"C:\\Windows\\System32\\wsl\.exe";/);
  assert.match(src, /pub const BASH_EXE: &str = "\/bin\/bash";/);
  assert.match(src, /creation_flags\(CREATE_NO_WINDOW\)/);
  assert.deepEqual(launcherHazards(src), []);
});

test("the script and the app name the fleet tab alike", () => {
  const rust = read(LAUNCHER).match(/pub const FLEET_TAB: &str = "([^"]+)";/);
  const sh = read("hooks/klepsydra-launch.sh").match(/^TAB_TITLE="([^"]+)"/m);
  assert.ok(rust && sh, "tab title constants not found");
  assert.equal(rust[1], sh[1]);
});

test("the script and the app name the fleet socket alike", () => {
  const rust = read(LAUNCHER).match(/pub const FLEET_SOCKET: &str = "([^"]+)";/);
  const sh = read("hooks/klepsydra-launch.sh").match(/^SOCKET_NAME=\$\{KLEPSYDRA_TMUX_SOCKET:-([^}]+)\}/m);
  assert.ok(rust && sh, "socket name constants not found");
  assert.equal(rust[1], sh[1]);
});

test("the launcher check catches a shell hop or an aliased Command", () => {
  for (const planted of ['.args(["-c", cmd])', "use std::process::Command as C;", 'a = ["--", "sh"];']) {
    assert.notDeepEqual(launcherHazards(planted), [], planted);
  }
  assert.deepEqual(launcherHazards('a = ["-e", "bash"]; use std::process::Command;'), []);
});

test("the spawn check catches each way of starting one", () => {
  for (const planted of [
    'std::process::Command::new("wsl.exe")',
    "use std::process;",
    'tauri-plugin-shell = "2"',
    "window.__TAURI__.shell.open(url)",
    'import { exec } from "node:child_process";',
    '{ "permissions": ["shell:allow-open"] }',
    'tauri-plugin-opener = "2"',
  ]) {
    assert.notDeepEqual(spawns(planted), [], planted);
  }
});

test("nothing but the launcher names wsl", () => {
  for (const f of [...RUST, ...FRONTEND, ...CONFIG].filter((f) => f !== LAUNCHER)) {
    assert.equal(mentionsWsl(read(f)), false, f);
  }
  assert.equal(mentionsWsl('let x = "C:\\\\Windows\\\\System32\\\\wsl.exe";'), true);
});

test("no shell or opener plugin is configured", () => {
  for (const f of CONFIG.filter((c) => c.endsWith("tauri.conf.json"))) assert.deepEqual(processPlugins(read(f)), [], f);
  assert.deepEqual(processPlugins('{"plugins":{"x":{"a":1},"shell":{}}}'), ["shell"]);
  assert.deepEqual(processPlugins('{"plugins":{"opener":null}}'), ["opener"]);
  assert.deepEqual(processPlugins('{"plugins":{"window-state":{}}}'), []);
});

// Ping is the one sound, and it plays only the chimes built into the binary.
const PING = "src-tauri/src/ping.rs";

test("only Ping makes a sound", () => {
  assert.ok(RUST.includes(PING), `${PING} not found`);
  for (const f of FRONTEND) assert.deepEqual(makesSound(read(f)), [], f);
  for (const f of RUST.filter((f) => f !== PING)) assert.deepEqual(makesNativeSound(read(f)), [], f);
  // The one audio feature Ping needs, and no audio crate.
  for (const f of CARGO) {
    const text = read(f).replace(/^\s*"Win32_Media_Audio",\s*$/m, "");
    assert.deepEqual(makesNativeSound(text), [], f);
  }
  for (const planted of [
    "new Audio(src)",
    "speechSynthesis.speak(u)",
    "<audio src=x>",
    "ctx = new AudioContext()",
    'document.createElement("audio")',
    "document.createElement('audio')",
    "clip.play()",
    "clip.play(0)",
    "new Howl({ src })",
    'new Notification("hi")',
    "el instanceof HTMLMediaElement",
  ]) {
    assert.notDeepEqual(makesSound(planted), [], planted);
  }
  for (const planted of ['rodio = "0.19"', "use cpal::traits::*;", "PlaySound(p, 0, 0)", "PlaySoundW(p, None, f)", "sndPlaySoundA(p, 0)", "MessageBeep(0)", "Beep(440, 100)",
    "waveOutOpen(&mut h)", "mciSendStringW(c)", "XAudio2Create(&mut x)", "use windows::Win32::Media::Audio::*;",
    "use windows::Media::Playback::MediaPlayer;", '"Win32_Media_Audio",']) {
    assert.notDeepEqual(makesNativeSound(planted), [], planted);
  }
});

/** Rust source with its comments removed, so a comment cannot satisfy a guard. */
const stripRustComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

test("Ping plays only its embedded chimes, and only the tray previews past the quiet check", () => {
  const code = stripRustComments(read(PING)).replace(/\s+/g, "");
  const calls = code.match(/(snd)?PlaySound[AW]?\(/g) ?? [];
  assert.deepEqual(calls, ["PlaySoundW("]);
  assert.ok(code.includes("PlaySoundW(PCWSTR(wav.as_ptr().cast()),None,SND_MEMORY|SND_ASYNC|SND_NODEFAULT,)"));
  assert.doesNotMatch(code, /SND_(FILENAME|ALIAS|RESOURCE|SYSTEM|LOOP|APPLICATION)|SND_FLAGS\(/);
  // Past that one call and its import, no other sound API.
  const rest = stripRustComments(read(PING)).replace(/\bPlaySoundW\b/g, "").replace(/Media::Audio\b/g, "");
  assert.deepEqual(makesNativeSound(rest), []);
  assert.deepEqual([...code.matchAll(/include_bytes!\("([^"]+)"\)/g)].map((m) => m[1]), [
    "../sounds/needs-you.wav",
    "../sounds/done.wav",
  ]);
  const previews = RUST.flatMap((f) => (stripRustComments(read(f)).match(/\bping::preview\(/g) ?? []).map(() => f));
  assert.deepEqual(previews, ["src-tauri/src/main.rs"]);
});

test("no animation runs forever, and every animation stops under reduced motion", () => {
  for (const f of [...CSS, ...FRONTEND]) {
    assert.equal(loopsForever(read(f)), false, f);
    assert.equal(animatesWithoutReducedMotion(read(f)), false, f);
  }
  assert.equal(loopsForever(".x { animation: pulse 1s infinite; }"), true);
  assert.equal(loopsForever("el.animate(k, { iterations: Infinity })"), true);
  assert.equal(loopsForever("/* infinite */ .x { color: red; }"), false);
  const off = "@media (prefers-reduced-motion: reduce) { .x { animation: none; } }";
  assert.equal(animatesWithoutReducedMotion(".x { animation: pulse 1s 1; }"), true);
  assert.equal(animatesWithoutReducedMotion(`.x { animation: pulse 1s 1; } ${off}`), false);
  assert.equal(animatesWithoutReducedMotion(`.x { animation: pulse 1s 1; } @media screen and (prefers-reduced-motion: reduce) { .x { animation-duration: 0s; } }`), false);
  assert.equal(animatesWithoutReducedMotion(`.x { animation: pulse 1s 1; } @media (prefers-reduced-motion: reduce) { .x { color: red; } }`), true);
  assert.equal(animatesWithoutReducedMotion(`.x { animation: pulse 1s 1; } @media (prefers-reduced-motion: reduce) { .y { animation: none; } }`), true);
  assert.equal(animatesWithoutReducedMotion(`@keyframes p { to { opacity: 0; } } ${off}`), false);
  assert.equal(animatesWithoutReducedMotion(`<style>.x { animation: pulse 1s 1; }</style>`), true);
  assert.equal(animatesWithoutReducedMotion(`<html><head><style>.x{animation:p 1s 1} @media (prefers-reduced-motion: reduce){.x{animation:none}}</style>`), false);
  assert.equal(animatesWithoutReducedMotion("const css = `.x{animation:p 1s 1} @media (prefers-reduced-motion: reduce){.x{animation:none}}`;"), false);
  assert.equal(animatesWithoutReducedMotion(`@media (prefers-reduced-motion: reduce){.x{animation:none}} .x{animation:p 1s 1}`), false);
  assert.equal(animatesWithoutReducedMotion(`.x{animation:p 1s 1} @media (not (prefers-reduced-motion: reduce)){.x{animation:none}}`), true);
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

const MAIN = { label: "main", alwaysOnTop: true };
const confWith = (...extra) => ({ app: { windows: [MAIN, ...extra] } });

test("at most one extra window exists, and it is the wall", () => {
  const conf = JSON.parse(read("src-tauri/tauri.conf.json"));
  const inputs = { conf, rust: RUST.map(read), js: FRONTEND.map(read) };
  assert.deepEqual(extraWindows(inputs), ["wall"]);
  assert.equal(tooManyWindows(inputs), false);

  const wall = 'WebviewWindowBuilder::new(&app, "wall", url)';
  const other = 'WebviewWindowBuilder::new(&app, "other", url)';
  assert.equal(tooManyWindows({ conf: confWith(), rust: [wall] }), false);
  assert.equal(tooManyWindows({ conf: confWith({ label: "wall" }) }), false);
  assert.equal(tooManyWindows({ conf: confWith(), js: ['new WebviewWindow("wall", {})'] }), false);
  assert.equal(tooManyWindows({ conf: confWith(), rust: [other] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), rust: [wall, wall] }), true);
  assert.equal(tooManyWindows({ conf: confWith({ label: "wall" }), rust: [wall] }), true);
  assert.equal(tooManyWindows({ conf: confWith({ label: "second" }) }), true);
  assert.equal(tooManyWindows({ conf: confWith(), rust: ["WebviewWindowBuilder::from_config(&app, cfg)"] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), js: ["new WebviewWindow(label, {})"] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), rust: ['WebviewWindow::builder(&app, "wall", url)'] }), false);
  assert.equal(tooManyWindows({ conf: confWith(), rust: ['WebviewWindow::builder(&app, "other", url)'] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), rust: ['WindowBuilder::new(&app, "other")'] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), rust: [wall, 'WindowBuilder::new(&app, "wall")'] }), true);
  assert.equal(tooManyWindows({ conf: confWith(), js: ['new WebviewWindow("x", {})'] }), true);
});

test("nothing but the configured main window is always on top", () => {
  const conf = JSON.parse(read("src-tauri/tauri.conf.json"));
  assert.deepEqual(alwaysOnTopOutsideMain({ conf, code: [...RUST, ...FRONTEND].map(read) }), []);
  assert.deepEqual(alwaysOnTopOutsideMain({ conf: confWith({ label: "wall" }), code: [] }), []);
  for (const code of [
    "w.setAlwaysOnTop(true)",
    "w.setAlwaysOnTop( true )",
    "w.setAlwaysOnTop(flag)",
    "b.always_on_top(true)",
    "w.set_always_on_top( true )",
    'WebviewWindowBuilder::new(&app, "wall", url)\n  .always_on_top(true)',
  ]) {
    assert.notDeepEqual(alwaysOnTopOutsideMain({ conf: confWith(), code: [code] }), [], code);
  }
  assert.notDeepEqual(alwaysOnTopOutsideMain({ conf: confWith({ label: "wall", alwaysOnTop: true }) }), []);
  assert.deepEqual(alwaysOnTopOutsideMain({ conf: confWith(), code: ["w.setAlwaysOnTop(false)"] }), []);
  assert.deepEqual(JSON.parse(read("src-tauri/tauri.conf.json")).app.windows.map((w) => w.label), ["main"]);
});

test("harness input never ships", async () => {
  const gitignore = read(".gitignore");
  const windows = read("scripts/build-windows.sh");
  const linux = read("scripts/build-linux.sh");
  for (const f of ["src/dev-fixture.json", "src/dev-fleet.json"]) {
    assert.match(gitignore, new RegExp(`^${f}$`, "m"), `.gitignore: ${f}`);
    assert.ok(windows.includes(`--exclude '${f}'`), `build-windows.sh: ${f}`);
    assert.ok(linux.includes(f), `build-linux.sh: ${f}`);
  }
  // The ?demo sample lives outside frontendDist, so neither build can bundle it.
  globalThis.window ??= {};
  const dist = join(ROOT, "src-tauri", JSON.parse(read("src-tauri/tauri.conf.json")).build.frontendDist);
  const demo = (await import("./fleet/feed.js")).devSnapshotUrl(false, "?demo");
  const onDisk = join(ROOT, "src", demo);
  assert.ok(existsSync(onDisk), `${demo} exists`);
  assert.ok(relative(dist, onDisk).startsWith(".."), `${demo} is outside ${dist}`);
  assert.deepEqual(filesUnder("src", [".json"]).filter((f) => /demo/.test(f)), [], "no demo snapshot under src/");
});

test("the hooks make no sound", () => {
  for (const f of SHELL) assert.doesNotMatch(read(f), /\b(paplay|aplay|afplay|espeak|ffplay|mpv|speaker-test|beep)\b/, f);
});

/** Files the guards need not read, each with its reason; a prefix ending in "/" covers a folder. */
const NOT_SCANNED = {
  "hooks/fixtures/": "recorded hook payloads, data",
  "statusline/fixtures/": "recorded status line payloads, data",
  "src-tauri/fleet/tests/fixtures/": "recorded OTLP exports, transcripts and ledger days, data",
  "src-tauri/fleet/tests/ledger_verify.rs": "runs the dev-only ledger-verify binary; a test, never in the app",
  "src/fleet/faces/": "generated portraits and their license table, data",
  "src/fleet/fonts/": "the nameplate's bundled typeface and its licence, data",
  "src/fleet/cast.json": "voice to portrait table, data",
  "src-tauri/fleet/Cargo.toml": "scanned as a manifest",
};

/** Every file (any extension) a fleet change can add, found without the guards' own walks. */
function fleetFiles(root) {
  const all = (dir, skip = []) => {
    const abs = join(root, dir);
    if (!existsSync(abs)) return [];
    return readdirSync(abs, { recursive: true })
      .map((f) => f.split(sep).join("/"))
      .filter((f) => !skip.some((d) => f === d || f.startsWith(`${d}/`)))
      .filter((f) => statSync(join(abs, f)).isFile())
      .map((f) => `${dir}/${f}`);
  };
  const named = ["src-tauri/src/fleet.rs", "src-tauri/src/jump.rs"].filter((f) => existsSync(join(root, f)));
  const pages = all("src").filter((f) => /^src\/[^/]+\.html$/.test(f));
  return [
    ...all("src-tauri/fleet", ["target"]),
    ...all("src/fleet"),
    ...all("hooks"),
    ...all("statusline"),
    ...named,
    ...pages,
  ];
}

/** Fleet files outside `scanned` that no rule or allowlist entry excuses. */
export function unreached(root, scanned) {
  const seen = new Set(scanned);
  return fleetFiles(root).filter(
    (f) =>
      !seen.has(f) &&
      !f.endsWith(".test.js") &&
      !Object.keys(NOT_SCANNED).some((k) => (k.endsWith("/") ? f.startsWith(k) : f === k)),
  );
}

test("the guards reach every fleet source", () => {
  assert.deepEqual(unreached(ROOT, [...RUST, ...FRONTEND, ...CSS, ...SHELL, ...CARGO]), []);
  const files = fleetFiles(ROOT);
  for (const f of ["src-tauri/fleet/src/hub.rs", "src-tauri/src/fleet.rs", "src-tauri/src/jump.rs", "src/fleet/strip.js", "src/wall.html", "hooks/klepsydra-fleet.sh"]) {
    assert.ok(files.includes(f), `${f} is not enumerated`);
  }
});

test("the reach check reports a planted unscanned file and excuses a test file", () => {
  const root = mkdtempSync(join(tmpdir(), "reach-"));
  const put = (f) => {
    mkdirSync(join(root, f, ".."), { recursive: true });
    writeFileSync(join(root, f), "x\n");
  };
  const scanned = () =>
    [
      ...filesUnder("src-tauri/src", [".rs"], root),
      ...filesUnder("src-tauri/fleet/src", [".rs"], root),
      ...filesUnder("src", [".js", ".mjs", ".html"], root).filter((f) => !f.endsWith(".test.js")),
      ...filesUnder("src", [".css"], root),
      ...filesUnder("hooks", [".sh", ".conf"], root),
      ...filesUnder("statusline", [".sh"], root),
    ];
  put("src-tauri/fleet/src/ok.rs");
  put("src/fleet/zz.test.js");
  put("src-tauri/fleet/target/debug/junk.rs");
  put("hooks/fixtures/a.json");
  assert.deepEqual(unreached(root, scanned()), []);
  for (const f of ["src-tauri/fleet/src/zz.rs", "src/fleet/zz.mjs", "src/zz.html", "src/fleet/zz.ts", "hooks/zz.bash", "src-tauri/fleet/build.rs"]) put(f);
  assert.deepEqual(unreached(root, scanned()).sort(), ["hooks/zz.bash", "src-tauri/fleet/build.rs", "src/fleet/zz.ts"]);
  // Nothing scanned: every planted file is reported, the test file and fixtures are not.
  const none = unreached(root, []);
  for (const f of ["src-tauri/fleet/src/zz.rs", "src/fleet/zz.mjs", "src/zz.html", "src-tauri/fleet/src/ok.rs"]) assert.ok(none.includes(f), f);
  assert.ok(!none.some((f) => f.endsWith(".test.js") || f.includes("/target/") || f.includes("fixtures/")));
});

test("the wall's Jump passes the session id along with its name", () => {
  const src = read("src/fleet/wall.js");
  assert.match(src, /invoke\("jump_to_terminal", \{ id: button\.dataset\.id, name: button\.dataset\.name \}\)/);
});

test("the wall has a New session button that calls the launcher", () => {
  assert.match(read("src/wall.html"), /<button type="button" id="new-session">\+ New session<\/button>/);
  assert.match(read("src/wall.html"), /<span id="new-note" role="status"><\/span>/);
  assert.match(read("src/fleet/wall.js"), /invoke\("launch_session"\)/);
  assert.match(read("src/fleet/wall.js"), /newButton\.hidden = !inTauri/);
  const html = read("src/wall.html");
  assert.ok(html.indexOf("</div>", html.indexOf('class="bar"')) < html.indexOf('<main id="wall"'));

  assert.match(html, /<div class="tally" role="group" aria-label="Session counts">/);
  assert.match(html, />Open terminal</);
});

test("the CSP lets images, and nothing else, come from a data URL", () => {
  const csp = JSON.parse(read("src-tauri/tauri.conf.json")).app.security.csp;
  const directives = Object.fromEntries(csp.split(";").map((d) => d.trim().split(/\s+/)).map(([k, ...v]) => [k, v]));
  assert.deepEqual(directives["default-src"], ["'self'"]);
  assert.deepEqual(directives["img-src"], ["'self'", "data:"], "the medallion faces are data URLs");
  for (const [k, v] of Object.entries(directives)) if (k !== "img-src") assert.ok(!v.includes("data:"), k);
});

test("the demo feed is never reachable inside the app", async () => {
  globalThis.window ??= {};
  const { devSnapshotUrl } = await import("./fleet/feed.js");
  for (const search of ["?demo", "?demo=1&focus=x", ""]) assert.equal(devSnapshotUrl(true, search), null, search);
  assert.equal(devSnapshotUrl(false, "?demo"), "../scripts/fixtures/fleet-demo.json");
  assert.equal(devSnapshotUrl(false, "?focus=x"), "./dev-fleet.json");
  const feed = read("src/fleet/feed.js");
  assert.equal(feed.match(/fleet-demo\.json/g).length, 1, "one way to the demo");
  const { demoCount } = await import("./fleet/feed.js");
  assert.equal(demoCount("?demo=8"), 8);
  for (const search of ["?demo", "?demo=0", "?demo=-2", "?demo=x", "?demo=2.5", ""]) assert.equal(demoCount(search), Infinity, search);
  assert.match(feed, /devSnapshotUrl\(inTauri, location\.search\)/);
});

test("wall buttons disable by aria-disabled, never by the disabled property, and paint leaves the note alone", () => {
  const src = read("src/fleet/wall.js");
  assert.doesNotMatch(src, /\.disabled\s*=/);
  const paint = src.slice(src.indexOf("function paint("), src.indexOf("\nfunction render("));
  assert.ok(paint.length > 100, "paint found");
  assert.doesNotMatch(paint, /note/);
});

test("Open terminal's disabled reason shows as text in the footer, apart from the note", () => {
  const html = read("src/wall.html");
  const footer = html.slice(html.indexOf('<footer class="actions">'), html.indexOf("</footer>"));
  assert.match(footer, /<span class="why"( [^>]*)?><\/span>/, "a footer element of its own");
  assert.doesNotMatch(footer, /class="note why"|class="why note"/);
  const src = read("src/fleet/wall.js");
  const paint = src.slice(src.indexOf("function paint("), src.indexOf("\nfunction render("));
  assert.match(paint, /show\(el\.querySelector\("\.why"\), c\.jump\.why\)/, "painted as text from the card");
  assert.match(paint, /jump\.title = c\.jump\.why \?\? ""/, "the title stays");
  assert.match(read("src/fleet/wall.css"), /\.actions \.why \{[^}]*font-size/);
});

test("the wall slides a reorder inside a feature-detected view transition, else updates directly", () => {
  const src = read("src/fleet/wall.js");
  assert.match(src, /matchMedia\("\(prefers-reduced-motion: reduce\)"\)\.matches/);
  assert.match(src, /typeof document\.startViewTransition === "function"/);
  assert.match(src, /document\.startViewTransition\(\(\) => sync\(\)\)/);
  assert.match(src, /shouldSlide\(was,/);
  assert.match(src, /style\.viewTransitionName = transitionName\(c\.id\)/);
  assert.match(src, /started\.has\(el\.dataset\.key\) && !reducedMotion\(\)/, "no pulse class under reduced motion");
  assert.match(src, /startedNeeding\(/);
});

test("the compact card's +N chip names its repos in its accessible name and on hover", () => {
  assert.match(read("src/wall.html"), /<span class="also-more" role="img" hidden><\/span>/);
  const src = read("src/fleet/wall.js");
  assert.match(src, /show\(more, c\.alsoChip\?\.text\)/);
  assert.match(src, /more\.title = c\.alsoChip\?\.label \?\? ""/);
  assert.match(src, /more\.setAttribute\("aria-label", c\.alsoChip\.label\)/);
});

test("the density control is a labelled radio group, Auto checked until the saved choice loads", () => {
  const html = read("src/wall.html");
  const picker = html.slice(html.indexOf('<fieldset class="density">'), html.indexOf("</fieldset>"));
  assert.match(picker, /<legend class="visually-hidden">Card density<\/legend>/);
  const values = [...picker.matchAll(/<input type="radio" name="density" value="(\w+)"( checked)? \/>/g)].map((m) => m[1] + (m[2] ?? ""));
  assert.deepEqual(values, ["auto checked", "comfortable", "compact"]);
  const css = read("src/fleet/wall.css");
  assert.match(css, /\.density label:has\(input:focus-visible\) \{ outline: 2px solid var\(--card-focus\)/, "a keyboard user sees where they are");
});

test("the ring key draws aria-hidden arcs and gives screen readers one sentence", () => {
  const html = read("src/wall.html");
  const key = html.slice(html.indexOf('<p class="ring-key" hidden>'), html.indexOf("</p>", html.indexOf('<p class="ring-key"')));
  assert.match(key, /<span class="visually-hidden">Ring key: thick arc, subagent; thin arc, background shell\.<\/span>/);
  const keys = [...key.matchAll(/<span class="key" aria-hidden="true"><svg[^>]*><path class="(\w+)"[^>]*\/><\/svg>(\w+)<\/span>/g)].map((m) => `${m[1]}:${m[2]}`);
  assert.deepEqual(keys, ["agent:agent", "shell:shell"]);
  assert.ok(html.indexOf('class="tally"') < html.indexOf('class="ring-key"'), "beside the tally");
  assert.match(read("src/fleet/wall.js"), /ringKey\.hidden = !showsRingKey\(cards\)/);
  assert.match(html, /<title>Background work: one arc per subagent \(thick\) or shell \(thin\)<\/title>/);
});

test("the ledger sample is never reachable inside the app, and the drawer reads the ledger through one command", async () => {
  globalThis.window ??= {};
  const feed = await import("./fleet/feed.js");
  for (const search of ["?demo", "?demo=1", ""]) assert.equal(feed.demoLedgerUrl(true, search), null, search);
  assert.equal(feed.demoLedgerUrl(false, "?demo"), "../scripts/fixtures/ledger-demo.json");
  assert.equal(feed.demoLedgerUrl(false, "?focus=x"), null, "only with ?demo");
  const src = read("src/fleet/feed.js");
  assert.equal(src.match(/ledger-demo\.json/g).length, 1, "one way to the ledger sample");
  assert.match(src, /invoke\("ledger_today", \{ session \}\)/);
  assert.ok(existsSync(join(ROOT, "scripts/fixtures/ledger-demo.json")));
});

test("the ledger drawer is a labelled modal dialog with a Close button that links nowhere", () => {
  const html = read("src/wall.html");
  const start = html.indexOf('<dialog id="ledger"');
  const dialog = html.slice(start, html.indexOf("</dialog>", start));
  assert.match(dialog, /^<dialog id="ledger" class="ledger" aria-labelledby="ledger-title">/);
  assert.match(dialog, /<h2 id="ledger-title" tabindex="-1" autofocus>Ledger<\/h2>/);
  assert.match(dialog, /<button type="button" class="ledger-close">Close<\/button>/);
  assert.match(html, /<button type="button" id="ledger-open" aria-haspopup="dialog">Ledger<\/button>/);
  const drawer = read("src/fleet/drawer.js");
  assert.match(drawer, /dialog\.showModal\(\)/, "modal, so the wall behind it is inert");
  assert.match(drawer, /back\.focus\(\)/, "focus returns explicitly");
  assert.doesNotMatch(drawer, /innerHTML|insertAdjacentHTML|href|<a\b|https?:/, "text nodes only, and no link to follow");
  assert.doesNotMatch(dialog, /<a\b|href/);
});
