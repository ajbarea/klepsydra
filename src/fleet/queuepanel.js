// The Queue panel: the queue file rendered live beside the wall, on the
// shared side panel (sidepanel.js: shut to a tab, docked, or full). Every
// word from the file goes in through queue.js as text.
import { follow } from "../ipc.js";
import { inTauri, served } from "./feed.js";
import { present, queueLabel } from "./queue.js";
import { createSidePanel } from "./sidepanel.js";

export {
  DOCK_MIN_PX, TEXT_SIZES, WALL_MIN, WIDTH, clampWidth, parseView, separatorKey, snap, stepText, textKey, textSize,
} from "./sidepanel.js";

const COPIED_MS = 2000;

/**
 * Ctrl+Alt+B, which toggles the panel as it toggles VS Code's secondary side
 * bar; once per press. By its letter, or where the key is no Latin letter
 * (Cyrillic, AltGr), by its place, as browsers fall back.
 */
export function toggleKey(e) {
  if (!e.ctrlKey || !e.altKey || e.metaKey || e.shiftKey || e.repeat) return false;
  return /^[a-z]$/i.test(e.key) ? e.key.toLowerCase() === "b" : e.code === "KeyB";
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

/**
 * Wire the panel to `dialog`, toggled by `button` and reopened from `tab`,
 * sharing `edge` with the other side panels. `onLayout()` runs on every
 * layout; `onResized()` once at the end of a drag of the separator.
 */
export function createQueuePanel({ dialog, button, tab, edge, onLayout, onResized }) {
  const panel = createSidePanel({ name: "queue", dialog, button, tab, edge, onLayout, onResized });
  const { body, content, title, announce } = panel;
  const pathLine = dialog.querySelector(".queue-path");
  const keeper = dialog.querySelector(".queue-kept");
  const problem = dialog.querySelector(".queue-problem");
  const opened = new Map(); // section title -> open, as the viewer left it
  let last = null;

  addEventListener("keydown", (e) => {
    if (served || !toggleKey(e) || panel.behind()) return;
    e.preventDefault();
    panel.toggle();
  });

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

  followQueue(paint);

  return {
    /** The docked panel's width in px; 0 while it is closed or a dialog. */
    dockedWidth: panel.dockedWidth,
    /** True while the separator is being dragged. */
    get resizing() {
      return panel.resizing;
    },
    get isOpen() {
      return panel.isOpen;
    },
    /** The content's text size, 1 for 100%. */
    get textSize() {
      return panel.textSize;
    },
    get view() {
      return last;
    },
  };
}
