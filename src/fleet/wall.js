// The card wall: a card per Claude Code session, in the reader's order, with
// a way back to its terminal.
import cast from "./cast.json" with { type: "json" };
import { RINGS, announcements, card, identity, shouldSlide, showsRingKey, startedNeeding, transitionName, statuses, tally } from "./model.js";
import { announcer, press, say, setOff, syncChildren } from "./dom.js";
import { ARM_MS, confirmCopy, createEnder, endAllCopy, endingAnnouncement, endingText, sessionCount } from "./end.js";
import { asking, readiness, wrapupAnnouncements, wrapupCopy, wrapupLines } from "./wrapup.js";
import { inTauri, subscribe, todayLedger } from "./feed.js";
import { createDrawer } from "./drawer.js";
import { showFace } from "./face.js";
import { GOLD, SPEAK_FADE_MS, STILL, Speaker, WAVE, waves } from "./speaking.js";
import { parseDensity, resolveDensity } from "./density.js";

const TICK_MS = 15_000; // ages re-render between snapshots, as on the gauge
const FACE_PX = 62; // the comfortable --wall-face less twice its --face-inset
const SVG_NS = "http://www.w3.org/2000/svg";
const SEGMENT_FADE_MS = 200; // wall.css .seg.leave
const MARK_ARC = "M 4.5 16 A 11.5 11.5 0 0 1 27.5 16"; // the ring key's arc (wall.html)
const RESIZE_SETTLE_MS = 100; // Auto measures once a drag pauses, not every frame of it
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
const announce = announcer(live);
const tpl = document.getElementById("card-tpl");
const counts = document.querySelector(".tally");
const newButton = document.getElementById("new-session");
const newNote = document.getElementById("new-note");
const bar = document.querySelector(".bar");
const densityPicker = document.querySelector(".density");
const ringKey = document.querySelector(".ring-key");
newButton.hidden = !inTauri;
newButton.addEventListener("click", () =>
  press(newButton, newNote, () => window.__TAURI__.core.invoke("launch_session"), "Starting…"),
);

let sessions = [];
let request = null; // the snapshot's wrap-up, while one is shown
const ledgerButton = document.getElementById("ledger-open");
const drawer = createDrawer({
  dialog: document.getElementById("ledger"),
  sessions: () => sessions,
  cast,
  fetchToday: todayLedger,
  home: ledgerButton,
});
ledgerButton.addEventListener("click", () => drawer.open(null, ledgerButton));
let before;
let wrapupBefore; // each card's wrap-up line at the last render
let wasSafe = false;
let pending = null; // a card to show once it exists
const speaker = new Speaker();
let speakingEl = null; // the card whose portrait shows the waves
let frameId = 0;
let stillTimer = 0;

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
  // A repaint must not cut the pulse or the arrival short.
  const playing = ["pulse", "arriving"].filter((cls) => el.classList.contains(cls)).map((cls) => ` ${cls}`).join("");
  el.className = `card ${c.dim ? "dim" : ""} tone-${c.tone}${c.ask ? " asking" : ""}${c.figure ? " has-figure" : ""}${c.actions.menu ? " has-menu" : ""}${playing}`;
  el.style.viewTransitionName = transitionName(c.id);
  el.setAttribute("aria-label", c.label);
  el.querySelector(".portrait").title = c.voiceTitle ?? "";
  paintRing(el, c);
  showFace(el.querySelector(".face"), c.face, c.face2x, FACE_PX);
  setText(el.querySelector(".name"), c.name);
  setText(el.querySelector(".task"), c.task);
  paintBand(el, c);

  const badgeKey = `${c.status}${c.quiet}`;
  if (el.dataset.badge !== badgeKey) {
    el.dataset.badge = badgeKey;
    for (const mark of el.querySelectorAll(".mark")) mark.innerHTML = c.badge;
  }
  setText(el.querySelector(".pill .label"), c.pill.label);
  setText(el.querySelector(".pill .age"), c.pill.age);
  setText(el.querySelector(".pill .when"), c.pill.when);
  const crewLine = el.querySelector(".crew-line");
  crewLine.hidden = !c.crew;
  setText(crewLine.querySelector(".count"), c.crew);
  crewLine.querySelector(".free").hidden = !c.promptFree;
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
  const more = el.querySelector(".also-more");
  show(more, c.alsoChip?.text);
  more.title = c.alsoChip?.label ?? "";
  if (c.alsoChip) more.setAttribute("aria-label", c.alsoChip.label);
  else more.removeAttribute("aria-label");

  show(el.querySelector(".error"), c.error);
  for (const [cls, text] of [["prompt", c.prompt], ["reply", c.reply]]) {
    const said = el.querySelector(`.said .${cls}`);
    setText(said, text);
    said.title = text ?? "";
  }
  show(el.querySelector(".updated"), c.updated);
  paintLedger(el, c);
  const wrap = el.querySelector(".wrapup");
  show(wrap, c.wrapup?.text);
  wrap.title = c.wrapup?.text ?? "";
  wrap.dataset.state = c.wrapup?.state ?? "";

  const jump = el.querySelector(".jump");
  jump.dataset.name = c.session ?? "";
  jump.dataset.id = c.id;
  jump.setAttribute("aria-label", c.jumpLabel);
  jump.title = c.jump.why ?? "";
  show(el.querySelector(".why"), c.jump.why);
  setOff(jump, !c.jump.enabled);
  // Fill for needs-you, a left marker for a character, neither when off (wall.css).
  jump.dataset.kind = c.jumpKind;
  if (c.jumpMark) {
    jump.style.setProperty("--accent", c.jumpMark.color);
    jump.style.setProperty("--mark-w", `${c.jumpMark.width}px`);
  } else {
    jump.style.removeProperty("--accent");
    jump.style.removeProperty("--mark-w");
  }
  const clear = el.querySelector(".clear");
  clear.hidden = !c.clear;
  clear.dataset.id = c.id;
  setOff(clear, false);
  const menuButton = el.querySelector(".menu");
  menuButton.hidden = !c.actions.menu;
  menuButton.setAttribute("aria-label", c.menuLabel);
  menuButton.title = c.menuLabel;
  setOff(menuButton, ender.pending(c.id)); // one pending end per card
}

