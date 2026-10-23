import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { ARM_MS, UNDO_MS, confirmCopy, createEnder, endingAnnouncement, endingText, sessionActions } from "./fleet/end.js";
import { card } from "./fleet/model.js";

const fleet = { tmux: { socket: "/tmp/tmux-1001/klepsydra", pane: "%3" }, distro: "Ubuntu", claude: { pid: 7, start: 9 } };

test("the menu is offered only to a live session in klepsydra's tmux with a known Claude process", () => {
  assert.deepEqual(sessionActions({ ...fleet, status: "done" }), { menu: true, interrupt: false });
  assert.deepEqual(sessionActions({ ...fleet, status: "working" }), { menu: true, interrupt: true });
  assert.equal(sessionActions({ ...fleet, status: "ended" }).menu, false);
  assert.equal(sessionActions({ ...fleet, status: "working", tmux: { socket: "/tmp/tmux-1001/default", pane: "%3" } }).menu, false);
  assert.equal(sessionActions({ ...fleet, status: "working", tmux: { socket: "/tmp/tmux-1001/klepsydra2", pane: "%3" } }).menu, false);
  assert.equal(sessionActions({ ...fleet, status: "working", claude: undefined }).menu, false);
  assert.equal(sessionActions({ ...fleet, status: "working", tmux: null }).menu, false);
  assert.equal(sessionActions({ status: "working" }).interrupt, false);
});

test("the menu mirrors launch::target(): strings and numbers of the right type, or no menu", () => {
  const live = { ...fleet, status: "working" };
  assert.equal(sessionActions(live).menu, true);
  const broken = {
    "no pane": { ...live, tmux: { socket: fleet.tmux.socket } },
    "pane not a string": { ...live, tmux: { ...fleet.tmux, pane: 3 } },
    "socket not a string": { ...live, tmux: { ...fleet.tmux, socket: 7 } },
    "no distro": { ...live, distro: undefined },
    "distro null": { ...live, distro: null },
    "distro not a string": { ...live, distro: 1 },
    "no pid": { ...live, claude: { start: 9 } },
    "pid a string": { ...live, claude: { pid: "7", start: 9 } },
    "pid zero": { ...live, claude: { pid: 0, start: 9 } },
    "pid past u32": { ...live, claude: { pid: 2 ** 32, start: 9 } },
    "pid negative": { ...live, claude: { pid: -1, start: 9 } },
    "pid fractional": { ...live, claude: { pid: 7.5, start: 9 } },
    "no start": { ...live, claude: { pid: 7 } },
    "start a string": { ...live, claude: { pid: 7, start: "9" } },
    "start negative": { ...live, claude: { pid: 7, start: -9 } },
  };
  for (const [what, s] of Object.entries(broken)) assert.deepEqual(sessionActions(s), { menu: false, interrupt: false }, what);
});

test("a model card carries its actions and the menu button's accessible name", () => {
  const c = card({ session_id: "a", status: "working", ...fleet, where: { repo: "r" } }, {}, Date.now());
  assert.equal(c.actions.menu, true);
  assert.equal(c.menuLabel, `Session actions for ${c.name}`);
});

