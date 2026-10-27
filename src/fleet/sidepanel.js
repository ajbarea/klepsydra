// A side panel on the wall's right edge, the Queue's and the Ledger's: shut
// to a tab, docked beside the cards when the window is wide (a modal dialog
// when it is narrow), or full over the whole window, with its own text size.
// Each panel keeps its view, width and text size under klepsydra.<name>.*;
// the panels on one edge open one at a time.
import { served } from "./feed.js";
import { wheelPixels, wheelStep } from "../zoom.js";

/** At this window width and wider a panel docks; below it, it is a modal dialog. */
export const DOCK_MIN_PX = 1200;
/** The docked width: its bounds, the default, and one arrow-key step. */
export const WIDTH = { min: 320, max: 900, initial: 480, step: 16 };
/** The room a docked panel leaves the cards. */
export const WALL_MIN = 700;

/** Where a panel keeps its state. `open` is an older Queue build's flag, read only when no view is stored. */
export function storeKeys(name) {
  const at = (k) => `klepsydra.${name}.${k}`;
  return { width: at("width"), view: at("view"), open: at("open"), text: at("text") };
}

/** `w` held to the panel's bounds and to leave WALL_MIN for the cards; the default for a `w` that is no number. */
export function clampWidth(w, viewport) {
  const room = Math.max(WIDTH.min, Math.min(WIDTH.max, viewport - WALL_MIN));
  const want = typeof w === "number" && !Number.isNaN(w) ? w : WIDTH.initial;
  return Math.round(Math.min(room, Math.max(WIDTH.min, want)));
}

/** The panel's views: shut to its tab, docked beside the wall, or full over it. */
const VIEWS = new Set(["shut", "docked", "full"]);

/**
 * Where a drag of the separator to `w` px from the right edge lands. As
 * VS Code's split view and AppKit's NSSplitView snap a pane, one line each
 * way, half a minimum past it: the panel shuts under half its own minimum,
 * and fills the window once the cards would have under half of theirs.
 */
export function snap(w, viewport) {
  if (w < WIDTH.min / 2) return "shut";
  if (viewport - w < WALL_MIN / 2) return "full";
  return "docked";
}

/** The stored view; an older build's open flag where none is stored or it is no view; shut for anything else. */
export function parseView(view, open) {
  if (VIEWS.has(view)) return view;
  return open === "1" ? "docked" : "shut";
}

const STEPS = new Map([["ArrowLeft", WIDTH.step], ["ArrowRight", -WIDTH.step], ["PageUp", WIDTH.step * 4], ["PageDown", -WIDTH.step * 4]]);

/**
 * A key on the separator, `{view, width}` after it, or null for a key it
 * leaves alone; `max` is the widest docked width. The APG window splitter:
 * arrows step, Home and End reach the bounds, Enter collapses or restores.
 * Pressed again at a bound, Home shuts and End fills, as a drag past it does.
 */
export function separatorKey(key, view, width, max) {
  if (view === "docked") {
    if (STEPS.has(key)) return { view, width: width + STEPS.get(key) };
    if (key === "Home") return width > WIDTH.min ? { view, width: WIDTH.min } : { view: "shut", width };
    if (key === "End") return width < max ? { view, width: max } : { view: "full", width };
    if (key === "Enter") return { view: "shut", width };
  } else if (view === "full") {
    if (key === "Enter") return { view: "docked", width };
    if (key === "Home") return { view: "docked", width: WIDTH.min };
    if (key === "ArrowRight" || key === "PageDown") return { view: "docked", width: max };
  }
  return null;
}

/** The text sizes, stepped as browsers step zoom: 75% to 200%, 100% the default. */
export const TEXT_SIZES = [0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2];

/** A stored text size held to the nearest of TEXT_SIZES; 1 for anything that is no number. */
export function textSize(stored) {
  const n = typeof stored === "number" ? stored : Number.parseFloat(stored);
  if (!Number.isFinite(n)) return 1;
  return TEXT_SIZES.reduce((a, b) => (Math.abs(b - n) < Math.abs(a - n) ? b : a));
}

/** The size `by` steps from `size` (+1 larger, -1 smaller), kept within TEXT_SIZES. */
export function stepText(size, by) {
  const i = TEXT_SIZES.indexOf(textSize(size)) + by;
  return TEXT_SIZES[Math.max(0, Math.min(TEXT_SIZES.length - 1, i))];
}

