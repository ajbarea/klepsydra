import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

globalThis.window ??= {};
const side = await import("./fleet/sidepanel.js");
const queue = await import("./fleet/queuepanel.js");

test("the Queue keeps its stored keys and the Ledger has its own, none shared", () => {
  assert.deepEqual(side.storeKeys("queue"), {
    width: "klepsydra.queue.width",
    view: "klepsydra.queue.view",
    open: "klepsydra.queue.open",
    text: "klepsydra.queue.text",
  }, "an installed build's Queue state reads back");
  const ledger = Object.values(side.storeKeys("ledger"));
  assert.ok(ledger.every((k) => k.startsWith("klepsydra.ledger.")), ledger.join());
  const shared = ledger.filter((k) => Object.values(side.storeKeys("queue")).includes(k));
  assert.deepEqual(shared, []);
});

test("the Queue's snap and text-size rules are the side panel's, not a copy", () => {
  for (const name of ["DOCK_MIN_PX", "WIDTH", "WALL_MIN", "TEXT_SIZES", "clampWidth", "snap", "parseView", "separatorKey", "textSize", "stepText", "textKey"]) {
    assert.equal(queue[name], side[name], name);
  }
  const src = readFileSync(new URL("./fleet/queuepanel.js", import.meta.url), "utf8");
  assert.doesNotMatch(src, /export (const|function) (DOCK_MIN_PX|WIDTH|snap|separatorKey|textKey)\b/);
});

/** A stand-in for a panel on the edge: its view, and what the edge asked of it. */
function fake(edge, name, view = "shut") {
  const p = {
    name,
    view,
    laid: 0,
    get isOpen() {
      return p.view !== "shut";
    },
    shuts: 0,
    shut() {
      p.shuts++;
      p.view = "shut";
    },
    layout() {
      p.laid++;
    },
    open(to = "docked") {
      edge.opening(p);
      p.view = to;
      edge.changed(p);
    },
  };
  edge.join(p);
  return p;
}

test("the edge holds one open panel: opening one shuts the other, docked or full", () => {
  for (const to of ["docked", "full"]) {
    const edge = side.createEdge();
    const ledger = fake(edge, "ledger");
    const q = fake(edge, "queue", "docked");
    ledger.open(to);
    assert.deepEqual([ledger.view, q.view], [to, "shut"], to);
    q.open(to);
    assert.deepEqual([ledger.view, q.view], ["shut", to], to);
  }
});

test("a shut panel's tab shows only while no other panel holds the edge", () => {
  const edge = side.createEdge();
  const ledger = fake(edge, "ledger");
  const q = fake(edge, "queue");
  assert.deepEqual([edge.othersOpen(ledger), edge.othersOpen(q)], [false, false], "both shut: both tabs");
  q.open();
  assert.deepEqual([edge.othersOpen(ledger), edge.othersOpen(q)], [true, false], "the Queue open: the Ledger's tab goes");
  assert.equal(ledger.laid, 1, "and the Ledger is laid out again to hide it");
  assert.equal(q.laid, 0, "the panel that changed lays itself out");
  q.shut();
  edge.changed(q);
  assert.deepEqual([edge.othersOpen(ledger), ledger.laid], [false, 2], "shut again: its tab is back");
});

test("an edge shuts nothing when the panel opening is the only one open", () => {
  const edge = side.createEdge();
  const q = fake(edge, "queue", "docked");
  const ledger = fake(edge, "ledger");
  q.open("full");
  assert.deepEqual([q.view, ledger.view], ["full", "shut"]);
  assert.deepEqual([q.shuts, ledger.shuts], [0, 0], "docked to full is no shut: the Ledger would lose its session");
});

test("the edge reports the docked panel's room and any drag, and knows its own dialogs", () => {
  const edge = side.createEdge();
  const panel = (width, resizing) => ({ dialog: {}, isOpen: width > 0, dockedWidth: () => width, resizing, layout() {}, shut() {} });
  const ledger = panel(0, false);
  const q = panel(480, false);
  edge.join(ledger);
  edge.join(q);
  assert.equal(edge.dockedWidth(), 480, "the wall gives up the docked panel's width");
  assert.equal(edge.resizing, false);
  ledger.resizing = true;
  assert.equal(edge.resizing, true, "a drag of either separator holds Auto's measure");
  assert.equal(edge.holds(q.dialog), true);
  assert.equal(edge.holds({}), false, "another dialog, such as the portrait, is not the edge's");
});
