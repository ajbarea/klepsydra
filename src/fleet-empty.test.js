import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { START, clearAll, clearLabel, endedIds, startLabel, wallState } from "./fleet/empty.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const s = (id, status) => ({ session_id: id, status });

test("clearAll tells its caller each id that cleared, and only those", async () => {
  const done = [];
  await clearAll(["a", "b", "c"], async (_cmd, { id }) => { if (id === "b") throw "gone"; }, (id) => done.push(id));
  assert.deepEqual(done.sort(), ["a", "c"]);
});

test("the wall's state: empty with no sessions, ended when every one has ended, else cards", () => {
  assert.equal(wallState([]), "empty");
  assert.equal(wallState([s("a", "ended")]), "ended");
  assert.equal(wallState([s("a", "ended"), s("b", "ended")]), "ended");
  for (const other of ["working", "needs_you", "done", "error", "new", "silent", "unknown"]) {
    assert.equal(wallState([s("a", "ended"), s("b", other)]), "cards", `ended beside ${other}`);
    assert.equal(wallState([s("b", other)]), "cards", `${other} alone`);
  }
});

test("only ended sessions are offered for clearing, in the reader's order", () => {
  assert.deepEqual(endedIds([s("a", "ended"), s("b", "silent"), s("c", "ended"), s("d", "working")]), ["a", "c"]);
  assert.deepEqual(endedIds([]), []);
});

test("the start button names the launch folder when it is known", () => {
  assert.equal(startLabel("/home/aj/ajsoftworks"), "Start a session in /home/aj/ajsoftworks");
  assert.equal(startLabel("~"), "Start a session in ~");
  for (const unknown of [null, undefined, "", "   ", 3, {}]) assert.equal(startLabel(unknown), START, String(unknown));
  assert.equal(START, "Start a session");
});

test("the clear link counts the ended sessions", () => {
  assert.equal(clearLabel(1), "Clear 1 ended session");
  assert.equal(clearLabel(2), "Clear 2 ended sessions");
  assert.equal(clearLabel(16), "Clear 16 ended sessions");
});

test("clearing sends clear_session once per id and says nothing when all are cleared", async () => {
  const sent = [];
  const note = await clearAll(["a", "b", "c"], async (cmd, args) => { sent.push([cmd, args]); });
  assert.deepEqual(sent, [["clear_session", { id: "a" }], ["clear_session", { id: "b" }], ["clear_session", { id: "c" }]]);
  assert.equal(note, "");
});

test("a clear that fails says how many were left and why", async () => {
  const note = await clearAll(["a", "b", "c"], async (_cmd, { id }) => {
    if (id !== "a") throw `${id} is running again`;
  });
  assert.equal(note, "2 of 3 not cleared: b is running again");
});

test("clearing nothing sends nothing", async () => {
  let calls = 0;
  assert.equal(await clearAll([], async () => calls++), "");
  assert.equal(calls, 0);
});

