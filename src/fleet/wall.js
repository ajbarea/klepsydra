// The card wall: a card per Claude Code session, in the reader's order, with
// a way back to its terminal.
import cast from "./cast.json" with { type: "json" };
import { announcements, card, statuses } from "./model.js";
import { syncChildren } from "./dom.js";
import { inTauri, subscribe } from "./feed.js";
import { showFace } from "./face.js";

const TICK_MS = 15_000; // ages re-render between snapshots, as on the gauge
const FACE_PX = 64; // --wall-face

const wall = document.getElementById("wall");
const empty = document.getElementById("empty");
const live = document.getElementById("live");
const tpl = document.getElementById("card-tpl");

let sessions = [];
let before;
let pending = null; // a card to show once it exists

// Everything session-derived goes in as text; the badge is markup the model
// built from constants.
const setText = (el, text) => {
  el.textContent = text ?? "";
};

function paint(el, c) {
  el.setAttribute("aria-label", c.label);
  showFace(el.querySelector(".face"), c.face, c.face2x, FACE_PX);
  setText(el.querySelector(".name"), c.name);
  setText(el.querySelector(".small"), [c.voice, c.session].filter(Boolean).join(" · "));
  setText(el.querySelector(".where"), c.where);
  el.querySelector(".touched").replaceChildren(
    ...c.touched.map((t) => Object.assign(document.createElement("li"), { textContent: t })),
  );
  const badgeKey = `${c.status}${c.quiet}`;
  if (el.dataset.badge !== badgeKey) {
    el.dataset.badge = badgeKey;
    el.querySelector(".corner").innerHTML = c.badge;
    el.querySelector(".mark").innerHTML = c.badge;
  }
  setText(el.querySelector(".status .line"), c.statusLine);
  const error = el.querySelector(".error");
  error.hidden = !c.error;
  setText(error, c.error);
  for (const [cls, text] of [["prompt", c.prompt], ["reply", c.reply]]) {
    const said = el.querySelector(`.${cls} .text`);
    setText(said, text);
    said.title = text ?? "";
  }
  const updated = el.querySelector(".updated");
  updated.hidden = !c.updated;
  setText(updated, c.updated);
  const jump = el.querySelector(".jump");
  const note = el.querySelector(".note");
  jump.dataset.name = c.session ?? "";
  jump.setAttribute("aria-label", c.jumpLabel);
  if (jump.dataset.busy) return;
  jump.disabled = !c.jump.enabled;
  if (!c.jump.enabled) {
    setText(note, c.jump.why);
    note.dataset.why = "";
  } else if ("why" in note.dataset) {
    setText(note, "");
    delete note.dataset.why;
  }
}

function render() {
  const now = Date.now();
  empty.hidden = sessions.length > 0;
  const cards = sessions.map((s) => card(s, cast, now));
  syncChildren(wall, cards, (c) => c.id, () => tpl.content.firstElementChild.cloneNode(true), paint);
}

function show(id) {
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
    before = statuses(message.sessions);
    sessions = message.sessions;
    render();
    if (pending) show(pending);
  }
  if (typeof message?.focus === "string") show(message.focus);
}

wall.addEventListener("click", async (e) => {
  const button = e.target.closest(".jump");
  if (!button || button.disabled || !inTauri) return;
  const note = button.parentElement.querySelector(".note");
  button.disabled = true;
  button.dataset.busy = "1";
  note.textContent = "";
  try {
    note.textContent = await window.__TAURI__.core.invoke("jump_to_terminal", { name: button.dataset.name });
  } catch (err) {
    note.textContent = String(err);
  } finally {
    button.disabled = false;
    delete button.dataset.busy;
    delete note.dataset.why;
  }
});

subscribe(receive);
setInterval(render, TICK_MS);
