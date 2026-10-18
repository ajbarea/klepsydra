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
  /"plugins"\s*:\s*\{[^}]*"(shell|opener)"/,
];
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
const NATIVE_SOUND = [/\b(rodio|cpal|PlaySound|MessageBeep|Beep)\b/];
export const makesNativeSound = (text) => NATIVE_SOUND.filter((re) => re.test(text)).map(String);

export const loopsForever = (css) => /\binfinite\b|iterations\s*:\s*Infinity/.test(stripCssComments(css));

const REDUCE = /@media[^{]*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)[^{]*\{/g;

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

const rules = (css) => [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].trim(), decl: m[2] }));
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
  for (const t of rust) {
    labels.push(...[...t.matchAll(/WebviewWindowBuilder::new\(\s*[^,]+,\s*"([^"]+)"/g)].map((m) => m[1]));
    const literal = (t.match(/WebviewWindowBuilder::new\(\s*[^,]+,\s*"/g) ?? []).length;
    const sites = (t.match(/WebviewWindowBuilder::(new|from_config)\b/g) ?? []).length;
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
  for (const t of code) hits.push(...(t.match(/(setAlwaysOnTop|always_on_top)\(\s*true\s*\)/g) ?? []));
  return hits;
}

test("the guards read real sources", () => {
  assert.ok(RUST.includes("src-tauri/src/main.rs"), "Rust sources not found");
  assert.ok(FRONTEND.includes("src/main.js"), "frontend sources not found");
  assert.ok(CSS.includes("src/style.css"), "CSS not found");
});

test("nothing starts a process", () => {
  for (const f of [...RUST, ...FRONTEND, ...MANIFESTS, ...CONFIG]) assert.deepEqual(spawns(read(f)), [], f);
});

test("the spawn check catches each way of starting one", () => {
  for (const planted of [
    'std::process::Command::new("wsl.exe")',
    "use std::process;",
    'tauri-plugin-shell = "2"',
    "window.__TAURI__.shell.open(url)",
    'import { exec } from "node:child_process";',
    '{ "permissions": ["shell:allow-open"] }',
    '{ "plugins": { "shell": {} } }',
    'tauri-plugin-opener = "2"',
  ]) {
    assert.notDeepEqual(spawns(planted), [], planted);
  }
});

test("nothing names wsl", () => {
  for (const f of [...RUST, ...FRONTEND, ...CONFIG]) assert.equal(mentionsWsl(read(f)), false, f);
  assert.equal(mentionsWsl('let x = "C:\\\\Windows\\\\System32\\\\wsl.exe";'), true);
});

test("the app makes no sound", () => {
  for (const f of FRONTEND) assert.deepEqual(makesSound(read(f)), [], f);
  for (const f of [...RUST, ...CARGO]) assert.deepEqual(makesNativeSound(read(f)), [], f);
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
  for (const planted of ['rodio = "0.19"', "use cpal::traits::*;", "PlaySound(p, 0, 0)", "MessageBeep(0)", "Beep(440, 100)"]) {
    assert.notDeepEqual(makesNativeSound(planted), [], planted);
  }
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
  assert.deepEqual(extraWindows(inputs), []);
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
  assert.equal(tooManyWindows({ conf: confWith(), js: ['new WebviewWindow("x", {})'] }), true);
});

test("nothing but the configured main window is always on top", () => {
  const conf = JSON.parse(read("src-tauri/tauri.conf.json"));
  assert.deepEqual(alwaysOnTopOutsideMain({ conf, code: [...RUST, ...FRONTEND].map(read) }), []);
  assert.deepEqual(alwaysOnTopOutsideMain({ conf: confWith({ label: "wall" }), code: [] }), []);
  for (const code of [
    "w.setAlwaysOnTop(true)",
    "w.setAlwaysOnTop( true )",
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