test("the empty state: Hesychia's portrait as decoration, the title, what will appear, one start button and a clear link", () => {
  const html = read("wall.html");
  const block = html.slice(html.indexOf('<section id="empty"'), html.indexOf("</section>", html.indexOf('<section id="empty"')));
  assert.match(block, /^<section id="empty" class="empty" aria-labelledby="empty-title" hidden>/);
  assert.match(block, /<img class="keeper" src="fleet\/faces\/kourai\/hesychia-full\.webp" alt="" \/>/, "decorative: screen readers skip it");
  assert.match(block, /<h2 id="empty-title" tabindex="-1">All quiet\.<\/h2>/);
  assert.match(block, /<p class="empty-body">Each Claude Code session you start appears here as a card, with its character, its repo and what it's doing\.<\/p>/);
  assert.match(block, /<button type="button" id="start-session" class="primary" hidden>Start a session<\/button>/);
  assert.match(block, /<button type="button" id="clear-ended" class="link" hidden><\/button>/);
  assert.doesNotMatch(block, /start-note/, "Start answers in the bar's note, which outlives the empty state");
  assert.match(block, /<span id="clear-note" role="status"><\/span>/, "the clear link has a note of its own");
  assert.ok(!/—/.test(block), "no em-dash in the copy");
  // One main landmark holds a level-one heading, the wall and the empty state (axe landmark-one-main, page-has-heading-one).
  assert.equal((html.match(/<main\b/g) ?? []).length, 1);
  const main = html.slice(html.indexOf("<main"), html.indexOf("</main>"));
  assert.match(main, /^<main id="main">\s*<h1 id="wall-title" class="visually-hidden">Claude Code sessions<\/h1>/);
  assert.match(main, /<section id="wall" class="wall" aria-labelledby="wall-title" tabindex="-1"><\/section>/);
  assert.ok(main.indexOf('<section id="wall"') < main.indexOf('<section id="empty"'), "the empty state stands where the wall stands");
  assert.equal((html.match(/<h1\b/g) ?? []).length, 1, "one h1");
});

test("the start button runs the same launch as + New session, in the app only", () => {
  const src = read("fleet/wall.js");
  assert.equal((src.match(/invoke\("launch_session"\)/g) ?? []).length, 1, "one launch call, shared by both buttons");
  assert.match(src, /newButton\.addEventListener\("click", \(\) => startSession\(newButton, newNote\)\)/);
  assert.match(src, /startButton\.addEventListener\("click", \(\) => startSession\(startButton, newNote\)\)/, "its answer shows in the bar, where it outlives the empty state");
  assert.match(src, /startButton\.hidden = !inTauri/);
  assert.match(src, /invoke\("get_launch_dir"\)/);
  assert.match(src, /const toClear = \(\) => endedIds\(sessions\)\.filter[\s\S]*press\(clearEnded, clearNote, \(\) => clearAll\(ids, tauri, \(id\) => cleared\.add\(id\)\)/, "the link clears through clear_session, ended sessions only, into its own note");
  assert.match(src, /clearEnded\.hidden = n === 0 \|\| !inTauri/, "the clear link, like Start, only in the app");
});

test("the empty state fades in, and not under reduced motion", () => {
  const css = read("fleet/wall.css");
  const motion = css.slice(css.indexOf("@media (prefers-reduced-motion: no-preference)"));
  assert.match(motion, /\.empty:not\(\[hidden\]\) \{ animation: empty-fade/);
  assert.ok(!/empty-fade/.test(css.slice(0, css.indexOf("@media (prefers-reduced-motion: no-preference)"))), "the fade sits only under no-preference");
  const fade = css.match(/@keyframes empty-fade \{([^}]*\{[^}]*\})*[^}]*\}/)?.[0] ?? "";
  assert.match(fade, /opacity/);
  assert.ok(!/translate|scale|rotate|transform/.test(fade), "a fade only");
});

test("the app registers the read-only launch folder command", () => {
  const main = read("../src-tauri/src/main.rs");
  assert.match(main, /launch::launch_session,\s*launch::get_launch_dir\s*\]/);
  const launch = read("../src-tauri/src/launch.rs");
  assert.match(launch, /pub async fn get_launch_dir\(app: tauri::AppHandle\) -> Option<String>/);
});

test("the demo shows the empty wall with ?demo&empty and the ended-only wall with ?demo&ended", async () => {
  globalThis.window ??= {};
  const { demoSessions } = await import("./fleet/feed.js");
  const all = [s("a", "working"), s("b", "ended"), s("c", "done"), s("d", "ended")];
  assert.deepEqual(demoSessions(all, "?demo&empty"), []);
  assert.deepEqual(demoSessions(all, "?demo&ended").map((x) => x.session_id), ["b", "d"]);
  assert.deepEqual(demoSessions(all, "?demo=2").map((x) => x.session_id), ["a", "b"]);
  assert.deepEqual(demoSessions(all, "?demo"), all);
});

test("a dev snapshot without `at` is still filtered by ?empty and ?ended", async () => {
  globalThis.window ??= {};
  const { demoSnapshot } = await import("./fleet/feed.js");
  const snap = { sessions: [s("a", "working"), s("b", "ended")], speaking: null };
  assert.deepEqual(demoSnapshot(snap, "?empty", 0).sessions, []);
  assert.deepEqual(demoSnapshot(snap, "?ended", 0).sessions.map((x) => x.session_id), ["b"]);
  assert.deepEqual(demoSnapshot(snap, "", 0), snap);
  const timed = demoSnapshot({ at: 100, sessions: [{ ...s("a", "done"), status_at: 90 }] }, "?demo", 160);
  assert.deepEqual(timed, { sessions: [{ ...s("a", "done"), status_at: 150 }] }, "times moved up to now, `at` dropped");
  assert.match(read("fleet/feed.js"), /const current = withWrapup\(demoSnapshot\(fleet, location\.search, now\), wrap && moved\(wrap\)\)/);
});
