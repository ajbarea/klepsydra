import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build, EMPTY, parse, present, queueLabel, render, safeHref, sections, textOf, toTree } from "./fleet/queue.js";

const FIXTURE = readFileSync(new URL("../scripts/fixtures/queue-demo.md", import.meta.url), "utf8");

/**
 * This thread's CPU time for `f()`, in ms: neither a loaded machine's waits
 * nor the GC helper threads count.
 */
function cpuMs(f) {
  const start = process.threadCpuUsage();
  f();
  const { user, system } = process.threadCpuUsage(start);
  return (user + system) / 1000;
}

/**
 * Asserts `run(n)` costs grow linearly, as Go's checkLinear does: the best of
 * five CPU times at n and 4n, where linear work grows about 4-fold and
 * quadratic 16-fold. `n` doubles until a run takes 50 ms, well past timer
 * grain and JIT warm-up, or reaches 2^24; a run that cheap there passes.
 */
function assertLinear(run, n) {
  const best = (m) => Math.min(...Array.from({ length: 5 }, () => cpuMs(() => run(m))));
  let small = best(n);
  while (small < 50 && n < 2 ** 24) small = best((n *= 2));
  if (small < 50) return;
  const large = best(4 * n);
  assert.ok(large < 8 * small, `n=${n}: ${small.toFixed(1)} ms, 4n: ${large.toFixed(1)} ms`);
}

