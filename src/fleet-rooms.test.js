// Needs you and Agents (#386): the model behind every number, the keys, Done
// and Undo, the toasts' events, the lanes and the layout pref.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

globalThis.window ??= {};
const { needsModel, dueOf, dueLabel, itemParts, dueNow } = await import("./fleet/needs.js");
const { asksCount, parse, sections, toTree } = await import("./fleet/queue.js");
const rooms = await import("./fleet/rooms.js");
const { LAYOUTS, DEFAULT_LAYOUT, parseLayout, keyAction, transitions, lanes, createDone, autoOpens, swipeDone } = rooms;

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const TODAY = new Date(2026, 10, 25, 9, 30); // Wed 11-25

// The real file's shape, its words made up: a title line, sections, nested
// steps, links, done items and dates written as the agents write them.
const FILE = `# Needs you

Your list, soonest first.

## Today (Wed 11-25)

- 📋 **Alpha review (Wed 11-25):** read the brief, then [the PR](https://example.com/pr/1).
- ✅ **Bravo:** done already.

## Coming up

- 📋 **Thu 11-27, 9:30 am: cedar meeting.** Bring the notes [doc](https://example.com/doc?id=2&x=1).
  - 📋 nested step one [inner](https://example.com/inner)
  - ✅ nested done
- 📋 **Delta 12-06: ember deadline** (two pages).
- 📋 Plain item with no bold and no date
- ✅ **Echo:** old.

## When convenient

- 📋 **Fable:** [notes/plan.md](notes/plan.md) and \`code\`.
`;

test("one parse drives every number: the room lists exactly what the header counts", () => {
  const m = needsModel(FILE, TODAY);
  assert.equal(m.count, m.items.length);
  assert.equal(m.count, asksCount(sections(toTree(parse(FILE)))));
  assert.equal(m.count, 5, "done items and nested steps never count");
  assert.deepEqual(
    m.items.map((i) => i.title),
    ["Alpha review (Wed 11-25)", "Thu 11-27, 9:30 am: cedar meeting", "Delta 12-06: ember deadline", "Plain item with no bold and no date", "Fable"],
  );
  assert.deepEqual(
    m.items.map((i) => i.section),
    ["Today (Wed 11-25)", "Coming up", "Coming up", "Coming up", "When convenient"],
  );
  for (const shape of ["scripts/fixtures/needs-you-shape.md", "scripts/fixtures/needs-demo.md"]) {
    const text = read(shape);
    const n = needsModel(text, TODAY);
    assert.equal(n.count, asksCount(sections(toTree(parse(text)))) ?? 0, shape);
  }
});

test("an item's block is its exact source lines, nested lines too, which Done sends to the app", () => {
  const m = needsModel(FILE, TODAY);
  const cedar = m.items[1];
  assert.equal(
    cedar.block,
    "- 📋 **Thu 11-27, 9:30 am: cedar meeting.** Bring the notes [doc](https://example.com/doc?id=2&x=1).\n  - 📋 nested step one [inner](https://example.com/inner)\n  - ✅ nested done",
  );
  for (const item of m.items) assert.ok(FILE.includes(item.block), item.title);
  assert.deepEqual(
    cedar.links.map((l) => l.url),
    ["https://example.com/doc?id=2&x=1", "https://example.com/inner"],
  );
  assert.deepEqual(m.items[4].links, [], "a relative link is not offered");
  const crlf = needsModel(FILE.replace(/\n/g, "\r\n"), TODAY);
  assert.equal(crlf.items[1].block, cedar.block, "CRLF files give the same block");
});

test("a loose list's item ends at its last text line, not the blank line after it", () => {
  const m = needsModel("- 📋 a\n\n  more of a\n\n- 📋 b\n\n## Later\n", TODAY);
  assert.deepEqual(
    m.items.map((i) => i.block),
    ["- 📋 a\n\n  more of a", "- 📋 b"],
  );
});

