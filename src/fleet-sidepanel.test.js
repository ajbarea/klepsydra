import { test } from "node:test";
import assert from "node:assert/strict";

globalThis.window ??= {};
const side = await import("./fleet/sidepanel.js");

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

/** Minimal DOM harness for createSidePanel (no browser required). */
function domPanelHarness({ wideMatches = true, width = 1920 } = {}) {
  const storage = new Map();
  const listeners = new Map();
  const mediaListeners = new Set();
  const classes = new Set();
  const props = new Map();
  const makeEl = (tag, id = "") => {
    const elListeners = new Map();
    const attrs = new Map();
    const el = {
      tagName: tag,
      id,
      hidden: false,
      dataset: {},
      style: {
        _props: new Map(),
        setProperty: (k, v) => el.style._props.set(k, v),
        getPropertyValue: (k) => el.style._props.get(k) ?? "",
      },
      children: [],
      contains: (node) => node === el || el.children.includes(node),
      querySelector: (sel) => el.children.find((c) => c._sel === sel) ?? null,
      querySelectorAll: () => [],
      addEventListener: (t, fn) => {
        if (!elListeners.has(t)) elListeners.set(t, []);
        elListeners.get(t).push(fn);
      },
      dispatch(t, evt = {}) {
        for (const fn of elListeners.get(t) ?? []) fn({ preventDefault() {}, stopPropagation() {}, ...evt });
      },
      setAttribute: (k, v) => attrs.set(k, String(v)),
      getAttribute: (k) => attrs.get(k) ?? null,
      removeAttribute: (k) => attrs.delete(k),
      focus() {
        doc.activeElement = el;
      },
      blur() {
        if (doc.activeElement === el) doc.activeElement = doc.body;
      },
    };
    return el;
  };
  const doc = {
    body: {
      classList: {
        toggle: (cls, force) => (force ? classes.add(cls) : classes.delete(cls)),
        contains: (cls) => classes.has(cls),
      },
    },
    documentElement: {
      style: {
        setProperty: (k, v) => props.set(k, v),
        getProperty: (k) => props.get(k) ?? "",
      },
    },
    activeElement: null,
    querySelector: () => null,
    addEventListener: (t, fn) => {
      if (!listeners.has(t)) listeners.set(t, []);
      listeners.get(t).push(fn);
    },
  };
  doc.activeElement = doc.body;
  const media = {
    get matches() {
      return wideMatches;
    },
    addEventListener: (_t, fn) => mediaListeners.add(fn),
  };
  const room = makeEl("SECTION", "needs-room");
  const title = makeEl("H2", "needs-title");
  title._sel = "#needs-title";
  const grip = makeEl("DIV");
  grip._sel = ".needs-resize";
  const close = makeEl("BUTTON");
  close._sel = ".needs-close";
  const body = makeEl("DIV");
  body._sel = ".needs-body";
  const live = makeEl("P");
  live._sel = ".needs-live";
  room.children.push(title, grip, close, body, live);
  const button = makeEl("BUTTON", "needs-pill");
  const tab = makeEl("BUTTON", "needs-tab");

  const prev = {
    document: globalThis.document,
    localStorage: globalThis.localStorage,
    matchMedia: globalThis.matchMedia,
    innerWidth: globalThis.innerWidth,
    addEventListener: globalThis.addEventListener,
    HTMLElement: globalThis.HTMLElement,
  };
  Object.assign(globalThis, {
    document: doc,
    localStorage: {
      getItem: (k) => storage.get(k) ?? null,
      setItem: (k, v) => storage.set(k, String(v)),
    },
    matchMedia: () => media,
    innerWidth: width,
    addEventListener: (t, fn) => {
      if (!listeners.has(t)) listeners.set(t, []);
      listeners.get(t).push(fn);
    },
    HTMLElement: Object,
  });

  return {
    room, title, grip, close, button, tab, doc, classes, props, storage,
    setWide(nextWide, nextWidth) {
      wideMatches = nextWide;
      globalThis.innerWidth = nextWidth;
      for (const fn of mediaListeners) fn();
    },
    restore() {
      Object.assign(globalThis, prev);
    },
  };
}

