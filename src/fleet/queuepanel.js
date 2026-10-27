// The Queue panel: the queue file rendered live beside the wall. Shut to a
// tab on the right edge, docked on the right when the window is wide (a modal
// dialog like Ledger when it is narrow), or full over the whole window. Every
// word from the file goes in through queue.js as text.
import { follow } from "../ipc.js";
import { inTauri, served } from "./feed.js";
import { present, queueLabel } from "./queue.js";
import { wheelPixels, wheelStep } from "../zoom.js";

/** At this window width and wider the panel docks; below it, it is a modal dialog. */
export const DOCK_MIN_PX = 1200;
/** The docked width: its bounds, the default, and one arrow-key step. */
export const WIDTH = { min: 320, max: 900, initial: 480, step: 16 };
/** The room the docked panel leaves the cards. */
export const WALL_MIN = 700;
// `open` is an older build's flag, read only when no view is stored.
const STORE = { width: "klepsydra.queue.width", view: "klepsydra.queue.view", open: "klepsydra.queue.open", text: "klepsydra.queue.text" };
const COPIED_MS = 2000;

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

/**
 * Ctrl+Alt+B, which toggles the panel as it toggles VS Code's secondary side
 * bar; once per press. By its letter, or where the key is no Latin letter
 * (Cyrillic, AltGr), by its place, as browsers fall back.
 */