const TEXT_KEYS = new Map([["=", 1], ["+", 1], ["-", -1], ["0", 0]]);
// Where the key's character is another (Ctrl+0 is "à" on AZERTY), its place, as browsers fall back.
const TEXT_CODES = new Map([["Digit0", 0], ["Numpad0", 0], ["NumpadAdd", 1], ["NumpadSubtract", -1]]);

/** What a key press does to the text size, as in browsers: +1 for Ctrl+= or Ctrl++, -1 for Ctrl+-, 0 (reset) for Ctrl+0, else null. */
export function textKey(e) {
  if (!e.ctrlKey || e.altKey || e.metaKey) return null;
  return TEXT_KEYS.get(e.key) ?? TEXT_CODES.get(e.code) ?? null;
}

/**
 * The panels sharing the right edge. One is open at a time, as Chrome's side
 * panel and VS Code's side bar show one view: opening one shuts the others,
 * and a shut panel's tab shows only while every panel on the edge is shut.
 */
export function createEdge() {
  const panels = new Set();
  return {
    join(panel) {
      panels.add(panel);
    },
    /** Shut every panel but `panel`, leaving focus to the one that opens. */
    opening(panel) {
      for (const p of panels) if (p !== panel && p.isOpen) p.shut();
    },
    /** Whether a panel other than `panel` is open. */
    othersOpen: (panel) => [...panels].some((p) => p !== panel && p.isOpen),
    /** Lay out the panels but `panel`, whose tabs follow its view. */
    changed(panel) {
      for (const p of panels) if (p !== panel) p.layout();
    },
  };
}

const stored = (key) => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};
const store = (key, value) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Private mode or blocked storage: the panel just forgets.
  }
};

/**
 * Wire the panel `name` to its `dialog`, toggled by `button` and reopened
 * from `tab`. The dialog holds `#<name>-title` and the elements classed
 * `<name>-body`, `-content`, `-resize`, `-smaller`, `-reset`, `-larger`,
 * `-full`, `-close` and `-live`. `returnTo()` is where focus goes when the
 * panel is closed (Close, Esc, the button); `onOpen()` runs as it opens and
 * `onShut()` once it has shut; `onLayout()` on every layout; `onResized()`
 * once at the end of a drag of the separator.
 */
