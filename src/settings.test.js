import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { apply, readRow, viewOf } from "./fleet/settings.js";
import { ROWS, SECTIONS, VOICE_MODES, filterRows } from "./settings/registry.js";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const row = (id) => ROWS.find((r) => r.id === id);

/** An invoke that records each call and answers from `answers` by command. */
function recorder(answers = {}) {
  const calls = [];
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (!(cmd in answers)) throw new Error(`unexpected command ${cmd}`);
    const a = answers[cmd];
    return typeof a === "function" ? a(args) : a;
  };
  return { calls, invoke };
}

test("every row has a known section, a unique id, words, and either its own commands or a binding", () => {
  const sections = new Set(SECTIONS.map((s) => s.id));
  const ids = new Set();
  for (const r of ROWS) {
    assert.ok(!ids.has(r.id), `duplicate row ${r.id}`);
    ids.add(r.id);
    assert.ok(sections.has(r.section), `${r.id}: unknown section ${r.section}`);
    assert.ok(r.label && r.description, `${r.id}: label and description`);
    if (r.bind) {
      // A bound row has nothing of its own to drift from the wall's control.
      assert.equal(r.read, undefined, `${r.id} is bound, so it reads nothing itself`);
      assert.equal(r.write, undefined, `${r.id} is bound, so it writes nothing itself`);
    } else {
      assert.equal(typeof r.write, "function", `${r.id}: write`);
      if (r.control.type !== "button") assert.equal(typeof r.read, "function", `${r.id}: read`);
    }
  }
  for (const s of SECTIONS) assert.ok(ROWS.some((r) => r.section === s.id), `section ${s.id} has rows`);
});

test("search matches the label shown now and the description, ignoring case", () => {
  assert.equal(filterRows(ROWS, "").length, ROWS.length);
  assert.equal(filterRows(ROWS, "   ").length, ROWS.length);
  assert.equal(filterRows(ROWS, null).length, ROWS.length);
  assert.deepEqual(filterRows(ROWS, "PING").map((r) => r.id), ["ping"]);
  assert.deepEqual(filterRows(ROWS, "tailscale").map((r) => r.id), ["phone_wall"]);
  assert.deepEqual(filterRows(ROWS, "keryx").map((r) => r.id), ["voices_mode"]);
  assert.deepEqual(filterRows(ROWS, "nothing like this").length, 0);
  // The app names the autostart row for its system; search finds it by that name.
  assert.deepEqual(filterRows(ROWS, "windows").map((r) => r.id), []);
  assert.deepEqual(filterRows(ROWS, "windows", new Map([["autostart", "Start with Windows"]])).map((r) => r.id), ["autostart"]);
});

// What each row sends, and what the app answers: always something other than
// what was asked, so a row that shows its ask instead of the answer fails.
const CASES = [
  { id: "compact", ask: true, cmd: "set_layout_mode", args: { compact: true }, answer: false, shown: { value: false } },
  { id: "ping", ask: true, cmd: "set_ping", args: { on: true }, answer: false, shown: { value: false } },
  { id: "phone_wall", ask: true, cmd: "set_phone_wall", args: { on: true }, answer: false, shown: { value: false } },
  {
    id: "autostart",
    ask: true,
    cmd: "set_autostart",
    args: { enabled: true },
    answer: { on: false, held: true, label: "Start with Windows" },
    shown: { value: false, label: "Start with Windows", disabled: true, note: "Held as it is: KLEPSYDRA_NO_AUTOSTART is set." },
  },
  {
    id: "voices_mode",
    ask: "everyone",
    cmd: "set_voices_mode",
    args: { mode: "everyone" },
    answer: { tick: "heph", says: "Not saved: the mode is still Heph only." },
    shown: { value: "heph", note: "Not saved: the mode is still Heph only." },
  },
  { id: "queue_file", cmd: "choose_queue_file", args: undefined, answer: { queue: "C:\\q.md", needs: "C:\\n.md" }, shown: { value: "C:\\q.md" } },
  { id: "needs_file", cmd: "choose_needs_file", args: undefined, answer: { queue: "C:\\q.md", needs: "C:\\n.md" }, shown: { value: "C:\\n.md" } },
  { id: "reset_position", cmd: "reset_gauge_position", args: undefined, answer: null, shown: { value: null } },
  { id: "set_home", cmd: "set_gauge_home", args: undefined, answer: null, shown: { value: null } },
];

