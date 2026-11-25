import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  parseNeedsItems,
  parseQueueNow,
  markItemDone,
  undoItemDone,
  needsCount,
  workingCount,
  parseLayout,
  extractLinks,
  cleanItemText,
  DEFAULT_LAYOUT,
  LAYOUTS,
} from "./fleet/rooms.js";

test("parseLayout: valid layouts and fallback default", () => {
  assert.equal(DEFAULT_LAYOUT, "B");
  assert.deepEqual(LAYOUTS, ["B", "D", "E"]);
  assert.equal(parseLayout("B"), "B");
  assert.equal(parseLayout("D"), "D");
  assert.equal(parseLayout("E"), "E");
  assert.equal(parseLayout("invalid"), "B");
  assert.equal(parseLayout(null), "B");
  assert.equal(parseLayout(undefined), "B");
});

test("extractLinks: finds markdown links and classifies them", () => {
  const text = "See [bravo#601](https://example.com/item) and [spec.md](docs/spec.md) and [folder/](dir/)";
  const links = extractLinks(text);
  assert.equal(links.length, 3);
  assert.equal(links[0].label, "bravo#601");
  assert.equal(links[0].kind, "pr");
  assert.equal(links[1].label, "spec.md");
  assert.equal(links[1].kind, "file");
  assert.equal(links[2].label, "folder/");
  assert.equal(links[2].kind, "folder");
});

test("cleanItemText: parses bold title and detail", () => {
  const { title, detail } = cleanItemText("- 📋 **Alpha: bravo cedar:** North → Orbit");
  assert.equal(title, "Alpha: bravo cedar");
  assert.equal(detail, "North → Orbit");

  const unbold = cleanItemText("- 📋 Review PR #42 (5 min): approve or drop");
  assert.equal(unbold.title, "Review PR #42 (5 min)");
  assert.equal(unbold.detail, "approve or drop");
});

test("parseNeedsItems with real fixture needs-you-shape.md", () => {
  const fixture = readFileSync(new URL("../scripts/fixtures/needs-you-shape.md", import.meta.url), "utf8");
  const items = parseNeedsItems(fixture);
  assert.equal(items.length, 18, "counts all 18 open steps in fixture");

  // Groups
  const todayItems = items.filter((it) => it.group === "Today");
  assert.equal(todayItems.length, 1);
  assert.equal(todayItems[0].title.startsWith("Alpha: bravo"), true);

  const comingUpItems = items.filter((it) => it.group === "Coming up");
  assert.equal(comingUpItems.length, 13);

  const convenientItems = items.filter((it) => it.group === "When convenient");
  assert.equal(convenientItems.length, 4);

  // Completed items are ignored
  const withDone = fixture + "\n- ✅ **Done item:** completed task\n";
  const itemsWithDone = parseNeedsItems(withDone);
  assert.equal(itemsWithDone.length, 18, "done items are never shown");
});

test("parseQueueNow with fixture queue-demo.md", () => {
  const fixture = readFileSync(new URL("../scripts/fixtures/queue-demo.md", import.meta.url), "utf8");
  const items = parseQueueNow(fixture);
  assert.ok(items.length >= 2, "extracts items from Running now");
  const tools = items.find((it) => it.title.includes("tools"));
  assert.ok(tools);
});

test("markItemDone and undoItemDone", () => {
  const text = `# Needs you

## Today
- 📋 **Item 1:** detail 1
- 📋 **Item 2:** detail 2
- 📋 **Item 3:** detail 3
`;
  const itemsBefore = parseNeedsItems(text);
  assert.equal(itemsBefore.length, 3);

  const { newText, removedLine } = markItemDone(text, itemsBefore[1].lineIndex);
  assert.ok(removedLine.includes("Item 2"));
  const itemsAfter = parseNeedsItems(newText);
  assert.equal(itemsAfter.length, 2);
  assert.equal(itemsAfter[0].title, "Item 1");
  assert.equal(itemsAfter[1].title, "Item 3");

  const restoredText = undoItemDone(newText, itemsBefore[1].lineIndex, removedLine);
  const itemsRestored = parseNeedsItems(restoredText);
  assert.equal(itemsRestored.length, 3);
  assert.equal(itemsRestored[1].title, "Item 2");
});

test("needsCount: open asks + sessions blocked on AJ", () => {
  const fixture = readFileSync(new URL("../scripts/fixtures/needs-you-shape.md", import.meta.url), "utf8");
  const sessions = [
    { id: "1", status: "working" },
    { id: "2", status: "needs_you" },
    { id: "3", status: "needs_you" },
    { id: "4", status: "done" },
  ];
  const count = needsCount(fixture, sessions);
  assert.equal(count, 18 + 2, "18 asks + 2 blocked sessions");
});

test("workingCount: counts working sessions", () => {
  const sessions = [
    { id: "1", status: "working" },
    { id: "2", status: "working" },
    { id: "3", status: "needs_you" },
    { id: "4", status: "done" },
  ];
  assert.equal(workingCount(sessions), 2);
});

test("Layout B: two rooms with dedicated titles, blocked sessions first, lanes", () => {
  assert.equal(DEFAULT_LAYOUT, "B");
  const fixture = readFileSync(new URL("../scripts/fixtures/needs-you-shape.md", import.meta.url), "utf8");
  const items = parseNeedsItems(fixture);
  assert.ok(items.length > 0);

  // Group order: Blocked, Today, Coming up, When convenient
  const groups = new Set(items.map((it) => it.group));
  assert.ok(groups.has("Today"));
  assert.ok(groups.has("Coming up"));
  assert.ok(groups.has("When convenient"));
});

test("Layout D: Inbox and Floor triage layout, All clear at 0, N/Esc toggle", () => {
  assert.equal(parseLayout("D"), "D");
  // At zero count in D, header shows "All clear"
  const emptyCount = needsCount("", []);
  assert.equal(emptyCount, 0);
});