export function toggleKey(e) {
  if (!e.ctrlKey || !e.altKey || e.metaKey || e.shiftKey || e.repeat) return false;
  return /^[a-z]$/i.test(e.key) ? e.key.toLowerCase() === "b" : e.code === "KeyB";
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

/** The browser's sample queue file, only with ?demo and never inside the app. */
export function demoQueueUrl(app, search) {
  return !app && new URLSearchParams(search).has("demo") ? "../scripts/fixtures/queue-demo.md" : null;
}

/** Queue file views, `{path, text, problem}`: the app's queue_subscribe channel, or the ?demo sample. */
export function followQueue(onMessage) {
  if (inTauri) {
    follow("queue_subscribe", onMessage).catch((err) =>
      onMessage({ path: null, text: null, problem: `The queue file could not be followed: ${err?.message ?? err}` }),
    );
    return;
  }
  const url = demoQueueUrl(inTauri, location.search);
  if (!url) {
    onMessage({ path: null, text: null, problem: "The app reads the queue file; add ?demo to see the sample." });
    return;
  }
  fetch(url, { cache: "no-store" })
    .then((res) => (res.ok ? res.text() : Promise.reject(new Error(String(res.status)))))
    .then(
      (text) => onMessage({ path: url, text, problem: null }),
      () => onMessage({ path: url, text: null, problem: "The sample queue file could not be read." }),
    );
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
 * Wire the panel to `dialog`, toggled by `button` and reopened from `tab`.
 * `onLayout()` runs on every layout; `onResized()` once at the end of a drag
 * of the separator.
 */
export function createQueuePanel({ dialog, button, tab, onLayout = () => {}, onResized = () => {} }) {
  const body = dialog.querySelector(".queue-body");
  const content = dialog.querySelector(".queue-content");
  const pathLine = dialog.querySelector(".queue-path");
  const keeper = dialog.querySelector(".queue-kept");
  const problem = dialog.querySelector(".queue-problem");
  const live = dialog.querySelector(".queue-live");
  const title = dialog.querySelector("#queue-title");
  const grip = dialog.querySelector(".queue-resize");
  const smaller = dialog.querySelector(".queue-smaller");
  const larger = dialog.querySelector(".queue-larger");
  const reset = dialog.querySelector(".queue-reset");
  const fill = dialog.querySelector(".queue-full");
  const wide = matchMedia(`(min-width: ${DOCK_MIN_PX}px)`);
  const opened = new Map(); // section title -> open, as the viewer left it
  // Reopened at start only where it docks: a dialog over the wall at launch
  // would hide it. A narrow start keeps the stored view for a wide one.
  let view = wide.matches ? parseView(stored(STORE.view), stored(STORE.open)) : "shut";
  // The width asked for; a narrow window shows less of it without forgetting it.
  let wanted = clampWidth(Number(stored(STORE.width) ?? NaN), Infinity);
  let width = clampWidth(wanted, innerWidth);
  let preview = null; // where a held drag would land
  let last = null;

  const docked = () => view === "docked" && wide.matches;

  function layout() {
    width = clampWidth(wanted, innerWidth);
    const max = clampWidth(Infinity, innerWidth);
    document.documentElement.style.setProperty("--queue-w", `${width}px`);
    document.body.classList.toggle("queue-docked", docked() && preview !== "shut");
    // The tab needs an edge to spare: none on the phone or in a half-screen window.
    const tabbed = view === "shut" && wide.matches && !served;
    document.body.classList.toggle("queue-tabbed", tabbed);
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
   * focus that was inside to the tab, or where the tab is hidden the button.
   */
  function setView(next, focus = next !== "shut") {
    const had = dialog.contains(document.activeElement);
    view = next;
    store(STORE.view, view);
    place(view === "shut" ? false : focus);
    if (view !== "shut") return;
    if (focus instanceof HTMLElement) focus.focus();
    else if (had) (tab.hidden ? button : tab).focus();
  }

  button.addEventListener("click", () => (view === "shut" ? setView("docked") : setView("shut", button)));
  tab.addEventListener("click", () => setView("docked"));
  fill.addEventListener("click", () => setView(view === "full" ? "docked" : "full", fill));
  dialog.querySelector(".queue-close").addEventListener("click", () => setView("shut", button));
  // A modal closes itself on Esc; the docked panel shuts on it too, and full
  // steps back to docked (its keydown default, the modal's cancel, prevented).
  // The close event comes a task later, so one from a switch of mode finds
  // the dialog open again and is ignored.
  dialog.addEventListener("close", () => {
    if (view !== "shut" && !dialog.open) setView("shut");
  });
  dialog.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (view === "full") setView("docked");
    else if (!dialog.matches(":modal")) setView("shut", button);
    else return;
    e.preventDefault();
  });
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog && dialog.dataset.mode === "modal") setView("shut");
  });
  wide.addEventListener("change", () => {
    const had = dialog.contains(document.activeElement);
    place(had);
  });
  addEventListener("resize", layout);
  // The shortcut acts unless another dialog is in front: a modal keeps the
  // focus inside itself, so focus elsewhere means another.
  const behind = () => document.querySelector("dialog:modal") && !dialog.contains(document.activeElement);
  addEventListener("keydown", (e) => {
    if (served || !toggleKey(e) || behind()) return;
    e.preventDefault();
    if (view === "shut") setView("docked");
    else setView("shut", button);
  });

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
        if (to === "shut" && had) (tab.hidden ? button : tab).focus();
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

  // Text size: the content only, by CSS zoom, so code and Copy buttons grow with the words.
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

  const relabel = new WeakMap(); // a button's pending return to its label
  async function copy(text, from, label) {
    try {
      await navigator.clipboard.writeText(text);
      from.textContent = "Copied";
      announce("Copied");
    } catch {
      // Selected, the text is one Ctrl+C away.
      const pre = from.closest(".q-code")?.querySelector("pre");
      if (pre) getSelection()?.selectAllChildren(pre);
      from.textContent = "Not copied";
      announce(pre ? "Could not copy. The code is selected: press Ctrl+C." : `Could not copy. The link is ${text}`);
    }
    clearTimeout(relabel.get(from));
    relabel.set(
      from,
      setTimeout(() => {
        from.textContent = label;
      }, COPIED_MS),
    );
  }

  /** The content's focusable controls: its summaries and buttons. */
  const controls = () => [...content.querySelectorAll("summary, button")];
  function paint(view) {
    last = view;
    // Read off the page, not from toggle events: one still queued would land after the repaint.
    for (const d of content.querySelectorAll("details")) opened.set(d.dataset.key, d.open);
    const shown = present(view, (t) => opened.get(t), document, copy);
    // The words after the count are visually hidden below the dock breakpoint
    // (wall.css), where the half-screen bar has no room; the name keeps them.
    const label = queueLabel(shown.count);
    const cut = label.indexOf(" for you");
    button.replaceChildren(cut < 0 ? label : label.slice(0, cut));
    if (cut >= 0) {
      const more = document.createElement("span");
      more.className = "for-you";
      more.textContent = label.slice(cut);
      button.append(more);
    }
    pathLine.textContent = view.path ?? "";
    pathLine.title = view.path ?? "";
    keeper.hidden = !view.kept_by;
    keeper.textContent = view.kept_by ? `Kept by ${view.kept_by}` : "";
    problem.hidden = !shown.problem;
    problem.classList.toggle("empty", shown.empty === true);
    problem.textContent = shown.problem ?? "";
    const at = controls().indexOf(document.activeElement);
    const scroll = body.scrollTop;
    // One node at a time: a spread of a long paragraph's nodes would overflow the stack.
    const fragment = document.createDocumentFragment();
    for (const child of shown.children) fragment.append(child);
    content.replaceChildren(fragment);
    body.scrollTop = scroll;
    if (at >= 0) (controls()[at] ?? title).focus();
  }

  place(false);
  followQueue(paint);

  return {
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
    get view() {
      return last;
    },
  };
}
