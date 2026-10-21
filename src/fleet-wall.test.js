import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { NOTE_MS, announcer, press, say, setOff } from "./fleet/dom.js";

// A button and a note: just the attributes, dataset and text the helpers touch.
const button = () => ({
  dataset: {},
  attrs: {},
  setAttribute(k, v) { this.attrs[k] = String(v); },
  getAttribute(k) { return this.attrs[k] ?? null; },
  removeAttribute(k) { delete this.attrs[k]; },
});
const off = (b) => b.getAttribute("aria-disabled") === "true";
const settle = () => new Promise((r) => setImmediate(r));

test("a button is off while its call runs, and on again after a success", async () => {
  const b = button();
  const note = { textContent: "" };
  setOff(b, false);
  let finish;
  const done = press(b, note, () => new Promise((r) => { finish = r; }));
  assert.ok(off(b), "off while the call runs");
  setOff(b, false); // a snapshot repaints the reused card mid-call
  assert.ok(off(b), "a repaint does not turn it on mid-call");
  finish();
  await done;
  assert.ok(!off(b), "on again once the call succeeds");
  assert.ok(!("disabled" in b), "never the disabled property, so focus stays");
});

test("a button the card says is unavailable stays off after its call", async () => {
  const b = button();
  setOff(b, false);
  const done = press(b, { textContent: "" }, async () => "ok");
  setOff(b, true);
  await done;
  assert.ok(off(b));
  setOff(b, false);
  assert.ok(!off(b));
});

test("an off button ignores a press", async () => {
  const b = button();
  setOff(b, true);
  let calls = 0;
  await press(b, { textContent: "" }, async () => calls++);
  assert.equal(calls, 0);
});

test("a result or error shows for eight seconds, and a newer one restarts the clock", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const b = button();
    const note = { textContent: "" };
    setOff(b, false);
    await press(b, note, async () => { throw new Error("no tmux window"); });
    await settle();
    assert.equal(note.textContent, "Error: no tmux window");
    assert.ok(!off(b), "on again after an error");
    mock.timers.tick(NOTE_MS - 1);
    say(note, "Opened Hephaestus");
    mock.timers.tick(NOTE_MS - 1);
    assert.equal(note.textContent, "Opened Hephaestus", "the first timer no longer clears it");
    mock.timers.tick(1);
    assert.equal(note.textContent, "");
    say(note, "Starting…", 0);
    mock.timers.tick(NOTE_MS * 2);
    assert.equal(note.textContent, "Starting…", "a pending note stays until its result");
  } finally {
    mock.timers.reset();
  }
});

test("a pending note shows during the call, then its result", async () => {
  const b = button();
  const note = { textContent: "" };
  setOff(b, false);
  let seen;
  await press(b, note, async () => { seen = note.textContent; return "Started"; }, "Starting…");
  assert.equal(seen, "Starting…");
  assert.equal(note.textContent, "Started");
});

test("a different announcement soon after a repeated one is the one left", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const live = { textContent: "" };
    const announce = announcer(live);
    announce("Ada speaking");
    announce("Ada speaking"); // repeated: cleared, then set again
    mock.timers.tick(50);
    announce("Bo needs you");
    mock.timers.tick(500);
    assert.equal(live.textContent, "Bo needs you");
    announce("Bo needs you");
    assert.equal(live.textContent, "", "a repeat clears first");
    mock.timers.tick(100);
    assert.equal(live.textContent, "Bo needs you", "then says it again");
  } finally {
    mock.timers.reset();
  }
});

test("a note's full text is its title, so a cut-off note can still be read", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const note = { textContent: "", title: "" };
    const long = "Error: no tmux window named Hephaestus in the fleet session, so nothing was selected";
    say(note, long);
    assert.equal(note.title, long);
    mock.timers.tick(NOTE_MS);
    assert.deepEqual([note.textContent, note.title], ["", ""], "cleared together");
  } finally {
    mock.timers.reset();
  }
});
