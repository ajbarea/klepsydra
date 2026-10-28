import { test } from "node:test";
import assert from "node:assert/strict";
import { DEBUG_KEY, LEVELS, MAX_CHARS, createLog, describe } from "./log.js";

/** A console that keeps what each method was given. */
function fakeConsole() {
  const said = [];
  const keep = (level) => (...args) => said.push([level, ...args]);
  return { said, debug: keep("debug"), warn: keep("warn"), error: keep("error") };
}

/** A window inside the app: invoke records each call. */
function inApp(answer = () => Promise.resolve()) {
  const calls = [];
  const window = { __TAURI__: { core: { invoke: (cmd, args) => (calls.push([cmd, args]), answer(cmd, args)) } } };
  return { calls, window };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test("inside the app a warning reaches the console and the log command, naming its module", async () => {
  const { calls, window } = inApp();
  const console = fakeConsole();
  const err = new TypeError("x is undefined");
  createLog("fleet/wall.js", { window, console }).warn("theme dicebear could not be loaded from fleet/themes/dicebear.json", err);
  await tick();
  assert.deepEqual(console.said, [["warn", "klepsydra: theme dicebear could not be loaded from fleet/themes/dicebear.json: TypeError: x is undefined", err]]);
  assert.deepEqual(calls, [
    [
      "plugin:log|log",
      {
        level: LEVELS.warn,
        message: "theme dicebear could not be loaded from fleet/themes/dicebear.json: TypeError: x is undefined",
        location: "fleet/wall.js",
        keyValues: undefined,
      },
    ],
  ]);
});

test("an error goes at error level, with its fields as strings", async () => {
  const { calls, window } = inApp();
  const console = fakeConsole();
  createLog("main.js", { window, console }).error("set_theme refused theme kourai", "prefs.json could not be saved", {
    session_id: "s1",
    n: 3,
  });
  await tick();
  assert.equal(console.said[0][0], "error");
  assert.equal(calls[0][1].level, 5);
  assert.equal(calls[0][1].message, "set_theme refused theme kourai: prefs.json could not be saved");
  assert.deepEqual(calls[0][1].keyValues, { session_id: "s1", n: "3" });
});

test("tauri-plugin-log's level numbers", () => {
  assert.deepEqual(LEVELS, { debug: 2, warn: 4, error: 5 });
});

test("debug lines are dropped unless the debug flag is on", async () => {
  const off = inApp();
  const quiet = fakeConsole();
  createLog("main.js", { window: off.window, console: quiet }).debug("the branch taken");
  const on = inApp();
  const loud = fakeConsole();
  createLog("main.js", { window: on.window, console: loud, debug: true }).debug("the branch taken");
  await tick();
  assert.deepEqual([quiet.said, off.calls], [[], []]);
  assert.deepEqual(loud.said, [["debug", "klepsydra: the branch taken"]]);
  assert.equal(on.calls[0][1].level, LEVELS.debug);
});

test("the debug flag is read from localStorage, and a storage that throws reads as off", () => {
  for (const [storage, want] of [
    [{ getItem: (k) => (k === DEBUG_KEY ? "1" : null) }, 1],
    [{ getItem: () => "0" }, 0],
    [
      {
        getItem: () => {
          throw new Error("denied");
        },
      },
      0,
    ],
  ]) {
    const console = fakeConsole();
    createLog("main.js", { window: { localStorage: storage }, console }).debug("d");
    assert.equal(console.said.length, want);
  }
});

test("outside the app (the phone wall, a test page) lines stay in the console", () => {
  const console = fakeConsole();
  const log = createLog("fleet/wall.js", { window: {}, console });
  log.warn("w");
  log.error("e", new Error("boom"));
  assert.deepEqual(
    console.said.map((s) => s.slice(0, 2)),
    [
      ["warn", "klepsydra: w"],
      ["error", "klepsydra: e: Error: boom"],
    ],
  );
});

test("a log command that fails or throws disturbs nothing and logs nothing more", async () => {
  for (const answer of [
    () => Promise.reject(new Error("plugin log not found")),
    () => {
      throw new Error("sync");
    },
  ]) {
    const { calls, window } = inApp(answer);
    const console = fakeConsole();
    assert.doesNotThrow(() => createLog("main.js", { window, console }).error("e"));
    await tick();
    assert.equal(calls.length, 1);
    assert.equal(console.said.length, 1);
  }
});

test("a long message is cut before it reaches the log file", async () => {
  const { calls, window } = inApp();
  createLog("main.js", { window, console: fakeConsole() }).warn("x".repeat(MAX_CHARS + 50));
  await tick();
  assert.equal(calls[0][1].message.length, MAX_CHARS);
});

test("describe gives one line for any rejection value", () => {
  assert.equal(describe(new RangeError("too far")), "RangeError: too far");
  assert.equal(describe("No reply to play."), "No reply to play.");
  assert.equal(describe({ code: 7 }), '{"code":7}');
  assert.equal(describe(undefined), "undefined");
  const loop = {};
  loop.self = loop;
  assert.equal(describe(loop), "[object Object]");
});
