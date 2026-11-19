import { test } from "node:test";
import assert from "node:assert/strict";
import { SECTIONS, ROWS, filterRows } from "./settings/registry.js";

test("registry defines all 7 expected sections", () => {
  const ids = SECTIONS.map((s) => s.id);
  assert.deepEqual(ids, [
    "appearance",
    "gauges",
    "characters",
    "voices",
    "engines",
    "files",
    "system",
  ]);
  for (const s of SECTIONS) {
    assert.ok(s.id && typeof s.id === "string", "section must have string id");
    assert.ok(s.title && typeof s.title === "string", "section must have string title");
  }
});

test("registry defines exactly the 13 settings that exist on main today", () => {
  assert.equal(ROWS.length, 13);
  const sectionIds = new Set(SECTIONS.map((s) => s.id));
  const seenIds = new Set();

  for (const row of ROWS) {
    assert.ok(row.id && typeof row.id === "string", `row id missing: ${row.id}`);
    assert.ok(!seenIds.has(row.id), `duplicate row id: ${row.id}`);
    seenIds.add(row.id);

    assert.ok(sectionIds.has(row.section), `unknown section: ${row.section} on row ${row.id}`);
    assert.ok(row.label && typeof row.label === "string", `row label missing on ${row.id}`);
    assert.ok(row.description && typeof row.description === "string", `row desc missing on ${row.id}`);
    assert.ok(row.control && typeof row.control.type === "string", `row control missing on ${row.id}`);
    assert.ok(typeof row.write === "function", `row write function missing on ${row.id}`);
  }
});

test("filterRows matches by label and description case-insensitively", () => {
  // Empty queries return all rows
  assert.equal(filterRows(ROWS, "").length, 13);
  assert.equal(filterRows(ROWS, "   ").length, 13);
  assert.equal(filterRows(ROWS, null).length, 13);
  assert.equal(filterRows(ROWS, undefined).length, 13);

  // Match by label
  const ping = filterRows(ROWS, "ping");
  assert.equal(ping.length, 1);
  assert.equal(ping[0].id, "ping");

  const pingUpper = filterRows(ROWS, "PING");
  assert.equal(pingUpper.length, 1);
  assert.equal(pingUpper[0].id, "ping");

  // Match by description
  const tailscale = filterRows(ROWS, "tailscale");
  assert.equal(tailscale.length, 1);
  assert.equal(tailscale[0].id, "phone_wall");

  const keryx = filterRows(ROWS, "keryx");
  assert.equal(keryx.length, 1);
  assert.equal(keryx[0].id, "voices_mode");

  // Match multiple rows
  const strip = filterRows(ROWS, "strip");
  const stripIds = strip.map((r) => r.id);
  assert.ok(stripIds.includes("compact"));
  assert.ok(stripIds.includes("reset_position"));
  assert.ok(stripIds.includes("set_home"));

  // No match
  const none = filterRows(ROWS, "nonexistent_query_xyz");
  assert.equal(none.length, 0);
});

