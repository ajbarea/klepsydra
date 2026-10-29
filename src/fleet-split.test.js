import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { SPLIT_LABEL, wireSplit } from "./fleet/split.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const settle = () => new Promise((r) => setImmediate(r));

// The toggle and its note: just what split.js touches.
function control() {
  const listeners = [];
  return {
    hidden: false,
    textContent: SPLIT_LABEL,
    dataset: {},
    attrs: { "aria-pressed": "false" },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return this.attrs[k] ?? null; },
    removeAttribute(k) { delete this.attrs[k]; },
    addEventListener(type, f) { if (type === "click") listeners.push(f); },
    click() { for (const f of listeners) f({}); },
  };
}
const pressed = (b) => b.getAttribute("aria-pressed") === "true";

/** An app stand-in: `saved` answers get_split_mode, `answer(on)` set_split_mode; every call is recorded. */
function app({ saved = Promise.resolve(false), answer = async () => "ok" } = {}) {
  const calls = [];
  const invoke = (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "get_split_mode") return saved;
    if (cmd === "set_split_mode") return answer(args.on);
    return Promise.reject(new Error(`unexpected ${cmd}`));
  };
  return { calls, invoke };
}

test("the toggle is a labelled toggle button, off and hidden until the saved choice loads", async () => {
  const html = read("./wall.html");
  const split = html.match(/<button type="button" id="split" aria-pressed="false" title="[^"]+" hidden>(.*?)<\/button>/);
  assert.ok(split, "a toggle button, off and hidden in the markup");
  assert.equal(split[1].replace(/<[^>]+>/g, ""), SPLIT_LABEL, "its name, part of it visually hidden");
  assert.match(split[1], /^Split<span class="visually-hidden">/, "the visible word starts the name (WCAG 2.5.3)");
  assert.match(html, /<span id="split-note" role="status"><\/span>/);
  assert.equal(SPLIT_LABEL, "Split with terminal");

  const button = control();
  const note = { textContent: "", title: "" };
  let load;
  const { calls, invoke } = app({ saved: new Promise((r) => { load = r; }) });
  const ready = wireSplit({ button, note, invoke, app: true });
  assert.ok(button.hidden, "hidden until the app says split mode is available");
  assert.ok(!pressed(button), "off by default");
  load(false);
  await ready;
  assert.ok(!button.hidden);
  assert.ok(!pressed(button), "a saved off stays off");
  assert.deepEqual(calls, [["get_split_mode", undefined]], "nothing moves for a saved off");
  assert.equal(button.textContent, SPLIT_LABEL, "the name never changes with the state");
});

test("a saved on is applied once the wall loads, and the toggle turns on when it lands", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { calls, invoke } = app({ saved: Promise.resolve(true), answer: async () => "Split: the wall on the left, the fleet terminal on the right." });
  await wireSplit({ button, note, invoke, app: true });
  await settle();
  assert.deepEqual(calls, [["get_split_mode", undefined], ["set_split_mode", { on: true }]]);
  assert.ok(pressed(button));
  assert.equal(note.textContent, "Split: the wall on the left, the fleet terminal on the right.");
});

test("a click turns split on, a second click turns it off, each through the command", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { calls, invoke } = app();
  await wireSplit({ button, note, invoke, app: true });
  button.click();
  await settle();
  assert.ok(pressed(button));
  button.click();
  await settle();
  assert.ok(!pressed(button));
  assert.deepEqual(calls.slice(1), [["set_split_mode", { on: true }], ["set_split_mode", { on: false }]]);
});

test("with the fleet terminal not open the note says so and the toggle stays off", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const notOpen = "The fleet terminal is not open, so nothing moved. Open it with + New session, then turn Split on.";
  const { invoke } = app({ answer: async () => { throw notOpen; } });
  await wireSplit({ button, note, invoke, app: true });
  button.click();
  await settle();
  assert.ok(!pressed(button), "the toggle never shows a split that did not happen");
  assert.equal(note.textContent, notOpen);
  assert.match(read("../src-tauri/src/split.rs"), new RegExp(`pub const NOT_OPEN: &str =\\s*"${notOpen.replace(/[.+]/g, "\\$&")}";`), "the note is the app's own sentence");
});

test("a saved on whose terminal is not open leaves the toggle off and says why", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { invoke } = app({ saved: Promise.resolve(true), answer: async () => { throw "The fleet terminal is not open."; } });
  await wireSplit({ button, note, invoke, app: true });
  await settle();
  assert.ok(!button.hidden);
  assert.ok(!pressed(button));
  assert.equal(note.textContent, "The fleet terminal is not open.");
});

test("a click while a call runs is ignored, so one press is one move", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  let finish;
  const { calls, invoke } = app({ answer: () => new Promise((r) => { finish = r; }) });
  await wireSplit({ button, note, invoke, app: true });
  button.click();
  button.click();
  finish("ok");
  await settle();
  assert.equal(calls.filter(([c]) => c === "set_split_mode").length, 1);
  assert.ok(pressed(button));
});

