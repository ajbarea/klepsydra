// The card wall: a card per Claude Code session, in the reader's order, with
// a way back to its terminal.
import { RINGS, accountsDiffer, arrivalLine, arrivals, branchPage, announcements, card, castPicks, identity, needsFirst, shouldSlide, startedNeeding, transitionName, statuses, tally } from "./model.js";
import { announcer, press, say, setOff, setWaiting, syncChildren } from "./dom.js";
import { ARM_MS, confirmCopy, createEnder, endAllCopy, endingAnnouncement, endingText, withdrawnText } from "./end.js";
import { askedNote, asking, isReady, readiness, wrapupAnnouncements, wrapupCopy, wrapupLines } from "./wrapup.js";
import { inTauri, served, subscribe, subscribeTheme, todayLedger } from "./feed.js";
import { DEFAULT_THEME, THEME_LABELS, THEME_SAVE_MS, THEME_WAIT_MS, keeperOf, loadTheme, loadedTheme, themeFile, themeId } from "./theme.js";
import { createDrawer } from "./drawer.js";
import { createQueueFile, followNeeds } from "./queuepanel.js";
import { DEFAULT_LAYOUT, createRooms, lanes } from "./rooms.js";
import { safeHref } from "./queue.js";
import { createEdge } from "./sidepanel.js";
import { showFace } from "./face.js";
import { MAKER_ICONS } from "./icons.js";
import { GOLD, SPEAK_FADE_MS, STILL, Speaker, WAVE, waves } from "./speaking.js";
import { parseDensity, resolveDensity } from "./density.js";
import { clearAll, clearLabel, endedIds, startLabel, wallState } from "./empty.js";
import { wireSplit } from "./split.js";
import { follow } from "../ipc.js";
import { ciView } from "./ci.js";
import { healthView } from "./health.js";
import { createReplayer } from "./replay.js";
import { cutsText } from "./fulltext.js";
import { syncNameWidths } from "./namewidth.js";
import { WAITING, toRows, usageRows } from "../gauge.js";
import { hiddenRows } from "./chips.js";
import { wireOpacityPick } from "./opacitypick.js";
import { subscribeOpacity } from "../opacity.js";
import { readMode, readStops, syncEntries } from "../gaugeview.js";
import { createLog } from "../log.js";
import { FIX_STEPS, buildEntries, buttonTitle, firstModel, launchArgs, menuEntries, pickDefault, roomWords } from "./newsession.js";

const FIRST_THEME_MS = 1500; // the longest the first paint waits for the app to name the theme
const TICK_MS = 15_000; // ages re-render between snapshots, as on the gauge
const FACE_PX = 62; // the comfortable --wall-face less twice its --face-inset
const SVG_NS = "http://www.w3.org/2000/svg";
const SEGMENT_FADE_MS = 200; // wall.css .seg.leave
const MARK_ARC = "M 4.5 16 A 11.5 11.5 0 0 1 27.5 16"; // a background-work mark's arc, in a 32 x 18 viewBox
const RESIZE_SETTLE_MS = 100; // Auto measures once a drag pauses, not every frame of it
// What each compact card's name was last measured at (namewidth.js), and a
// count of the fonts that loaded since, which can change every name's width.
const nameWidths = new WeakMap();
let fontsLoaded = 0;
// GitHub's mark (octicon mark-github, 16 px).
const GITHUB_ICON =
  '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>';
const BRANCH_ICON =
  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="4" cy="3.5" r="1.8"/><circle cx="4" cy="12.5" r="1.8"/><circle cx="12" cy="5" r="1.8"/><path d="M4 5.3v5.4M12 6.8c0 3-3.5 3-8 4.2"/></svg><span></span>';
// A head and shoulders: the account a session runs on, told apart from the branch beside it.
const ACCOUNT_ICON =
  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="8" cy="5.5" r="2.6"/><path d="M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2"/></svg><span class="visually-hidden">account </span><span></span>';
const BROWSER_ICON =
  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M2 6.5h12M4.5 4.8h.01M7 4.8h.01"/></svg><span></span>';

const TALLY = [
  ["needs", "blocked"],
  ["working", "working"],
  ["done", "done"],
  ["error", "error"],
  ["idle", "idle or ended"],
];

const log = createLog("fleet/wall.js");
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
const startButton = document.getElementById("start-session");
const clearNote = document.getElementById("clear-note");
const clearEnded = document.getElementById("clear-ended");
const emptyTitle = document.getElementById("empty-title");
const limits = document.querySelector(".limits");
const limitRows = limits.querySelector(".limit-rows");

// The gear's view menu is a disclosure over the wall's corner: Escape closes it
// and gives focus back to the gear, and so does a press anywhere outside it.
const gear = document.querySelector(".gear");
gear.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || !gear.open) return;
  e.preventDefault();
  e.stopPropagation();
  gear.open = false;
  gear.querySelector("summary").focus();
});
document.addEventListener("pointerdown", (e) => {
  if (gear.open && !gear.contains(e.target)) gear.open = false;
});
const limitWait = limits.querySelector(".limit-wait");
// + New session (#440, Variant A): the split button names the engine it
// starts; its caret opens one row per other engine with its account, room and
// models. Room comes from read_usage through the gauge's own toRows (the
// desktop snapshot carries no readings), engines and accounts from the
// launcher, the default and the last used from prefs.json.
let sessions = [];
let latestSnapshot = null; // its usage readings draw the limit gauges
const newKind = document.getElementById("new-kind");
const newMenu = document.getElementById("new-menu");
const engList = newMenu.querySelector(".eng-list");
const footWhy = newMenu.querySelector(".mfoot-why");
const footReset = newMenu.querySelector(".eng-reset");
const engTpl = document.getElementById("eng-tpl");
const modelTpl = document.getElementById("model-tpl");
const USAGE_MS = 60_000; // readings change only as sessions reply; the menu reads again on opening
const ENGINES_MS = 60_000; // a newly installed engine shows by the next opening after this
const ns = {
  rows: [],
  engines: null,
  agy: { state: inTauri ? "waiting" : "missing", models: [] },
  prefs: { default: null, last: null },
  enginesError: null,
  ready: !inTauri, // the saved default can be judged: prefs, engines and (when it names agy) agy answered
  open: null, // the menu row shown open
  picked: new Map(), // entry id -> model id the user picked
  fixShown: new Set(), // entry ids whose fix step is shown
  enginesAt: 0,
};

// The engine icons as nodes, parsed once from their constant markup.
const iconCache = new Map();
function iconNode(key) {
  if (!iconCache.has(key)) {
    // The HTML parser puts <svg> in the SVG namespace; the markup carries no xmlns for an XML parse.
    const doc = new DOMParser().parseFromString(MAKER_ICONS[key] ?? MAKER_ICONS.claude, "text/html");
    iconCache.set(key, doc.body.firstElementChild);
  }
  return document.importNode(iconCache.get(key), true);
}

function nsState() {
  const entries = buildEntries({ rows: ns.rows, engines: ns.engines, enginesError: ns.enginesError, agy: ns.agy, nowMs: Date.now() });
  const pick = pickDefault(entries, { userDefault: ns.prefs.default, lastUsed: ns.prefs.last });
  return { entries, pick };
}

const modelOf = (entry) => (ns.picked.has(entry.id) ? ns.picked.get(entry.id) : firstModel(entry));

async function startSession(button, note, args) {
  if (button.getAttribute("aria-disabled") === "true") return;
  const others = [newButton, startButton, newKind].filter((b) => b !== button);
  for (const b of others) setOff(b, true);
  try {
    await press(button, note, () => window.__TAURI__.core.invoke("launch_session", args ?? {}), "Starting…");
  } finally {
    for (const b of others) setOff(b, false);
    loadPrefs(); // a launch that started is now the last used
  }
}
const startDefault = (button) => {
  if (!ns.ready) return; // a click before the saved default is known would start the wrong engine
  const { entry } = nsState().pick;
  startSession(button, newNote, launchArgs(entry, modelOf(entry)));
};
newButton.hidden = !inTauri;
newButton.addEventListener("click", () => startDefault(newButton));