test("a lone carriage return ends a line for the blocks as it does for the parser", () => {
  const m = needsModel("- 📋 a\rb\n- 📋 c\n- 📋 d\n", TODAY);
  assert.deepEqual(
    m.items.map((i) => [i.title, i.block, i.line]),
    [
      ["a b", "- 📋 a\nb", 0],
      ["c", "- 📋 c", 2],
      ["d", "- 📋 d", 3],
    ],
  );
});

test("each item's block is the source lines from its line on, whatever the line endings", () => {
  for (const eol of ["\n", "\r\n", "\r"]) {
    const text = FILE.replaceAll("\n", eol);
    const lines = text.split(/\r\n?|\n/);
    for (const i of needsModel(text, TODAY).items) {
      assert.equal(lines.slice(i.line, i.line + i.block.split("\n").length).join("\n"), i.block, JSON.stringify([eol, i.title]));
    }
  }
});

test("an item opens only links the app will open: https and written in its block as it stands", () => {
  const m = needsModel("- 📋 **A:** [x](https://ex.com/Café) [y](http://ex.com/) [z](https://ex.com/ok?a=1&b=2) <mailto:a@b.c>\n", TODAY);
  assert.deepEqual(
    m.items[0].links.map((l) => [l.url, l.opens]),
    [
      ["https://ex.com/Caf%C3%A9", false],
      ["http://ex.com/", false],
      ["https://ex.com/ok?a=1&b=2", true],
      ["mailto:a@b.c", false],
    ],
  );
});

test("two identical items keep distinct keys", () => {
  const m = needsModel("- 📋 same\n- 📋 same\n", TODAY);
  assert.equal(m.count, 2);
  assert.notEqual(m.items[0].key, m.items[1].key);
  assert.equal(m.items[0].block, m.items[1].block);
});

test("details render the item's markdown, never its raw link syntax", () => {
  const li = toTree(parse("- 📋 **T:** see [x](https://example.com/a)"))[0].kids[0];
  const { title, detail } = itemParts(li);
  assert.equal(title, "T");
  const flat = JSON.stringify(detail);
  assert.ok(!flat.includes("](https://"), flat);
  assert.ok(flat.includes('"link":"https://example.com/a"'), flat);
});

test("due dates: the first date the item names, nearest today, shown as a date", () => {
  assert.equal(dueOf("Wed 11-25 review", TODAY)?.toDateString(), new Date(2026, 10, 25).toDateString());
  assert.equal(dueOf("by 12-06", TODAY)?.toDateString(), new Date(2026, 11, 6).toDateString());
  assert.equal(dueOf("Jan 3 kickoff", TODAY)?.getFullYear(), 2027, "a date past New Year is next year's");
  assert.equal(dueOf("2026-12-10 due", TODAY)?.getDate(), 10);
  assert.equal(dueOf("Dec 6", TODAY)?.getMonth(), 11);
  assert.equal(dueOf("Delta 12-06: deadline", TODAY)?.getDate(), 6, "a colon after the date");
  assert.equal(dueOf("Thu 11-27, 9:30-10:00 am", TODAY)?.getDate(), 27, "the date, not the time range");
  for (const none of ["9:30-10:00 slot", "#12-3", "55-03", "1.5-2 hours", "no date at all", "13-40"]) assert.equal(dueOf(none, TODAY), null, none);
  // Words and counts that only look like dates.
  for (const none of ["Review the deck 2 times", "Decide 3 options", "Write 2-3 paragraphs", "a 10-20 minutes read", "Marching 4 abreast", "you may 2 of them", "Junior 5"]) {
    assert.equal(dueOf(none, TODAY), null, none);
  }
  assert.equal(dueOf("December 6 deadline", TODAY)?.getDate(), 6);
  assert.equal(dueOf("Sept. 9", TODAY)?.getMonth(), 8);
  assert.equal(dueOf("Mon 1-4 kickoff", TODAY)?.getDate(), 4, "a weekday before it makes a short date a date");
  assert.equal(dueOf("by 1-05", TODAY)?.getMonth(), 0);
  assert.deepEqual(dueLabel(new Date(2026, 10, 25), TODAY), { label: "Today", tone: "today", days: 0 });
  assert.equal(dueLabel(new Date(2026, 10, 26), TODAY).label, "Tomorrow, Thu 11-26");
  assert.equal(dueLabel(new Date(2026, 10, 27), TODAY).tone, "soon");
  assert.equal(dueLabel(new Date(2026, 11, 6), TODAY).label, "Sun 12-06");
  assert.equal(dueLabel(new Date(2026, 11, 6), TODAY).tone, "later");
  assert.equal(dueLabel(new Date(2026, 10, 20), TODAY).tone, "past");
});

