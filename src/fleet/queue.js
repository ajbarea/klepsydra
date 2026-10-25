// The Queue panel's renderer: the queue file's markdown parsed by the
// vendored markdown-it, its tokens walked into a plain tree, and the tree
// built with createElement and text nodes only. Nothing from the file is ever
// read as markup: raw HTML shows as text, and a link is its text with the
// address on hover and a Copy link button, never an href to follow.
import markdownit from "../vendor/markdown-it/markdown-it.esm.min.mjs";

const md = markdownit({ html: true, linkify: false, typographer: false });

/** The only link schemes the panel offers to copy. */
export const SCHEMES = ["https:", "http:", "mailto:"];

/** `href` when it is an absolute https, http or mailto address, else null. */
export function safeHref(href) {
  if (typeof href !== "string") return null;
  const h = href.trim();
  if (!SCHEMES.some((s) => h.toLowerCase().startsWith(s))) return null;
  try {
    return SCHEMES.includes(new URL(h).protocol) ? h : null;
  } catch {
    return null;
  }
}

export const parse = (text) => md.parse(text ?? "", {});

const node = (tag, props = {}) => ({ tag, kids: [], ...props });
const DONE = "✅";
const PENDING = "📋";
/** A comment alone is invisible in any renderer, so it stays out of the panel too. */
const commentOnly = (html) => /^\s*<!--[\s\S]*?-->\s*$/.test(html);

const BLOCK = {
  paragraph: "p",
  blockquote: "blockquote",
  bullet_list: "ul",
  ordered_list: "ol",
  list_item: "li",
  table: "table",
  thead: "thead",
  tbody: "tbody",
  tr: "tr",
  th: "th",
  td: "td",
};
const INLINE = { strong: "strong", em: "em", s: "s" };
const ALIGN = /^text-align:(left|center|right)$/;

function inline(children) {
  const root = node("span");
  const stack = [root];
  for (const c of children ?? []) {
    const top = stack.at(-1);
    const kind = c.type.replace(/_(open|close)$/, "");
    if (c.nesting === 1) {
      const href = kind === "link" ? safeHref(c.attrGet("href")) : null;
      const n = kind === "link" ? node("span", href ? { cls: "q-link", title: href, link: href } : {}) : node(INLINE[kind] ?? "span");
      top.kids.push(n);
      stack.push(n);
    } else if (c.nesting === -1) {
      if (stack.length > 1) stack.pop();
    } else if (c.type === "text") top.kids.push(c.content);
    else if (c.type === "code_inline") top.kids.push(node("code", { text: c.content }));
    else if (c.type === "softbreak") top.kids.push("\n");
    else if (c.type === "hardbreak") top.kids.push(node("br"));
    else if (c.type === "image") top.kids.push(c.content);
    else if (c.type === "html_inline") {
      if (!commentOnly(c.content)) top.kids.push(c.content);
    } else if (c.content) top.kids.push(c.content);
  }
  return root.kids;
}

/** The first text in `n`, depth first. */
function leadText(n) {
  for (const k of n.kids ?? []) {
    if (typeof k === "string") {
      if (k.trim()) return k.trimStart();
    } else {
      const t = leadText(k);
      if (t) return t;
    }
  }
  return n.text ?? "";
}

/** All the text in `n`. */
export function textOf(n) {
  if (typeof n === "string") return n;
  return (n.text ?? "") + (n.kids ?? []).map(textOf).join("");
}

/** The tokens as a tree of plain nodes: {tag, cls, kids, text, ...}; strings are text. */
export function toTree(tokens) {
  const root = node("div");
  const stack = [root];
  for (const t of tokens) {
    const top = stack.at(-1);
    if (t.nesting === 1) {
      // A tight list's paragraph is no element: its text sits in the item.
      if (t.hidden) {
        stack.push(top);
        continue;
      }
      let n;
      if (t.type === "heading_open") {
        const level = Number(t.tag.slice(1));
        n = node(`h${Math.min(6, level + 2)}`, { level });
      } else {
        n = node(BLOCK[t.type.replace(/_open$/, "")] ?? "div");
      }
      const start = t.type === "ordered_list_open" ? Number(t.attrGet("start") ?? 1) : 1;
      if (Number.isInteger(start) && start !== 1) n.start = start;
      const align = ALIGN.exec(t.attrGet?.("style") ?? "");
      if (align) n.cls = `q-align-${align[1]}`;
      top.kids.push(n);
      stack.push(n);
    } else if (t.nesting === -1) {
      if (stack.length > 1) stack.pop();
    } else if (t.type === "inline") {
      top.kids.push(...inline(t.children));
    } else if (t.type === "fence" || t.type === "code_block") {
      const code = t.content.replace(/\n$/, "");
      top.kids.push(node("div", { cls: "q-code", copy: code, kids: [node("pre", { kids: [node("code", { text: code })] })] }));
    } else if (t.type === "html_block") {
      if (!commentOnly(t.content)) top.kids.push(node("pre", { cls: "q-html", text: t.content.replace(/\n$/, "") }));
    } else if (t.type === "hr") {
      top.kids.push(node("hr"));
    } else if (t.content) {
      top.kids.push(node("p", { text: t.content }));
    }
  }
  mark(root);
  return root.kids;
}