function paintButton() {
  const { entry, reason } = nsState().pick;
  newButton.querySelector(".ico").replaceChildren(iconNode(entry.engine));
  const label = newButton.querySelector(".new-label");
  label.replaceChildren(`New ${entry.shortName}`, Object.assign(document.createElement("span"), { className: "ns-word", textContent: " session" }));
  const mono = newButton.querySelector(".mono");
  mono.hidden = !entry.badge;
  mono.textContent = entry.badge;
  newButton.title = buttonTitle(entry);
  setWaiting(newButton, !ns.ready);
  setWaiting(startButton, !ns.ready);
  newButton.setAttribute("aria-label", `New ${entry.name} session`);
  newKind.hidden = !inTauri;
  footWhy.textContent = `Default: ${entry.name}, ${reason}.`;
  footReset.hidden = !ns.prefs.default;
}

/** One menu row. Keys in data-fk let a redraw put focus back where it was. */
function engRow(e, openId) {
  const row = engTpl.content.firstElementChild.cloneNode(true);
  const head = row.querySelector(".eng-h");
  row.dataset.id = e.id;
  row.setAttribute("aria-label", e.name);
  head.dataset.fk = `h:${e.id}`;
  row.querySelector(".ico").append(iconNode(e.engine));
  row.querySelector(".eng-name").textContent = e.name;
  row.querySelector(".rec").hidden = !e.recommended;
  const words = roomWords(e.room);
  row.querySelector(".room b").textContent = e.usable ? words.bold : "";
  row.querySelector(".room-detail").textContent = e.usable ? words.detail : "";
  row.querySelector(".eng-acct").textContent = e.usable
    ? e.accountLabel
    : e.fix === "install"
      ? "Not installed on this PC"
      : e.fix === "signin"
        ? "Installed, not signed in"
        : e.failed ?? (e.engine === "copilot" ? "Checking whether Copilot is installed…" : "Asking Antigravity for its models…");
  if (!e.usable) {
    row.classList.add("off");
    head.setAttribute("aria-disabled", "true");
    head.removeAttribute("aria-expanded");
    const fixRow = row.querySelector(".eng-fixrow");
    const fix = row.querySelector(".eng-fix");
    const step = FIX_STEPS[e.engine]?.[e.fix];
    fixRow.hidden = !e.fix || (e.fix !== "retry" && !step);
    fix.dataset.fk = `f:${e.id}`;
    fix.dataset.fix = e.fix ?? "";
    fix.textContent = e.fix === "install" ? "How to install" : e.fix === "signin" ? "Sign in" : "Try again";
    if (step && e.fix !== "retry") {
      const shown = ns.fixShown.has(e.id);
      fix.setAttribute("aria-expanded", String(shown));
      const p = row.querySelector(".eng-step");
      p.hidden = !shown;
      p.id = `step-${e.id.replace(/[^A-Za-z0-9-]/g, "-")}`;
      fix.setAttribute("aria-controls", p.id);
      p.querySelector("code").textContent = step;
    } else fix.removeAttribute("aria-expanded");
    return row;
  }
  const open = e.id === openId;
  head.setAttribute("aria-expanded", String(open));
  if (!open) return row;
  row.classList.add("open");
  const models = row.querySelector(".models");
  const picked = modelOf(e);
  if (e.models.length) {
    models.hidden = false;
    models.querySelector("legend").textContent = `${e.name} model`;
    const groups = e.groups ?? [{ key: "all", label: e.engine === "claude" ? "Model · Claude Code's default unless you pick one" : "", models: e.models }];
    for (const g of groups) {
      if (g.label) models.append(Object.assign(document.createElement("div"), { className: "mgrp", textContent: g.label }));
      for (const m of g.models) {
        const lab = modelTpl.content.firstElementChild.cloneNode(true);
        const input = lab.querySelector("input");
        input.name = `model-${e.id}`;
        input.value = m.id;
        input.checked = m.id === picked;
        input.disabled = m.disabled; // a spent model: arrow keys pass over it
        input.dataset.fk = `m:${e.id}:${m.id}`;
        lab.querySelector(".model-name").textContent = m.label;
        lab.querySelector(".why").textContent = m.why;
        models.append(lab);
      }
    }
  }
  row.querySelector(".eng-actions").hidden = false;
  const start = row.querySelector(".eng-start");
  start.textContent = `Start ${e.shortName} session`;
  start.dataset.fk = `s:${e.id}`;
  if ((e.engine === "agy" && !picked) || e.spent) start.setAttribute("aria-disabled", "true");
  row.querySelector(".eng-default").dataset.fk = `d:${e.id}`;
  return row;
}

/** Draw the menu, keeping focus on the control that had it. Only while it is open. */
function paintMenu() {
  if (!newMenu.matches(":popover-open")) return;
  const { entries, pick } = nsState();
  const menu = menuEntries(entries, pick.entry.id);
  if (!menu.some((e) => e.id === ns.open && e.usable)) ns.open = menu.find((e) => e.usable)?.id ?? null;
  const active = newMenu.contains(document.activeElement) ? document.activeElement : null;
  const had = active?.dataset.fk;
  const hadRow = active?.closest(".eng")?.dataset.id;
  engList.replaceChildren(...menu.map((e) => engRow(e, ns.open)));
  if (active) {
    // The same control, else its row's header, else the footer's button, else the caret: never the page.
    const same = had && engList.querySelector(`[data-fk="${CSS.escape(had)}"]`);
    const head = hadRow && engList.querySelector(`.eng[data-id="${CSS.escape(hadRow)}"] .eng-h:not([aria-disabled="true"])`);
    const keep = active === footReset && !footReset.hidden ? footReset : null;
    (same && same.getAttribute("aria-disabled") !== "true" && !same.disabled ? same : head || keep || newKind).focus();
  }
}

function paintNewSession() {
  paintButton();
  paintMenu();
}

async function readRows() {
  try {
    ns.rows = toRows(await window.__TAURI__.core.invoke("read_usage"), Date.now());
  } catch (err) {
    log.warnRepeat("read_usage", "read_usage failed, so + New session shows no room", err);
  }
}
async function readEngines(force = false) {
  if (!force && Date.now() - ns.enginesAt < ENGINES_MS) return;
  ns.enginesAt = Date.now();
  try {
    ns.engines = await window.__TAURI__.core.invoke("engines_status");
    ns.enginesError = null;
  } catch (err) {
    ns.enginesAt = 0;
    if (!ns.engines) ns.enginesError = `klepsydra could not ask which engines are here: ${err}`;
    log.warnRepeat("engines_status", "engines_status failed, so + New session lists every engine as it last knew", err);
  }
}
// agy's models: "not found" alone means not installed; any other failure is
// an error to show, with a retry, never a sign-in.
async function readAgy() {
  ns.agy = { state: "waiting", models: [] };
  try {
    const models = await window.__TAURI__.core.invoke("agy_models");
    ns.agy = Array.isArray(models) && models.length ? { state: "ok", models } : { state: "error", models: [], error: "Antigravity listed no models." };
  } catch (err) {
    const msg = String(err ?? "");
    ns.agy = /not found/i.test(msg)
      ? { state: "missing", models: [] }
      : /not (logged|signed) in|log ?in required|unauthori[sz]ed/i.test(msg)
        ? { state: "signedout", models: [] }
        : { state: "error", models: [], error: msg || "Antigravity did not list its models." };
  }
}
async function loadPrefs() {
  try {
    ns.prefs = await window.__TAURI__.core.invoke("new_session_prefs");
  } catch (err) {
    log.warnRepeat("new_session_prefs", "new_session_prefs failed, so + New session uses the first engine set up", err);
  }
  paintNewSession();
}

newKind.addEventListener("click", () => {
  // Fresh room and engines for the opening menu; the open menu redraws as they land.
  if (!inTauri) return;
  readRows().then(paintNewSession);
  readEngines().then(paintNewSession);
});
newMenu.addEventListener("toggle", (e) => {
  const open = e.newState === "open";
  newKind.setAttribute("aria-expanded", String(open));
  if (open) {
    paintMenu();
    engList.querySelector('.eng-h:not([aria-disabled="true"]), .eng-fix')?.focus();
  } else if (newMenu.contains(document.activeElement) || document.activeElement === document.body) {
    newKind.focus(); // Escape or a click outside: back to the caret, never the page
  }
});

