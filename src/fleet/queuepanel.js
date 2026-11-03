// The Queue panel: the Needs you file and the queue file rendered live beside
// the wall, one over the other, on the shared side panel (sidepanel.js: shut
// to a tab, docked, or full). Every word from either file goes in through
// queue.js as text.
import { keeperName } from "./theme.js";
import { follow } from "../ipc.js";
import { inTauri, served } from "./feed.js";
import { EMPTY, EMPTY_NEEDS, headerCount, present, queueLabel, render, renderAsks } from "./queue.js";
import { createSidePanel, wireListSplit } from "./sidepanel.js";

export {
  DOCK_MIN_PX, SPLIT, TEXT_SIZES, WALL_MIN, WIDTH, clampShare, clampWidth, parseView, separatorKey, snap, splitKey, stepText,
  textKey, textSize,
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

/** The two lists the panel follows: the app's channel, the ?demo sample, and how each names its file. */
export const LISTS = {
  queue: { command: "queue_subscribe", sample: (app, search) => demoQueueUrl(app, search), what: "queue file" },
  needs: {
    command: "needs_subscribe",
    sample: (app, search) => (demoQueueUrl(app, search) ? "../scripts/fixtures/needs-demo.md" : null),
    what: "Needs you file",
  },
};

/** One list's views, `{path, text, problem}`: the app's channel, or the ?demo sample. */
export function followList({ command, sample, what }, onMessage) {
  if (inTauri) {
    follow(command, onMessage).catch((err) =>
      onMessage({ path: null, text: null, problem: `The ${what} could not be followed: ${err?.message ?? err}` }),
    );
    return;
  }
  const url = sample(inTauri, location.search);
  if (!url) {
    onMessage({ path: null, text: null, problem: `The app reads the ${what}; add ?demo to see the sample.` });
    return;
  }
  fetch(url, { cache: "no-store" })
    .then((res) => (res.ok ? res.text() : Promise.reject(new Error(String(res.status)))))
    .then(
      (text) => onMessage({ path: url, text, problem: null }),
      () => onMessage({ path: url, text: null, problem: `The sample ${what} could not be read.` }),
    );
}

/** Queue file views: the app's queue_subscribe channel, or the ?demo sample. */
export const followQueue = (onMessage) => followList(LISTS.queue, onMessage);

/**
 * Wire the panel to `dialog`, toggled by `button` and reopened from `tab`,
 * sharing `edge` with the other side panels. It holds two lists, Needs you
 * over Queue, each live, scrolled and folded on its own, with a split between
 * them. `cast()` is the character theme worn, which names each file's keeper;
 * `onLayout()` runs on every layout; `onResized()` once at the end of a drag
 * of the separator.
 */
export function createQueuePanel({ dialog, button, tab, edge, cast = () => null, onLayout, onResized }) {
  const panel = createSidePanel({ name: "queue", dialog, button, tab, edge, onLayout, onResized });
  const { title, announce } = panel;
  wireListSplit(dialog.querySelector(".lists"), dialog.querySelector(".lists-split"));

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

  const counts = { needs: null, queue: null };
  function paintButton() {
    // The words after the count are visually hidden below the dock breakpoint
    // (wall.css), where the half-screen bar has no room; the name keeps them.
    const label = queueLabel(headerCount(counts.needs, counts.queue));
    const cut = label.indexOf(" for you");
    button.replaceChildren(cut < 0 ? label : label.slice(0, cut));
    if (cut >= 0) {
      const more = document.createElement("span");
      more.className = "for-you";
      more.textContent = label.slice(cut);
      button.append(more);
    }
  }

  /** One list: its part of the dialog, painted from each view of its file. */
  function wireList(list, renderWith, empty) {
    const part = dialog.querySelector(`.list-${list}`);
    const content = part.querySelector(".queue-content");
    const scroller = part.querySelector(".list-scroll");
    // The Needs you list's title, path and keeper sit in the panel's own header.
    const head = list === "needs" ? dialog.querySelector(".queue-head") : part;
    // Where focus goes when the control it was on is gone: this list's own heading.
    const heading = list === "needs" ? title : part.querySelector("h2");
    const pathLine = head.querySelector(".list-path");
    const keeper = head.querySelector(".list-kept");
    const problem = part.querySelector(".list-problem");
    const opened = new Map(); // section title -> open, as the viewer left it
    let keptBy = null; // the keeper as the keeper file names them, and the voice the hook recorded
    let keptVoice = null;
    /** "Kept by" the keeper: the character their voice is in the theme worn, else the name as typed. */
    const paintKeeper = () => {
      const name = keeperName(keptBy, keptVoice, cast());
      keeper.hidden = !name;
      keeper.textContent = name ? `Kept by ${name}` : "";
      keeper.title = keptBy && name !== keptBy ? `Set as ${keptBy}` : "";
    };
    /** The content's focusable controls: its summaries and buttons. */
    const controls = () => [...content.querySelectorAll("summary, button")];
    function paint(view) {
      // Read off the page, not from toggle events: one still queued would land after the repaint.
      for (const d of content.querySelectorAll("details")) opened.set(d.dataset.key, d.open);
      const shown = present(view, (t) => opened.get(t), document, copy, renderWith, { empty, what: LISTS[list].what });
      counts[list] = view.text === null || view.text === undefined ? null : shown.count;
      paintButton();
      pathLine.textContent = view.path ?? "";
      pathLine.title = view.path ?? "";
      keptBy = view.kept_by ?? null;
      keptVoice = view.kept_voice ?? null;
      paintKeeper();
      problem.hidden = !shown.problem;
      problem.classList.toggle("empty", shown.empty === true);
      problem.textContent = shown.problem ?? "";
      const at = controls().indexOf(document.activeElement);
      const scroll = scroller.scrollTop;
      // One node at a time: a spread of a long paragraph's nodes would overflow the stack.
      const fragment = document.createDocumentFragment();
      for (const child of shown.children) fragment.append(child);
      content.replaceChildren(fragment);
      scroller.scrollTop = scroll;
      if (at >= 0) (controls()[at] ?? heading).focus();
    }
    followList(LISTS[list], paint);
    return paintKeeper;
  }

  const rethemes = [wireList("needs", renderAsks, EMPTY_NEEDS), wireList("queue", render, EMPTY)];
  /** A theme switch renames the keepers; nothing is read again. */
  panel.retheme = () => {
    for (const r of rethemes) r();
  };
  return panel;
}