test("each row the app answers sends its command once and shows the answer, not the ask", async () => {
  const own = ROWS.filter((r) => !r.bind).map((r) => r.id);
  assert.deepEqual(CASES.map((c) => c.id).sort(), own.sort(), "every row with its own commands has a case");
  for (const c of CASES) {
    const { calls, invoke } = recorder({ [c.cmd]: c.answer });
    const shown = await apply(row(c.id), invoke, c.ask);
    assert.deepEqual(calls, [[c.cmd, c.args]], `${c.id} sends ${c.cmd}`);
    assert.deepEqual(shown, c.shown, `${c.id} shows what ${c.cmd} answered`);
  }
});

test("a refused command rejects, so the page keeps what it showed and says why", async () => {
  const { invoke } = recorder({ set_ping: () => Promise.reject("Ping plays on Windows only.") });
  await assert.rejects(apply(row("ping"), invoke, true), /Windows only/);
});

test("each row reads its state from the app's answer", async () => {
  const answers = {
    get_layout: true,
    get_ping: true,
    get_phone_wall: true,
    get_autostart: { on: true, held: false, label: "Start at login" },
    get_voices_mode: { tick: null, says: "keryx now: on for 1 other session only" },
    get_fleet_files: { queue: "/q.md", needs: "/n.md" },
  };
  const { invoke } = recorder(answers);
  const got = {};
  for (const r of ROWS.filter((x) => x.read)) got[r.id] = await readRow(r, invoke);
  assert.deepEqual(got, {
    compact: { value: true },
    ping: { value: true },
    phone_wall: { value: true },
    autostart: { value: true, label: "Start at login", disabled: false, note: "" },
    voices_mode: { value: null, note: "keryx now: on for 1 other session only" },
    queue_file: { value: "/q.md" },
    needs_file: { value: "/n.md" },
  });
  const { invoke: refuses } = recorder({ get_ping: () => Promise.reject("Ping plays on Windows only.") });
  await assert.rejects(readRow(row("ping"), refuses), /Windows only/, "a read the app refuses hides the row");
});

test("a bound row goes through the wall's function and shows the wall's state after it", async () => {
  const { calls, invoke } = recorder({});
  for (const r of ROWS.filter((x) => x.bind)) {
    const seen = [];
    let state = "before";
    const bindings = {
      [r.bind]: {
        view: () => ({ value: state }),
        write: async (v) => {
          seen.push(v);
          state = "the wall's own";
          return "Split: the terminal is on the right.";
        },
      },
    };
    assert.deepEqual(await readRow(r, invoke, bindings), { value: "before" });
    const shown = await apply(r, invoke, "asked", bindings);
    assert.deepEqual(seen, ["asked"], `${r.id} calls its binding once`);
    assert.deepEqual(shown, { value: "the wall's own", note: "Split: the terminal is on the right." }, `${r.id} shows the wall's state and the app's message`);
  }
  assert.deepEqual(calls, [], "a bound row sends no command of its own");
  await assert.rejects(readRow(row("split_terminal"), invoke, {}), /no split control/);
});

test("every command a row sends is registered with the app", async () => {
  const sent = new Set();
  const invoke = async (cmd) => {
    sent.add(cmd);
    return null;
  };
  for (const r of ROWS.filter((x) => !x.bind)) {
    await r.write(invoke, true);
    if (r.read) await r.read(invoke);
  }
  const main = read("src-tauri/src/main.rs");
  const list = main.match(/tauri::generate_handler!\[([\s\S]*?)\]/)[1];
  const registered = new Set(list.split(",").map((s) => s.trim().split("::").pop()).filter(Boolean));
  for (const cmd of sent) assert.ok(registered.has(cmd), `${cmd} is in generate_handler!`);
});