newMenu.addEventListener("click", async (e) => {
  const head = e.target.closest(".eng-h");
  if (head?.getAttribute("aria-disabled") === "true") return;
  if (head) {
    const id = head.closest(".eng").dataset.id;
    ns.open = ns.open === id ? null : id;
    paintMenu();
    return;
  }
  const fix = e.target.closest(".eng-fix");
  if (fix) {
    const id = fix.closest(".eng").dataset.id;
    if (fix.dataset.fix === "retry") {
      if (id === "copilot") await readEngines(true);
      else await readAgy();
    } else if (ns.fixShown.has(id)) ns.fixShown.delete(id);
    else ns.fixShown.add(id);
    paintNewSession();
    return;
  }
  const start = e.target.closest(".eng-start");
  if (start?.getAttribute("aria-disabled") === "true") return;
  if (start) {
    const entry = nsState().entries.find((x) => x.id === start.closest(".eng").dataset.id);
    newMenu.hidePopover();
    if (entry) startSession(newKind, newNote, launchArgs(entry, modelOf(entry)));
    return;
  }
  const def = e.target.closest(".eng-default");
  if (def) {
    await saveDefault(def.closest(".eng").dataset.id);
    return;
  }
  if (e.target.closest(".eng-reset")) await saveDefault(null);
});
newMenu.addEventListener("change", (e) => {
  const input = e.target.closest(".model input");
  if (!input) return;
  ns.picked.set(input.closest(".eng").dataset.id, input.value);
  paintMenu();
});

async function saveDefault(id) {
  try {
    await window.__TAURI__.core.invoke("set_new_session_default", { id });
    ns.prefs = { ...ns.prefs, default: id };
  } catch (err) {
    say(newNote, String(err));
  }
  // The new default leaves the menu: focus goes to the caret, not the page.
  paintNewSession();
  if (!newMenu.contains(document.activeElement)) newKind.focus();
}

if (inTauri) {
  const agyRead = readAgy();
  agyRead.then(paintNewSession);
  Promise.all([readRows(), readEngines(true), loadPrefs()])
    .then(() => ([ns.prefs.default, ns.prefs.last].includes("agy") ? agyRead : null))
    .finally(() => {
      ns.ready = true;
      paintNewSession();
    });
  setInterval(() => readRows().then(paintNewSession), USAGE_MS);
}
paintNewSession();
startButton.hidden = !inTauri;
// Its answer goes to the bar's note, which stays in view once the empty state gives way.
startButton.addEventListener("click", () => startDefault(startButton));
// A cleared id stays off the link until the snapshot that drops its card.
let cleared = new Set();
// The phone cards whose Full text is open, by id; a card that leaves drops out.
let openText = new Set();
const toClear = () => endedIds(sessions).filter((id) => !cleared.has(id));
clearEnded.addEventListener("click", () => {
  if (wallState(sessions) !== "ended") return;
  const ids = toClear();
  press(clearEnded, clearNote, () => clearAll(ids, tauri, (id) => cleared.add(id)), "Clearing…").then(() => paintEmpty(!empty.hidden));
});
// On the phone (the page came from the phone wall server) only the look and
// the Remote Control link act: wall.css hides every other button there.
// scheme.js, in the head, marks the page `.served` before the first paint.
if (served) navigator.serviceWorker?.register("/sw.js").catch(() => {});
const linkNote = document.getElementById("link");
// The phone's stream is down: what the wall shows may be old, so it says so.
const showLink = (up) => {
  linkNote.hidden = up;
  linkNote.textContent = up ? "" : "Reconnecting: the cards may be out of date";
};
// A phone's narrow screen takes one column of compact cards.
const phoneNarrow = () => served && matchMedia("(max-width: 600px)").matches;

// The character theme the wall wears: who each voice is and how they look.
let worn = DEFAULT_THEME;
let cast = loadedTheme(worn);
const wallBackdrop = document.getElementById("wall-backdrop");
function updateBackdrop(theme) {
  if (!wallBackdrop) return;
  const bd = theme?.backdrop;
  const motif = bd?.motif || "forge";
  wallBackdrop.dataset.motif = motif;
  if (bd?.glow) wallBackdrop.style.setProperty("--bg-glow", bd.glow);
  if (bd?.secondary) wallBackdrop.style.setProperty("--bg-secondary", bd.secondary);
}
updateBackdrop(cast);
let request = null; // the snapshot's wrap-up, while one is shown
let native = false; // the snapshot's flag for a native Linux app, which reaches tmux itself (launch.rs NATIVE)
// The Ledger and the Queue share the right edge, one open at a time. Docked,
// a panel narrows the wall, and Auto measures again (its ResizeObserver).
const edge = createEdge();
const drawer = createDrawer({
  dialog: document.getElementById("ledger"),
  button: document.getElementById("ledger-open"),
  tab: document.getElementById("ledger-tab"),
  edge,
  sessions: () => sessions,
  cast: () => cast,
  fetchToday: todayLedger,
  onResized: () => showDensity(),
});
let latest = { state: "empty", cards: [] }; // the last render's, which a deferred sync reads
// The queue file folds under the Agents wall (#386); the phone has no queue file to show.
const queueSection = document.getElementById("queue-file");
// Its height counts in Auto's fit, so opening or showing it re-measures.
const queueFile = served ? null : createQueueFile({ section: queueSection, cast: () => cast, onToggle: () => showDensity() });
// Needs you and Agents (#386): one room each, laid out as the settings pick.
const rooms = createRooms({
  nodes: {
    needsPill: document.getElementById("needs-pill"),
    agentsPill: document.getElementById("agents-pill"),
    tabs: document.getElementById("phone-tabs"),
    room: document.getElementById("needs-room"),
    toast: document.getElementById("room-toast"),
    picker: document.getElementById("needs-layout"),
    note: document.getElementById("layout-note"),
  },
  cards: () => latest.cards,
  makeFace: (c) => {
    if (!c.face) return null;
    const img = Object.assign(document.createElement("img"), { className: "ny-face", alt: "", decoding: "async" });
    showFace(img, c.face, c.face2x, 40);
    return img;
  },
  focusCard: (id) => focusCard(id),
  invoke: inTauri ? (command, args) => tauri(command, args) : null,
  // The desktop webview opens no new window: the app opens a link the Needs you file holds.
  openLink: (url) => {
    if (inTauri) return tauri("needs_open", { url });
    if (!safeHref(url)?.startsWith("https:")) return Promise.reject(new Error("only an https link opens here"));
    window.open(url, "_blank", "noopener,noreferrer");
    return Promise.resolve();
  },
  savedLayout: (() => {
    // A browser page (not the app or the phone) may name one: ?layout=E, as ?theme= names a cast.
    const asked = !inTauri && !served ? new URLSearchParams(location.search).get("layout") : null;
    if (asked) return asked;
    try {
      return localStorage.getItem("klepsydra.needs.layout") ?? DEFAULT_LAYOUT;
    } catch {
      return DEFAULT_LAYOUT;
    }
  })(),
  saveLayout: (layout) => {
    try {
      localStorage.setItem("klepsydra.needs.layout", layout);
    } catch {
      // A viewer's convenience only; the app keeps it in prefs.json.
    }
    return inTauri ? tauri("set_needs_layout", { layout }) : Promise.resolve();
  },
  onLayout: () => {
    render();
    showDensity();
  },
});
// The phone wall serves no file: its Needs you lists the sessions blocked on you.
if (served) rooms.updateNeeds({ text: null, calm: true, problem: "Your to-do list stays in the app on the PC; sessions blocked on you show here." });
else followNeeds((view) => rooms.updateNeeds(view));
let before;
let wrapupBefore; // each card's wrap-up line at the last render
let wasSafe = false;
let pending = null; // a card to show once it exists
const speaker = new Speaker();
let speakingEl = null; // the card whose portrait shows the waves
let frameId = 0;
let stillTimer = 0;
let wasState = null;
let revealed = false; // a focus request named an ended card, so the ended cards show
let launchDir = null;
let dirAsk = 0; // the latest get_launch_dir request; an older answer is dropped

// The empty state stands in for the wall while nothing runs. With only ended
// cards it still does, and offers to clear them, until a focus request asks
// for one of those cards. Read when a sync runs, never when it was asked for.
const showsCards = () => latest.state === "cards" || revealed;
const visibleCards = () => (showsCards() ? latest.cards : []);

function paintEmpty(quiet) {
  empty.hidden = !quiet;
  wall.hidden = quiet; // it holds no card then
  paintStart();
  const n = latest.state === "ended" ? toClear().length : 0;
  clearEnded.hidden = n === 0 || !inTauri;
  setText(clearEnded, n ? clearLabel(n) : "");
}

function paintStart() {
  const label = startLabel(launchDir);
  setText(startButton, label);
  startButton.title = label;
}

