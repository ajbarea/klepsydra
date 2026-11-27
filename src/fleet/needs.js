// The Needs you room's model (#386): the Needs you file read once into the
// items the room lists, the count the header shows and the next dated item,
// so every number on screen comes from one parse. Pure: no DOM. The item's
// words stay a node tree that queue.js builds as text; nothing here is markup.
import { asks, parse, sections, textOf, toTree } from "./queue.js";

const PENDING = "📋";
const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DAY_MS = 86_400_000;
/** A date with no year is the one within this many days of today. */
const HALF_YEAR_DAYS = 183;

const isEl = (n) => typeof n !== "string";
const isList = (n) => isEl(n) && (n.tag === "ul" || n.tag === "ol");

/** The longest link the app opens (needs.rs URL_MAX). */
const URL_MAX = 2048;
/** Whether the app opens `url` (needs.rs safe_url): https, a host, plain URL characters. */
export const opensInApp = (url) =>
  url.length <= URL_MAX && /^https:\/\/[^/?#]+/.test(url) && /^[A-Za-z0-9\-._~:/?#[\]@!$&()*+,;=%]+$/.test(url);

/** The links a tree holds, each once: `{label, url}`, safe ones only (queue.js keeps no other). */
export function linksOf(nodes) {
  const out = [];
  const seen = new Set();
  const walk = (list) => {
    for (const n of list ?? []) {
      if (!isEl(n)) continue;
      if (n.link && !seen.has(n.link)) {
        seen.add(n.link);
        out.push({ label: textOf(n).trim() || n.link, url: n.link });
      }
      walk(n.kids);
    }
  };
  walk(nodes);
  return out;
}

/** `kids` less a leading 📋 and the space after it. */
function unmarked(kids) {
  const out = [...kids];
  while (out.length && typeof out[0] === "string" && !out[0].trim()) out.shift();
  if (typeof out[0] === "string" && out[0].trimStart().startsWith(PENDING)) {
    const rest = out[0].trimStart().slice(PENDING.length).trimStart();
    if (rest) out[0] = rest;
    else out.shift();
  }
  return out;
}

/** A bold title's text, less the colon or full stop that ends it inside the bold. */
const titleText = (t) => t.trim().replace(/[:.]\s*$/, "").trim();

/**
 * An item's parts: its title (the leading bold, else its first line's text),
 * the rest of its first line as `detail` nodes, and what is nested under it
 * as `more` nodes.
 */
export function itemParts(li) {
  let kids = li.kids ?? [];
  // A loose list's item holds paragraphs: the first is its line.
  const first = kids.find(isEl);
  let more = [];
  if (first && first.tag === "p" && kids.filter((k) => !(typeof k === "string" && !k.trim()))[0] === first) {
    more = kids.slice(kids.indexOf(first) + 1);
    kids = first.kids ?? [];
  } else {
    more = kids.filter(isList);
    kids = kids.filter((k) => !isList(k));
  }
  const lead = unmarked(kids);
  const head = lead.find((k) => !(typeof k === "string" && !k.trim()));
  if (head && isEl(head) && head.tag === "strong") {
    const detail = lead.slice(lead.indexOf(head) + 1);
    if (typeof detail[0] === "string") {
      detail[0] = detail[0].replace(/^\s*[:.]?\s*/, "");
      if (!detail[0]) detail.shift();
    }
    return { title: titleText(textOf(head)), detail, more };
  }
  return { title: textOf({ kids: lead }).replace(/\s+/g, " ").trim(), detail: [], more };
}

/** Local midnight of `date`. */
const midnight = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate());

/** The date `month`/`day` names nearest `today`: within half a year of it. Null when no such day exists. */
function nearest(month, day, today, year) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const at = (y) => {
    const d = new Date(y, month - 1, day);
    return d.getMonth() === month - 1 ? d : null;
  };
  if (year) return at(year);
  const t = midnight(today);
  for (const y of [t.getFullYear(), t.getFullYear() + 1, t.getFullYear() - 1]) {
    const d = at(y);
    if (d && Math.abs(d - t) <= HALF_YEAR_DAYS * DAY_MS) return d;
  }
  return null;
}