test("each bound row's binding is the function the wall's own control calls (one code path)", () => {
  const wall = read("src/fleet/wall.js");
  const split = read("src/fleet/split.js");
  const bindings = wall.match(/bindings: \{([\s\S]*?)\n {2}\},\n {2}onBack/)[1];
  const bound = new Set(ROWS.filter((r) => r.bind).map((r) => r.bind));
  for (const name of bound) assert.match(bindings, new RegExp(`\\n {4}${name}: \\{`), `the wall binds ${name}`);
  // Split: the toolbar's click and the page both run split.set.
  assert.match(bindings, /split: \{ view: split\.view, write: split\.set \}/);
  assert.match(split, /const turn = \(on\) => press\(button, note, \(\) => set\(on\)\);/);
  assert.match(split, /const set = async \(on\) => \{\s*const said = await invoke\("set_split_mode", \{ on \}\);\s*show\(on\);/);
  // Density: the gear's picker and the page both run pickDensity.
  assert.match(bindings, /density: \{ view: \(\) => \(\{ value: choice \}\), write: pickDensity \}/);
  assert.match(wall, /densityPicker\.addEventListener\("change", \(e\) => \{\s*pickDensity\(e\.target\.value\)/);
  // Characters: the gear's picker and the page both run chooseTheme, whose save waits for the theme to load.
  assert.match(bindings, /write: chooseTheme,\s*flush: \(\) => flushTheme\(\),/);
  assert.match(wall, /themePicker\.addEventListener\("change", \(\) => chooseTheme\(themePicker\.value\)\);/);
  assert.match(wall, /function chooseTheme\(id\) \{[\s\S]*?saving = setTimeout\(saveTheme, THEME_SAVE_MS\);/);
  // + New session: the menu and the page both run setDefault, which keeps ns.prefs.
  assert.match(bindings, /newSession: \{ view: nsView, write: \(id\) => setDefault\(id \|\| null\) \}/);
  assert.match(wall, /async function saveDefault\(id\) \{\s*try \{\s*await setDefault\(id\);/);
  assert.match(wall, /async function setDefault\(id\) \{[\s\S]*?ns\.prefs = \{ \.\.\.ns\.prefs, default: id \};/);
  // Each control tells the page when it changes, so the page shows what the wall shows.
  for (const id of ["split_terminal", "card_density", "character_theme", "new_session_default"]) {
    assert.match(wall, new RegExp(`settingsController\\?\\.sync\\("${id}"\\)`), `the wall syncs ${id}`);
  }
});

test("the + New session row offers the engines + New session lists, by their real ids", () => {
  const wall = read("src/fleet/wall.js");
  assert.match(wall, /const nsView = \(\) => \{\s*const \{ entries \} = nsState\(\);/, "the same entries the button and menu use");
  assert.match(wall, /options: \[\{ value: "", label: "Last used" \}, \.\.\.entries\.map\(\(e\) => \(\{ value: e\.id, label: e\.name \}\)\)\]/);
  assert.doesNotMatch(read("src/settings/registry.js"), /claude:default/);
});

test("the Voices row offers keryx's modes as the app names them", () => {
  const rust = read("src-tauri/fleet/src/voices.rs");
  const table = rust.match(/pub const VOICES: \[\(&str, &str\); 3\] = \[([\s\S]*?)\];/)[1];
  const modes = [...table.matchAll(/\("([^"]+)", "([^"]+)"\)/g)].map((m) => ({ value: m[1], label: m[2] }));
  assert.deepEqual(VOICE_MODES, modes);
});

test("the tray opens the settings page by its hash, which the wall reads at start and on change", () => {
  const fleet = read("src-tauri/src/fleet.rs");
  assert.match(fleet, /let page = if settings \{ "wall\.html#settings" \} else \{ "wall\.html" \};/, "a wall made now loads the page");
  assert.match(fleet, /wall\.eval\("location\.hash = '#settings'"\)/, "a wall already open is sent the hash");
  assert.doesNotMatch(fleet, /emit\("open-settings"/, "no event a wall still loading would miss");
  const wall = read("src/fleet/wall.js");
  assert.match(wall, /addEventListener\("hashchange", showView\);\nshowView\(\);/);
});

test("viewOf passes a row's answer through its view, or as the value", () => {
  assert.deepEqual(viewOf({}, 3), { value: 3 });
  assert.deepEqual(viewOf({ view: (x) => ({ value: x + 1 }) }, 3), { value: 4 });
});