// The launch folder, read again each time the empty state comes back and,
// while it shows, each time the window does (it hides rather than closes, so
// a prefs.json edit lands meanwhile). Its answer changes the label only.
function readLaunchDir() {
  if (!inTauri) return;
  const ask = ++dirAsk;
  window.__TAURI__.core.invoke("get_launch_dir").then(
    (dir) => {
      if (ask !== dirAsk) return;
      launchDir = dir;
      paintStart();
    },
    () => {},
  );
}
const rereadLaunchDir = () => {
  if (!empty.hidden && !document.hidden) readLaunchDir();
};
addEventListener("focus", rereadLaunchDir);
document.addEventListener("visibilitychange", rereadLaunchDir);

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
  el.className = `card ${c.dim ? "dim" : ""} tone-${c.tone}${c.ask ? " asking" : ""}${c.figure ? " has-figure" : ""}${c.actions.menu ? " has-menu" : ""}${openText.has(c.id) ? " open-text" : ""}${playing}`;
  el.dataset.motif = c.motif || "burst";
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
  crewLine.hidden = !c.crew && !c.delegate;
  setText(crewLine.querySelector(".count"), c.crew);
  const delChip = crewLine.querySelector(".delegate");
  if (delChip) {
    delChip.hidden = !c.delegate;
    delChip.textContent = c.delegate || "";
    if (c.delegate) delChip.title = `Delegated to ${c.delegate}`;
    else delChip.removeAttribute("title");
  }
  crewLine.querySelector(".free").hidden = !c.promptFree;
  const ask = el.querySelector(".ask");
  ask.hidden = !c.ask;
  // Cut short, the line loses its middle: the tool's own name stays in view (wall.css).
  setText(ask.querySelector(".ask-lead"), c.askParts?.[0]);
  setText(ask.querySelector(".ask-keep"), c.askParts?.[1]);
  ask.title = c.ask ?? "";
  // Inbox and Floor (#386): a blocked card links to its row in Needs you.
  const toNeeds = ask.querySelector(".to-needs");
  toNeeds.hidden = served || rooms.layout !== "D" || c.status !== "needs_you";
  toNeeds.setAttribute("aria-label", `${c.name} in Needs you`);

  const repo = el.querySelector(".repo");
  const worktree = c.place?.worktree ? [Object.assign(document.createElement("span"), { className: "wt", textContent: ` / ${c.place.worktree}` })] : [];
  repo.replaceChildren(c.place?.repo ?? "", ...worktree);
  // #149: on the desktop the folder name opens the folder; on the phone, its GitHub page.
  const page = c.place?.github ?? null;
  const opens = inTauri && !served && c.place?.folder ? "button" : served && page ? "link" : null;
  if (opens) {
    repo.setAttribute("role", opens);
    repo.tabIndex = 0;
    repo.setAttribute("aria-label", opens === "button" ? `Open ${c.place.repo} folder` : `Open ${c.place.repo} on GitHub`);
  } else {
    for (const a of ["role", "tabindex", "aria-label"]) repo.removeAttribute(a);
  }
  const engineBadge = el.querySelector(".engine-badge");
  if (engineBadge) {
    if (c.engineInfo) {
      const iconSvg = MAKER_ICONS[c.engineInfo.maker] || MAKER_ICONS[c.engineInfo.engine] || "";
      engineBadge.innerHTML = iconSvg;
      engineBadge.hidden = !iconSvg;
      engineBadge.title = c.engineInfo.tooltip;
      engineBadge.setAttribute("aria-label", c.engineInfo.ariaLabel);
    } else {
      engineBadge.hidden = true;
      engineBadge.innerHTML = "";
      engineBadge.removeAttribute("title");
      engineBadge.removeAttribute("aria-label");
    }
  }
  const gh = el.querySelector(".gh");
  gh.hidden = !page;
  if (!gh.firstChild) gh.innerHTML = GITHUB_ICON;
  if (page) {
    gh.href = page;
    gh.setAttribute("aria-label", `Open ${c.place.repo} on GitHub`);
    gh.title = `${c.place.repo} on GitHub`;
  } else gh.removeAttribute("href");
  const branch = el.querySelector(".branch");
  branch.hidden = !c.place?.branch;
  if (!branch.firstChild) branch.innerHTML = BRANCH_ICON;
  setText(branch.lastChild, c.place?.branch);
  const tree = branchPage(page, c.place?.branch);
  if (tree) {
    branch.href = tree;
    branch.setAttribute("aria-label", `Open branch ${c.place.branch} on GitHub`);
  } else {
    branch.removeAttribute("href");
    branch.removeAttribute("aria-label");
  }
  const acct = el.querySelector(".acct");
  acct.hidden = !c.showAccount;
  if (!acct.firstChild) acct.innerHTML = ACCOUNT_ICON;
  setText(acct.lastChild, c.showAccount ? c.account : null);
  acct.title = c.showAccount ? `Account: ${c.account}` : "";
  const browserChip = el.querySelector(".browser-chip");
  if (browserChip) {
    browserChip.hidden = !c.browser;
    if (!browserChip.firstChild) browserChip.innerHTML = BROWSER_ICON;
    setText(browserChip.lastChild, c.browser ? `browser: ${c.browser}` : null);
    browserChip.title = c.browser ? `MCP browser held by ${c.browser}` : "";
  }
  el.querySelector(".where").title = [`${c.place?.repo ?? ""}${c.place?.worktree ? ` / ${c.place.worktree}` : ""}`, c.place?.branch, c.showAccount ? `on ${c.account}` : null].filter(Boolean).join(" \u00b7 ");
  const also = c.also.map((t) => Object.assign(document.createElement("li"), { textContent: t }));
  if (c.alsoRest) {
    // The repos past the named ones, as the compact chip names them; Full text names each instead.
    const chip = Object.assign(document.createElement("span"), { className: "also-rest", textContent: c.alsoRest.text, title: c.alsoRest.label });
    chip.setAttribute("role", "img");
    chip.setAttribute("aria-label", c.alsoRest.label);
    const li = Object.assign(document.createElement("li"), { className: "rest" });
    li.append(chip);
    also.push(li, ...c.alsoPast.map((t) => Object.assign(document.createElement("li"), { className: "past", textContent: t })));
  }
  el.querySelector(".also").replaceChildren(...also);
  const more = el.querySelector(".also-more");
  show(more, c.alsoChip?.text);
  more.title = c.alsoChip?.label ?? "";
  if (c.alsoChip) more.setAttribute("aria-label", c.alsoChip.label);
  else more.removeAttribute("aria-label");

  show(el.querySelector(".error"), c.error);
  el.querySelector(".error").title = c.error ?? "";
  for (const [cls, text] of [["prompt", c.prompt], ["reply", c.reply]]) {
    const said = el.querySelector(`.said .${cls}`);
    setText(said, text);
    said.title = text ?? "";
  }
  paintPlay(el, c);
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
  // A Remote Control link, on the phone only: the desktop has its terminal.
  const remote = el.querySelector(".remote");
  remote.hidden = !(served && c.remote);
  if (served && c.remote) {
    remote.href = c.remote;
    remote.setAttribute("aria-label", c.remoteLabel);
  } else remote.removeAttribute("href");
  el.classList.toggle("has-remote", served && Boolean(c.remote));
  const unfold = el.querySelector(".unfold");
  unfold.setAttribute("aria-expanded", String(openText.has(c.id)));
  unfold.setAttribute("aria-label", `Full text, ${c.name}`);
  const menuButton = el.querySelector(".menu");
  menuButton.hidden = !c.actions.menu;
  menuButton.setAttribute("aria-label", c.menuLabel);
  menuButton.title = c.menuLabel;
  setOff(menuButton, ender.pending(c.id)); // one pending end per card
}

// A card's play button for keryx's latest spoken reply: shown only with a
// clip, on the desktop and the phone alike; Stop while it plays.
const replayer = createReplayer({
  audio: document.getElementById("reply-audio"),
  app: inTauri,
  invoke: (command, args) => window.__TAURI__.core.invoke(command, args),
  onChange: (id) => {
    const el = [...wall.children].find((n) => n.dataset.key === id);
    const c = cardOf.get(id);
    if (el && c) paintPlay(el, c);
  },
});

function paintPlay(el, c) {
  const play = el.querySelector(".play");
  const playing = replayer.playing(c.id);
  play.hidden = c.clip === null;
  play.classList.toggle("playing", playing);
  play.setAttribute("aria-label", playing ? c.stopLabel : c.playLabel);
  play.title = playing ? c.stopLabel : c.playLabel;
  el.querySelector(".reply-line").hidden = c.clip === null && !c.reply;
}

