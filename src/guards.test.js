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