/** ✅ items and lines read as done, 📋 as pending. */
function mark(n) {
  for (const k of n.kids ?? []) {
    if (typeof k === "string") continue;
    if (k.tag === "li" || k.tag === "p") {
      const lead = leadText(k);
      if (lead.startsWith(DONE)) k.cls = "q-done";
      else if (lead.startsWith(PENDING)) k.cls = "q-pending";
    }
    mark(k);
  }
}

/** Whether a heading's text names the Needs you section. */
export const isNeedsYou = (title) => /^needs you\b/i.test(title.trim());

/**
 * The top-level nodes with each `##` heading and what follows it, up to the
 * next, folded into a <details>. `opened(title)` says whether a section is
 * open: the caller's memory, else open for Needs you alone.
 */
export function sections(nodes, opened = () => undefined) {
  const out = [];
  let current = null;
  for (const n of nodes) {
    if (typeof n !== "string" && n.level !== undefined && n.level <= 2) {
      current = null;
      if (n.level === 2) {
        const title = textOf(n).trim();
        current = node("details", { key: title, open: opened(title) ?? isNeedsYou(title) });
        if (isNeedsYou(title)) current.cls = "q-needs";
        current.kids.push(node("summary", { kids: [n] }));
        out.push(current);
        continue;
      }
    }
    (current ? current.kids : out).push(n);
  }
  return out;
}

/**
 * Top-level items in the file's first Needs you section, less the ones
 * marked ✅; null when the file has no such section.
 */
export function needsYouCount(tokens) {
  const at = tokens.findIndex(
    (t, i) => t.type === "heading_open" && t.tag === "h2" && isNeedsYou(tokens[i + 1]?.content ?? ""),
  );
  if (at < 0) return null;
  let level = null;
  let count = 0;
  for (let i = at + 3; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type === "heading_open" && (t.tag === "h1" || t.tag === "h2")) break;
    if (t.type !== "list_item_open") continue;
    level ??= t.level;
    if (t.level !== level) continue;
    // The item's first inline token is its own text.
    const first = tokens.slice(i + 1).find((x) => x.type === "inline");
    if (!first?.content.trimStart().startsWith(DONE)) count++;
  }
  return count;
}

/** The header button's text: never "needs you", which the session tally owns. */
export const queueLabel = (count) => (count === null || count === undefined ? "Queue" : `Queue · ${count} for you`);

/**
 * Build the tree with `doc`'s createElement and text nodes. `copy(text,
 * button)` runs for a Copy click. Only tags from the tree and the attributes
 * named here are ever set.
 */
export function build(nodes, doc, { copy }) {
  const out = [];
  for (const n of nodes) {
    if (typeof n === "string") {
      out.push(doc.createTextNode(n));
      continue;
    }
    const el = doc.createElement(n.tag);
    if (n.cls) el.className = n.cls;
    if (n.title) el.title = n.title;
    if (n.start !== undefined) el.setAttribute("start", String(n.start));
    if (n.key !== undefined) el.dataset.key = n.key;
    if (n.tag === "details") el.open = Boolean(n.open);
    if (n.text !== undefined) el.textContent = n.text;
    else el.append(...build(n.kids, doc, { copy }));
    out.push(el);
    if (n.copy !== undefined) el.append(copyButton(doc, "Copy", "Copy code", n.copy, copy));
    if (n.link) out.push(copyButton(doc, "Copy link", `Copy link: ${n.link}`, n.link, copy));
  }
  return out;
}

function copyButton(doc, label, name, text, copy) {
  const b = doc.createElement("button");
  b.type = "button";
  b.className = "q-copy";
  b.textContent = label;
  b.setAttribute("aria-label", name);
  b.addEventListener("click", () => copy(text, b));
  return b;
}

/** The queue file's markdown as the panel shows it: its nodes and the Needs you count. */
export function render(text, opened) {
  const tokens = parse(text);
  return { nodes: sections(toTree(tokens), opened), count: needsYouCount(tokens) };
}