test("the next dated item is the soonest from today on; past dates are not next", () => {
  const m = needsModel(FILE, TODAY);
  assert.equal(m.next.title, "Alpha review (Wed 11-25)");
  const later = needsModel(FILE, new Date(2026, 10, 28));
  assert.equal(later.next.title, "Delta 12-06: ember deadline");
  assert.ok(dueNow(m.items[0], TODAY) && !dueNow(m.items[2], TODAY));
  assert.equal(needsModel("", TODAY).next, null);
});

test("Done sends the item's block to the app and Undo puts back that block alone, once", async () => {
  const calls = [];
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "needs_done") return { undo: { block: args.block, after: "above", at: 3 }, text: "after done" };
    return "after undo";
  };
  const writer = createDone(invoke);
  const item = needsModel(FILE, TODAY).items[1];
  assert.equal(item.line, 11, "the line the item starts on, as the app counts lines");
  assert.deepEqual(await writer.done(item), { ok: true, text: "after done" });
  assert.ok(writer.undoable);
  assert.deepEqual(await writer.undo(), { ok: true, text: "after undo" });
  assert.deepEqual(await writer.undo(), { ok: false, why: null }, "a second Undo does nothing");
  assert.deepEqual(calls, [
    ["needs_done", { block: item.block, line: 11 }],
    ["needs_undo", { undo: { block: item.block, after: "above", at: 3 } }],
  ]);
});

test("an Undo window ends only its own Done, never a later one's", async () => {
  let n = 0;
  const writer = createDone(async (cmd) => (cmd === "needs_done" ? { undo: { block: "- x", after: null, at: n++ }, text: "" } : ""));
  const [a, b] = needsModel(FILE, TODAY).items;
  await writer.done(a);
  const endsA = writer.expiry();
  await writer.done(b);
  endsA();
  assert.equal(writer.undoable, true, "the second Done can still be undone");
  writer.expiry()();
  assert.equal(writer.undoable, false);
});

test("Done runs one at a time, so a held key cannot remove several rows", { timeout: 5000 }, async () => {
  let release;
  const calls = [];
  const writer = createDone((cmd, args) => {
    calls.push(cmd);
    return new Promise((r) => {
      release = () => r({ undo: { block: args.block, after: null, at: 0 }, text: "" });
    });
  });
  const [a, b] = needsModel(FILE, TODAY).items;
  const first = writer.done(a);
  assert.deepEqual(await writer.done(b), { ok: false, why: null });
  release();
  await first;
  assert.deepEqual(calls, ["needs_done"]);
});

test("a refused Done says why and leaves nothing to undo", async () => {
  const writer = createDone(async () => {
    throw "That item is no longer in the Needs you file";
  });
  const r = await writer.done(needsModel(FILE, TODAY).items[0]);
  assert.equal(r.ok, false);
  assert.match(r.why, /no longer/);
  assert.equal(writer.undoable, false);
});

