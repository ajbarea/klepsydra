// The Queue panel: the queue file rendered live beside the wall. Docked on
// the right when the window is wide, a modal dialog like Ledger when it is
// narrow. Every word from the file goes in through queue.js as text.
import { follow } from "../ipc.js";
import { inTauri } from "./feed.js";
import { present, queueLabel } from "./queue.js";
import { wheelPixels, wheelStep } from "../zoom.js";

/** At this window width and wider the panel docks; below it, it is a modal dialog. */
export const DOCK_MIN_PX = 1200;
/** The docked width: its bounds, the default, and one arrow-key step. */
export const WIDTH = { min: 320, max: 900, initial: 480, step: 16 };
const STORE = { width: "klepsydra.queue.width", open: "klepsydra.queue.open", text: "klepsydra.queue.text" };
const COPIED_MS = 2000;

/** `w` held to the panel's bounds and to leave 700 px for the cards; the default for a `w` that is no number. */
export function clampWidth(w, viewport) {
  const room = Math.max(WIDTH.min, Math.min(WIDTH.max, viewport - 700));
  const want = typeof w === "number" && !Number.isNaN(w) ? w : WIDTH.initial;
  return Math.round(Math.min(room, Math.max(WIDTH.min, want)));
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
 * Wire the panel to `dialog`, toggled by `button`. `onLayout()` runs on every
 * layout; `onResized()` once at the end of a drag of the separator.
 */
export function createQueuePanel({ dialog, button, onLayout = () => {}, onResized = () => {} }) {
  const body = dialog.querySelector(".queue-body");
  const content = dialog.querySelector(".queue-content");
  const pathLine = dialog.querySelector(".queue-path");
  const problem = dialog.querySelector(".queue-problem");
  const live = dialog.querySelector(".queue-live");
  const title = dialog.querySelector("#queue-title");
  const grip = dialog.querySelector(".queue-resize");
  const smaller = dialog.querySelector(".queue-smaller");
  const larger = dialog.querySelector(".queue-larger");
  const reset = dialog.querySelector(".queue-reset");
  const wide = matchMedia(`(min-width: ${DOCK_MIN_PX}px)`);
  const opened = new Map(); // section title -> open, as the viewer left it
  // Reopened at start only where it docks: a dialog over the wall at launch would hide it.
  let open = stored(STORE.open) === "1" && wide.matches;
  // The width asked for; a narrow window shows less of it without forgetting it.
  let wanted = clampWidth(Number(stored(STORE.width) ?? NaN), Infinity);
  let width = clampWidth(wanted, innerWidth);
  let last = null;

  const docked = () => open && wide.matches;

  function layout() {
    width = clampWidth(wanted, innerWidth);
    document.documentElement.style.setProperty("--queue-w", `${width}px`);
    document.body.classList.toggle("queue-docked", docked());
    grip.setAttribute("aria-valuemin", String(WIDTH.min));
    grip.setAttribute("aria-valuemax", String(clampWidth(Infinity, innerWidth)));
    grip.setAttribute("aria-valuenow", String(width));
    button.setAttribute("aria-expanded", String(open));
    onLayout();
  }

  /** Show the dialog in the mode the window's width calls for. */
  function place(focus) {
    const before = document.activeElement;
    if (dialog.open) dialog.close();
    if (open) {
      if (wide.matches) dialog.show();
      else dialog.showModal();
      dialog.dataset.mode = wide.matches ? "docked" : "modal";
      // show() focuses the first control inside; a panel reopened at load leaves focus where it was.
      if (focus) title.focus();
      else if (!dialog.matches(":modal") && dialog.contains(document.activeElement)) {
        if (before && !dialog.contains(before)) before.focus({ preventScroll: true });
        if (dialog.contains(document.activeElement)) document.activeElement.blur();
      }
    }
    layout();
  }

  function setOpen(next, focus = next) {
    open = next;
    store(STORE.open, open ? "1" : "0");
    place(focus);
    if (!open && focus !== false) button.focus();
  }

  button.addEventListener("click", () => setOpen(!open));
  dialog.querySelector(".queue-close").addEventListener("click", () => setOpen(false));
  // A modal closes itself on Esc; the docked panel closes on it too. The
  // close event comes a task later, so one from a switch of mode finds the
  // dialog open again and is ignored.
  dialog.addEventListener("close", () => {
    if (open && !dialog.open) setOpen(false);
  });
  dialog.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !dialog.matches(":modal")) {
      e.preventDefault();
      setOpen(false);
    }
  });
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog && dialog.matches(":modal")) setOpen(false);
  });
  wide.addEventListener("change", () => {
    const had = dialog.contains(document.activeElement);
    place(had);
  });
  addEventListener("resize", layout);

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
    const steps = { ArrowLeft: WIDTH.step, ArrowRight: -WIDTH.step, PageUp: WIDTH.step * 4, PageDown: -WIDTH.step * 4 };
    if (e.key in steps) resizeTo(width + steps[e.key]);
    else if (e.key === "Home") resizeTo(WIDTH.min);
    else if (e.key === "End") resizeTo(Infinity);
    else return;
    e.preventDefault();
  });
  grip.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    grip.setPointerCapture(e.pointerId);
    resizing = true;
    let x = e.clientX;
    const move = (m) => {
      x = m.clientX;
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        wanted = clampWidth(document.documentElement.clientWidth - x, innerWidth);
        layout();
      });
    };
    const done = () => {
      grip.removeEventListener("pointermove", move);
      grip.removeEventListener("pointerup", done);
      grip.removeEventListener("pointercancel", done);
      cancelAnimationFrame(frame);
      frame = 0;
      resizing = false;
      resizeTo(document.documentElement.clientWidth - x);
      onResized();
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", done);
    grip.addEventListener("pointercancel", done);
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
  // The keys act while the panel is open, unless another dialog is in front
  // of it: a modal keeps the focus inside itself, so focus elsewhere means another.
  addEventListener("keydown", (e) => {
    const by = textKey(e);
    if (by === null || !open) return;
    if (document.querySelector("dialog:modal") && !dialog.contains(document.activeElement)) return;
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
    problem.hidden = !shown.problem;
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
      return open;
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
