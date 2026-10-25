// The Queue panel: the queue file rendered live beside the wall. Docked on
// the right when the window is wide, a modal dialog like Ledger when it is
// narrow. Every word from the file goes in through queue.js as text.
import { follow } from "../ipc.js";
import { inTauri } from "./feed.js";
import { present, queueLabel } from "./queue.js";

/** At this window width and wider the panel docks; below it, it is a modal dialog. */
export const DOCK_MIN_PX = 1200;
/** The docked width: its bounds, the default, and one arrow-key step. */
export const WIDTH = { min: 320, max: 900, initial: 480, step: 16 };
const STORE = { width: "klepsydra.queue.width", open: "klepsydra.queue.open" };
const COPIED_MS = 2000;

/** `w` held to the panel's bounds and to leave 700 px for the cards; the default for a `w` that is no number. */
export function clampWidth(w, viewport) {
  const room = Math.max(WIDTH.min, Math.min(WIDTH.max, viewport - 700));
  const want = typeof w === "number" && !Number.isNaN(w) ? w : WIDTH.initial;
  return Math.round(Math.min(room, Math.max(WIDTH.min, want)));
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

  /** Where focus is inside the content, as an index among its controls. */
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
    get view() {
      return last;
    },
  };
}