test("a non-dialog sidepanel supports active(), push vs overlay, dblclick reset, Esc focus return, and saveWidth/setWidth", () => {
  const h = domPanelHarness({ wideMatches: true, width: 1920 });
  try {
    h.storage.set("klepsydra.needs.view", "docked");
    let isActive = false;
    const saved = [];
    let resized = 0;
    let opens = 0;
    let shuts = 0;
    const edge = side.createEdge();
    const panel = side.createSidePanel({
      name: "needs",
      dialog: h.room,
      button: h.button,
      tab: h.tab,
      edge,
      active: () => isActive,
      persistView: false,
      wireButton: false,
      saveWidth: (w) => saved.push(w),
      returnTo: () => h.button,
      onOpen: () => opens++,
      onShut: () => shuts++,
      onResized: () => resized++,
    });

    assert.equal(panel.isOpen, false, "inactive panel starts shut");
    assert.equal(h.tab.hidden, true, "inactive panel hides its tab");
    assert.equal(h.grip.hidden, true, "inactive panel hides its resize handle");
    assert.equal(h.classes.has("needs-docked"), false);

    // Activate Amber Door (Layout E): shut at start despite stored view (persistView: false).
    isActive = true;
    panel.sync();
    assert.equal(panel.isOpen, false, "persistView: false ignores stored view on load");
    assert.equal(h.tab.hidden, false, "wide shut panel shows edge tab");
    assert.equal(h.classes.has("needs-tabbed"), true);

    // Open docked (push).
    panel.open();
    assert.equal(panel.isOpen, true);
    assert.equal(h.room.hidden, false);
    assert.equal(h.room.dataset.mode, "docked");
    assert.equal(h.classes.has("needs-docked"), true);
    assert.equal(h.props.get("--dock-w"), "480px");
    assert.equal(edge.dockedWidth(), 480);
    assert.equal(h.grip.hidden, false);
    assert.equal(opens, 1);

    // Keyboard resize via ArrowLeft and End (no full mode without full button).
    h.grip.dispatch("keydown", { key: "ArrowLeft" });
    assert.equal(edge.dockedWidth(), 496);
    assert.equal(saved.at(-1), 496);
    h.grip.dispatch("keydown", { key: "End" });
    h.grip.dispatch("keydown", { key: "End" });
    assert.equal(edge.dockedWidth(), 900);
    assert.equal(h.room.dataset.mode, "docked", "no full mode when no full button exists");

    // Double-click resets width to 480.
    h.grip.dispatch("dblclick");
    assert.equal(edge.dockedWidth(), 480);
    assert.equal(saved.at(-1), 480);
    assert.equal(resized, 1);

    // Loaded width from prefs.json applies via setWidth().
    panel.setWidth(620);
    assert.equal(edge.dockedWidth(), 620);

    // Narrow viewport switches to overlay: no wall push, grip hidden.
    h.setWide(false, 945);
    assert.equal(h.room.dataset.mode, "overlay");
    assert.equal(h.classes.has("needs-docked"), false);
    assert.equal(edge.dockedWidth(), 0);
    assert.equal(h.grip.hidden, true);

    // Escape closes and returns focus to the toggle button.
    h.title.focus();
    h.room.dispatch("keydown", { key: "Escape" });
    assert.equal(panel.isOpen, false);
    assert.equal(h.room.hidden, true);
    assert.equal(h.doc.activeElement, h.button);
    assert.equal(shuts, 1);

    // Deactivating (switching back to B/D) clears docked/tabbed classes.
    h.setWide(true, 1920);
    assert.equal(h.tab.hidden, false);
    isActive = false;
    panel.sync();
    assert.equal(h.tab.hidden, true);
    assert.equal(h.classes.has("needs-tabbed"), false);
  } finally {
    h.restore();
  }
});
