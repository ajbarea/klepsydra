import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ciView } from "./fleet/ci.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const red = (over = {}) => ({
  repo: "pharos", workflow: "CI", branch: "main", pr: null, conclusion: "failure",
  url: "https://github.com/ajbarea/pharos/actions/runs/5",
  failing: { job: "test", step: "pytest" },
  triage: { state: "done", cause: "test_croissant fails", location: "tests/test_c.py:12" },
  ...over,
});

test("without a CI watch the button stays hidden", () => {
  for (const v of [null, undefined, "x", 3]) assert.equal(ciView(v).hidden, true);
});

test("all green says so, with the Dependabot runs kept for the morning", () => {
  const v = ciView({ repos: 14, red: [], dependabot: 2, unread: 0, stale: false });
  assert.deepEqual([v.hidden, v.label, v.tone], [false, "CI ok", "ok"]);
  assert.equal(v.title, "CI green across 14 repos");
  assert.equal(v.note, "2 Dependabot runs for the morning");
});

test("a red run names its repo, workflow, branch or PR, failing step and triaged cause", () => {
  const v = ciView({ repos: 14, red: [red(), red({ repo: "klepsydra", pr: 160, triage: { state: "unavailable" } })], dependabot: 0, unread: 1 });
  assert.deepEqual([v.label, v.tone], ["CI 2 red", "red"]);
  assert.deepEqual(v.rows[0], {
    head: "pharos · CI · main", step: "test › pytest",
    cause: "test_croissant fails (tests/test_c.py:12)", url: "https://github.com/ajbarea/pharos/actions/runs/5",
  });
  assert.equal(v.rows[1].head, "klepsydra · CI · PR #160");
  assert.match(v.rows[1].cause, /not installed/);
  assert.equal(v.note, "1 repo not read");
});

test("only a github.com link is a link", () => {
  assert.equal(ciView({ red: [red({ url: "javascript:alert(1)" })] }).rows[0].url, null);
});

test("a watch that stopped reporting says so before anything else", () => {
  const v = ciView({ repos: 14, red: [red()], stale: true });
  assert.deepEqual([v.label, v.tone], ["CI ?", "stale"]);
  assert.match(v.note, /stopped reporting/);
  assert.equal(v.rows.length, 1, "its last reading still shows");
});

test("the wall wires the button to the app and the phone, and the app registers the command", () => {
  const wall = read("./fleet/wall.js");
  assert.match(wall, /if \(inTauri\) follow\("ci_subscribe", showCi\)/);
  assert.match(wall, /if \(served && "ci" in \(message \?\? \{\}\)\) showCi\(message\.ci\);/);
  const html = read("./wall.html");
  assert.match(html, /<button type="button" id="ci-open" popovertarget="ci" data-phone hidden>CI<\/button>/, "shown on the phone too");
  assert.ok(html.indexOf('id="ci-open"') < html.indexOf('class="tools"'), "outside the desktop tool group, which the phone hides");
  assert.match(read("../src-tauri/src/main.rs"), /fleet::queue_subscribe,\s*fleet::ci_subscribe,/);
  assert.match(read("../src-tauri/src/main.rs"), /fleet::start_ci\(app\.handle\(\), klepsydra_dir\(app\.handle\(\)\)\);/);
});