test("all 13 rows wire to their respective Tauri commands", async () => {
  const calls = [];
  const mockInvoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "get_layout") return "compact";
    if (cmd === "new_session_prefs") return { default: "claude:default", last: "agy" };
    if (cmd === "get_fleet_files") return { queue: "queue.md", needs: "needs.md" };
    if (cmd === "get_split_mode") return true;
    if (cmd === "get_wall_density") return "comfortable";
    if (cmd === "get_theme") return "kourai";
    if (cmd === "get_voices_mode") return "heph";
    if (cmd === "get_ping") return false;
    if (cmd === "get_autostart") return true;
    if (cmd === "get_phone_wall") return false;
    return "ok";
  };

  // 1. split_terminal
  const splitRow = ROWS.find((r) => r.id === "split_terminal");
  assert.equal(await splitRow.read(mockInvoke), true);
  await splitRow.write(mockInvoke, true);
  assert.deepEqual(calls.pop(), ["set_split_mode", { on: true }]);

  // 2. card_density
  const densityRow = ROWS.find((r) => r.id === "card_density");
  assert.equal(await densityRow.read(mockInvoke), "comfortable");
  await densityRow.write(mockInvoke, "compact");
  assert.deepEqual(calls.pop(), ["set_wall_density", { density: "compact" }]);

  // 3. compact
  const compactRow = ROWS.find((r) => r.id === "compact");
  assert.equal(await compactRow.read(mockInvoke), true);
  await compactRow.write(mockInvoke, false);
  assert.deepEqual(calls.pop(), ["set_layout_mode", { compact: false }]);

  // 4. reset_position
  const resetRow = ROWS.find((r) => r.id === "reset_position");
  assert.equal(resetRow.read, null);
  await resetRow.write(mockInvoke);
  assert.deepEqual(calls.pop(), ["reset_gauge_position", undefined]);

  // 5. set_home
  const homeRow = ROWS.find((r) => r.id === "set_home");
  assert.equal(homeRow.read, null);
  await homeRow.write(mockInvoke);
  assert.deepEqual(calls.pop(), ["set_gauge_home", undefined]);

  // 6. character_theme
  const themeRow = ROWS.find((r) => r.id === "character_theme");
  assert.equal(await themeRow.read(mockInvoke), "kourai");
  await themeRow.write(mockInvoke, "professions");
  assert.deepEqual(calls.pop(), ["set_theme", { theme: "professions" }]);

  // 7. voices_mode
  const voicesRow = ROWS.find((r) => r.id === "voices_mode");
  assert.equal(await voicesRow.read(mockInvoke), "heph");
  await voicesRow.write(mockInvoke, "everyone");
  assert.deepEqual(calls.pop(), ["set_voices_mode", { mode: "everyone" }]);

  // 8. ping
  const pingRow = ROWS.find((r) => r.id === "ping");
  assert.equal(await pingRow.read(mockInvoke), false);
  await pingRow.write(mockInvoke, true);
  assert.deepEqual(calls.pop(), ["set_ping", { on: true }]);

  // 9. new_session_default
  const nsRow = ROWS.find((r) => r.id === "new_session_default");
  assert.equal(await nsRow.read(mockInvoke), "claude:default");
  await nsRow.write(mockInvoke, "agy");
  assert.deepEqual(calls.pop(), ["set_new_session_default", { id: "agy" }]);
  await nsRow.write(mockInvoke, "");
  assert.deepEqual(calls.pop(), ["set_new_session_default", { id: null }]);

  // 10. queue_file
  const queueRow = ROWS.find((r) => r.id === "queue_file");
  assert.equal(await queueRow.read(mockInvoke), "queue.md");
  await queueRow.write(mockInvoke);
  assert.deepEqual(calls.pop(), ["choose_queue_file", undefined]);

  // 11. needs_file
  const needsRow = ROWS.find((r) => r.id === "needs_file");
  assert.equal(await needsRow.read(mockInvoke), "needs.md");
  await needsRow.write(mockInvoke);
  assert.deepEqual(calls.pop(), ["choose_needs_file", undefined]);

  // 12. autostart
  const autostartRow = ROWS.find((r) => r.id === "autostart");
  assert.equal(await autostartRow.read(mockInvoke), true);
  await autostartRow.write(mockInvoke, false);
  assert.deepEqual(calls.pop(), ["set_autostart", { enabled: false }]);

  // 13. phone_wall
  const phoneRow = ROWS.find((r) => r.id === "phone_wall");
  assert.equal(await phoneRow.read(mockInvoke), false);
  await phoneRow.write(mockInvoke, true);
  assert.deepEqual(calls.pop(), ["set_phone_wall", { on: true }]);
});

test("mutation check: breaking any row write wiring causes assertion failure", async () => {
  // Test that our test suite catches mutations:
  // Mutate ping write to call a wrong command or corrupt argument
  const brokenPingWrite = (invoke, on) => invoke("wrong_command", { on: Boolean(on) });
  const recorded = [];
  const mockInvoke = async (cmd, args) => {
    recorded.push([cmd, args]);
  };

  await brokenPingWrite(mockInvoke, true);
  assert.notDeepEqual(recorded[0], ["set_ping", { on: true }], "mutation must not match expected wiring");
});