// A just-enough DOM that records every attribute set and refuses markup.
class El {
  constructor(tag) {
    this.tag = tag;
    this.kids = [];
    this.attrs = {};
    this.dataset = {};
    this.listeners = {};
    this.className = "";
    this.title = "";
  }
  set innerHTML(_) { throw new Error("innerHTML assigned"); }
  set outerHTML(_) { throw new Error("outerHTML assigned"); }
  insertAdjacentHTML() { throw new Error("insertAdjacentHTML called"); }
  set textContent(t) { this.kids = [{ text: String(t) }]; }
  get textContent() { return this.kids.map((k) => (k instanceof El ? k.textContent : k.text)).join(""); }
  append(...k) { this.kids.push(...k); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  click() { (this.listeners.click ?? []).forEach((fn) => fn({ target: this })); }
  all(pred, out = []) {
    for (const k of this.kids) if (k instanceof El) { if (pred(k)) out.push(k); k.all(pred, out); }
    return out;
  }
}
const doc = { createElement: (t) => new El(t), createTextNode: (text) => ({ text }), write() { throw new Error("document.write"); } };

function dom(text, opened) {
  const root = new El("div");
  const copied = [];
  for (const n of build(render(text, opened).nodes, doc, { copy: (t) => copied.push(t) })) root.append(n);
  return { root, copied };
}
const find = (root, tag) => root.all((e) => e.tag === tag);
const byText = (root, tag, re) => find(root, tag).find((e) => re.test(e.textContent));

test("headings, ordered and nested lists, bold and inline code render as elements", () => {
  const { root } = dom(FIXTURE);
  assert.equal(find(root, "h3")[0].textContent, "Claude queue", "the file's # sits under the panel's own h2");
  assert.deepEqual(find(root, "h4").map((h) => h.textContent), ["Needs you (short, today)", "Running now", "Queued", "Answers"]);
  const needs = find(root, "details")[0];
  const ol = find(needs, "ol")[0];
  assert.equal(ol.kids.filter((k) => k.tag === "li").length, 5);
  const running = find(root, "details")[1];
  const nested = find(running, "ul");
  assert.ok(nested.length >= 2 && find(nested[0], "ul").length >= 1, "a list inside a list item");
  assert.ok(byText(root, "strong", /^How it runs:$/));
  assert.ok(find(root, "code").some((c) => c.textContent === "~/.local/state/orchestrator/"));
  assert.ok(find(root, "table").length === 1 && find(root, "th").length === 2);
  assert.equal(find(root, "th")[1].className, "q-align-right");
  assert.ok(find(root, "blockquote").length === 1 && find(root, "hr").length === 1);
});

test("an ordered list keeps its start number", () => {
  const { root } = dom("3. three\n4. four\n");
  assert.equal(find(root, "ol")[0].attrs.start, "3");
  assert.equal(find(dom("1. one\n").root, "ol")[0].attrs.start, undefined);
});

test("every fenced code block has a Copy button that copies its text", () => {
  const { root, copied } = dom(FIXTURE);
  const blocks = root.all((e) => e.className === "q-code");
  assert.equal(blocks.length, 2);
  for (const b of blocks) {
    const button = b.kids.find((k) => k.tag === "button");
    assert.equal(button.textContent, "Copy");
    assert.equal(button.attrs["aria-label"], "Copy code");
    button.click();
  }
  assert.ok(copied[0].startsWith("cp ~/.claude/settings.json") && !copied[0].endsWith("\n"));
  assert.ok(copied[1].includes("[Service]"));
  // An indented code block too.
  const { root: r2, copied: c2 } = dom("text\n\n    make all\n");
  r2.all((e) => e.tag === "button")[0].click();
  assert.deepEqual(c2, ["make all"]);
});

test("a safe link is its text with the address on hover and a Copy link button; nothing has an href", () => {
  const { root, copied } = dom(FIXTURE);
  const link = byText(root, "span", /^help page$/);
  assert.equal(link.className, "q-link");
  assert.equal(link.title, "https://support.example.com/calendar/export");
  const buttons = root.all((e) => e.tag === "button" && e.textContent === "Copy link");
  assert.deepEqual(
    buttons.map((b) => b.attrs["aria-label"]),
    ["Copy link: https://support.example.com/calendar/export", "Copy link: mailto:desk@example.com", "Copy link: https://tracker.example.com/items/42"],
  );
  buttons[1].click();
  assert.deepEqual(copied, ["mailto:desk@example.com"]);
  assert.ok(root.all((e) => "href" in e.attrs || "src" in e.attrs || Object.keys(e.attrs).some((a) => /^on|^style$/i.test(a))).length === 0);
  assert.ok(root.all((e) => e.tag === "a" || e.tag === "img" || e.tag === "script").length === 0);
});

test("javascript:, data:, vbscript:, file: and relative links are dropped to plain text", () => {
  // markdown-it's own check never makes these links: the source shows as text.
  for (const href of ["javascript:alert(1)", " JaVaScRiPt:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "vbscript:x", "file:///etc/passwd"]) {
    const { root } = dom(`[label](<${href}>)`);
    assert.equal(root.all((e) => e.tag === "button" || e.className === "q-link").length, 0, href);
    assert.match(root.textContent, /label/, href);
  }
  // These it parses as links; the panel's own check drops them to their text.
  for (const href of ["/relative", "notes.md", "//host/x", "httpx://a", "#top", "ftp://a.example/x"]) {
    const { root } = dom(`[label](${href})`);
    assert.equal(root.all((e) => e.tag === "button" || e.className === "q-link").length, 0, href);
    assert.equal(root.textContent, "label", href);
  }
  const { root } = dom(FIXTURE);
  const queued = byText(root, "li", /bad link/);
  assert.equal(queued.all((e) => e.className === "q-link").length, 0);
  assert.match(queued.textContent, /^A \[bad link\]\(javascript:alert\(1\)\) and an \[image link\]\(data:/, "shown as written");
});

test("safeHref allows only absolute https, http and mailto, after trimming and case-folding", () => {
  assert.equal(safeHref("https://a.example/x"), "https://a.example/x");
  assert.equal(safeHref("  HTTP://a.example "), "HTTP://a.example");
  assert.equal(safeHref("MAILTO:x@example.com"), "MAILTO:x@example.com");
  for (const bad of ["javascript:x", "\tjavascript:x", "data:,x", "vbscript:x", "file:///x", "/x", "x", "", null, undefined, 7, "https:", "http://"]) {
    assert.equal(safeHref(bad), null, String(bad));
  }
});

test("an HTML block and inline HTML show as text; a lone comment is left out", () => {
  const { root } = dom(FIXTURE);
  const html = root.all((e) => e.className === "q-html");
  assert.equal(html.length, 1);
  assert.equal(html[0].textContent, '<script>alert("an HTML block shows as text")</script>');
  assert.ok(!root.textContent.includes("budget"), "the budget comment stays out");
  const inline = dom("a <b onclick=x>bold</b> word").root;
  assert.equal(inline.textContent, "a <b onclick=x>bold</b> word");
  assert.equal(inline.all((e) => e.tag === "b").length, 0);
  assert.equal(dom('<img src=x onerror="alert(1)">').root.textContent, '<img src=x onerror="alert(1)">');
});

test("✅ lines read done and 📋 lines pending, in lists and paragraphs", () => {
  const { root } = dom(FIXTURE);
  const lead = (cls) => root.all((e) => e.className === cls).map((e) => e.textContent.split(" ").slice(0, 3).join(" "));
  assert.deepEqual(lead("q-done"), ["✅ Reply to", "✅ #201 option"]);
  assert.deepEqual(lead("q-pending"), ["📋 #197 →", "📋 Being built"]);
  assert.equal(dom("📋 a paragraph").root.kids[0].className, "q-pending");
  assert.equal(dom("plain ✅ later").root.kids[0].className, "", "only a leading mark counts");
});

test("sections fold, Needs you open by default and the rest as remembered", () => {
  const { root } = dom(FIXTURE);
  const details = find(root, "details");
  assert.deepEqual(details.map((d) => [d.dataset.key, d.open]), [
    ["Needs you (short, today)", true],
    ["Running now", false],
    ["Queued", false],
    ["Answers", false],
  ]);
  assert.equal(details[0].className, "q-needs");
  assert.equal(details[0].kids[0].tag, "summary");
  // Intro text before the first ## stays outside any section.
  assert.equal(root.kids[0].tag, "h3");
  const remembered = find(dom(FIXTURE, (t) => ({ "Running now": true, "Needs you (short, today)": false })[t]).root, "details");
  assert.deepEqual(remembered.map((d) => d.open), [false, true, false, false]);
});

test("the Needs you count is its top-level items less the done ones, and null without the section", () => {
  const count = (text) => render(text).count;
  assert.equal(count(FIXTURE), 4, "five items, one ✅");
  assert.equal(count("# Q\n\n## Running now\n\n1. a\n"), null);
  assert.equal(count(""), null);
  assert.equal(count("## Needs you\n\nNothing today.\n\n## Later\n\n1. a\n2. b\n"), 0);
  assert.equal(count("## needs YOU now\n\n- a\n  - nested\n  - nested\n- b\n"), 2, "nested items are part of their item");
  assert.equal(count("## Needs you\n\n- a\n\n### Sub\n\n- b\n\n## Next\n\n- c\n"), 2, "a ### stays in the section");
  assert.equal(count("## Not needs you\n\n- a\n"), null);
});

test("the header label cannot be read as the sessions' needs-you tally", () => {
  assert.equal(queueLabel(null), "Queue");
  assert.equal(queueLabel(3), "Queue · 3 for you");
  assert.equal(queueLabel(0), "Queue · 0 for you");
  for (const n of [null, 0, 1, 9]) assert.doesNotMatch(queueLabel(n), /needs/i);
});

test("the renderer never writes markup, even from hostile text", () => {
  const hostile = "<script>x</script>\n\n[a](javascript:x) <img src=x onerror=y> <!-- c --> `<b>` ```\n<i>\n```\n";
  assert.doesNotThrow(() => dom(hostile));
  assert.doesNotThrow(() => dom(FIXTURE));
});

test("textOf reads a node's whole text", () => {
  const [h] = sections(toTree(parse("## A **b** `c`\n")));
  assert.equal(textOf(h.kids[0]), "A b c");
});

test("a file at the size cap parses and renders quickly, and its cost grows linearly", () => {
  const show = (bytes) => {
    const root = new El("div");
    for (const n of build(render(FIXTURE.repeat(Math.ceil(bytes / FIXTURE.length)).slice(0, bytes)).nodes, doc, { copy() {} })) root.append(n);
  };
  const ms = cpuMs(() => show(256 * 1024));
  assert.ok(ms < 5000, `${ms.toFixed(0)} ms of CPU`);
  assertLinear(show, 64 * 1024);
});

test("the docked width keeps to its bounds and leaves the cards room; no number is the default", async () => {
  globalThis.window ??= {};
  const { clampWidth, WIDTH } = await import("./fleet/queuepanel.js");
  assert.equal(clampWidth(NaN, 1920), WIDTH.initial);
  assert.equal(clampWidth(Number(undefined), 1920), WIDTH.initial);
  assert.equal(clampWidth(Infinity, 1920), WIDTH.max);
  assert.equal(clampWidth(Infinity, Infinity), WIDTH.max);
  assert.equal(clampWidth(0, 1920), WIDTH.min);
  assert.equal(clampWidth(-50, 1920), WIDTH.min);
  assert.equal(clampWidth(700, 1300), 600, "700 px stay for the cards");
  assert.equal(clampWidth(700, 945), WIDTH.min, "never below the minimum");
  assert.equal(clampWidth(500.4, 1920), 500);
});

// The count is what the panel shows: the visible top-level items of the
// Needs you section that do not read as done.
test("the Needs you count agrees with the panel, whatever the markup", () => {
  const count = (text) => render(text).count;
  const shownNotDone = (text) => {
    const { root } = dom(text);
    const needs = root.all((e) => e.tag === "details" && e.className === "q-needs")[0];
    if (!needs) return null;
    return needs.kids.filter((k) => k.tag === "ol" || k.tag === "ul").flatMap((l) => l.kids.filter((i) => i.tag === "li" && i.className !== "q-done")).length;
  };
  for (const [text, want] of [
    ["## Needs you\n\n1. **✅ Done.**\n2. b\n", 1],
    ["## **Needs you**\n\n- a\n- b\n", 2],
    ["## [Needs you](https://x.example)\n\n- a\n", 1],
    ["## Needs you\n\n1.\n2. ✅ b\n", 1],
    ["## Needs you\n\n- ![✅](x.png) shipped\n- b\n", 1],
    ["## Needs you\n\n> - a\n\n- b\n- c\n", 2],
    ["## Needs you\n\n- a\n\n## Needs you\n\n- b\n- c\n", 1],
  ]) {
    assert.equal(count(text), want, JSON.stringify(text));
    assert.equal(count(text), shownNotDone(text), `display: ${JSON.stringify(text)}`);
  }
});

test("a long Needs you list counts in linear time", () => {
  assert.equal(render("## Needs you\n\n" + "- a\n".repeat(65000)).count, 65000);
  assertLinear((n) => assert.equal(render("## Needs you\n\n" + "- a\n".repeat(n)).count, n), 1000);
});

test("a paragraph of many inline nodes renders without overflowing the stack", () => {
  for (const text of ["a\n".repeat(131071), "*a".repeat(131072), "`a` ".repeat(65535)]) {
    assert.doesNotThrow(() => dom(text), `${text.slice(0, 6)}… (${text.length})`);
  }
});

test("a render that throws is one problem line, not the old file", () => {
  const boom = () => {
    throw new RangeError("Maximum call stack size exceeded");
  };
  const shown = present({ path: "/q.md", text: "# Q", problem: null }, () => undefined, doc, () => {}, boom);
  assert.deepEqual([shown.count, shown.children.length], [null, 0]);
  assert.equal(shown.problem, "The queue file could not be shown: Maximum call stack size exceeded");
  const ok = present({ path: "/q.md", text: "## Needs you\n\n- a\n", problem: null }, () => undefined, doc, () => {});
  assert.deepEqual([ok.count, ok.problem, ok.children.length > 0], [1, null, true]);
  const fault = present({ path: "/q", text: null, problem: "The queue path is not a regular file." }, () => undefined, doc, () => {});
  assert.deepEqual([fault.count, fault.problem, fault.empty, fault.children.length], [null, "The queue path is not a regular file.", undefined, 0]);
});

test("a path with no file yet is the empty state, not a problem", () => {
  const missing = present({ path: "/q.md", text: null, problem: "No queue file at this path.", missing: true }, () => undefined, doc, () => {});
  assert.deepEqual([missing.count, missing.problem, missing.empty, missing.children.length], [null, EMPTY, true, 0]);
});

test("comments are left out wherever they sit, and the text between them stays", () => {
  assert.equal(dom("<!-- a --> Ship the fix today <!-- b -->\n").root.textContent, "Ship the fix today");
  assert.equal(dom("<!-- a -->\n").root.kids.length, 0);
  assert.equal(dom("a <!-- x --> b\n").root.textContent, "a  b");
  assert.equal(dom("<div><!-- x --></div>\n").root.textContent, "<div></div>");
  // An unclosed comment shows as written, and many of them stay linear.
  assert.equal(dom("<!-- open\n").root.textContent, "<!-- open");
  assertLinear((n) => dom("<!--".repeat(n)), 4096);
});

test("the Queue label hides its words below exactly the dock breakpoint", () => {
  const js = readFileSync(new URL("./fleet/queuepanel.js", import.meta.url), "utf8");
  const side = readFileSync(new URL("./fleet/sidepanel.js", import.meta.url), "utf8");
  const DOCK_MIN_PX = Number(side.match(/export const DOCK_MIN_PX = (\d+);/)?.[1]);
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const m = css.match(/@media \(width < (\d+)px\) \{\s*#queue-open \.for-you \{/);
  assert.ok(m, "the narrow rule for the label's words");
  assert.equal(Number(m[1]), DOCK_MIN_PX);
  assert.match(js, /more\.className = "for-you"/);
});

test("text sizes step as browsers zoom, stay in bounds, and read a stored value back safely", async () => {
  globalThis.window ??= {};
  const { TEXT_SIZES, stepText, textKey, textSize } = await import("./fleet/queuepanel.js");
  assert.equal(TEXT_SIZES[0], 0.75);
  assert.equal(TEXT_SIZES.at(-1), 2);
  assert.ok(TEXT_SIZES.includes(1), "100% is a step, so reset lands on one");
  assert.deepEqual([stepText(1, 1), stepText(1.1, 1), stepText(1, -1)], [1.1, 1.25, 0.9]);
  assert.equal(stepText(2, 1), 2, "never past the largest");
  assert.equal(stepText(0.75, -1), 0.75, "never past the smallest");
  assert.equal(textSize(null), 1, "nothing stored");
  assert.equal(textSize("abc"), 1);
  assert.equal(textSize("1.25"), 1.25, "as localStorage hands it back");
  assert.equal(textSize("1.3"), 1.25, "an off-step value goes to the nearest step");
  assert.equal(textSize("9"), 2);
  assert.equal(textSize("-4"), 0.75);
  assert.equal(stepText("1.3", 1), 1.5, "a step from an off-step value starts at its nearest");
  const key = (k, mods = {}) => textKey({ key: k, ctrlKey: true, altKey: false, metaKey: false, ...mods });
  assert.deepEqual([key("="), key("+"), key("-"), key("0")], [1, 1, -1, 0]);
  assert.equal(key("=", { ctrlKey: false }), null, "only with Ctrl");
  assert.equal(key("=", { altKey: true }), null, "Ctrl+Alt is AltGr on some layouts");
  assert.equal(key("a"), null);
  assert.equal(key("toString"), null, "no key reads through to the prototype");
  assert.equal(key("à", { code: "Digit0" }), 0, "AZERTY's Ctrl+0 by its place");
  assert.deepEqual([key("+", { code: "NumpadAdd" }), key("Subtract", { code: "NumpadSubtract" })], [1, -1]);
  assert.equal(key("&", { code: "Digit1" }), null);
});

test("a drag snaps shut past half the panel's minimum and full past half the cards' minimum", async () => {
  globalThis.window ??= {};
  const { snap, WIDTH, WALL_MIN, clampWidth } = await import("./fleet/queuepanel.js");
  assert.equal(WALL_MIN, 700, "the room clampWidth leaves the cards");
  assert.equal(clampWidth(Infinity, 1920), Math.min(WIDTH.max, 1920 - WALL_MIN));
  const shutBelow = WIDTH.min / 2;
  for (const viewport of [1200, 1300, 1920, 2560]) {
    const fullAbove = viewport - WALL_MIN / 2;
    assert.equal(snap(shutBelow - 1, viewport), "shut", `${viewport}: one px past the shut line`);
    assert.equal(snap(shutBelow, viewport), "docked", `${viewport}: on the shut line it stays`);
    assert.equal(snap(0, viewport), "shut");
    assert.equal(snap(-40, viewport), "shut", "past the window's edge");
    assert.equal(snap(WIDTH.min, viewport), "docked");
    assert.equal(snap(fullAbove, viewport), "docked", `${viewport}: on the full line it stays`);
    assert.equal(snap(fullAbove + 1, viewport), "full", `${viewport}: one px past the full line`);
    assert.equal(snap(viewport + 40, viewport), "full", "past the window's left edge");
  }
  // One line each way, so a drag back across it undoes the snap at the same place (AppKit, VS Code).
  assert.equal(snap(shutBelow - 0.5, 1920), "shut");
  assert.equal(snap(shutBelow + 0.5, 1920), "docked");
  assert.equal(snap(NaN, 1920), "docked", "no number snaps nowhere");
});

test("the stored view reads back safely, an older build's open flag standing in for a missing one", async () => {
  globalThis.window ??= {};
  const { parseView } = await import("./fleet/queuepanel.js");
  assert.equal(parseView("shut", null), "shut");
  assert.equal(parseView("docked", null), "docked");
  assert.equal(parseView("full", "0"), "full", "the view wins over the old flag");
  assert.equal(parseView(null, "1"), "docked", "an older build left it open");
  assert.equal(parseView(null, "0"), "shut");
  assert.equal(parseView(null, null), "shut", "first run: shut, its tab showing");
  assert.equal(parseView("banana", null), "shut", "corrupt");
  assert.equal(parseView("banana", "1"), "docked", "corrupt, with the old flag");
  assert.equal(parseView("toString", null), "shut", "no value reads through to the prototype");
  assert.equal(parseView(" full", null), "shut");
});

test("the separator's keys: arrows step, Home and End reach the bounds then snap past them, Enter shuts or restores", async () => {
  globalThis.window ??= {};
  const { separatorKey, WIDTH } = await import("./fleet/queuepanel.js");
  const max = 900; // at 1920
  const k = (key, view, width) => separatorKey(key, view, width, max);
  assert.deepEqual(k("ArrowLeft", "docked", 480), { view: "docked", width: 480 + WIDTH.step });
  assert.deepEqual(k("ArrowRight", "docked", 480), { view: "docked", width: 480 - WIDTH.step });
  assert.deepEqual(k("PageUp", "docked", 480), { view: "docked", width: 480 + 4 * WIDTH.step });
  assert.deepEqual(k("PageDown", "docked", 480), { view: "docked", width: 480 - 4 * WIDTH.step });
  assert.deepEqual(k("ArrowRight", "docked", WIDTH.min), { view: "docked", width: WIDTH.min - WIDTH.step }, "the caller clamps; an arrow never snaps");
  assert.deepEqual(k("Home", "docked", 480), { view: "docked", width: WIDTH.min });
  assert.deepEqual(k("Home", "docked", WIDTH.min), { view: "shut", width: WIDTH.min }, "Home at the narrowest shuts");
  assert.deepEqual(k("End", "docked", 480), { view: "docked", width: max });
  assert.deepEqual(k("End", "docked", max), { view: "full", width: max }, "End at the widest fills the window");
  assert.deepEqual(k("Enter", "docked", 480), { view: "shut", width: 480 }, "APG: Enter collapses");
  assert.deepEqual(k("Enter", "full", 480), { view: "docked", width: 480 }, "APG: Enter restores");
  assert.deepEqual(k("Home", "full", 480), { view: "docked", width: WIDTH.min });
  assert.deepEqual(k("ArrowRight", "full", 480), { view: "docked", width: max }, "a step out of full lands at the widest");
  assert.deepEqual(k("PageDown", "full", 480), { view: "docked", width: max });
  for (const key of ["ArrowLeft", "PageUp", "End"]) assert.equal(k(key, "full", 480), null, `${key} in full: already the largest`);
  assert.equal(k("a", "docked", 480), null);
  assert.equal(k("toString", "docked", 480), null);
  assert.equal(k("Enter", "shut", 480), null, "a shut panel's separator is hidden");
});

test("Ctrl+Alt+B toggles the panel, as VS Code's secondary side bar; nothing else does", async () => {
  globalThis.window ??= {};
  const { toggleKey } = await import("./fleet/queuepanel.js");
  const key = (k, code, mods = {}) => toggleKey({ key: k, code, ctrlKey: true, altKey: true, metaKey: false, shiftKey: false, repeat: false, ...mods });
  assert.equal(key("b", "KeyB"), true);
  assert.equal(key("B", "KeyB"), true, "with Caps Lock");
  assert.equal(key("b", "KeyN"), true, "Dvorak: the letter, not the place");
  assert.equal(key("x", "KeyB"), false, "Dvorak's x sits where QWERTY's b is");
  assert.equal(key("и", "KeyB"), true, "a non-Latin layout: its place, as browsers fall back");
  assert.equal(key("{", "KeyB"), true, "AltGr+B typing a character: its place");
  assert.equal(key("b", "KeyB", { repeat: true }), false, "a held key toggles once");
  assert.equal(key("b", "KeyB", { altKey: false }), false, "Ctrl+B alone is not it");
  assert.equal(key("b", "KeyB", { ctrlKey: false }), false);
  assert.equal(key("b", "KeyB", { shiftKey: true }), false);
  assert.equal(key("b", "KeyB", { metaKey: true }), false);
  assert.equal(key("n", "KeyN"), false);
});