// The receipt, the partial mark and the guardrail chip share one line, hidden when all are empty.
function paintLedger(el, c) {
  const line = el.querySelector(".ledger-line");
  line.hidden = !c.ledger;
  const receipt = el.querySelector(".receipt");
  receipt.hidden = !c.ledger?.full;
  setText(receipt.querySelector(".r-full"), c.ledger?.full);
  setText(receipt.querySelector(".r-short"), c.ledger?.short);
  receipt.title = c.ledger?.full ?? "";
  const partial = el.querySelector(".partial");
  show(partial, c.ledger?.partial?.text);
  partial.title = c.ledger?.partial?.label ?? "";
  if (c.ledger?.partial) partial.setAttribute("aria-label", c.ledger.partial.label);
  else partial.removeAttribute("aria-label");
  const chip = el.querySelector(".chip");
  chip.hidden = !c.ledger?.chip;
  chip.dataset.id = c.id;
  setText(chip.querySelector(".c-short"), c.ledger?.chip?.short);
  setText(chip.querySelector(".c-full"), c.ledger?.chip?.full);
}

// The header band: the character's light and figure, epithet, and the crew
// marks on the figure's plinth. Colours ride on the card as custom properties.
function paintBand(el, c) {
  for (const [prop, value] of [["--accent", c.accent], ["--accent-ink", c.accentInk]]) {
    if (value) el.style.setProperty(prop, value);
    else el.style.removeProperty(prop);
  }
  const epithet = el.querySelector(".epithet");
  epithet.hidden = !c.epithet;
  setText(epithet.lastElementChild, c.epithet);
  const look = el.querySelector(".look");
  look.hidden = !c.full;
  look.dataset.id = c.id;
  look.setAttribute("aria-label", `View ${c.name}'s portrait`);
  const figure = look.querySelector(".figure");
  if (c.figure) {
    if (figure.getAttribute("src") !== c.figure.src) figure.src = c.figure.src;
    ["--head-x", "--head-y"].forEach((prop, i) => el.style.setProperty(prop, c.figure.head[i]));
  } else {
    figure.removeAttribute("src");
    for (const prop of ["--head-x", "--head-y"]) el.style.removeProperty(prop);
  }
  const marks = el.querySelector(".marks");
  const key = `${c.marks.kinds.join(" ")}|${c.marks.more}`;
  if (marks.dataset.key !== key) {
    marks.dataset.key = key;
    marks.replaceChildren(
      ...c.marks.kinds.map((kind) => {
        const svg = document.createElementNS(SVG_NS, "svg");
        svg.setAttribute("viewBox", "0 0 32 18");
        svg.innerHTML = `<path class="${kind}" d="${MARK_ARC}"/>`;
        return svg;
      }),
      ...(c.marks.more > 0 ? [Object.assign(document.createElement("b"), { textContent: `+${c.marks.more}` })] : []),
    );
  }
  if (c.ringColor) marks.style.setProperty("--crew", c.ringColor);
  else marks.style.removeProperty("--crew");
}