export function createSidePanel({
  name, dialog, button, tab, edge = createEdge(), returnTo = () => button,
  onOpen = () => {}, onShut = () => {}, onLayout = () => {}, onResized = () => {},
}) {
  const STORE = storeKeys(name);
  const part = (role) => dialog.querySelector(`.${name}-${role}`);
  const body = part("body");
  const content = part("content");
  const live = part("live");
  const grip = part("resize");
  const smaller = part("smaller");
  const larger = part("larger");
  const reset = part("reset");
  const fill = part("full");
  const title = dialog.querySelector(`#${name}-title`);
  const wide = matchMedia(`(min-width: ${DOCK_MIN_PX}px)`);
  // Reopened at start only where it docks: a dialog over the wall at launch
  // would hide it. A narrow start keeps the stored view for a wide one. The
  // phone has no button to open a panel, so it never starts one open.
  let view = wide.matches && !served ? parseView(stored(STORE.view), stored(STORE.open)) : "shut";
  // The width asked for; a narrow window shows less of it without forgetting it.
  let wanted = clampWidth(Number(stored(STORE.width) ?? NaN), Infinity);
  let width = clampWidth(wanted, innerWidth);
  let preview = null; // where a held drag would land

  const docked = () => view === "docked" && wide.matches;

  function layout() {
    width = clampWidth(wanted, innerWidth);
    const max = clampWidth(Infinity, innerWidth);
    document.documentElement.style.setProperty(`--${name}-w`, `${width}px`);
    document.body.classList.toggle(`${name}-docked`, docked() && preview !== "shut");
    // The tab needs an edge to spare: none on the phone, in a half-screen
    // window, or while another panel holds the edge.
    const tabbed = view === "shut" && wide.matches && !served && !edge.othersOpen(api);
    document.body.classList.toggle(`${name}-tabbed`, tabbed);
    tab.hidden = !tabbed;
    if (preview) dialog.dataset.snap = preview;
    else delete dialog.dataset.snap;
    grip.hidden = !wide.matches;
    grip.setAttribute("aria-valuemin", String(WIDTH.min));
    grip.setAttribute("aria-valuemax", String(max));
    grip.setAttribute("aria-valuenow", String(view === "full" ? max : width));
    if (view === "full") grip.setAttribute("aria-valuetext", "Full screen");
    else grip.removeAttribute("aria-valuetext");
    fill.setAttribute("aria-pressed", String(view === "full"));
    button.setAttribute("aria-expanded", String(view !== "shut"));
    onLayout();
  }

  /** Show the dialog in the mode the view and the window's width call for; `focus` as setView's. */
  function place(focus) {
    const before = document.activeElement;
    if (dialog.open) dialog.close();
    if (view !== "shut") {
      const mode = view === "full" ? "full" : wide.matches ? "docked" : "modal";
      if (mode === "docked") dialog.show();
      else dialog.showModal();
      dialog.dataset.mode = mode;
      layout();
      // show() focuses the first control inside; a panel reopened at load
      // leaves focus where it was, and a modal one starts at its title.
      if (focus === true || (!focus && mode !== "docked")) title.focus();
      else if (focus) focus.focus();
      else if (dialog.contains(document.activeElement)) {
        if (before && !dialog.contains(before)) before.focus({ preventScroll: true });
        if (dialog.contains(document.activeElement)) document.activeElement.blur();
      }
      return;
    }
    layout();
  }

  /**
   * Shut, dock or fill the panel, and remember it. `focus`: true for the
   * title, an element to focus, or false to leave focus be; shutting moves
   * focus that was inside to the tab, or where the tab is hidden to
   * returnTo(). Opening shuts the edge's other panels. `quiet` (a shut by
   * another panel) moves no focus: the panel opening takes it.
   */
  function setView(next, focus = next !== "shut", quiet = false) {
    const had = dialog.contains(document.activeElement);
    const was = view;
    if (next !== "shut") edge.opening(api);
    view = next;
    store(STORE.view, view);
    if (was === "shut" && view !== "shut") onOpen();
    place(view === "shut" ? false : focus);
    edge.changed(api);
    if (view !== "shut") return;
    if (focus instanceof HTMLElement) focus.focus();
    else if (had && !quiet) (tab.hidden ? returnTo() : tab).focus();
    if (was !== "shut") onShut();
  }

  /** The button's toggle: shut opens docked; open shuts, focus going to returnTo(). */
  const toggle = () => (view === "shut" ? setView("docked") : setView("shut", returnTo()));

  button.addEventListener("click", toggle);
  tab.addEventListener("click", () => setView("docked"));
  fill.addEventListener("click", () => setView(view === "full" ? "docked" : "full", fill));
  part("close").addEventListener("click", () => setView("shut", returnTo()));
  // A modal closes itself on Esc; the docked panel shuts on it too, and full
  // steps back to docked (its keydown default, the modal's cancel, prevented).
  // The close event comes a task later, so one from a switch of mode finds
  // the dialog open again and is ignored.
  dialog.addEventListener("close", () => {
    if (view !== "shut" && !dialog.open) setView("shut", returnTo());
  });
  dialog.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (view === "full") setView("docked");
    else if (!dialog.matches(":modal")) setView("shut", returnTo());
    else return;
    e.preventDefault();
  });
  // A click on the backdrop lands on the dialog itself, never on its body.
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog && dialog.dataset.mode === "modal") setView("shut", returnTo());
  });
  wide.addEventListener("change", () => {
    const had = dialog.contains(document.activeElement);
    place(had);
    edge.changed(api);
  });
  addEventListener("resize", layout);
  // A key acts unless another dialog is in front: a modal keeps the focus
  // inside itself, so focus elsewhere means another.
  const behind = () => document.querySelector("dialog:modal") && !dialog.contains(document.activeElement);

  function resizeTo(w) {
    wanted = clampWidth(w, innerWidth);
    store(STORE.width, String(wanted));
    layout();
  }
  // A drag moves the panel once a frame and settles once, on release: the
  // wall's Auto measure skips the frames in between (`resizing`).
  let resizing = false;
  let frame = 0;
  grip.addEventListener("keydown", (e) => {
    const to = separatorKey(e.key, view, width, clampWidth(Infinity, innerWidth));
    if (!to) return;
    e.preventDefault();
    if (to.width !== width) resizeTo(to.width);
    if (to.view !== view) setView(to.view, to.view === "shut" ? tab : grip);
  });
  grip.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    grip.setPointerCapture(e.pointerId);
    resizing = true;
    const from = wanted; // kept by a drag that snaps, as VS Code keeps a snapped view's size
    const had = dialog.contains(document.activeElement);
    let x = e.clientX;
    const reach = () => document.documentElement.clientWidth - x;
    const move = (m) => {
      x = m.clientX;
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        preview = snap(reach(), innerWidth);
        wanted = preview === "docked" ? clampWidth(reach(), innerWidth) : from;
        layout();
      });
    };
    // Released, the drag lands; cancelled or its capture lost, it puts the panel back.
    const end = (land) => {
      grip.removeEventListener("pointermove", move);
      grip.removeEventListener("pointerup", done);
      grip.removeEventListener("pointercancel", undo);
      grip.removeEventListener("lostpointercapture", undo);
      cancelAnimationFrame(frame);
      frame = 0;
      resizing = false;
      preview = null;
      wanted = from;
      const to = land ? snap(reach(), innerWidth) : view;
      if (to === "docked" && land) resizeTo(reach());
      // A modal's focus would drop to the page as it docks; it stays on the separator.
      // Shut, the separator goes with the panel, so the focus moves to the tab once it shows.
      if (to !== view) {
        setView(to, to !== "shut" && had ? grip : false);
        if (to === "shut" && had) (tab.hidden ? returnTo() : tab).focus();
      }
      else layout();
      onResized();
    };
    const done = () => end(true);
    const undo = () => end(false);
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", done);
    grip.addEventListener("pointercancel", undo);
    grip.addEventListener("lostpointercapture", undo);
    e.preventDefault();
  });

  const announce = (text) => {
    live.textContent = "";
    setTimeout(() => {
      live.textContent = text;
    }, 50);
  };

  // Text size: the content only, by CSS zoom, so tables and buttons grow with the words.
  let size = textSize(stored(STORE.text));
  function showText() {
    content.style.zoom = String(size);
    const pct = `${Math.round(size * 100)}%`;
    reset.textContent = pct;
    reset.setAttribute("aria-label", `Reset text size, now ${pct}`);
    smaller.setAttribute("aria-disabled", String(size === TEXT_SIZES[0]));
    larger.setAttribute("aria-disabled", String(size === TEXT_SIZES.at(-1)));
  }
  function setText(next) {
    if (next === size) return;
    // Keep the reader's place: the same share of the way down.
    const range = body.scrollHeight - body.clientHeight;
    const share = range > 0 ? body.scrollTop / range : 0;
    size = next;
    store(STORE.text, String(size));
    showText();
    body.scrollTop = share * (body.scrollHeight - body.clientHeight);
    announce(`Text ${Math.round(size * 100)}%`);
  }
  smaller.addEventListener("click", () => setText(stepText(size, -1)));
  larger.addEventListener("click", () => setText(stepText(size, 1)));
  reset.addEventListener("click", () => setText(1));
  // The keys act while the panel is open, unless another dialog is in front of it.
  addEventListener("keydown", (e) => {
    const by = textKey(e);
    if (by === null || view === "shut" || behind()) return;
    e.preventDefault();
    setText(by === 0 ? 1 : stepText(size, by));
  });
  // Ctrl+wheel over the panel (not a modal's backdrop), a notch a step; touchpad pinches add up to one.
  let wheel = null;
  body.addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      const turn = wheelStep(wheel, wheelPixels(e.deltaY, e.deltaMode), e.timeStamp);
      wheel = turn.state;
      if (turn.steps) setText(stepText(size, turn.steps));
    },
    { passive: false },
  );
  showText();

  const api = {
    layout,
    /** Shut by another panel opening: no focus moves. */
    shut: () => setView("shut", false, true),
    get isOpen() {
      return view !== "shut";
    },
  };
  edge.join(api);
  if (view !== "shut") {
    edge.opening(api);
    onOpen();
  }
  place(false);
  edge.changed(api);

  return {
    title,
    body,
    content,
    announce,
    behind,
    toggle,
    /** Open docked if shut, focusing the title; an open panel keeps its view and takes the focus to its title. */
    open() {
      if (view === "shut") setView("docked");
      else title.focus();
    },
    /** The docked panel's width in px; 0 while it is closed or a dialog. */
    dockedWidth: () => (docked() ? width : 0),
    /** True while the separator is being dragged. */
    get resizing() {
      return resizing;
    },
    get isOpen() {
      return view !== "shut";
    },
    /** The content's text size, 1 for 100%. */
    get textSize() {
      return size;
    },
  };
}