// "Wed 11-25", "11-26", "2026-12-06", "Dec 6", "December 6": the first whole one in the text.
const UNIT = String.raw`\s+(?:min|mins|minutes?|h|hrs?|hours?|days?|weeks?|months?|years?|pages?|words?|times|slides?|people|steps?|percent)\b|\s*%`;
const DATES = [
  [/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/g, (m) => [Number(m[2]), Number(m[3]), Number(m[1])]],
  // After a weekday, any month-day: "Mon 1-4".
  [/\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\.?,?\s+(\d{1,2})-(\d{1,2})(?![\d-]|:\d)/g, (m) => [Number(m[1]), Number(m[2]), null]],
  // Alone, two digits each ("11-26", "01-05"), so a count range ("2-3 paragraphs", "rounds 1-10") is
  // no date; not glued to a word (r1-10), a time range (9:30-10:00), a number range (1.5-2), an
  // issue (#12-3) or a range of units. A two-digit range ("pages 12-15") still reads as a date:
  // the file writes dates this way, so the rare range is the price.
  [new RegExp(String.raw`(?<![\w#.-]|\d:)(\d{2})-(\d{2})(?![\d-]|:\d|${UNIT})`, "g"), (m) => [Number(m[1]), Number(m[2]), null]],
  // A month's name or its short form, capitalised: "Dec 6", "Sept. 9"; not "Decide 3" or "may 2".
  [
    /\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b\.?\s+(\d{1,2})(?![\d:])/g,
    (m) => [MONTHS.indexOf(m[1].slice(0, 3).toLowerCase()) + 1, Number(m[2]), null],
  ],
];

/** The first date `text` names, as local midnight, or null. */
export function dueOf(text, today = new Date()) {
  let best = null;
  for (const [re, parts] of DATES) {
    re.lastIndex = 0;
    for (const m of text.matchAll(re)) {
      const [month, day, year] = parts(m);
      const d = nearest(month, day, today, year);
      if (d) {
        if (!best || m.index < best.at) best = { at: m.index, date: d };
        break;
      }
    }
  }
  return best?.date ?? null;
}

const pad = (n) => String(n).padStart(2, "0");

/** A due date as the room shows it: `{label, tone}`; tone is past, today, soon (a week) or later. */
export function dueLabel(date, today = new Date()) {
  const days = Math.round((midnight(date) - midnight(today)) / DAY_MS);
  const md = `${WEEKDAYS[date.getDay()]} ${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  if (days === 0) return { label: "Today", tone: "today", days };
  if (days === 1) return { label: `Tomorrow, ${md}`, tone: "soon", days };
  if (days < 0) return { label: `${md}, passed`, tone: "past", days };
  return { label: md, tone: days <= 7 ? "soon" : "later", days };
}

/** `text`'s lines `[from, to)`, less trailing blank lines: an item's exact source. */
function blockOf(lines, [from, to]) {
  const out = lines.slice(from, to);
  while (out.length && !out.at(-1).trim()) out.pop();
  return out.join("\n");
}

/**
 * The Needs you file `text` as the room shows it: `items` in file order, each
 * `{key, section, title, detail, more, links, block, line, due}` (`line`: where
 * `block` starts, `links`: `{label, url, opens}`), and `next`, the
 * soonest item dated today or later. `count` is the header's number and
 * always `items.length`. `today` is injected for tests.
 */
export function needsModel(text, today = new Date()) {
  if (typeof text !== "string" || !text) return { items: [], count: 0, next: null };
  const nodes = sections(toTree(parse(text)));
  // Lines as markdown-it counts them (a lone CR ends one too), so `line` and `block` match the app's.
  const lines = text.split(/\r\n?|\n/);
  const seen = new Map();
  const items = (asks(nodes) ?? []).map(({ node, section }) => {
    const parts = itemParts(node);
    const block = node.lines ? blockOf(lines, node.lines) : "";
    // Two identical items get distinct keys, in file order.
    const n = (seen.get(block) ?? 0) + 1;
    seen.set(block, n);
    const due = dueOf(parts.title, today) ?? dueOf(textOf({ kids: parts.detail }), today);
    // Open only what the app opens: https, written in the item as it stands (markdown-it may re-encode the rest).
    const links = linksOf([node]).map((l) => ({ ...l, opens: opensInApp(l.url) && block.includes(l.url) }));
    return {
      key: n > 1 ? `${block}\u0000${n}` : block,
      section,
      title: parts.title || "(untitled item)",
      detail: parts.detail,
      more: parts.more,
      links,
      block,
      line: node.lines ? node.lines[0] : null,
      due,
    };
  });
  const t = midnight(today);
  const next = items.filter((i) => i.due && i.due >= t).sort((a, b) => a.due - b.due)[0] ?? null;
  return { items, count: items.length, next };
}

/** Whether an item is due today or has passed: the room's "now". */
export const dueNow = (item, today = new Date()) => Boolean(item.due) && item.due <= midnight(today);

/** A section title reads as today's. */
export const isTodaySection = (title) => /^today\b/i.test(String(title ?? "").trim());
