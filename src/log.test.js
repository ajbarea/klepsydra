import { test } from "node:test";
import assert from "node:assert/strict";
import { DEBUG_KEY, LEVELS, MAX_CHARS, REPEAT_KEYS, createLog, describe, detail, loggedRepeat } from "./log.js";

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
  err.stack = "TypeError: x is undefined\n    at paint (fleet/wall.js:12:3)";
  createLog("fleet/wall.js", { window, console }).warn("theme dicebear could not be loaded from fleet/themes/dicebear.json", err);
  await tick();
  assert.deepEqual(console.said, [["warn", "klepsydra: theme dicebear could not be loaded from fleet/themes/dicebear.json: TypeError: x is undefined", err]]);
  assert.deepEqual(calls, [
    [
      "plugin:log|log",
      {
        level: LEVELS.warn,
        message: "theme dicebear could not be loaded from fleet/themes/dicebear.json: TypeError: x is undefined\n    at paint (fleet/wall.js:12:3)",
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

test("detail gives an Error's stack, and the one-line form for anything else", () => {
  const e = new Error("boom");
  assert.match(detail(e), /^Error: boom\n\s+at /);
  const bare = new Error("no stack");
  bare.stack = undefined;
  assert.equal(detail(bare), "Error: no stack");
  const foreign = new Error("mine");
  foreign.stack = "a stack that names another error";
  assert.equal(detail(foreign), "Error: mine");
  for (const v of ["No reply to play.", { code: 7 }, undefined]) assert.equal(detail(v), describe(v));
});

test("a repeat logs at the 1st, 10th, 100th and 1000th sighting", () => {
  const logged = [];
  for (let n = 1; n <= 1200; n++) if (loggedRepeat(n)) logged.push(n);
  assert.deepEqual(logged, [1, 10, 100, 1000]);
});

test("a failure on every snapshot logs its cause once, then a count; another cause logs at once", async () => {
  const { calls, window } = inApp();
  const console = fakeConsole();
  const log = createLog("fleet/wall.js", { window, console });
  for (let i = 0; i < 12; i++) log.errorRepeat("snapshot", "a fleet snapshot could not be shown", new TypeError("x is undefined"));
  log.errorRepeat("snapshot", "a fleet snapshot could not be shown", new RangeError("too far"));
  log.warnRepeat("set_size", "set_size failed", "busy");
  await tick();
  assert.deepEqual(
    calls.map(([, a]) => [a.level, a.message.split("\n")[0]]),
    [
      [5, "a fleet snapshot could not be shown: TypeError: x is undefined"],
      [5, "a fleet snapshot could not be shown (10 times so far): TypeError: x is undefined"],
      [5, "a fleet snapshot could not be shown: RangeError: too far"],
      [4, "set_size failed: busy"],
    ],
  );
  assert.equal(console.said.length, 4);
});

test("the repeat memory is bounded and starts over when full", async () => {
  const { calls, window } = inApp();
  const log = createLog("main.js", { window, console: fakeConsole() });
  for (let i = 0; i < REPEAT_KEYS; i++) log.warnRepeat(`k${i}`, "w");
  log.warnRepeat("k0", "w"); // still remembered: a repeat, not logged
  log.warnRepeat("one more", "w"); // full: the memory starts over
  log.warnRepeat("k0", "w"); // forgotten, so logged again
  await tick();
  assert.equal(calls.length, REPEAT_KEYS + 2);
});