test("off Windows, and outside the app, the toggle stays hidden", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { calls, invoke } = app({ saved: Promise.reject("Split mode works on Windows only.") });
  await wireSplit({ button, note, invoke, app: true });
  assert.ok(button.hidden);
  const browser = control();
  const none = app();
  await wireSplit({ button: browser, note, invoke: none.invoke, app: false });
  assert.ok(browser.hidden);
  assert.deepEqual(none.calls, [], "a browser asks the app nothing");
  assert.equal(calls.length, 1);
});

test("the wall wires the toggle, and the app registers both commands", () => {
  const wall = read("./fleet/wall.js");
  assert.match(wall, /wireSplit\(\{ button: document\.getElementById\("split"\), note: document\.getElementById\("split-note"\), invoke: tauri, app: inTauri, follow \}\)/);
  assert.match(wall, /import \{ follow \} from "\.\.\/ipc\.js";/);
  const main = read("../src-tauri/src/main.rs");
  assert.match(main, /split::get_split_mode,\s*split::set_split_mode,\s*split::split_subscribe,/);
  assert.match(main, /\.manage\(split::Follow::default\(\)\)/);
  const rs = read("../src-tauri/src/split.rs");
  assert.match(rs, /pub const SPLIT_KEY: &str = "wall_split";/);
  assert.match(rs, /crate::write_pref\(&app, SPLIT_KEY, Value::Bool\(saved_on\(on, said\.is_ok\(\)\)\)\);/, "saved the way wall density is, on only once a split lands");
  assert.match(rs, /crate::read_prefs\(&app\)/);
});

/** A follow stand-in: records each subscription; `send(m)` pushes m to the last one. */
function follower() {
  const subs = [];
  const follow = (cmd, onMessage) => {
    subs.push([cmd, onMessage]);
    return Promise.resolve();
  };
  return { subs, follow, send: (m) => subs.at(-1)[1](m) };
}

test("when a window leaves the split the toggle turns off, the note says why, and nothing is called", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { calls, invoke } = app({ saved: Promise.resolve(true) });
  const f = follower();
  await wireSplit({ button, note, invoke, app: true, follow: f.follow });
  await settle();
  assert.deepEqual(f.subs.map(([c]) => c), ["split_subscribe"], "subscribed once, after the saved choice loads");
  assert.ok(pressed(button));
  const said = "Split off: the fleet terminal was maximized, so both windows stay where they are.";
  f.send({ on: false, note: said });
  assert.ok(!pressed(button), "unchecked");
  assert.equal(note.textContent, said);
  assert.deepEqual(calls.map(([c]) => c), ["get_split_mode", "set_split_mode"], "no put-back is asked for");
  button.click();
  await settle();
  assert.ok(pressed(button), "one click snaps them back");
  assert.deepEqual(calls.at(-1), ["set_split_mode", { on: true }]);
});

test("#182: when AJ snaps both windows into the split the toggle turns on and the note says so, with nothing called", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const { calls, invoke } = app({ saved: Promise.resolve(false) });
  const f = follower();
  await wireSplit({ button, note, invoke, app: true, follow: f.follow });
  await settle();
  assert.ok(!pressed(button));
  const said = "Split on: the wall and the fleet terminal were snapped side by side.";
  f.send({ on: true, note: said });
  assert.ok(pressed(button), "checked");
  assert.equal(note.textContent, said);
  assert.deepEqual(calls.map(([c]) => c), ["get_split_mode"], "nothing moves: the app already watches the split");
  button.click();
  await settle();
  assert.deepEqual(calls.at(-1), ["set_split_mode", { on: false }], "one click turns it off");
});

test("a message that is neither a leave nor a snap changes nothing, and outside Windows nothing subscribes", async () => {
  const button = control();
  const note = { textContent: "", title: "" };
  const f = follower();
  await wireSplit({ button, note, invoke: app({ saved: Promise.resolve(true) }).invoke, app: true, follow: f.follow });
  await settle();
  for (const m of [null, {}, { on: "no", note: "x" }, "off"]) f.send(m);
  assert.ok(pressed(button));
  const g = follower();
  await wireSplit({ button: control(), note, invoke: app({ saved: Promise.reject("Split mode works on Windows only.") }).invoke, app: true, follow: g.follow });
  assert.deepEqual(g.subs, [], "the toggle stays hidden, so nothing listens");
});

