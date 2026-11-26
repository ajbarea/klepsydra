// The wall's two lists (#386): each file followed live, the queue file shown
// under the Agents wall and the Needs you file read by the Needs you room
// (rooms.js). Every word from either file goes in through queue.js as text.
import { keeperName } from "./theme.js";
import { follow } from "../ipc.js";
import { inTauri } from "./feed.js";
import { EMPTY, present, render } from "./queue.js";

const COPIED_MS = 2000;
/** Where a viewer's open or folded queue file is kept. */
export const FOLD_KEY = "klepsydra.queuefile.open";

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

/** Needs you file views: the app's needs_subscribe channel, or the ?demo sample. */
export const followNeeds = (onMessage) => followList(LISTS.needs, onMessage);

/** Whether a queue file section opens unasked: Running now, the agents' live work. */
export const openByDefault = (title) => /^running now\b/i.test(String(title).trim());

/**
 * Show the queue file in `section` under the Agents wall: one line until
 * opened, then its sections folded but Running now, each as the viewer left
 * it across repaints. `cast()` is the character theme worn, which names the
 * file's keeper; `onToggle()` runs when the viewer opens or folds it.
 * Returns `retheme`.
 */
export function createQueueFile({ section, cast = () => null, onToggle = () => {} }) {
  const content = section.querySelector(".queue-content");
  const pathLine = section.querySelector(".list-path");
  const keeper = section.querySelector(".list-kept");
  const problem = section.querySelector(".list-problem");
  const live = section.querySelector(".queue-live");
  // Folded to one line unless the viewer opened it: the wall stays one screen (#386).
  const fold = section.querySelector(".qf-fold");
  try {
    fold.open = localStorage.getItem(FOLD_KEY) === "open";
  } catch {
    // Blocked storage: it starts folded.
  }
  fold.addEventListener("toggle", () => {
    try {
      localStorage.setItem(FOLD_KEY, fold.open ? "open" : "shut");
    } catch {
      // A viewer's convenience only.
    }
    onToggle();
  });
  const opened = new Map(); // section title -> open, as the viewer left it
  const relabel = new WeakMap();
  let keptBy = null;
  let keptVoice = null;

  async function copy(text, from, label) {
    try {
      await navigator.clipboard.writeText(text);
      from.textContent = "Copied";
      live.textContent = "Copied";
    } catch {
      const pre = from.closest(".q-code")?.querySelector("pre");
      if (pre) getSelection()?.selectAllChildren(pre);
      from.textContent = "Not copied";
      live.textContent = pre ? "Could not copy. The code is selected: press Ctrl+C." : `Could not copy. The link is ${text}`;
    }
    clearTimeout(relabel.get(from));
    relabel.set(
      from,
      setTimeout(() => {
        from.textContent = label;
      }, COPIED_MS),
    );
  }

  const paintKeeper = () => {
    const name = keeperName(keptBy, keptVoice, cast());
    keeper.hidden = !name;
    keeper.textContent = name ? `Kept by ${name}` : "";
    keeper.title = keptBy && name !== keptBy ? `Set as ${keptBy}` : "";
  };

  function paint(view) {
    for (const d of content.querySelectorAll("details")) opened.set(d.dataset.key, d.open);
    const shown = present(view, (t) => opened.get(t) ?? openByDefault(t), document, copy, render, { empty: EMPTY, what: LISTS.queue.what });
    const was = section.hidden;
    section.hidden = view.text === null && !shown.problem;
    if (was !== section.hidden) onToggle();
    pathLine.textContent = view.path ?? "";
    pathLine.title = view.path ?? "";
    keptBy = view.kept_by ?? null;
    keptVoice = view.kept_voice ?? null;
    paintKeeper();
    problem.hidden = !shown.problem;
    problem.classList.toggle("empty", shown.empty === true);
    problem.textContent = shown.problem ?? "";
    const at = [...content.querySelectorAll("summary, button")].indexOf(document.activeElement);
    const fragment = document.createDocumentFragment();
    for (const child of shown.children) fragment.append(child);
    content.replaceChildren(fragment);
    if (at >= 0) ([...content.querySelectorAll("summary, button")][at] ?? section.querySelector("h2"))?.focus({ preventScroll: true });
  }

  followQueue(paint);
  return paintKeeper;
}
