// A compact card's name width as --name-w (fleet/namewidth.js, #535): which
// cards it measures, what it writes, and that it reads before it writes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { syncNameWidths } from "./fleet/namewidth.js";

// A card with a name of `text`, recording what is set on its style.
const cardOf = (text) => {
  const name = { textContent: text };
  const props = new Map();
  return {
    name,
    props,
    querySelector: (sel) => (sel === ".name" ? name : null),
    style: { setProperty: (k, v) => props.set(k, v), removeProperty: (k) => props.delete(k) },
  };
};

test("each card gets its name's own width, rounded up to a whole pixel", () => {
  const cards = [cardOf("Mneme"), cardOf("Hephaestus")];
  const widths = { Mneme: 48.2, Hephaestus: 96 };
  const n = syncNameWidths(cards, 0, new WeakMap(), (el) => widths[el.textContent]);
  assert.equal(n, 2);
  assert.equal(cards[0].props.get("--name-w"), "49px");
  assert.equal(cards[1].props.get("--name-w"), "96px");
});

test("a card is measured again only when its name or the face changes", () => {
  const card = cardOf("Mneme");
  const measured = new WeakMap();
  let reads = 0;
  const measure = () => {
    reads++;
    return 50;
  };
  syncNameWidths([card], 0, measured, measure);
  assert.equal(syncNameWidths([card], 0, measured, measure), 0, "same name, same face");
  assert.equal(reads, 1);
  card.name.textContent = "Aletheia";
  assert.equal(syncNameWidths([card], 0, measured, measure), 1, "a new name");
  assert.equal(syncNameWidths([card], 1, measured, measure), 1, "a font loaded");
  assert.equal(reads, 3);
});

test("every width is read before any is written, so the wall lays out once", () => {
  const cards = [cardOf("A"), cardOf("B"), cardOf("C")];
  const log = [];
  for (const c of cards) c.style.setProperty = () => log.push("write");
  syncNameWidths(cards, 0, new WeakMap(), () => {
    log.push("read");
    return 10;
  });
  assert.deepEqual(log, ["read", "read", "read", "write", "write", "write"]);
});

test("a name not drawn yet (0 px) waits for the next pass instead of setting no floor", () => {
  const card = cardOf("Mneme");
  const measured = new WeakMap();
  assert.equal(syncNameWidths([card], 0, measured, () => 0), 0);
  assert.equal(card.props.has("--name-w"), false);
  assert.equal(syncNameWidths([card], 0, measured, () => 50), 1, "measured once it is drawn");
  assert.equal(card.props.get("--name-w"), "50px");
});

test("a card whose name goes empty loses its floor", () => {
  const card = cardOf("Mneme");
  const measured = new WeakMap();
  syncNameWidths([card], 0, measured, () => 50);
  card.name.textContent = "";
  let reads = 0;
  assert.equal(
    syncNameWidths([card], 0, measured, () => {
      reads++;
      return 0;
    }),
    1,
  );
  assert.equal(card.props.has("--name-w"), false);
  assert.equal(reads, 0, "an empty name is not measured");
});

test("wall.css floors the compact name's column at --name-w up to 90 px, the same in every engine", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  assert.match(css, /--name-floor: calc\(min\(var\(--name-w, 0px\), 90px\) \+ var\(--head-gap\)\)/);
  assert.match(css, /grid-template-columns: var\(--wall-face\) minmax\(var\(--name-floor\), 1fr\) auto max-content max-content;/);
  assert.doesNotMatch(css, /calc-size\(/, "no engine-only fork");
});