test("every command the pages invoke is one the app registers", () => {
  const handler = read("src-tauri/src/main.rs").match(/generate_handler!\[([\s\S]*?)\]/)[1];
  const registered = new Set(handler.split(",").map((h) => h.trim().split("::").at(-1)).filter(Boolean));
  const pages = ["src/fleet/wall.js", "src/fleet/rooms.js", "src/fleet/queuepanel.js", "src/fleet/drawer.js", "src/fleet/replay.js", "src/fleet/split.js", "src/main.js"];
  const used = new Set();
  for (const f of pages) {
    for (const m of read(f).matchAll(/\b(?:invoke|tauri|follow)\(\s*"([a-z_]+)"/g)) used.add(m[1]);
  }
  assert.ok(used.has("needs_done") && used.has("needs_undo") && used.has("needs_open") && used.has("set_needs_layout"));
  assert.deepEqual([...used].filter((c) => !registered.has(c)), []);
});

test("a blocked row answers through the wall's jump, with the card's id and session name", () => {
  const src = read("src/fleet/rooms.js");
  assert.match(src, /invoke\("jump_to_terminal", \{ id: c\.id, name: c\.session \?\? "" \}\)/);
  assert.doesNotMatch(read("src/fleet/wall.js"), /\brequest\(/, "the wrap-up request is a value, not a function");
});

test("block and finish events are keyed by session_id, blocks first, none on the first look", () => {
  const s = (session_id, status) => ({ session_id, status });
  assert.deepEqual(transitions(null, [s("a", "needs_you")]), []);
  const before = new Map([
    ["a", "working"],
    ["b", "working"],
    ["c", "needs_you"],
  ]);
  assert.deepEqual(transitions(before, [s("a", "done"), s("b", "needs_you"), s("c", "needs_you")]), [
    { id: "b", kind: "blocked" },
    { id: "a", kind: "finished" },
  ]);
  assert.deepEqual(transitions(new Map([["a", "needs_you?"]]), [s("a", "needs_you")]), [], "a quiet needs-you is not a new block");
});

test("E opens its panel on a block only when nobody is typing and no dialog is open", () => {
  assert.equal(autoOpens({ layout: "E", typing: false, modal: false }), true);
  assert.equal(autoOpens({ layout: "E", typing: true, modal: false }), false);
  assert.equal(autoOpens({ layout: "E", typing: false, modal: true }), false);
  for (const l of ["B", "D"]) assert.equal(autoOpens({ layout: l, typing: false, modal: false }), false);
});

test("keys: N, A, Esc and the room's letters; never with a modifier, a repeat, a dialog, typing, or Enter on a control", () => {
  const k = (key, more = {}) => ({ key, ctrlKey: false, metaKey: false, altKey: false, repeat: false, defaultPrevented: false, ...more });
  const needs = { view: "needs", typing: false, modal: false, control: false, jump: false };
  const agents = { ...needs, view: "agents" };
  assert.equal(keyAction(k("n"), agents), "needs");
  assert.equal(keyAction(k("N"), agents), "needs");
  assert.equal(keyAction(k("a"), needs), "agents");
  assert.equal(keyAction(k("Escape"), needs), "back");
  assert.equal(keyAction(k("Escape"), agents), null);
  for (const [key, act] of [["j", "down"], ["ArrowDown", "down"], ["k", "up"], ["o", "open"], ["Enter", "open"], ["e", "done"], ["u", "undo"], ["c", "copy"]])
    assert.equal(keyAction(k(key), needs), act, key);
  for (const key of ["j", "o", "e", "u", "c"]) assert.equal(keyAction(k(key), agents), null, `${key} outside the room`);
  for (const mod of ["ctrlKey", "metaKey", "altKey"]) {
    assert.equal(keyAction(k("c", { [mod]: true }), needs), null, `${mod}+C copies the selection`);
    assert.equal(keyAction(k("n", { [mod]: true }), agents), null);
  }
  for (const key of ["e", "n", "a", "u", "c", "o", "Enter", "Escape"]) assert.equal(keyAction(k(key, { repeat: true }), needs), null, `held ${key}`);
  assert.equal(keyAction(k("j", { repeat: true }), needs), "down", "holding j moves on");
  for (const key of ["n", "a", "Escape", "e"]) {
    assert.equal(keyAction(k(key), { ...needs, modal: true }), null, `${key} behind a dialog`);
    assert.equal(keyAction(k(key), { ...needs, typing: true }), null, `${key} while typing`);
  }
  assert.equal(keyAction(k("Enter"), { ...needs, control: true }), null, "Enter on a focused button is the button's");
  assert.equal(keyAction(k("Enter"), { ...needs, control: true, jump: true }), null);
  assert.equal(keyAction(k("Enter"), { ...agents, jump: true }), "jump");
  assert.equal(keyAction(k("Enter"), agents), null, "no Undo by Enter: Enter after E is not Undo");
  assert.equal(keyAction(k("e", { defaultPrevented: true }), needs), null);
});

test("a Done swipe is rightward, long and level; a diagonal scroll is not one", () => {
  assert.equal(swipeDone(120, 4), true);
  assert.equal(swipeDone(120, 30), false);
  assert.equal(swipeDone(90, 50), false, "diagonal");
  assert.equal(swipeDone(60, 0), false, "short");
  assert.equal(swipeDone(-120, 0), false, "leftward");
});

test("lanes: B is blocked, errors, working, finished, idle; D puts Working first; E keeps the wall", () => {
  const c = (id, status) => ({ id, status });
  const cards = [c("w1", "working"), c("n1", "needs_you"), c("d1", "done"), c("e1", "error"), c("i1", "ended"), c("w2", "working"), c("s1", "silent")];
  const shape = (out) => out.map((x) => (x.lane ? `[${x.label} ${x.count}]` : x.id)).join(" ");
  // Blocked means needs_you everywhere (pill, tally, room, lane): an error has its own lane.
  assert.equal(shape(lanes(cards, "B")), "[Blocked 1] n1 [Errors 1] e1 [Working 2] w1 w2 [Finished 1] d1 [Idle 2] i1 s1");
  assert.equal(shape(lanes(cards, "D")), "[Working 2] w1 w2 [Needs you 1] n1 [Errors 1] e1 [Finished 1] d1 [Idle 2] i1 s1");
  assert.equal(lanes(cards, "E"), cards);
  assert.deepEqual(lanes([], "B"), []);
});

test("the layout pref: B by default, D and E kept, anything else B; the app keeps it in prefs.json", () => {
  assert.equal(DEFAULT_LAYOUT, "B");
  assert.deepEqual(LAYOUTS, ["B", "D", "E"]);
  for (const v of ["B", "D", "E"]) assert.equal(parseLayout(v), v);
  for (const v of ["b", "A", "", null, undefined, "C"]) assert.equal(parseLayout(v), "B");
  const fleet = read("src-tauri/src/fleet.rs");
  assert.match(fleet, /const LAYOUTS: \[&str; 3\] = \["B", "D", "E"\];/, "the app's list matches rooms.js");
  const wall = read("src/fleet/wall.js");
  assert.match(wall, /tauri\("get_needs_layout"\)\.then\(\(l\) => rooms\.setLayout\(l\)/);
  assert.match(wall, /tauri\("set_needs_layout", \{ layout \}\)/);
});

test("the old stacked drawer is gone: no Queue button, edge tab or Ctrl+Alt+B", () => {
  const html = read("src/wall.html");
  for (const gone of ['id="queue-open"', 'id="queue-tab"', '<dialog id="queue"', "Control+Alt+B"]) assert.ok(!html.includes(gone), gone);
  assert.doesNotMatch(read("src/fleet/queuepanel.js"), /toggleKey|createQueuePanel/);
  assert.match(html, /id="needs-pill"[^>]*aria-keyshortcuts="N"/);
  assert.match(html, /id="agents-pill"[^>]*aria-keyshortcuts="A"/);
});

test("no worker's private spec file is tracked", () => {
  const tracked = execFileSync("git", ["ls-files"], { cwd: new URL("..", import.meta.url), encoding: "utf8" }).split("\n");
  assert.deepEqual(tracked.filter((f) => /(^|\/)IMPL-[^/]*\.md$/.test(f)), []);
  assert.match(read(".gitignore"), /^IMPL-agy\.md$/m);
});
