// The gauge strip's chips as DOM (#421, variant A "Readout"): a mark, a bold
// value, the reset, a pip per window, and the account's portraits docked
// beside it. Linear is one row (the tray's Compact); stacked is a line per
// account with every window (the tray's Full). Shared by the floating strip
// and, later, the wall header, so both draw the same chip the same way.
import { rampColor, windowLabel } from "../gauge.js";
import { STALE_AFTER_MS, ageText, cellWhen, rowAge } from "./chips.js";
import { syncChildren } from "./dom.js";
import { MAKER_ICONS } from "./icons.js";

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

// The stacked layout's cells: the session, the week, and a model group's pool.
const CELL_KIND = (row) =>
  row.window === "five_hour" ? "session" : row.window === "seven_day" ? "week" : windowLabel(row.window).toLowerCase();

/**
 * One pip: a short bar filled to the window's percent, notched when spent,
 * greyed when its own reading is stale. `lead` marks the chip's lead window
 * (the tray icon reads its colour); `big` draws it larger (linear only).
 */
function pip(row, lead, opts, big = lead) {
  const old = rowAge(row, opts.now) > STALE_AFTER_MS;
  const p = el("span", `pip${big ? " big" : ""}${row.pct >= 100 ? " full" : ""}${old ? " old" : ""}`);
  if (lead) p.dataset.lead = "";
  const fill = el("i");
  const pct = Math.max(0, Math.min(100, row.pct ?? 0));
  fill.style.height = `${pct}%`;
  fill.style.backgroundColor = rampColor(pct, opts.stops, opts.mode);
  p.append(fill);
  return p;
}

function mark(chip) {
  const m = el("span", "mark");
  m.setAttribute("aria-hidden", "true");
  if (chip.mark.mono) m.append(el("span", "mono", chip.mark.mono));
  else m.innerHTML = MAKER_ICONS[chip.mark.icon] ?? "";
  return m;
}

/** Build a chip's parts once; its faces slot survives every repaint. */
function make(chip) {
  const c = el("div", "chip");
  c.setAttribute("role", "group");
  const faces = el("span", "faces");
  faces.dataset.dock = chip.key;
  c.append(el("span", "body"), faces);
  return c;
}

function linearBody(chip, opts) {
  const body = [mark(chip), el("b", "val", chip.value), el("span", "when", chip.when)];
  if (chip.pips.length) {
    const pips = el("span", "pips");
    pips.setAttribute("aria-hidden", "true");
    chip.pips.forEach((r, i) => pips.append(pip(r, i === 0, opts)));
    body.push(pips);
  }
  if (chip.age) body.push(el("span", "age", chip.age));
  if (chip.route) body.push(el("span", "rt", "route"));
  return body;
}

function stackedBody(chip, opts) {
  const name = el("span", "nm", chip.name);
  if (chip.ageText) name.append(" ", el("span", "age", chip.ageText));
  if (chip.route) name.append(" ", el("span", "rt", `route · ${windowLabel(chip.route.window).toLowerCase()}`));
  if (chip.placeholder) return [mark(chip), name, el("span", "cell wide", chip.when)];
  const cells = chip.windows.map((r) => {
    const cell = el("span", "cell");
    cell.append(el("span", "k", CELL_KIND(r)));
    if (chip.hidden.includes(r)) {
      cell.classList.add("hidden-win");
      cell.append(el("span", "t", "hidden"));
      return cell;
    }
    const lead = r === chip.lead;
    // A window read longer ago than the lead says so in its own cell.
    const age = rowAge(r, opts.now);
    const own = !lead && !(age <= chip.ageMs) ? ageText(age) : null;
    const when = lead ? chip.when : cellWhen(r, opts.now);
    cell.append(
      el("b", "", lead ? chip.value : r.pct >= 100 ? "out" : `${Math.floor(r.pct ?? 0)}%`),
      el("span", "t", own ? `${when} · ${own}` : when),
      pip(r, lead, opts, false),
    );
    return cell;
  });
  return [mark(chip), name, ...cells];
}

const looks = new WeakMap(); // each chip element's last drawn look

/** Draw `chip` on its element: words, pips, state flags, its hover and its spoken line. */
function paint(c, chip, opts) {
  // Redrawn only when what it shows changed: the strip redraws every few
  // seconds, and a chip's words move once a minute at most.
  const look = [opts.layout, opts.mode, opts.stops.low, opts.stops.mid, opts.stops.high, opts.stops.midAt, opts.stops.highAt,
    chip.value, chip.when, chip.age, chip.ageText, chip.route?.window, chip.stale, chip.detail.join("\n"),
    chip.pips.map((r) => `${r.window}:${r.state}:${r.pct}:${rowAge(r, opts.now) > STALE_AFTER_MS}`).join(",")].join("|");
  if (looks.get(c) === look) return;
  looks.set(c, look);
  const body = c.firstChild;
  body.replaceChildren(...(opts.layout === "stacked" ? stackedBody(chip, opts) : linearBody(chip, opts)));
  c.title = chip.detail.join("\n");
  c.setAttribute("aria-label", chip.spoken);
  c.dataset.harness = chip.harness;
  for (const [flag, on] of [["route", chip.route], ["stale", chip.stale], ["placeholder", chip.placeholder]]) {
    if (on) c.dataset[flag] = "";
    else delete c.dataset[flag];
  }
}

/**
 * Make `container`'s chips `chips`, in order. A chip's element is reused by
 * its key, so its docked portraits stay put; its body is redrawn each time.
 * `opts`: { now, layout: "linear" | "stacked", stops, mode }.
 */
export function syncChips(container, chips, opts) {
  container.dataset.layout = opts.layout;
  // Stacked: a column per window of the account with the most, so a fourth
  // window (agy's Gemini, an API key's pools) never wraps its line.
  const cells = String(Math.max(1, ...chips.map((c) => c.windows.length)));
  if (container.dataset.cells !== cells) {
    container.dataset.cells = cells;
    container.style.setProperty("--cells", cells);
  }
  syncChildren(container, chips, (chip) => chip.key, make, (c, chip) => paint(c, chip, opts));
}

/** The faces slot of each chip in `container`, by the chip's key. */
export function dockSlots(container) {
  return new Map([...container.querySelectorAll(".faces[data-dock]")].map((s) => [s.dataset.dock, s]));
}
