import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { healthView } from "./fleet/health.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const check = (status, name, detail = "") => ({ status, check: name, detail });

test("without a reading the button stays hidden", () => {
  for (const v of [null, undefined, "x", 3, {}, { checks: "no" }]) assert.equal(healthView(v).hidden, true);
});

test("all ok says so; warnings keep it ok but mark it and are counted", () => {
  const ok = healthView({ checks: [check("ok", "resume service", "active")], stale: false });
  assert.deepEqual([ok.hidden, ok.label, ok.tone, ok.title], [false, "Fleet ok", "ok", "fleet doctor: every check ok"]);
  const warn = healthView({ checks: [check("ok", "a"), check("warn", "briefs", "stale: task-x.src")] });
  assert.deepEqual([warn.label, warn.tone, warn.note], ["Fleet ok", "warn", "1 warning"]);
});

test("a failing check turns it red and names each check with its status and detail", () => {
  const v = healthView({ checks: [check("FAIL", "pane watcher", "none running"), check("FAIL", "agents", "gone: x"), check("ok", "resume service", "active")] });
  assert.deepEqual([v.label, v.tone, v.title], ["Fleet 2 failing", "red", "fleet doctor: 2 checks failing"]);
  assert.deepEqual(v.rows[0], { status: "FAIL", statusLabel: "Failing", check: "pane watcher", detail: "none running" });
});

test("a doctor that stopped reporting says so before anything else, and odd rows are dropped", () => {
  const v = healthView({ checks: [check("FAIL", "x"), check("bad", "y"), { status: "ok" }, null], stale: true });
  assert.deepEqual([v.label, v.tone], ["Fleet ?", "stale"]);
  assert.match(v.note, /stopped/);
  assert.equal(v.rows.length, 1, "its last reading still shows");
});

test("the wall wires the button to the app and the phone, and the app registers the command", () => {
  const wall = read("./fleet/wall.js");
  assert.match(wall, /if \(inTauri\) follow\("health_subscribe", showHealth\)/);
  assert.match(wall, /if \(served && "health" in \(message \?\? \{\}\)\) showHealth\(message\.health\);/);
  const html = read("./wall.html");
  assert.match(html, /<button type="button" id="health-open" popovertarget="health" data-phone hidden>Fleet<\/button>/);
  assert.ok(html.indexOf('id="health-open"') < html.indexOf('class="tools"'), "outside the desktop tool group, which the phone hides");
  const main = read("../src-tauri/src/main.rs");
  assert.match(main, /fleet::ci_subscribe,\s*fleet::health_subscribe,/);
  assert.match(main, /fleet::start_health\(app\.handle\(\), klepsydra_dir\(app\.handle\(\)\)\);/);
});