test("the app watches from each split, stops at each unsplit and at exit, and wires the leave to the wall", () => {
  const rs = code(read("../src-tauri/src/split.rs"));
  const fn = (name) => rs.slice(rs.indexOf(`pub fn ${name}(`), rs.indexOf("\n    }\n", rs.indexOf(`pub fn ${name}(`)));
  const split = fn("split");
  assert.match(split, /^pub fn split\(wall: isize\) -> Result<String, String> \{\s*let generation = watch::disarm\(\);/, "a split ends the last watch before it moves anything");
  assert.match(split, /watch::arm\(generation, wall, terminal\);\s*Ok\(ON\.into\(\)\)/, "and watches only once it has landed");
  assert.match(fn("unsplit"), /^pub fn unsplit\(wall: isize\) -> String \{\s*watch::disarm\(\);\s*if restore\(take\(\), wall\)/, "an unsplit stops watching before it puts anything back");
  assert.match(rs, /win::when_left\(move \|note\| turned_off\(&to, note\)\);/, "a leave reaches the wall and prefs.json");
  const main = code(read("../src-tauri/src/main.rs"));
  assert.match(main, /if let tauri::RunEvent::Exit = event \{\s*split::quitting\(\);\s*\}/, "quitting stops the watch before Tauri hides the windows");
  assert.match(rs, /pub fn quitting\(\) \{\s*#\[cfg\(windows\)\]\s*win::stop_watching\(\);\s*\}/);
});

test("the app sends the leave the wall listens for, and saves split off", () => {
  const rs = read("../src-tauri/src/split.rs");
  assert.match(rs, /json!\(\{ "on": false, "note": note \}\)/);
  assert.match(rs, /crate::write_pref\(app, SPLIT_KEY, Value::Bool\(false\)\)/);
});

test("#182: while split is off the app watches for a hand-made split, sends the snap and saves split on", () => {
  const rs = code(read("../src-tauri/src/split.rs"));
  assert.match(rs, /json!\(\{ "on": true, "note": SNAPPED \}\)/);
  assert.match(rs, /crate::write_pref\(app, SPLIT_KEY, Value::Bool\(true\)\)/);
  assert.match(rs, /if !on \{\s*watch_for_snap\(&app\);\s*\}\s*Ok\(on\)/, "at the wall's load, when saved off");
  assert.match(rs, /if !saved_on\(on, said\.is_ok\(\)\) \{\s*watch_for_snap\(&app\);\s*\}/, "after an unsplit or a split that failed");
  assert.match(rs, /drop\(channel\);\s*#\[cfg\(windows\)\]\s*watch_for_snap\(app\);/, "after a window left the split");
  assert.match(rs, /win::watch_split\(wall, terminal\);/, "a hand-made split is then watched like one the app made");
  assert.match(rs, /crate::jump::fleet_window_quiet\(\)/, "the watch finds the terminal without selecting its tab");
});

/** Rust source with its comments removed. */
const code = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
/** What on the Jump path moves, sizes or re-places a window. */
const PLACES = [/SetWindowPos/, /SetWindowPlacement/, /MoveWindow/, /DeferWindowPos/, /\bset_position\b/, /\bset_size\b/, /\bsplit::/, /\bgeometry::/, /\bmove_resize\b/];
export const placesWindows = (src) => PLACES.filter((re) => re.test(code(src))).map(String);

test("Jump never moves or re-places a window, so split mode survives it", () => {
  for (const f of ["../src-tauri/src/jump.rs", "../src-tauri/src/launch.rs"]) assert.deepEqual(placesWindows(read(f)), [], f);
});

test("the placement check catches each way to move a window, and ignores a comment", () => {
  for (const planted of [
    "unsafe { SetWindowPos(hwnd, None, 0, 0, 1, 1, f) }",
    "let _ = SetWindowPlacement(h, &wp);",
    "MoveWindow(h, 0, 0, 9, 9, true);",
    "BeginDeferWindowPos(2); DeferWindowPos(..)",
    "window.set_position(p)?;",
    "w.set_size(s)",
    "crate::split::place(h)",
    "crate::geometry::halves(work)",
    "move_resize(&w, r)",
  ]) assert.notDeepEqual(placesWindows(planted), [], planted);
  assert.deepEqual(placesWindows("// never SetWindowPos here\n/* MoveWindow */ fn ok() {}"), []);
});

test("split's lookup selects the fleet tab in the window it places", () => {
  const jump = code(read("../src-tauri/src/jump.rs"));
  assert.match(jump, /pub\(crate\) fn fleet_window\(\) -> Result<isize, JumpError> \{\s*uia::window\(Lookup::Exact\(crate::launch::FLEET_TAB\)\)\s*\}/);
  const window = jump.slice(jump.indexOf("pub fn window("), jump.indexOf("pub fn jump("));
  assert.ok(window.length > 0, "uia::window is found");
  assert.match(window, /select\(tab\)\?/, "the tab is selected, so the right half shows the fleet");
  assert.deepEqual(placesWindows(window), [], "selecting moves no window");
});

test("split places each window as `moves` plans it, the terminal under the wall", () => {
  const rs = code(read("../src-tauri/src/split.rs"));
  assert.match(rs, /moves\(wall, terminal, work\)\s*\.into_iter\(\)\s*\.try_for_each\(\|\(h, r, under\)\| place\(hwnd\(h\), r, under\.map\(hwnd\)\)\)/);
});