// The receipt, the partial mark and the guardrail chip share one line, hidden when all are empty.
function paintLedger(el, c) {
  const line = el.querySelector(".ledger-line");
  line.hidden = !c.ledger;
  const receipt = el.querySelector(".receipt");
  receipt.hidden = !c.ledger?.full;
  receipt.classList.toggle("warn", Boolean(c.ledger?.warn));
  setText(receipt.querySelector(".r-full"), c.ledger?.full);
  setText(receipt.querySelector(".r-short"), c.ledger?.short);
  receipt.title = c.ledger?.why ? `${c.ledger.full}\n${c.ledger.why}` : (c.ledger?.full ?? "");
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
  for (const [prop, value] of [["--accent", c.accent], ["--accent-ink", c.accentInk], ["--accent-light", c.accentLight]]) {
    if (value) el.style.setProperty(prop, value);
    else el.style.removeProperty(prop);
  }
  const epithet = el.querySelector(".epithet");
  epithet.hidden = !c.epithet;
  setText(epithet.lastElementChild, c.epithet);
  setText(el.querySelector(".herald-name"), c.name);
  setText(el.querySelector(".herald-epithet"), c.epithet);
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

// The usage-limit gauges: the desktop gauge's rows, drawn by its own code,
// for a snapshot that carries readings (the phone server's).
function paintLimits(now) {
  const all = usageRows(latestSnapshot, now);
  limits.hidden = all === null;
  if (all === null) return;
  // A spent week hides its account's session row, as on the gauge strip (#421).
  const hidden = hiddenRows(all);
  const rows = all.filter((r) => !hidden.has(r));
  limitWait.hidden = rows.length > 0;
  limitWait.textContent = WAITING;
  syncEntries(limitRows, rows, { compact: true, stops: readStops(), mode: readMode() }, true);
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

// Arrivals (#373): the ids seen so far (null until the first snapshot seeds
// them), those announced whose card is not built yet, and those built while
// the window was hidden, played once it is shown.
const ARRIVE_STAGGER_MS = 450;
let seenIds = null;
const arriving = new Set();
const heldArrivals = new Set();
// The slide needs the browser's view transitions and a reader who allows motion.
const canSlide = () =>
  typeof document.startViewTransition === "function" && !reducedMotion();

/** The layout whose lanes the wall wears: the chosen one, none on the phone. */
const wallLayout = () => (served ? null : rooms.layout);

/** A status lane's head on the wall: its name and how many cards it holds. */
function laneHead() {
  const h = document.createElement("h2");
  h.className = "lane-head";
  h.append(Object.assign(document.createElement("span"), { className: "lane-name" }), Object.assign(document.createElement("span"), { className: "lane-count" }));
  return h;
}
function paintLane(el, x) {
  el.dataset.lane = x.lane;
  setText(el.querySelector(".lane-name"), x.label);
  setText(el.querySelector(".lane-count"), String(x.count));
}

// A snapshot (`snapshot` = ids that started needing) may slide and pulse; the 15 s tick passes nothing and does neither.
// Returns what the live region should say about the wrap-up since the last render.
function render(snapshot) {
  const started = snapshot ?? new Set();
  const now = Date.now();
  const state = wallState(sessions);
  if (state !== "ended") revealed = false;
  if (state !== wasState && state !== "cards") readLaunchDir();
  wasState = state;
  paintTally();
  paintLimits(now);
  const cards = sessions.map((s) => card(s, cast, now, request, native));
  const twoAccounts = accountsDiffer(cards);
  for (const c of cards) c.showAccount = twoAccounts && Boolean(c.account);
  cardOf = new Map(cards.map((c) => [c.id, c]));
  replayer.keep(new Set(cardOf.keys()));
  latest = { state, cards };
  cleared = new Set([...cleared].filter((id) => cardOf.has(id)));
  openText = new Set([...openText].filter((id) => cardOf.has(id)));
  rooms.updateSessions(sessions, { snapshot: Boolean(snapshot) });
  const said = wrapupAnnouncements(wrapupBefore, cards);
  wrapupBefore = wrapupLines(cards);
  const r = readiness(sessions, request);
  const safe = Boolean(request) && r.safe;
  if (safe && !wasSafe) said.push(`${r.live ? "Every session is ready" : "Every session has ended"}. Safe to restart`);
  wasSafe = safe;
  const sync = () => {
    const focused = document.activeElement;
    const inside = wall.contains(focused) || empty.contains(focused);
    const visible = visibleCards();
    // A session's first appearance is an event (#373, wall.css .arriving): its
    // figure steps in over the frame and its banner settles into the header.
    // Several at once arrive in turn; a hidden window keeps theirs until shown.
    let turn = 0;
    const make = (c) => {
      const el = tpl.content.firstElementChild.cloneNode(true);
      el.dataset.motif = c.motif || "burst";
      if (arriving.has(c.id)) {
        arriving.delete(c.id);
        el.style.setProperty("--arrive-at", `${ARRIVE_STAGGER_MS * turn++}ms`);
        if (document.hidden) heldArrivals.add(c.id);
        else el.classList.add("arriving");
      }
      return el;
    };
    paintEmpty(!showsCards());
    // Status lanes (#386): a head before each lane's cards, as the layout groups them;
    // the phone keeps its one column, needs-you first, with no heads to cost it height.
    const laid = lanes(visible, wallLayout());
    wall.toggleAttribute("data-lanes", laid.length !== visible.length);
    syncChildren(
      wall,
      laid,
      (x) => (x.lane ? `lane:${x.lane}` : x.id),
      (x) => (x.lane ? laneHead() : make(x)),
      (el, x) => (x.lane ? paintLane(el, x) : paint(el, x)),
    );
    for (const id of arriving) if (!cardOf.has(id)) arriving.delete(id); // left before it was ever shown
    const shown = new Set([...wall.children].map((el) => el.dataset.key));
    for (const id of heldArrivals) if (!shown.has(id)) heldArrivals.delete(id); // its card left while the window was hidden
    for (const el of wall.children) if (started.has(el.dataset.key) && !reducedMotion()) el.classList.add("pulse");
    // Moving a card in the DOM drops focus; give it back to what had it.
    if (focused !== document.body && focused?.isConnected && document.activeElement !== focused) focused.focus({ preventScroll: true });
    else if (focused && focused !== document.body && !focused.isConnected) wall.focus({ preventScroll: true }); // its card left
    // The wall gave way to the empty state, or the clear link left: its title takes focus.
    const lost = document.activeElement === document.body || !usable(document.activeElement);
    if (inside && lost) [emptyTitle, wall].find(usable)?.focus({ preventScroll: true });
    reconcileActions();
    syncNames();
    syncFullText();
    // Auto looks again when a card arrives or leaves, not when one's text changes.
    const ids = visible.map((c) => c.id).join(" ");
    if (ids !== lastIds) {
      lastIds = ids;
      showDensity();
    }
  };
  const was = [...wall.children].map((el) => el.dataset.key).filter((k) => !k.startsWith("lane:"));
  const next = lanes(visibleCards(), wallLayout()).filter((x) => !x.lane).map((c) => c.id);
  if (shouldSlide(was, next, snapshot) && canSlide()) document.startViewTransition(() => sync());
  else sync();
  paintWrapup(cards, now);
  return said;
}

// The pulse and the arrival play once; a later repaint must not replay them.
const arrived = (e) => {
  if (e.animationName !== "herald" && e.animationName !== "herald-calm") return;
  const el = e.target.closest(".card");
  el?.classList.remove("arriving");
  el?.style.removeProperty("--arrive-at");
};
document.addEventListener("visibilitychange", () => {
  wallBackdrop?.classList.toggle("paused", document.hidden);
  if (document.hidden || !heldArrivals.size) return;
  for (const el of wall.children) if (heldArrivals.has(el.dataset.key)) el.classList.add("arriving");
  heldArrivals.clear();
});
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
  fillPortrait(c);
  portrait.showModal();
}
function fillPortrait(c) {
  const img = portrait.querySelector(".full");
  if (img.getAttribute("src") !== c.full) {
    img.removeAttribute("src"); // never the last portrait under this name while the new one loads
    img.src = c.full;
  }
  img.alt = `${c.name}'s portrait`;
  setText(portrait.querySelector("#portrait-name"), c.name);
  const epithet = portrait.querySelector(".epithet");
  setText(epithet, c.epithet);
  if (c.accentInk) portrait.style.setProperty("--accent-ink", c.accentInk);
  else portrait.style.removeProperty("--accent-ink");
  setText(portrait.querySelector(".voice"), c.voiceTitle);
}
/** An open portrait shows its card as now painted: a theme switch renames and redraws it. */
function refillPortrait() {
  if (portrait.open && cardOf.get(openedFrom)?.full) fillPortrait(cardOf.get(openedFrom));
}
portrait.addEventListener("close", () => {
  const card = [...wall.children].find((el) => el.dataset.key === openedFrom);
  openedFrom = null;
  [card?.querySelector(".look"), wall, emptyTitle].find(usable)?.focus();
});
// A click on the backdrop lands on the dialog itself; its content fills the rest.
portrait.addEventListener("click", (e) => {
  if (e.target === portrait) portrait.close();
});

// A request for a card not drawn yet waits one snapshot, and no longer.
function focusCard(id, retry = false) {
  if (!revealed && wallState(sessions) === "ended" && sessions.some((s) => s.session_id === id)) {
    revealed = true;
    render();
  }
  const el = [...wall.children].find((c) => c.dataset.key === id);
  if (!el) {
    pending = retry ? null : id;
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

// The phone wears the theme each snapshot names before painting it, so its
// first card is already in that theme, but waits at most THEME_WAIT_MS for
// the theme's file (wearSoon): past that it paints in the theme it wears and
// takes the new one when the file comes. Snapshots are taken in order.
let inbox = Promise.resolve();
function receive(message) {
  if (!served) {
    try {
      take(message);
    } catch (err) {
      notShown(message, err);
    }
    return;
  }
  const theme = Array.isArray(message?.sessions) ? () => wearSoon(message.theme, false) : () => null;
  inbox = inbox
    .then(theme)
    .then(() => take(message))
    .catch((err) => notShown(message, err));
}

/** Every snapshot after a render bug fails the same way: its cause once, then a count. */
function notShown(message, err) {
  const n = Array.isArray(message?.sessions) ? message.sessions.length : "no";
  log.errorRepeat("snapshot", `a fleet snapshot (${n} sessions, theme ${message?.theme}) could not be shown`, err);
}

// A bar button hidden while its popover is open takes the popover with it (#248
// hides CI and Fleet while all is well): nothing stays open with no way back.
function showButton(button, panel, hidden) {
  button.hidden = hidden;
  if (hidden && panel.matches(":popover-open")) panel.hidePopover();
}

// CI watch: the bar's CI button and its popover (ci.js). The phone's view
// comes with each snapshot; the app's through ci_subscribe.
const ciButton = document.getElementById("ci-open");
const ciPanel = document.getElementById("ci");
function showCi(view) {
  const v = ciView(view);
  showButton(ciButton, ciPanel, v.hidden);
  ciButton.textContent = v.label;
  ciButton.title = v.title;
  ciButton.dataset.tone = v.tone;
  ciPanel.querySelector(".ci-title").textContent = v.title;
  ciPanel.querySelector(".ci-note").textContent = v.note;
  ciPanel.querySelector(".ci-runs").replaceChildren(
    ...v.rows.map((r) => {
      const li = document.createElement("li");
      // A link on the phone; on the desktop a run's address is its tooltip (the app opens only a session's own GitHub pages).
      const link = r.url && served;
      const head = document.createElement(link ? "a" : "span");
      head.className = "ci-head";
      head.textContent = r.head;
      if (link) Object.assign(head, { href: r.url, target: "_blank", rel: "noopener noreferrer" });
      else if (r.url) head.title = r.url;
      const step = Object.assign(document.createElement("span"), { className: "ci-step", textContent: r.step });
      const cause = Object.assign(document.createElement("span"), { className: "ci-cause", textContent: r.cause });
      li.append(head, step, cause);
      return li;
    }),
  );
}
if (inTauri) follow("ci_subscribe", showCi).catch(() => {});

// Fleet health: the bar's Fleet button and its popover of fleet doctor's checks
// (health.js). The phone's view comes with each snapshot; the app's through health_subscribe.
const healthButton = document.getElementById("health-open");
const healthPanel = document.getElementById("health");
function showHealth(view) {
  const v = healthView(view);
  showButton(healthButton, healthPanel, v.hidden);
  healthButton.textContent = v.label;
  healthButton.title = v.title;
  healthButton.dataset.tone = v.tone;
  healthPanel.querySelector(".health-title").textContent = v.title;
  healthPanel.querySelector(".health-note").textContent = v.note;
  healthPanel.querySelector(".health-checks").replaceChildren(
    ...v.rows.map((r) => {
      const li = document.createElement("li");
      li.dataset.status = r.status;
      li.append(
        Object.assign(document.createElement("span"), { className: "health-status", textContent: r.statusLabel }),
        Object.assign(document.createElement("span"), { className: "health-check", textContent: r.check }),
        Object.assign(document.createElement("span"), { className: "health-detail", textContent: r.detail }),
      );
      return li;
    }),
  );
}
if (inTauri) follow("health_subscribe", showHealth).catch(() => {});

function take(message) {
  if (served && "ci" in (message ?? {})) showCi(message.ci);
  if (served && "health" in (message ?? {})) showHealth(message.health);
  if (Array.isArray(message?.sessions)) {
    const fresh = castPicks(message.sessions, cast);
    const got = arrivals(seenIds, fresh);
    seenIds = got.seen;
    const came = new Set(got.arrived);
    for (const id of came) arriving.add(id);
    const said = [
      ...fresh.filter((s) => came.has(s.session_id)).map((s) => arrivalLine(s, cast)),
      ...announcements(before, fresh.filter((s) => !came.has(s.session_id)), cast, Date.now()),
    ];
    const speaking = speaker.update(message.speaking ?? null, Date.now());
    const who = speaking && fresh.find((s) => s.session_id === speaking);
    if (who) said.push(`${identity(who, cast).name} speaking`);
    const started = startedNeeding(before, fresh);
    before = statuses(fresh);
    sessions = served ? needsFirst(fresh) : fresh;
    request = message.wrapup ?? null;
    native = message.native === true;
    latestSnapshot = message;
    said.push(...render(started));
    if (said.length) announce(said.join(". "));
    refillPortrait();
    drawer.refresh();
    if (!frameId) drawSpeaking();
    if (pending) focusCard(pending, true);
  }
  if (typeof message?.focus === "string") focusCard(message.focus);
}

wall.addEventListener("click", (e) => {
  // The desktop webview opens no new window: the app opens the page it has on record.
  const ghLink = inTauri && !served ? e.target.closest(".gh[href], .branch[href]") : null;
  if (ghLink) {
    e.preventDefault();
    const card = ghLink.closest(".card");
    press(ghLink, card.querySelector(".note"), () => tauri("open_github", { id: card.dataset.key, branch: ghLink.classList.contains("branch") }));
    return;
  }
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
  const toNeeds = e.target.closest(".to-needs");
  if (toNeeds) {
    rooms.showBlocked(toNeeds.closest(".card").dataset.key);
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
  const play = e.target.closest(".play");
  if (play) {
    const id = play.closest(".card").dataset.key;
    const note = play.closest(".card").querySelector(".note");
    replayer.toggle(id, cardOf.get(id)?.clip).then((why) => {
      if (!why) return;
      say(note, why);
      log.warn(`a reply clip did not play: ${why}`, undefined, { session_id: id });
    });
    return;
  }
  // Full text opens or shuts in place; nothing else.
  const unfold = e.target.closest(".unfold");
  if (unfold) {
    const card = unfold.closest(".card");
    const id = card.dataset.key;
    if (!openText.delete(id)) openText.add(id);
    card.classList.toggle("open-text", openText.has(id));
    unfold.setAttribute("aria-expanded", String(openText.has(id)));
    syncFullText();
    return;
  }
  const repoName = e.target.closest(".repo[role]");
  if (repoName) {
    openRepo(repoName);
    return;
  }
  // On the phone a tap anywhere on a card with a Remote Control link opens it.
  if (served && !e.target.closest("a, button")) {
    const remote = e.target.closest(".card")?.querySelector(".remote:not([hidden])");
    if (remote) remote.click();
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
// Split mode: the wall left, the fleet terminal right (Windows only; split.js).
wireSplit({ button: document.getElementById("split"), note: document.getElementById("split-note"), invoke: tauri, app: inTauri, follow });
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

// A card's folder name (#149): the folder in the file manager, or on the phone its GitHub page.
function openRepo(name) {
  const card = name.closest(".card");
  if (name.getAttribute("role") === "link") {
    card.querySelector(".gh[href]")?.click();
    return;
  }
  press(name, card.querySelector(".note"), () => tauri("open_folder", { id: card.dataset.key }));
}

wall.addEventListener("keydown", (e) => {
  const name = e.target.closest?.(".repo[role]");
  if (name && (e.key === "Enter" || e.key === " ")) {
    e.preventDefault();
    openRepo(name);
    return;
  }
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
// that breaks it closes the dialog as Cancel would. `bulk`: End all ready,
// whose every end still needs its session ready when its window runs out.
function openConfirm(kind, ids, copy, opener, holds = () => true, bulk = false) {
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
  confirmFor = { kind, ids, opener, holds, bulk };
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
  if (!request || !readiness(sessions, request).safe) return { ids: [], outside: 0 };
  const live = [...cardOf.values()].filter((c) => c.status !== "ended");
  const ids = live.filter((c) => c.actions.menu && !ender.pending(c.id)).map((c) => c.id);
  return { ids, outside: live.filter((c) => !c.actions.menu).length };
}

function openEndReady() {
  const { ids, outside } = readyToEnd();
  if (!ids.length) return;
  // Every live card still ready, not just the listed ones: a session that arrives unready closes it.
  const stillReady = () => Boolean(request) && readiness(sessions, request).safe && ids.every((id) => endable(id));
  openConfirm("end", ids, endAllCopy(ids.map((id) => cardOf.get(id)), outside), endReadyButton, stillReady, true);
}

// Who the Wrap up confirm lists and how each is asked; it closes if that changes.
const wrapupList = () =>
  [...cardOf.values()]
    .filter((c) => c.wrapupRoute)
    .map((c) => `${c.id} ${c.wrapupRoute}`)
    .join("\n");

function openWrapup() {
  if (wrapButton.getAttribute("aria-disabled") === "true") return;
  const cards = [...cardOf.values()];
  const list = wrapupList();
  const ids = cards.filter((c) => c.wrapupRoute).map((c) => c.id);
  // A request still asking is replaced, and its answers cleared: the confirm says so.
  const running = asking(request, Date.now());
  openConfirm("wrapup", ids, wrapupCopy(cards, running), wrapButton, () => wrapupList() === list && asking(request, Date.now()) === running);
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
  if (what.kind === "end") for (const id of what.ids) beginEnd(id, what.bulk);
  else startWrapup(what.ids);
});

// Focus back to `first`, else the card (Enter or Space on it does nothing), else the wall or the empty state.
function settleFocus(id, first = null) {
  [first, cardEl(id), wall, emptyTitle].find(usable)?.focus({ preventScroll: true });
}

function hideEnding(el, menuOff = false) {
  el.querySelector(".ending").hidden = true;
  el.querySelector(".ending-live").textContent = "";
  setOff(el.querySelector(".menu"), menuOff);
}

// Whether session `id` still counts as ready for the request shown.
const readyNow = (id) => Boolean(request) && isReady(sessions.find((s) => s.session_id === id), request);

function beginEnd(id, bulk = false) {
  const c = cardOf.get(id);
  const el = cardEl(id);
  if (!c?.actions.menu || !el) return;
  const note = el.querySelector(".note");
  const ending = el.querySelector(".ending");
  const started = ender.start(id, {
    // End all ready ends a session only while it is still ready.
    holds: bulk ? () => readyNow(id) : undefined,
    onSkip: () => {
      const now = cardEl(id);
      if (!now) return;
      hideEnding(now);
      say(now.querySelector(".note"), withdrawnText(c.name));
      paintEndReady();
    },
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
// its pending end, its open menu and its open dialog; so does a bulk end
// whose session is no longer ready.
function reconcileActions() {
  for (const id of ender.ids()) {
    const endable = cardOf.get(id)?.actions.menu;
    if (endable && ender.holds(id)) continue;
    ender.cancel(id);
    const el = cardEl(id);
    if (!el) continue;
    const focused = el.querySelector(".ending").contains(document.activeElement);
    hideEnding(el);
    if (endable) say(el.querySelector(".note"), withdrawnText(cardOf.get(id).name));
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

function startWrapup(ids) {
  if (usable(wrapButton)) wrapButton.focus({ preventScroll: true });
  press(
    wrapButton,
    wrapNote,
    async () => {
      const answer = await tauri("start_wrapup", { ids });
      const asked = Array.isArray(answer) ? answer : [];
      for (const a of asked) {
        const el = a.error ? cardEl(a.id) : null;
        if (el) say(el.querySelector(".note"), a.error);
      }
      return askedNote(asked, (id) => cardOf.get(id)?.name);
    },
    "Asking…",
  );
}

// Offered in the app while every live card is ready and klepsydra can end
// at least one not already ending.
const paintEndReady = () => {
  endReadyButton.hidden = !inTauri || readyToEnd().ids.length === 0;
};

function paintWrapup(cards, now) {
  const focused = bar.contains(document.activeElement) ? document.activeElement : null;
  const r = readiness(sessions, request);
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
  // Less the docked panel (Queue or Ledger), which the wall gives up its room to.
  Object.assign(probe.style, { position: "absolute", top: "0", left: "0", width: `${innerWidth - edge.dockedWidth()}px`, visibility: "hidden" });
  const copy = (el) => {
    const c = el.cloneNode(true);
    c.dataset.density = "comfortable";
    // A copied radio would join the real control's group and take its check.
    for (const input of c.querySelectorAll("input[name]")) input.removeAttribute("name");
    for (const card of c.querySelectorAll(".card")) card.style.viewTransitionName = "";
    return c;
  };
  const grid = copy(wall);
  // Without the id, wall.css's #wall .open-text rules miss the copy: Auto
  // judges every card shut, so opening Full text never turns the wall compact.
  grid.removeAttribute("id");
  probe.append(copy(bar), grid);
  // The queue file under the cards, as it shows: Auto keeps the whole Agents room in one screen.
  if (!queueSection.hidden && getComputedStyle(queueSection).display !== "none") probe.append(queueSection.cloneNode(true));
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
  shown = resolveDensity(phoneNarrow() ? "compact" : choice, shown, comfortableFits);
  if (shown !== was) for (const el of wall.children) if (cardOf.has(el.dataset.key)) paintRing(el, cardOf.get(el.dataset.key));
  wall.dataset.density = shown;
  bar.dataset.density = shown;
  densityPicker.querySelector('label:has([value="auto"])').title =
    `Compact while the comfortable cards would scroll; ${shown} now`;
  syncNames();
  syncFullText();
}

// A compact card's name floors its column at its own width, up to 90 px (#535).
function syncNames() {
  if (wall.dataset.density !== "compact") return;
  syncNameWidths([...wall.children].filter((el) => cardOf.has(el.dataset.key)), fontsLoaded, nameWidths);
}
document.fonts?.addEventListener("loadingdone", () => {
  fontsLoaded++;
  syncNames();
  syncFullText();
});

// The phone's Full text shows on a card that cuts text short, and stays on
// one already open. A pointer has each cut line's title; touch has no hover.
function syncFullText() {
  if (!served) return;
  const cards = [...wall.children].filter((el) => cardOf.has(el.dataset.key));
  const want = cards.map((el) => openText.has(el.dataset.key) || cutsText(el, usable));
  cards.forEach((el, i) => {
    const button = el.querySelector(".unfold");
    if (!want[i] && document.activeElement === button) el.focus({ preventScroll: true });
    button.hidden = !want[i];
  });
}
if (served) document.fonts?.ready.then(syncFullText);

const densityNote = document.getElementById("density-note");
function choose(value) {
  choice = parseDensity(value);
  for (const input of densityPicker.querySelectorAll("input")) input.checked = input.value === choice;
  showDensity();
}

densityPicker.addEventListener("change", (e) => {
  choose(e.target.value);
  if (inTauri)
    window.__TAURI__.core.invoke("set_wall_density", { density: choice }).then(
      () => setText(densityNote, ""),
      (err) => setText(densityNote, `Not saved: ${err}`),
    );
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
  if (edge.resizing) return; // a drag of a panel's separator measures once, on release
  cancelAnimationFrame(densityFrame);
  densityFrame = requestAnimationFrame(showDensity);
}).observe(wall);
if (inTauri) window.__TAURI__.core.invoke("get_wall_density").then(choose, () => {});
if (inTauri) tauri("get_needs_layout").then((l) => rooms.setLayout(l), () => {});

// Amber Door's panel stands beside the wall, under the bar (a standard side sheet):
// its top follows the bar's foot as the bar wraps or scrolls away.
let doorFrame = 0;
const placeDoor = () => {
  cancelAnimationFrame(doorFrame);
  doorFrame = requestAnimationFrame(() => document.body.style.setProperty("--bar-foot", `${Math.max(0, Math.round(bar.getBoundingClientRect().bottom))}px`));
};
new ResizeObserver(placeDoor).observe(bar);
addEventListener("scroll", placeDoor, { passive: true });

// The floating gauge's background opacity (#438), in the app only.
if (inTauri) {
  const input = document.getElementById("gauge-opacity");
  const opacityNote = document.getElementById("opacity-note");
  input.closest("label").hidden = false;
  wireOpacityPick({
    input,
    value: input.nextElementSibling,
    invoke: tauri,
    subscribe: (fn) => subscribeOpacity(fn, { inTauri, follow }),
    note: (text) => setText(opacityNote, text),
    log,
  });
}

// Characters (#135): the theme picker, the tray's Characters menu and the
// phone all wear one theme. html[data-theme] names it, as a CSS colour theme
// does, and a switch repaints every name, face, epithet and accent from the
// data already held: the wall and its compact cards, the empty wall's keeper,
// an open portrait, the Ledger and the Queue's keeper, with nothing read again.
const themePicker = document.getElementById("theme");
themePicker.replaceChildren(
  ...Object.entries(THEME_LABELS).map(([id, label]) => Object.assign(document.createElement("option"), { value: id, textContent: label })),
);
const keeper = empty.querySelector(".keeper");

let wanted = DEFAULT_THEME; // the theme last asked for: a slower load must not undo a later one
const asked = new Map(); // theme id -> when a paint first waited for its file; cleared when it fails
const themeNote = document.getElementById("theme-note");
/**
 * Wear theme `id` (an unknown one is the default), repainting unless `paint`
 * is false. A theme not loaded yet is worn once its file arrives. Resolves
 * true once worn; false when another theme was asked for meanwhile (the last
 * ask wins) or its file could not be loaded, which leaves the theme worn as
 * it was, the picker on it, and says why.
 */
function wearTheme(id, paint = true) {
  const next = themeId(id);
  wanted = next;
  const theme = loadedTheme(next);
  if (theme) {
    put(next, theme, paint);
    return Promise.resolve(true);
  }
  return loadTheme(next).then(
    (loaded) => {
      if (wanted !== next) return null;
      put(next, loaded, paint);
      if (themeNote.textContent.startsWith("Loading")) setText(themeNote, "");
      return true;
    },
    (err) => {
      // Each snapshot asks for its theme again: the cause once, then a count.
      log.warnRepeat(`theme:${next}`, `theme ${next} could not be loaded from ${themeFile(next)}`, err);
      asked.delete(next); // a retry waits its own THEME_WAIT_MS before saying "Loading…"
      if (wanted === next) {
        wanted = worn;
        themePicker.value = worn;
        setText(themeNote, `Not switched: the ${THEME_LABELS[next]} theme could not be loaded.`);
      }
      return false;
    },
  );
}
/**
 * Wear theme `id` for a paint, repainting at once unless `paint` is false
 * (a snapshot about to paint): at once when its file is in; else resolves
 * when it is worn or fails, or THEME_WAIT_MS after a paint first waited for
 * it, whichever is first. Past that the page paints in the theme it wears,
 * the note says the theme is still loading, and the theme is worn, painted
 * again, when its file comes.
 */
function wearSoon(id, paint = true) {
  const next = themeId(id);
  if (loadedTheme(next)) return wearTheme(next, paint);
  if (!asked.has(next)) asked.set(next, performance.now());
  let late = false;
  // Worn in time, the paint waiting on it draws it; worn late, it paints itself.
  const wear = wearTheme(next, paint).then((done) => {
    if (done === true && late && !paint) repaintTheme();
    return done;
  });
  return Promise.race([wear, deadline(next)]).finally(() => {
    late = true;
  });
}
/** Resolves THEME_WAIT_MS after a paint first waited for `next`'s file, saying it is still loading if it is. */
function deadline(next) {
  if (!asked.has(next)) asked.set(next, performance.now());
  const since = asked.get(next);
  const left = Math.max(0, since + THEME_WAIT_MS - performance.now());
  return new Promise((late) =>
    setTimeout(() => {
      // A wait whose load failed since is over: a retry has its own.
      if (asked.get(next) === since && wanted === next && worn !== next) setText(themeNote, `Loading the ${THEME_LABELS[next]} theme…`);
      late(null);
    }, left),
  );
}
function put(next, theme, paint) {
  const was = worn;
  worn = next;
  cast = theme;
  document.documentElement.dataset.theme = next;
  themePicker.value = next;
  updateBackdrop(theme);
  const src = keeperOf(cast);
  if (src && keeper.getAttribute("src") !== src) keeper.src = src;
  if (!paint || next === was) return;
  repaintTheme();
}
/** Paint every surface again in the theme worn: the cards, an open portrait, the Ledger, the Queue's keeper. */
function repaintTheme() {
  sessions = castPicks(sessions, cast);
  if (latestSnapshot) {
    const said = render();
    if (said.length) announce(said.join(". "));
  }
  refillPortrait();
  drawer.repaint();
  queueFile?.();
}
put(DEFAULT_THEME, loadedTheme(DEFAULT_THEME), false);
// The picker wears each step once its file is in, and only then is the step
// a choice: the app saves where the picker rests, so an arrow key held over
// the closed picker writes prefs.json and reaches every window and the phone
// once, not once a step, and never for a theme the wall could not wear.
let saving = 0;
let picking = false; // a choice not saved yet, over which the app's word is older
let flushNow = false; // the picker let go while its theme was still loading: save once worn
/** Save the theme worn now. A save prefs.json refused says so; the app sends back the theme it kept. */
function saveTheme() {
  clearTimeout(saving);
  saving = 0;
  picking = false;
  const asked = worn;
  window.__TAURI__.core.invoke("set_theme", { theme: asked }).then(
    () => setText(themeNote, ""),
    (err) => {
      log.error(`set_theme refused theme ${asked}`, err);
      setText(themeNote, `Not saved: ${err}`);
    },
  );
}
themePicker.addEventListener("change", () => {
  picking = true;
  clearTimeout(saving);
  saving = 0;
  // Picked before the app names a theme, a file that never answers holds the first paint no longer than any other.
  if (!loadedTheme(themePicker.value)) deadline(themeId(themePicker.value)).then(firstReady);
  wearTheme(themePicker.value).then((worn) => {
    firstReady();
    if (worn === null) return; // a later choice took over: this one changes nothing
    const now = flushNow;
    flushNow = false;
    if (!worn) {
      picking = false;
      return;
    }
    setText(themeNote, "");
    if (!inTauri) {
      picking = false;
      return;
    }
    clearTimeout(saving);
    saving = setTimeout(saveTheme, THEME_SAVE_MS);
    if (now) saveTheme();
  });
});
// A choice still waiting is saved before the picker, the window or the page
// lets go of it: a click on the tray's Quit first takes the focus away.
const flushTheme = () => {
  if (saving) saveTheme();
  else if (picking) flushNow = true;
};
themePicker.addEventListener("blur", flushTheme);
addEventListener("blur", flushTheme);
addEventListener("pagehide", flushTheme);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) flushTheme();
});
// The first paint waits for the theme worn, so no card shows another theme
// first: for the app to name it, at most FIRST_THEME_MS (else Kourai), then
// for its file, at most THEME_WAIT_MS (wearSoon). A theme picked before the
// app names one lets the paint go as soon as it is worn or fails. The
// phone's theme comes with each snapshot (receive).
let firstReady = () => {};
const firstTheme = new Promise((ready) => {
  firstReady = ready;
  if (served) {
    ready();
    return;
  }
  const noWord = setTimeout(ready, FIRST_THEME_MS);
  subscribeTheme((id) => {
    clearTimeout(noWord);
    if (picking) return;
    wearSoon(id).then(ready);
  });
});
firstTheme.then(() => subscribe(receive, showLink));
setInterval(() => {
  const said = render();
  if (said.length) announce(said.join(". "));
  drawer.checkDay();
}, TICK_MS);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) drawer.checkDay();
});
