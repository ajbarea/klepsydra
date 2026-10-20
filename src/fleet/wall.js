// The card wall: a card per Claude Code session, in the reader's order, with
// a way back to its terminal.
import cast from "./cast.json" with { type: "json" };
import { announcements, card, orderChanged, startedNeeding, statuses, tally } from "./model.js";
import { press, setOff, syncChildren } from "./dom.js";
import { inTauri, subscribe } from "./feed.js";
import { showFace } from "./face.js";

const TICK_MS = 15_000; // ages re-render between snapshots, as on the gauge
const FACE_PX = 66; // --wall-face less the arc's inset
const BRANCH_ICON =
  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="4" cy="3.5" r="1.8"/><circle cx="4" cy="12.5" r="1.8"/><circle cx="12" cy="5" r="1.8"/><path d="M4 5.3v5.4M12 6.8c0 3-3.5 3-8 4.2"/></svg><span></span>';
const TALLY = [
  ["needs", "needs you"],
  ["working", "working"],
  ["done", "done"],
  ["error", "error"],
  ["idle", "idle or ended"],
];

const wall = document.getElementById("wall");
const empty = document.getElementById("empty");
const live = document.getElementById("live");
const tpl = document.getElementById("card-tpl");
const counts = document.querySelector(".tally");
const newButton = document.getElementById("new-session");
const newNote = document.getElementById("new-note");
newButton.hidden = !inTauri;
newButton.addEventListener("click", () =>
  press(newButton, newNote, () => window.__TAURI__.core.invoke("launch_session"), "Starting…"),
);

let sessions = [];
let before;
let pending = null; // a card to show once it exists

// Everything session-derived goes in as text; the badge and branch icon are
// markup built from constants.
const setText = (el, text) => {
  el.textContent = text ?? "";
};
const show = (el, text) => {
  el.hidden = !text;
  setText(el, text);
};

function paint(el, c) {
  const pulsing = el.classList.contains("pulse"); // a repaint must not cut the pulse short
  el.className = `card ${c.dim ? "dim" : ""} tone-${c.tone}${pulsing ? " pulse" : ""}`;
  if (UUID.test(c.id)) el.style.viewTransitionName = `card-${c.id}`;
  else el.style.viewTransitionName = "";
  el.setAttribute("aria-label", c.label);
  el.querySelector(".portrait").title = c.voiceTitle ?? "";
  const fill = el.querySelector(".arc .fill");
  fill.style.display = c.arc > 0 ? "" : "none";
  fill.style.strokeDasharray = `${c.arc} 1`;
  showFace(el.querySelector(".face"), c.face, c.face2x, FACE_PX);
  setText(el.querySelector(".name"), c.name);
  setText(el.querySelector(".task"), c.task);

  const badgeKey = `${c.status}${c.quiet}`;
  if (el.dataset.badge !== badgeKey) {
    el.dataset.badge = badgeKey;
    for (const mark of el.querySelectorAll(".mark")) mark.innerHTML = c.badge;
  }
  setText(el.querySelector(".pill .label"), c.pill.label);
  setText(el.querySelector(".pill .age"), c.pill.age);
  const ask = el.querySelector(".ask");
  ask.hidden = !c.ask;
  setText(ask.querySelector(".text"), c.ask);

  const repo = el.querySelector(".repo");
  const worktree = c.place?.worktree ? [Object.assign(document.createElement("span"), { className: "wt", textContent: ` / ${c.place.worktree}` })] : [];
  repo.replaceChildren(c.place?.repo ?? "", ...worktree);
  const branch = el.querySelector(".branch");
  branch.hidden = !c.place?.branch;
  if (!branch.firstChild) branch.innerHTML = BRANCH_ICON;
  setText(branch.lastChild, c.place?.branch);
  el.querySelector(".also").replaceChildren(
    ...c.also.map((t) => Object.assign(document.createElement("li"), { textContent: t })),
  );

  show(el.querySelector(".error"), c.error);
  for (const [cls, text] of [["prompt", c.prompt], ["reply", c.reply]]) {
    const said = el.querySelector(`.said .${cls}`);
    setText(said, text);
    said.title = text ?? "";
  }
  show(el.querySelector(".updated"), c.updated);

  const jump = el.querySelector(".jump");
  jump.dataset.name = c.session ?? "";
  jump.dataset.id = c.id;
  jump.setAttribute("aria-label", c.jumpLabel);
  jump.title = c.jump.why ?? "";
  show(el.querySelector(".why"), c.jump.why);
  setOff(jump, !c.jump.enabled);
  const clear = el.querySelector(".clear");
  clear.hidden = !c.clear;
  clear.dataset.id = c.id;
  setOff(clear, false);
}

function paintTally() {
  const t = tally(sessions);
  counts.replaceChildren(
    ...TALLY.filter(([key]) => key !== "error" || t.error > 0).map(([key, label]) => {
      const span = Object.assign(document.createElement("span"), { className: `t-${key}` });
      span.append(Object.assign(document.createElement("b"), { textContent: String(t[key]) }), ` ${label}`);
      return span;
    }),
  );
}

const UUID = /^[0-9a-f-]{36}$/i;
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

// The slide needs the browser's view transitions and a reader who allows motion.
const canSlide = () =>
  typeof document.startViewTransition === "function" && !reducedMotion();

// A snapshot (`snapshot` = ids that started needing) may slide and pulse; the 15 s tick passes nothing and does neither.
function render(snapshot) {
  const started = snapshot ?? new Set();
  const now = Date.now();
  empty.hidden = sessions.length > 0;
  paintTally();
  const cards = sessions.map((s) => card(s, cast, now));
  const sync = () => {
    syncChildren(wall, cards, (c) => c.id, () => tpl.content.firstElementChild.cloneNode(true), paint);
    for (const el of wall.children) if (started.has(el.dataset.key) && !reducedMotion()) el.classList.add("pulse");
  };
  const was = [...wall.children].map((el) => el.dataset.key);
  // The first paint, and a reload, has nothing to slide from.
  const reordered = was.length > 0 && orderChanged(was, cards.map((c) => c.id));
  if (snapshot && reordered && canSlide()) document.startViewTransition(() => sync());
  else sync();
}

// The pulse plays once; a later repaint must not replay it.
wall.addEventListener("animationend", (e) => e.target.classList?.remove("pulse"));

function focusCard(id) {
  const el = [...wall.children].find((c) => c.dataset.key === id);
  if (!el) {
    pending = id;
    return;
  }
  pending = null;
  el.scrollIntoView({ block: "center" });
  el.focus({ preventScroll: true });
}

function receive(message) {
  if (Array.isArray(message?.sessions)) {
    const said = announcements(before, message.sessions, cast, Date.now());
    if (said.length) live.textContent = said.join(". ");
    const started = startedNeeding(before, message.sessions);
    before = statuses(message.sessions);
    sessions = message.sessions;
    render(started);
    if (pending) focusCard(pending);
  }
  if (typeof message?.focus === "string") focusCard(message.focus);
}

wall.addEventListener("click", (e) => {
  const button = e.target.closest(".jump, .clear");
  if (!button || !inTauri) return;
  const note = button.closest(".card").querySelector(".note");
  const { invoke } = window.__TAURI__.core;
  if (button.classList.contains("clear")) press(button, note, () => invoke("clear_session", { id: button.dataset.id }));
  else press(button, note, () => invoke("jump_to_terminal", { id: button.dataset.id, name: button.dataset.name }));
});

subscribe(receive);
setInterval(() => render(), TICK_MS);