// One arc per piece of background work, drawn for the density on screen.
// Arcs past the new count fade out; new ones fade in; the rest take their new
// place at once.
function paintRing(el, c) {
  const ring = c.rings[shown] ?? c.rings.comfortable;
  const g = RINGS[shown] ?? RINGS.comfortable;
  const crew = el.querySelector(".ring .crew");
  const track = el.querySelector(".ring .track");
  track.setAttribute("r", g.r);
  track.setAttribute("stroke-width", g.shell);
  el.querySelector(".ring").classList.toggle("busy", ring.segments.length > 0);
  if (c.ringColor) crew.style.setProperty("--crew", c.ringColor);
  else crew.style.removeProperty("--crew");
  const drawn = [...crew.children].filter((p) => !p.classList.contains("leave"));
  ring.segments.forEach((seg, i) => {
    let path = drawn[i];
    if (!path) {
      path = document.createElementNS(SVG_NS, "path");
      path.classList.add("seg", "enter");
      path.addEventListener("animationend", () => path.classList.remove("enter"), { once: true });
      crew.append(path);
    }
    path.classList.toggle("agent", seg.kind === "agent");
    path.classList.toggle("shell", seg.kind === "shell");
    path.setAttribute("d", seg.d);
    path.setAttribute("stroke-width", seg.width);
  });
  for (const path of drawn.slice(ring.segments.length)) {
    if (reducedMotion()) path.remove();
    else {
      path.classList.add("leave");
      setTimeout(() => path.remove(), SEGMENT_FADE_MS);
    }
  }
  show(el.querySelector(".more"), ring.more > 0 ? `+${ring.more}` : null);
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

const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

// The slide needs the browser's view transitions and a reader who allows motion.
const canSlide = () =>
  typeof document.startViewTransition === "function" && !reducedMotion();

// A snapshot (`snapshot` = ids that started needing) may slide and pulse; the 15 s tick passes nothing and does neither.
// Returns what the live region should say about the wrap-up since the last render.
function render(snapshot) {
  const started = snapshot ?? new Set();
  const now = Date.now();
  empty.hidden = sessions.length > 0;
  paintTally();
  const cards = sessions.map((s) => card(s, cast, now, request));
  cardOf = new Map(cards.map((c) => [c.id, c]));
  ringKey.hidden = !showsRingKey(cards);
  const said = wrapupAnnouncements(wrapupBefore, cards);
  wrapupBefore = wrapupLines(cards);
  const safe = Boolean(request) && readiness(sessions).safe;
  if (safe && !wasSafe) said.push("Every session is ready. Safe to restart");
  wasSafe = safe;
  const sync = () => {
    const focused = document.activeElement;
    // A new card arrives once: its figure steps in and its light rises (wall.css
    // .arriving). Only on the comfortable band; a compact card has no stage to run it.
    const make = () => {
      const el = tpl.content.firstElementChild.cloneNode(true);
      if (shown === "comfortable" && !reducedMotion()) el.classList.add("arriving");
      return el;
    };
    syncChildren(wall, cards, (c) => c.id, make, paint);
    for (const el of wall.children) if (started.has(el.dataset.key) && !reducedMotion()) el.classList.add("pulse");
    // Moving a card in the DOM drops focus; give it back to what had it.
    if (focused !== document.body && focused?.isConnected && document.activeElement !== focused) focused.focus({ preventScroll: true });
    else if (focused && focused !== document.body && !focused.isConnected) wall.focus({ preventScroll: true }); // its card left
    reconcileActions();
    // Auto looks again when a card arrives or leaves, not when one's text changes.
    const ids = cards.map((c) => c.id).join(" ");
    if (ids !== lastIds) {
      lastIds = ids;
      showDensity();
    }
  };
  const was = [...wall.children].map((el) => el.dataset.key);
  if (shouldSlide(was, cards.map((c) => c.id), snapshot) && canSlide()) document.startViewTransition(() => sync());
  else sync();
  paintWrapup(cards, now);
  return said;
}

// The pulse and the arrival play once; a later repaint must not replay them.
const arrived = (e) => {
  if (e.animationName === "light-rise") e.target.closest(".card")?.classList.remove("arriving");
};
wall.addEventListener("animationend", (e) => {
  e.target.classList?.remove("pulse");
  arrived(e);
});
wall.addEventListener("animationcancel", arrived);

// The full portrait (#44): a native modal dialog, so focus stays inside it and
// Escape closes it. Focus goes back to the portrait that opened it, or to the
// wall when that card has left.
const portrait = document.getElementById("portrait");
let openedFrom = null;
function showPortrait(id) {
  const c = cardOf.get(id);
  if (!c?.full) return;
  openedFrom = id;
  const img = portrait.querySelector(".full");
  img.removeAttribute("src"); // never the last portrait under this name while the new one loads
  img.src = c.full;
  img.alt = `${c.name}'s portrait`;
  setText(portrait.querySelector("#portrait-name"), c.name);
  const epithet = portrait.querySelector(".epithet");
  setText(epithet, c.epithet);
  if (c.accentInk) portrait.style.setProperty("--accent-ink", c.accentInk);
  else portrait.style.removeProperty("--accent-ink");
  setText(portrait.querySelector(".voice"), c.voiceTitle);
  portrait.showModal();
}
portrait.addEventListener("close", () => {
  const card = [...wall.children].find((el) => el.dataset.key === openedFrom);
  openedFrom = null;
  (card?.querySelector(".look") ?? wall).focus();
});
// A click on the backdrop lands on the dialog itself; its content fills the rest.
portrait.addEventListener("click", (e) => {
  if (e.target === portrait) portrait.close();
});

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


const circles = (svg, cls, n) => {
  if (svg.childElementCount !== n || !svg.firstElementChild?.classList.contains(cls)) {
    svg.replaceChildren(...Array.from({ length: n }, () => {
      const c = document.createElementNS(SVG_NS, "circle");
      c.classList.add(cls);
      c.setAttribute("cx", WAVE.cx);
      c.setAttribute("cy", WAVE.cy);
      return c;
    }));
  }
  return [...svg.children];
};

// Gold waves outside the crew ring of the card that is speaking, paced by the
// line's loudness. Frames run only while someone speaks; under reduced motion
// a still ring shows instead, and a timer takes it down.
function drawSpeaking() {
  frameId = 0;
  clearTimeout(stillTimer);
  const now = Date.now();
  const f = speaker.frame(now);
  const el = f ? [...wall.children].find((c) => c.dataset.key === f.id) ?? null : null;
  if (el !== speakingEl) {
    speakingEl?.querySelector(".waves")?.replaceChildren();
    speakingEl = el;
  }
  if (!f) return;
  const svg = el?.querySelector(".waves");
  if (svg && reducedMotion()) {
    const [ring] = circles(svg, "still", 1);
    ring.setAttribute("r", STILL.r);
    ring.setAttribute("stroke", GOLD);
    ring.setAttribute("stroke-width", STILL.width);
    stillTimer = setTimeout(drawSpeaking, Math.max(0, speaker.endMs + SPEAK_FADE_MS - now) + 1);
    return;
  }
  if (svg) {
    waves(f.level, f.alpha, now).forEach((w, i) => {
      const c = circles(svg, "wave", WAVE.rings)[i];
      c.setAttribute("r", w.r);
      c.setAttribute("stroke", w.color);
      c.setAttribute("stroke-width", w.width);
      c.setAttribute("stroke-opacity", w.opacity);
    });
  }
  frameId = requestAnimationFrame(drawSpeaking);
}

function receive(message) {
  if (Array.isArray(message?.sessions)) {
    const said = announcements(before, message.sessions, cast, Date.now());
    const speaking = speaker.update(message.speaking ?? null, Date.now());
    const who = speaking && message.sessions.find((s) => s.session_id === speaking);
    if (who) said.push(`${identity(who, cast).name} speaking`);
    const started = startedNeeding(before, message.sessions);
    before = statuses(message.sessions);
    sessions = message.sessions;
    request = message.wrapup ?? null;
    said.push(...render(started));
    if (said.length) announce(said.join(". "));
    drawer.refresh();
    if (!frameId) drawSpeaking();
    if (pending) focusCard(pending);
  }
  if (typeof message?.focus === "string") focusCard(message.focus);
}

wall.addEventListener("click", (e) => {
  const menuButton = e.target.closest(".menu");
  if (menuButton) {
    toggleMenu(menuButton);
    return;
  }
  const undo = e.target.closest(".undo");
  if (undo) {
    undoEnd(undo.closest(".card").dataset.key);
    return;
  }
  const chip = e.target.closest(".chip");
  if (chip) {
    drawer.open(chip.dataset.id, chip);
    return;
  }
  const look = e.target.closest(".look");
  if (look) {
    showPortrait(look.dataset.id);
    return;
  }
  const button = e.target.closest(".jump, .clear");
  if (!button || !inTauri) return;
  const note = button.closest(".card").querySelector(".note");
  const { invoke } = window.__TAURI__.core;
  if (button.classList.contains("clear")) press(button, note, () => invoke("clear_session", { id: button.dataset.id }));
  else press(button, note, () => invoke("jump_to_terminal", { id: button.dataset.id, name: button.dataset.name }));
});

// Session actions: a menu per card, a confirm step, then an undo window. Only
// the undo window's end (end.js) ends a session.
const tauri = (command, args) =>
  inTauri && window.__TAURI__?.core ? window.__TAURI__.core.invoke(command, args) : Promise.reject("Needs the klepsydra app");
const ender = createEnder({ invoke: tauri });
const menu = document.getElementById("session-menu");
const dialog = document.getElementById("end-dialog");
const endCancel = dialog.querySelector(".end-cancel");
const endConfirm = dialog.querySelector(".end-confirm");
let menuFor = null; // { id, button } while the menu is open
let confirmFor = null; // { kind, ids, opener, holds } while the confirm dialog is open
let armTimer = 0;
let openedAt = 0;
// End takes a click only once its timer has run and the click came ARM_MS after the opening.
const armed = (e) => endConfirm.getAttribute("aria-disabled") !== "true" && e.timeStamp - openedAt >= ARM_MS;
const cardEl = (id) => [...wall.children].find((c) => c.dataset.key === id) ?? null;
const menuItems = () => [...menu.querySelectorAll('[role="menuitem"]')].filter((i) => !i.hidden);
const usable = (node) =>
  Boolean(node?.isConnected) && (node.checkVisibility ? node.checkVisibility() : !node.closest("[hidden]"));

function syncMenu() {
  const c = cardOf.get(menuFor.id);
  menu.querySelector('[data-act="interrupt"]').hidden = !c.actions.interrupt;
  menu.querySelector("hr").hidden = !c.actions.interrupt;
}

function closeMenu(refocus) {
  if (!menuFor) return;
  const { button } = menuFor;
  menuFor = null;
  menu.hidden = true;
  button.setAttribute("aria-expanded", "false");
  button.removeAttribute("aria-controls");
  if (refocus && usable(button)) button.focus({ preventScroll: true });
}

function openMenu(button, last = false) {
  const id = button.closest(".card").dataset.key;
  if (!cardOf.get(id)?.actions.menu || button.getAttribute("aria-disabled") === "true") return;
  closeMenu(false);
  menuFor = { id, button };
  syncMenu();
  menu.setAttribute("aria-label", cardOf.get(id).menuLabel);
  menu.hidden = false;
  button.setAttribute("aria-expanded", "true");
  button.setAttribute("aria-controls", menu.id);
  // The list stays inside its own card, never over another card's buttons:
  // below the button where it fits, else above it (the compact corner).
  const at = button.getBoundingClientRect();
  const box = button.closest(".card").getBoundingClientRect();
  const [w, h] = [menu.offsetWidth, menu.offsetHeight];
  const left = Math.max(box.left + 4, Math.min(at.right - w, box.right - w - 4));
  const top = at.bottom + 4 + h <= box.bottom - 4 ? at.bottom + 4 : Math.max(box.top + 4, at.top - h - 4);
  Object.assign(menu.style, { left: `${left}px`, top: `${top}px` });
  const items = menuItems();
  items[last ? items.length - 1 : 0].focus();
}

const toggleMenu = (button) => (menuFor?.button === button ? closeMenu(true) : openMenu(button));

wall.addEventListener("keydown", (e) => {
  const button = e.target.closest?.(".menu");
  if (button && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
    e.preventDefault();
    openMenu(button, e.key === "ArrowUp");
  }
});

menu.addEventListener("keydown", (e) => {
  const items = menuItems();
  const at = items.indexOf(document.activeElement);
  const to = { ArrowDown: (at + 1) % items.length, ArrowUp: (at - 1 + items.length) % items.length, Home: 0, End: items.length - 1 }[e.key];
  if (to !== undefined) items[to].focus();
  else if (e.key === "Tab") {
    // APG: Tab closes the menu and moves on. The menu sits outside the card, so focus goes back to its
    // button first and the browser's own Tab step leaves from there.
    closeMenu(true);
    return;
  } else if (e.key === "Escape") closeMenu(true);
  else return;
  e.preventDefault();
  e.stopPropagation();
});

menu.addEventListener("click", (e) => {
  const item = e.target.closest("[data-act]");
  if (!item || !menuFor) return;
  const { id, button } = menuFor;
  closeMenu(false);
  if (item.dataset.act === "interrupt") {
    press(button, cardEl(id).querySelector(".note"), () => tauri("interrupt_session", { id }), "Interrupting…");
    button.focus({ preventScroll: true });
  } else openEnd(id, button);
});

document.addEventListener("pointerdown", (e) => {
  if (menuFor && !menu.contains(e.target) && !e.target.closest(".menu")) closeMenu(false);
});
addEventListener("resize", () => closeMenu(false));
addEventListener("scroll", () => closeMenu(false), true);
addEventListener("blur", () => closeMenu(false));

// The one confirm dialog, for End on one card, End all ready sessions and
// Wrap up. `holds()` says whether what it names still stands; a snapshot
// that breaks it closes the dialog as Cancel would.
function openConfirm(kind, ids, copy, opener, holds = () => true) {
  dialog.dataset.kind = kind;
  dialog.querySelector("#end-title").textContent = copy.title;
  dialog.querySelector(".end-what").textContent = copy.text;
  const list = dialog.querySelector(".end-list");
  const groups = copy.groups ?? [];
  list.hidden = groups.length === 0;
  list.replaceChildren(
    ...groups.flatMap((g) => [
      ...(g.heading ? [Object.assign(document.createElement("h3"), { textContent: g.heading })] : []),
      listOf(g.names),
    ]),
  );
  const warn = dialog.querySelector(".end-warn");
  warn.hidden = !copy.warn;
  warn.textContent = copy.warn ?? "";
  endCancel.textContent = copy.cancel;
  endConfirm.textContent = copy.confirm;
  confirmFor = { kind, ids, opener, holds };
  dialog.returnValue = "";
  setOff(endConfirm, true);
  clearTimeout(armTimer);
  armTimer = setTimeout(() => setOff(endConfirm, false), ARM_MS);
  openedAt = performance.now();
  dialog.showModal();
  endCancel.focus(); // Enter or Space right after opening cancels
}

const listOf = (names) => {
  const ul = document.createElement("ul");
  ul.append(...names.map((n) => Object.assign(document.createElement("li"), { textContent: n })));
  return ul;
};

const endable = (id) => Boolean(cardOf.get(id)?.actions.menu);

function openEnd(id, opener) {
  if (!endable(id) || ender.pending(id)) return;
  openConfirm("end", [id], confirmCopy(cardOf.get(id)), opener, () => endable(id));
}

// While every live card is ready: the ones klepsydra can end, none already
// ending, and how many ready ones it cannot.
function readyToEnd() {
  if (!request || !readiness(sessions).safe) return { ids: [], outside: 0 };
  const live = [...cardOf.values()].filter((c) => c.status !== "ended");
  const ids = live.filter((c) => c.actions.menu && !ender.pending(c.id)).map((c) => c.id);
  return { ids, outside: live.filter((c) => !c.actions.menu).length };
}

function openEndReady() {
  const { ids, outside } = readyToEnd();
  if (!ids.length) return;
  const stillReady = () => ids.every((id) => endable(id) && cardOf.get(id).wrapup?.state === "ready");
  openConfirm("end", ids, endAllCopy(ids.map((id) => cardOf.get(id)), outside), endReadyButton, stillReady);
}

function openWrapup() {
  if (wrapButton.getAttribute("aria-disabled") === "true") return;
  openConfirm("wrapup", [], wrapupCopy([...cardOf.values()]), wrapButton);
}

endConfirm.addEventListener("click", (e) => {
  if (armed(e)) dialog.close("confirm");
});
endCancel.addEventListener("click", () => dialog.close("cancel"));
dialog.addEventListener("click", (e) => {
  // The backdrop (the body fills the rest), once a double-click's second click is over.
  if (e.target === dialog && armed(e)) dialog.close("cancel");
});
dialog.addEventListener("close", () => {
  clearTimeout(armTimer);
  const what = confirmFor;
  confirmFor = null;
  if (!what) return;
  if (dialog.returnValue !== "confirm") {
    settleFocus(what.ids[0], what.opener);
    return;
  }
  if (what.kind === "end") for (const id of what.ids) beginEnd(id);
  else startWrapup();
});

// Focus back to `first`, else the card (Enter or Space on it does nothing), else the wall.
function settleFocus(id, first = null) {
  [first, cardEl(id), wall].find(usable)?.focus({ preventScroll: true });
}

function hideEnding(el, menuOff = false) {
  el.querySelector(".ending").hidden = true;
  el.querySelector(".ending-live").textContent = "";
  setOff(el.querySelector(".menu"), menuOff);
}

function beginEnd(id) {
  const c = cardOf.get(id);
  const el = cardEl(id);
  if (!c?.actions.menu || !el) return;
  const note = el.querySelector(".note");
  const ending = el.querySelector(".ending");
  const started = ender.start(id, {
    onTick: (left) => {
      el.querySelector(".ending-text").textContent = endingText(c.name, left);
    },
    onSend: () => {
      const now = cardEl(id);
      if (!now) return;
      hideEnding(now, true); // the menu stays off until the end call answers
      say(now.querySelector(".note"), `Ending ${c.name}…`, 0);
    },
    onDone: ({ text }) => {
      const now = cardEl(id);
      if (!now) return;
      setOff(now.querySelector(".menu"), false);
      say(now.querySelector(".note"), text);
    },
  });
  if (!started) return;
  say(note, "", 0);
  ending.hidden = false;
  setOff(el.querySelector(".menu"), true);
  el.querySelector(".ending-live").textContent = endingAnnouncement(c.name);
  el.querySelector(".undo").focus({ preventScroll: true }); // a stray Enter undoes
  paintEndReady();
}

function undoEnd(id) {
  const el = cardEl(id);
  const name = cardOf.get(id)?.name;
  if (!ender.cancel(id) || !el) return;
  hideEnding(el);
  paintEndReady();
  say(el.querySelector(".note"), name ? `${name} keeps running` : "Not ended");
  const menuButton = el.querySelector(".menu");
  if (usable(menuButton)) menuButton.focus({ preventScroll: true });
}

// A card that is gone, or whose session ended or left klepsydra's tmux, drops
// its pending end, its open menu and its open dialog.
function reconcileActions() {
  for (const id of ender.ids()) {
    if (cardOf.get(id)?.actions.menu) continue;
    ender.cancel(id);
    const el = cardEl(id);
    if (!el) continue;
    const focused = el.querySelector(".ending").contains(document.activeElement);
    hideEnding(el);
    if (focused) settleFocus(id);
  }
  if (confirmFor && !confirmFor.holds()) dialog.close("cancel");
  if (menuFor) {
    if (cardOf.get(menuFor.id)?.actions.menu) syncMenu();
    else {
      const { id } = menuFor;
      const had = menu.contains(document.activeElement);
      closeMenu(false);
      if (had) settleFocus(id);
    }
  }
}

// Wrapping up: the bar's Wrap up…, and while a request is shown its count,
// Stop wrap-up, Safe to restart and End all ready sessions….
const wrapButton = document.getElementById("wrapup-open");
const wrapNote = document.getElementById("wrapup-note");
const wrapBar = document.querySelector(".wrapup-bar");
const stopButton = document.getElementById("wrapup-stop");
const endReadyButton = document.getElementById("end-ready");
wrapButton.hidden = !inTauri;
wrapButton.addEventListener("click", openWrapup);
endReadyButton.addEventListener("click", openEndReady);
stopButton.addEventListener("click", () =>
  press(stopButton, wrapNote, () => tauri("cancel_wrapup").then(() => "Stopped asking; answers so far stay"), "Stopping…"),
);

function startWrapup() {
  if (usable(wrapButton)) wrapButton.focus({ preventScroll: true });
  press(
    wrapButton,
    wrapNote,
    async () => {
      const answer = await tauri("start_wrapup");
      const asked = Array.isArray(answer) ? answer : [];
      for (const a of asked) {
        const el = a.error ? cardEl(a.id) : null;
        if (el) say(el.querySelector(".note"), a.error);
      }
      const hand = asked.filter((a) => a.route === "by_hand").length;
      return `Asked ${sessionCount(asked.length - hand)}${hand ? `; ${hand} to ask by hand` : ""}`;
    },
    "Asking…",
  );
}

// Offered while there is a ready card to end and none of them is ending yet.
const paintEndReady = () => {
  endReadyButton.hidden = !inTauri || readyToEnd().ids.length === 0;
};

function paintWrapup(cards, now) {
  const focused = bar.contains(document.activeElement) ? document.activeElement : null;
  const r = readiness(sessions);
  wrapBar.hidden = !request;
  document.querySelector(".wrapup-count").textContent = r.text;
  document.querySelector(".wrapup-safe").hidden = !r.safe;
  stopButton.hidden = !inTauri || !asking(request, now);
  paintEndReady();
  setOff(wrapButton, !cards.some((c) => c.wrapupRoute));
  // A button that just went away hands focus to Wrap up…, never to the page.
  if (focused && !usable(focused) && usable(wrapButton)) wrapButton.focus({ preventScroll: true });
}

// Density: the saved choice, and what is on screen. Auto measures an unseen
// comfortable copy of the wall, so its switch rests on the real render.
let choice = "auto";
let shown = "comfortable";
let lastIds = "";
let cardOf = new Map(); // the last painted card by id, to redraw rings for a new density

/**
 * Whether the comfortable wall, with `extra` more cards as tall as its
 * tallest, fits the window without scrolling. The copy carries the bar too,
 * as comfortable, since the compact bar can be a line shorter.
 */
function comfortableFits(extra) {
  const probe = document.createElement("div");
  probe.inert = true;
  probe.setAttribute("aria-hidden", "true");
  // The window's whole width: a wall that fits shows no scrollbar to take any of it.
  Object.assign(probe.style, { position: "absolute", top: "0", left: "0", width: `${innerWidth}px`, visibility: "hidden" });
  const copy = (el) => {
    const c = el.cloneNode(true);
    c.dataset.density = "comfortable";
    // A copied radio would join the real control's group and take its check.
    for (const input of c.querySelectorAll("input[name]")) input.removeAttribute("name");
    for (const card of c.querySelectorAll(".card")) card.style.viewTransitionName = "";
    return c;
  };
  const grid = copy(wall);
  grid.removeAttribute("id");
  probe.append(copy(bar), grid);
  document.body.append(probe);
  const cards = [...grid.children];
  const tallest = cards.reduce((a, b) => (b.offsetHeight > (a?.offsetHeight ?? -1) ? b : a), null);
  for (let i = 0; i < extra && tallest; i++) grid.append(tallest.cloneNode(true));
  // Fractional heights round up: a wall 0.4 px over still scrolls.
  const fits = Math.ceil(probe.getBoundingClientRect().height) <= innerHeight;
  probe.remove();
  return fits;
}

function showDensity() {
  const was = shown;
  shown = resolveDensity(choice, shown, comfortableFits);
  if (shown !== was) for (const el of wall.children) if (cardOf.has(el.dataset.key)) paintRing(el, cardOf.get(el.dataset.key));
  wall.dataset.density = shown;
  bar.dataset.density = shown;
  // Cards that arrived while the wall was compact do not arrive again when it turns comfortable.
  if (shown !== "comfortable") for (const el of wall.querySelectorAll(".arriving")) el.classList.remove("arriving");
  densityPicker.querySelector('label:has([value="auto"])').title =
    `Compact while the comfortable cards would scroll; ${shown} now`;
}

function choose(value) {
  choice = parseDensity(value);
  for (const input of densityPicker.querySelectorAll("input")) input.checked = input.value === choice;
  showDensity();
}

densityPicker.addEventListener("change", (e) => {
  choose(e.target.value);
  if (inTauri) window.__TAURI__.core.invoke("set_wall_density", { density: choice }).catch(() => {});
});
let resizeTimer = 0;
addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(showDensity, RESIZE_SETTLE_MS);
});
// A card that grows or shrinks (a needs-you line, a longer error) changes the
// wall's height without a card arriving: Auto looks again, once a frame. A
// switch it makes changes the height too, and the hysteresis holds it there.
let densityFrame = 0;
new ResizeObserver(() => {
  cancelAnimationFrame(densityFrame);
  densityFrame = requestAnimationFrame(showDensity);
}).observe(wall);
if (inTauri) window.__TAURI__.core.invoke("get_wall_density").then(choose, () => {});

subscribe(receive);
setInterval(() => {
  const said = render();
  if (said.length) announce(said.join(". "));
}, TICK_MS);
