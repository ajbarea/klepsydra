import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build, parse, present, queueLabel, render, safeHref, sections, textOf, toTree } from "./fleet/queue.js";

const FIXTURE = readFileSync(new URL("../scripts/fixtures/queue-demo.md", import.meta.url), "utf8");

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

test("a file at the size cap parses and renders quickly", () => {
  const big = FIXTURE.repeat(Math.ceil((256 * 1024) / FIXTURE.length)).slice(0, 256 * 1024);
  const started = performance.now();
  const root = new El("div");
  for (const n of build(render(big).nodes, doc, { copy() {} })) root.append(n);
  const ms = performance.now() - started;
  assert.ok(ms < 1000, `${ms.toFixed(0)} ms`);
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

test("a long Needs you list counts in well under a second", () => {
  const text = "## Needs you\n\n" + "- a\n".repeat(65000);
  const started = performance.now();
  assert.equal(render(text).count, 65000);
  const ms = performance.now() - started;
  assert.ok(ms < 1000, `${ms.toFixed(0)} ms`);
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
  const missing = present({ path: "/q.md", text: null, problem: "No queue file at this path." }, () => undefined, doc, () => {});
  assert.deepEqual([missing.count, missing.problem, missing.children.length], [null, "No queue file at this path.", 0]);
});

test("comments are left out wherever they sit, and the text between them stays", () => {
  assert.equal(dom("<!-- a --> Ship the fix today <!-- b -->\n").root.textContent, "Ship the fix today");
  assert.equal(dom("<!-- a -->\n").root.kids.length, 0);
  assert.equal(dom("a <!-- x --> b\n").root.textContent, "a  b");
  assert.equal(dom("<div><!-- x --></div>\n").root.textContent, "<div></div>");
  // An unclosed comment shows as written, and many of them stay linear.
  assert.equal(dom("<!-- open\n").root.textContent, "<!-- open");
  const started = performance.now();
  dom("<!--".repeat(65536));
  assert.ok(performance.now() - started < 1000);
});