test("the confirm names the character, the repo and what happens", () => {
  const c = { name: "Hephaestus", status: "done", place: { repo: "claude-prefs", worktree: "wt", branch: "main" } };
  const copy = confirmCopy(c);
  assert.equal(copy.title, "End Hephaestus's session?");
  assert.equal(copy.confirm, "End Hephaestus");
  assert.match(copy.text, /ends Hephaestus's Claude session in claude-prefs \(worktree wt, branch main\), as if you typed \/exit in its terminal/);
  assert.match(copy.text, /resumed later\.$/);
  assert.equal(copy.warn, null);
  assert.match(confirmCopy({ ...c, status: "working", place: { repo: "r" } }).warn, /mid-turn/);
  assert.doesNotMatch(confirmCopy({ ...c, place: null }).text, / in null| in undefined/);
  for (const t of [copy.title, copy.text, copy.confirm, endingText("A", 3), endingAnnouncement("A")]) assert.ok(!t.includes("\u2014"), "no em-dash");
});

test("the undo window is five seconds and the countdown reads in whole seconds", () => {
  assert.equal(UNDO_MS, 5000);
  assert.equal(endingText("Kallos", 5), "Ending Kallos in 5 s");
});

function harness() {
  mock.timers.enable({ apis: ["setTimeout"] });
  const calls = [];
  const ender = createEnder({
    invoke: (cmd, args) => {
      calls.push([cmd, args]);
      return Promise.resolve("Ended");
    },
    timers: { setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (t) => clearTimeout(t) },
  });
  const ticks = [];
  const done = [];
  const opts = { onTick: (n) => ticks.push(n), onSend: () => done.push("send"), onDone: (r) => done.push(r) };
  return { calls, ender, ticks, done, opts };
}
const flush = () => new Promise((r) => setImmediate(r));

test("nothing is sent until the full window has run, then exactly one end_session", async () => {
  const { calls, ender, ticks, done, opts } = harness();
  try {
    assert.ok(ender.start("a", opts));
    assert.deepEqual(ticks, [5]);
    mock.timers.tick(UNDO_MS - 1);
    await flush();
    assert.deepEqual(calls, [], "not before the window ends");
    assert.deepEqual(ticks, [5, 4, 3, 2, 1]);
    mock.timers.tick(1);
    await flush();
    assert.deepEqual(calls, [["end_session", { id: "a" }]]);
    assert.deepEqual(done, ["send", { ok: true, text: "Ended" }]);
    assert.ok(!ender.pending("a"));
    mock.timers.tick(UNDO_MS * 3);
    await flush();
    assert.equal(calls.length, 1, "never twice");
  } finally {
    mock.timers.reset();
  }
});

test("the end stays pending, and cannot be cancelled, from the send until the call answers", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  let answer;
  const ender = createEnder({
    invoke: () => new Promise((r) => (answer = r)),
    timers: { setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (t) => clearTimeout(t) },
  });
  const seen = [];
  try {
    ender.start("a", { onTick() {}, onSend: () => seen.push("send"), onDone: (r) => seen.push([r, ender.pending("a")]) });
    mock.timers.tick(UNDO_MS);
    await flush();
    assert.ok(ender.pending("a"), "pending while end_session runs");
    assert.equal(ender.start("a", { onTick() {}, onDone() {} }), false, "no second end meanwhile");
    assert.equal(ender.cancel("a"), false, "too late to cancel");
    assert.deepEqual(ender.ids(), [], "nothing left for a card's reconcile to cancel");
    answer("Ended");
    await flush();
    assert.deepEqual(seen, ["send", [{ ok: true, text: "Ended" }, false]], "released before onDone runs");
    assert.ok(!ender.pending("a"));
    assert.ok(ender.start("a", { onTick() {}, onDone() {} }), "free again after the answer");
  } finally {
    mock.timers.reset();
  }
});

test("undo or cancel inside the window sends nothing, ever", async () => {
  const { calls, ender, opts } = harness();
  try {
    ender.start("a", opts);
    mock.timers.tick(UNDO_MS - 1);
    assert.ok(ender.cancel("a"));
    assert.equal(ender.cancel("a"), false, "nothing left to cancel");
    mock.timers.tick(UNDO_MS * 3);
    await flush();
    assert.deepEqual(calls, []);
  } finally {
    mock.timers.reset();
  }
});

test("one pending end per card, and cards run apart", async () => {
  const { calls, ender, opts } = harness();
  try {
    assert.ok(ender.start("a", opts));
    assert.equal(ender.start("a", opts), false);
    assert.ok(ender.start("b", opts));
    ender.cancel("a");
    mock.timers.tick(UNDO_MS);
    await flush();
    assert.deepEqual(calls, [["end_session", { id: "b" }]]);
  } finally {
    mock.timers.reset();
  }
});

test("a failed call is reported, not thrown", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const done = [];
    const ender = createEnder({ invoke: () => Promise.reject("refused: not klepsydra's tmux"), timers: { setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout } });
    ender.start("a", { onTick() {}, onDone: (r) => done.push(r) });
    mock.timers.tick(UNDO_MS);
    await flush();
    assert.deepEqual(done, [{ ok: false, text: "refused: not klepsydra's tmux" }]);
  } finally {
    mock.timers.reset();
  }
});

test("the dialog's End wakes only after a double-click would be over", () => {
  assert.ok(ARM_MS >= 500, "Windows' default double-click time is 500 ms");
  assert.ok(ARM_MS < UNDO_MS);
});
