// Needs you and Agents as two experiences (#386), in three layouts the
// settings pick: B "Two rooms" (default), D "Inbox and Floor" and E "Amber
// Door". One model drives every number (needs.js); every word from the
// Needs you file or a session goes in as text (queue.js build), and links
// open only through the app's checked command.
import { build } from "./queue.js";
import { dueLabel, dueNow, isTodaySection, needsModel } from "./needs.js";
import { press, say, setOff, syncChildren } from "./dom.js";
import { startedNeeding } from "./model.js";

export const LAYOUTS = ["B", "D", "E"];
export const DEFAULT_LAYOUT = "B";
export const LAYOUT_NAMES = { B: "Two rooms", D: "Inbox and Floor", E: "Amber Door" };
/** A saved layout, else the default. */
export const parseLayout = (v) => (LAYOUTS.includes(v) ? v : DEFAULT_LAYOUT);

/** How long Undo stays after Done, and a jump toast after a block or finish. */
export const UNDO_MS = 6000;
export const JUMP_MS = 8000;

/** Blocked on you: a question waits. The pill, the tally, the room and the lanes all mean this. */
export const isBlocked = (status) => status === "needs_you";
const LANES = {
  B: [
    ["blocked", "Blocked", isBlocked],
    ["error", "Errors", (s) => s === "error"],
    ["working", "Working", (s) => s === "working"],
    ["finished", "Finished", (s) => s === "done"],
    ["idle", "Idle", () => true],
  ],
  D: [
    ["working", "Working", (s) => s === "working"],
    ["blocked", "Needs you", isBlocked],
    ["error", "Errors", (s) => s === "error"],
    ["finished", "Finished", (s) => s === "done"],
    ["idle", "Idle", () => true],
  ],
};

/**
 * The cards in status lanes for `layout`: a `{lane, label, count}` head
 * before each lane that has cards, each lane in the cards' own order. E keeps
 * the wall as it is (no heads).
 */
export function lanes(cards, layout) {
  const defs = LANES[layout];
  if (!defs) return cards;
  const groups = defs.map(() => []);
  for (const c of cards) groups[defs.findIndex(([, , takes]) => takes(c.status))].push(c);
  const out = [];
  defs.forEach(([lane, label], i) => {
    if (!groups[i].length) return;
    out.push({ lane, label, count: groups[i].length });
    for (const c of groups[i]) out.push(c);
  });
  return out;
}

/** The sessions that finished since `before` (statuses()); none on the first look. */
export function finished(before, sessions) {
  if (!before) return new Set();
  return new Set(
    sessions.filter((s) => s.status === "done" && !String(before.get(s.session_id)).startsWith("done")).map((s) => s.session_id),
  );
}

/** The block and finish events between two looks, by session id: blocks first. */
export function transitions(before, sessions) {
  return [
    ...[...startedNeeding(before, sessions)].map((id) => ({ id, kind: "blocked" })),
    ...[...finished(before, sessions)].map((id) => ({ id, kind: "finished" })),
  ];
}

/** E opens its panel on a new block, once, and never while the user types or a dialog is open. */
export const autoOpens = ({ layout, typing, modal }) => layout === "E" && !typing && !modal;

/**
 * The room's action for a key press, or null to leave it alone. `ctx`:
 * `view` ("needs" or "agents"), `typing` (focus in a text field), `modal` (a
 * dialog, popover or menu is open), `control` (focus on a button, link or
 * summary, whose Enter and Space are its own) and `jump` (a jump toast is up).
 */
export function keyAction(e, ctx) {
  if (e.defaultPrevented || ctx.typing || ctx.modal) return null;
  if (e.ctrlKey || e.metaKey || e.altKey) return null;
  const k = e.key;
  const steps = { j: "down", ArrowDown: "down", k: "up", ArrowUp: "up" };
  if (ctx.view === "needs" && steps[k] && !(ctx.control && k.startsWith("Arrow"))) return steps[k];
  if (e.repeat) return null;
  if (k === "n" || k === "N") return "needs";
  if (k === "a" || k === "A") return "agents";
  if (k === "Escape") return ctx.view === "needs" ? "back" : null;
  if (k === "Enter") return ctx.control ? null : ctx.jump ? "jump" : ctx.view === "needs" ? "open" : null;
  if (ctx.view !== "needs") return null;
  return { o: "open", e: "done", u: "undo", c: "copy" }[k] ?? null;
}

/**
 * Done and Undo for the room: `invoke` is the app's command call. One Done
 * at a time; Undo puts back the last one, once. Each answers with the file's
 * text as the app wrote it, so the room need not wait for the file watcher.
 */
export function createDone(invoke) {
  let token = null;
  let busy = false;
  return {
    get busy() {
      return busy;
    },
    get undoable() {
      return token !== null;
    },
    /** Mark `item` done; `seen` is the file's text as the room rendered it (the app writes only while it still is). */
    async done(item, seen) {
      if (busy) return { ok: false, why: null };
      busy = true;
      try {
        const r = await invoke("needs_done", { seen, block: item.block, line: item.line });
        token = r.undo;
        return { ok: true, text: r.text };
      } catch (err) {
        return { ok: false, why: String(err) };
      } finally {
        busy = false;
      }
    },
    async undo() {
      if (busy || token === null) return { ok: false, why: null };
      const t = token;
      token = null;
      busy = true;
      try {
        const text = await invoke("needs_undo", { undo: t });
        return { ok: true, text };
      } catch (err) {
        return { ok: false, why: String(err) };
      } finally {
        busy = false;
      }
    },
    /** A function that ends this Undo's window, and no later one's. */
    expiry() {
      const t = token;
      return () => {
        if (token === t) token = null;
      };
    },
  };
}

const el = (doc, tag, cls, text) => {
  const n = doc.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = text;
  return n;
};
const button = (doc, cls, text, label) => {
  const b = el(doc, "button", cls, text);
  b.type = "button";
  if (label) b.setAttribute("aria-label", label);
  return b;
};

/**
 * Wire the rooms. `nodes`: the header pills (`needsPill`, `agentsPill`), the
 * phone tabs, the Needs you room, the toast and the layout picker.
 * `cards()` is the wall's last painted cards; `makeFace(card)` a portrait
 * element for a blocked row; `focusCard(id)` shows a card on the wall;
 * `invoke` the app's command call (null outside the app); `openLink(url)`
 * opens an https link; `canWrite` whether Done can write the file; `copy`
 * puts text on the clipboard; `onLayout(layout)` runs after each switch.
 */
export function createRooms({
  doc = document,
  body = document.body,
  nodes,
  cards = () => [],
  makeFace = () => null,
  focusCard = () => {},
  invoke = null,
  openLink = () => Promise.reject(new Error("Opening links needs the app")),
  copy = (text) => navigator.clipboard.writeText(text),
  savedLayout = DEFAULT_LAYOUT,
  saveLayout = () => Promise.resolve(),
  onLayout = () => {},
  now = () => new Date(),
}) {
  const { needsPill, agentsPill, tabs, room, toast, picker, note } = nodes;
  const groupsBox = room.querySelector(".ny-groups");
  const sub = room.querySelector(".ny-sub");
  const problemLine = room.querySelector(".ny-problem");
  const nextLine = room.querySelector(".ny-next");
  const clear = room.querySelector(".ny-clear");
  const focusBox = room.querySelector(".ny-focus");
  const writer = invoke ? createDone(invoke) : null;

  let layout = parseLayout(savedLayout);
  let view = "agents";
  let needs = { items: [], count: 0, next: null };
  let fileState = { text: null, problem: null, calm: false };
  let hidden = new Set(); // items whose Done is on its way to the file
  let focusKey = null;
  let before = null; // statuses at the last look
  let toastTimer = 0;
  let toastJump = null; // the session id a jump toast names

  const blocked = () => cards().filter((c) => isBlocked(c.status));
  const shownItems = () => needs.items.filter((i) => !hidden.has(i.key));
  const rows = () => [...room.querySelectorAll(".ny-row")];

  /** Every number on screen, from the one model: open asks plus blocked sessions. */
  function count() {
    return shownItems().length + blocked().length;
  }

  function paintPills() {
    const n = count();
    const working = cards().filter((c) => c.status === "working").length;
    needsPill.querySelector(".rp-count").textContent = String(n);
    needsPill.classList.toggle("is-amber", n > 0);
    needsPill.setAttribute("aria-label", `Needs you, ${n === 0 ? "all clear" : n}`);
    agentsPill.querySelector(".rp-count").textContent = `${working} working`;
    for (const [pill, name] of [
      [needsPill, "needs"],
      [agentsPill, "agents"],
    ]) {
      pill.setAttribute("aria-pressed", String(view === name));
    }
    for (const t of tabs.querySelectorAll("button")) {
      t.setAttribute("aria-pressed", String(t.dataset.view === view));
      t.classList.toggle("is-amber", t.dataset.view === "needs" && n > 0);
      const badge = t.querySelector(".pt-count");
      if (badge) badge.textContent = t.dataset.view === "needs" ? String(n) : String(working);
    }
  }

  function paintBody() {
    body.dataset.layout = layout;
    body.dataset.view = view;
    room.hidden = view !== "needs";
    if (picker) picker.value = layout;
  }

  /** A row's due chip, or nothing. */
  function dueChip(item) {
    if (!item.due) return null;
    const d = dueLabel(item.due, now());
    const chip = el(doc, "span", `ny-due due-${d.tone}`, d.label);
    return chip;
  }

  function copyText(text, from) {
    Promise.resolve()
      .then(() => copy(text))
      .then(
        () => showToast("Copied the link."),
        () => showToast(`Could not copy. The link is ${text}`),
      );
    from?.focus?.();
  }

  function itemRow(row, item) {
    row.replaceChildren();
    row.className = "ny-row ny-item";
    row.tabIndex = -1;
    row.dataset.key = item.key;
    const chip = dueChip(item);
    const lead = el(doc, "div", "ny-lead");
    if (chip) lead.append(chip);
    const main = el(doc, "div", "ny-main");
    main.append(el(doc, "h3", "ny-title", item.title));
    if (item.detail.length) {
      const p = el(doc, "p", "ny-detail");
      for (const n of build(item.detail, doc, { copy: (t) => copyText(t), linkButtons: false })) p.append(n);
      main.append(p);
    }
    if (item.more.length) {
      const more = el(doc, "div", "ny-more");
      for (const n of build(item.more, doc, { copy: (t) => copyText(t), linkButtons: false })) more.append(n);
      main.append(more);
    }
    if (item.links.length) {
      const links = el(doc, "div", "ny-links");
      for (const l of item.links) {
        // A link the app would not open (not https, or re-encoded from how the file writes it) copies instead.
        const b = button(doc, l.opens ? "ny-link" : "ny-link ny-link-copy", l.label, `${l.opens ? "Open" : "Copy"} ${l.label}`);
        b.title = l.opens ? l.url : `${l.url} (copies; it opens from the file only as written)`;
        b.dataset.url = l.url;
        links.append(b);
      }
      main.append(links);
    }
    const acts = el(doc, "div", "ny-acts");
    if (item.links.length) {
      const c = button(doc, "ny-copy", "Copy link", `Copy link: ${item.title}`);
      c.dataset.url = item.links[0].url;
      acts.append(c);
    }
    const done = button(doc, "ny-done", "Done", `Done: ${item.title}`);
    done.title = writer ? "Remove this item from the Needs you file (E)" : "Marking done writes the file in the app only";
    if (!writer) setOff(done, true);
    acts.append(done);
    row.append(lead, main, acts);
    row.setAttribute("aria-label", item.title);
  }

  function blockedRow(row, c) {
    row.replaceChildren();
    row.className = "ny-row ny-blocked";
    row.tabIndex = -1;
    row.dataset.key = `s:${c.id}`;
    row.dataset.id = c.id;
    const lead = el(doc, "div", "ny-lead");
    const face = makeFace(c);
    if (face) lead.append(face);
    const main = el(doc, "div", "ny-main");
    const who = el(doc, "h3", "ny-title");
    who.append(el(doc, "strong", null, c.name));
    if (c.task) who.append(el(doc, "span", "ny-task", ` · ${c.task}`));
    main.append(who, el(doc, "p", "ny-detail", c.ask ?? c.pill?.label ?? "Waiting on you"));
    const acts = el(doc, "div", "ny-acts");
    const answer = button(doc, "ny-answer", "Answer", `Answer ${c.name} in its terminal`);
    answer.title = c.jump?.why ?? "Open its terminal (Enter)";
    setOff(answer, !invoke || !c.jump?.enabled);
    const show = button(doc, "ny-card", "Show card", `Show ${c.name}'s card`);
    const said = el(doc, "span", "ny-said");
    said.setAttribute("role", "status");
    acts.append(answer, show, said);
    row.append(lead, main, acts);
    row.setAttribute("aria-label", `${c.name}, blocked: ${c.ask ?? ""}`);
  }

  /** The groups: Blocked first, then the file's sections in order. */
  function groups() {
    const out = [];
    const b = blocked();
    if (b.length) out.push({ key: "blocked", title: "Blocked on you", rows: b.map((c) => ({ kind: "blocked", key: `s:${c.id}`, c })) });
    for (const item of shownItems()) {
      const title = item.section ?? "Asks";
      let g = out.find((x) => x.key === `sec:${title}`);
      if (!g) out.push((g = { key: `sec:${title}`, title, rows: [] }));
      g.rows.push({ kind: "item", key: item.key, item });
    }
    return out;
  }

  function paintRoom() {
    const day = now().toDateString();
    const gs = groups();
    const order = gs.flatMap((g) => g.rows);
    if (!order.some((r) => r.key === focusKey)) focusKey = order[0]?.key ?? null;
    const n = order.length;
    sub.textContent = n === 0 ? "" : `${n} open${blocked().length ? `, ${blocked().length} blocked` : ""}`;
    problemLine.hidden = !fileState.problem;
    problemLine.classList.toggle("is-calm", fileState.calm);
    problemLine.textContent = fileState.problem ?? "";
    clear.hidden = n > 0;
    const today = now();
    const nowItems = shownItems().filter((i) => dueNow(i, today) || isTodaySection(i.section));
    const next = needs.next && !hidden.has(needs.next.key) ? needs.next : null;
    const showNext = next && !blocked().length && !nowItems.length;
    nextLine.hidden = !showNext;
    nextLine.replaceChildren();
    if (showNext) {
      nextLine.append(el(doc, "span", "ny-next-lead", n ? "Nothing due today. Next: " : "Next: "));
      nextLine.append(el(doc, "strong", null, next.title));
      nextLine.append(` · ${dueLabel(next.due, today).label}`);
    }
    syncChildren(
      groupsBox,
      gs,
      (g) => g.key,
      () => {
        const sec = el(doc, "section", "ny-group");
        const h = el(doc, "h2", "ny-group-head");
        h.append(el(doc, "span", "ny-group-title"), el(doc, "span", "ny-group-count"));
        sec.append(h, el(doc, "ul", "ny-list"));
        return sec;
      },
      (sec, g) => {
        sec.classList.toggle("is-blocked", g.key === "blocked");
        sec.querySelector(".ny-group-title").textContent = g.title;
        sec.querySelector(".ny-group-count").textContent = String(g.rows.length);
        syncChildren(
          sec.querySelector(".ny-list"),
          g.rows,
          (r) => r.key,
          () => doc.createElement("li"),
          (row, r) => {
            // Rebuilt only when what it shows changed: an open detail or focus survives a repaint.
            // An item's due chip reads from today, so a new day rebuilds it.
            const sig = r.kind === "blocked" ? JSON.stringify([r.c.name, r.c.task, r.c.ask, r.c.jump, Boolean(invoke)]) : `${r.key}\u0000${day}`;
            if (row.dataset.sig !== sig) {
              (r.kind === "blocked" ? blockedRow : itemRow)(row, r.kind === "blocked" ? r.c : r.item);
              row.dataset.sig = sig;
            }
            row.classList.toggle("is-focused", r.key === focusKey);
            row.setAttribute("aria-current", String(r.key === focusKey));
          },
        );
      },
    );
    paintFocusCard(order);
  }

  /** E's focus card: the focused ask, large, with its actions. */
  function paintFocusCard(order) {
    if (!focusBox) return;
    const r = order.find((x) => x.key === focusKey);
    focusBox.hidden = layout !== "E" || !r || r.kind !== "item";
    if (focusBox.hidden) {
      focusBox.replaceChildren();
      delete focusBox.dataset.key;
      return;
    }
    const sig = `${r.key}\u0000${now().toDateString()}`;
    if (focusBox.dataset.key === sig) return;
    focusBox.dataset.key = sig;
    const items = order.filter((x) => x.kind === "item");
    const holder = doc.createElement("div");
    itemRow(holder, r.item);
    holder.className = "ny-focus-card";
    holder.removeAttribute("tabindex");
    const meta = el(doc, "p", "ny-focus-meta", `${items.indexOf(r) + 1} of ${items.length} · ${r.item.section ?? "Asks"}`);
    focusBox.replaceChildren(meta, holder);
  }

  function paint() {
    paintPills();
    paintBody();
    if (view === "needs") paintRoom();
  }

  function setView(next, { focus = true } = {}) {
    view = next === "needs" ? "needs" : "agents";
    paint();
    if (view === "needs" && focus) focusRow(focusKey) ?? room.focus({ preventScroll: true });
  }

  function focusRow(key) {
    const row = rows().find((r) => r.dataset.key === key);
    if (!row) return null;
    focusKey = key;
    for (const r of rows()) {
      r.classList.toggle("is-focused", r === row);
      r.setAttribute("aria-current", String(r === row));
    }
    paintFocusCard(groups().flatMap((g) => g.rows));
    row.focus({ preventScroll: true });
    row.scrollIntoView({ block: "nearest" });
    return row;
  }

  function step(by) {
    const all = rows();
    const at = all.findIndex((r) => r.dataset.key === focusKey);
    const to = all[Math.max(0, Math.min(all.length - 1, (at < 0 ? 0 : at) + by))];
    if (to) focusRow(to.dataset.key);
  }

  const focusedItem = () => shownItems().find((i) => i.key === focusKey) ?? null;
  const focusedCard = () => blocked().find((c) => `s:${c.id}` === focusKey) ?? null;

  function answer(c, from) {
    const row = rows().find((r) => r.dataset.key === `s:${c.id}`);
    const b = from ?? row?.querySelector(".ny-answer");
    if (!b || !invoke) return;
    press(b, row?.querySelector(".ny-said"), () => invoke("jump_to_terminal", { id: c.id, name: c.session ?? "" }));
  }

  function openUrl(url) {
    Promise.resolve()
      .then(() => openLink(url))
      .catch((err) => showToast(`Not opened: ${err?.message ?? err}`));
  }

  function open(item) {
    const link = item?.links.find((l) => l.opens);
    if (link) openUrl(link.url);
    else showToast(item?.links.length ? "This link opens from the file only; C copies it." : "This item has no link to open.");
  }

  /** The model of `text`; a file the room cannot read is a problem line, never a frozen room. */
  function modelOf(text) {
    try {
      return { model: needsModel(text ?? "", now()), problem: null };
    } catch (err) {
      return { model: { items: [], count: 0, next: null }, problem: `The Needs you file could not be shown: ${err?.message ?? err}` };
    }
  }

  /** The file as the app just wrote it: the room shows it now, not when the watcher next reads. */
  function written(text) {
    if (typeof text !== "string") return;
    const { model, problem } = modelOf(text);
    fileState = { ...fileState, text, problem: problem ?? fileState.problem };
    needs = model;
  }

  async function markDone(item) {
    if (!item) return;
    if (!writer) {
      showToast("Marking done writes the Needs you file in the app only.");
      return;
    }
    if (writer.busy) return;
    const order = rows().map((r) => r.dataset.key);
    const nextKey = order[order.indexOf(item.key) + 1] ?? order[order.indexOf(item.key) - 1] ?? null;
    hidden.add(item.key);
    focusKey = nextKey;
    paint();
    if (view === "needs" && nextKey) focusRow(nextKey);
    const r = await writer.done(item, fileState.text ?? "");
    hidden.delete(item.key);
    if (r.ok) written(r.text);
    paint();
    if (!r.ok) {
      if (r.why) showToast(`Not done: ${r.why}`);
      return;
    }
    showToast(`Done: ${item.title}`, { action: "Undo", onAction: undo, ms: UNDO_MS, onExpire: writer.expiry() });
  }

  async function undo() {
    if (!writer?.undoable) return;
    hideToast();
    const r = await writer.undo();
    if (r.ok) {
      written(r.text);
      paint();
      showToast("Put back.");
    } else if (r.why) showToast(`Not undone: ${r.why}`);
  }

  // The toast: one at a time, never taking focus; its timer waits while the pointer or focus is in it.
  let toastLeft = 0;
  let toastStarted = 0;
  let toastExpire = null;
  const toastHidden = () => toast.hidden;
  function hideToast() {
    clearTimeout(toastTimer);
    toast.hidden = true;
    toast.replaceChildren();
    toastJump = null;
    toastExpire = null;
  }
  function arm(ms) {
    clearTimeout(toastTimer);
    toastLeft = ms;
    toastStarted = Date.now();
    toastTimer = setTimeout(() => {
      const expire = toastExpire;
      hideToast();
      expire?.();
    }, ms);
  }
  const pause = () => {
    if (toast.hidden) return;
    clearTimeout(toastTimer);
    toastLeft = Math.max(1000, toastLeft - (Date.now() - toastStarted));
  };
  const resume = () => {
    if (!toast.hidden && !toast.contains(doc.activeElement)) arm(toastLeft);
  };
  toast.addEventListener("pointerenter", pause);
  toast.addEventListener("pointerleave", resume);
  toast.addEventListener("focusin", pause);
  toast.addEventListener("focusout", () => setTimeout(resume, 0));

  function showToast(text, { action = null, onAction = null, ms = 4000, jump = null, onExpire = null } = {}) {
    // A toast that replaces Undo's leaves Undo its time: U still works until then.
    const prev = toastExpire;
    const left = toastHidden() ? 0 : Math.max(0, toastLeft - (Date.now() - toastStarted));
    hideToast();
    if (prev && prev !== onExpire) setTimeout(prev, left);
    toast.append(el(doc, "span", "rt-text", text));
    if (action) {
      const b = button(doc, "rt-action", action);
      b.addEventListener("click", () => {
        hideToast();
        onAction();
      });
      toast.append(b);
    }
    toastJump = jump;
    toastExpire = onExpire;
    toast.hidden = false;
    arm(ms);
  }

  function jumpTo(id) {
    hideToast();
    if (layout !== "E") setView("agents", { focus: false });
    focusCard(id);
  }

  // Clicks inside the room.
  room.addEventListener("click", (e) => {
    const t = e.target;
    const row = t.closest(".ny-row, .ny-focus-card");
    const key = row?.dataset.key;
    const item = shownItems().find((i) => i.key === key) ?? null;
    const c = blocked().find((x) => `s:${x.id}` === key) ?? null;
    if (t.closest(".ny-done")) {
      if (t.closest(".ny-done").getAttribute("aria-disabled") === "true") showToast("Marking done writes the Needs you file in the app only.");
      else markDone(item);
    } else if (t.closest(".ny-link-copy")) copyText(t.closest(".ny-link-copy").dataset.url, t.closest(".ny-link-copy"));
    else if (t.closest(".ny-link")) openUrl(t.closest(".ny-link").dataset.url);
    else if (t.closest(".ny-copy")) copyText(t.closest(".ny-copy").dataset.url, t.closest(".ny-copy"));
    else if (t.closest(".ny-answer") && c) answer(c, t.closest(".ny-answer"));
    else if (t.closest(".ny-card") && c) jumpTo(c.id);
    else if (row?.classList.contains("ny-row") && !t.closest("button, a")) focusRow(key);
  });

  // A swipe right on a phone marks an ask done: mostly sideways, never a scroll.
  let touch = null;
  room.addEventListener(
    "touchstart",
    (e) => {
      const row = e.target.closest(".ny-item");
      touch = row && e.touches.length === 1 ? { row, x: e.touches[0].clientX, y: e.touches[0].clientY, off: false } : null;
    },
    { passive: true },
  );
  room.addEventListener(
    "touchmove",
    (e) => {
      if (!touch) return;
      const dx = e.touches[0].clientX - touch.x;
      const dy = e.touches[0].clientY - touch.y;
      if (Math.abs(dy) > 24 || Math.abs(dy) > Math.abs(dx) / 2) touch.off = true;
    },
    { passive: true },
  );
  room.addEventListener("touchcancel", () => {
    touch = null;
  });
  room.addEventListener("touchend", (e) => {
    const t = touch;
    touch = null;
    if (!t || t.off) return;
    const dx = e.changedTouches[0].clientX - t.x;
    const dy = e.changedTouches[0].clientY - t.y;
    if (swipeDone(dx, dy)) markDone(shownItems().find((i) => i.key === t.row.dataset.key));
  });

  needsPill.addEventListener("click", () => setView(layout === "D" && view === "needs" ? "agents" : "needs"));
  agentsPill.addEventListener("click", () => setView("agents"));
  for (const t of tabs.querySelectorAll("button")) t.addEventListener("click", () => setView(t.dataset.view));
  picker?.addEventListener("change", () => setLayout(picker.value, true));

  function setLayout(next, save = false) {
    const was = layout;
    layout = parseLayout(next);
    if (focusBox) delete focusBox.dataset.key;
    paint();
    if (save && layout !== was)
      Promise.resolve()
        .then(() => saveLayout(layout))
        .then(
          () => note && say(note, ""),
          (err) => note && say(note, `Not saved: ${err}`),
        );
    onLayout(layout);
  }

  const typingIn = (a) => Boolean(a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName)));
  const modalOpen = () => Boolean(doc.querySelector("dialog[open]:modal, :popover-open, [role='menu']:not([hidden]), details.gear[open]"));
  const onControl = (a) => Boolean(a && a !== room && a.closest?.("button, a, summary, [role='menuitem'], [role='button']"));

  doc.addEventListener("keydown", (e) => {
    const a = doc.activeElement;
    const act = keyAction(e, { view, typing: typingIn(a), modal: modalOpen(), control: onControl(a), jump: Boolean(toastJump) });
    if (!act) return;
    e.preventDefault();
    if (act === "needs") setView(layout === "D" && view === "needs" ? "agents" : "needs");
    else if (act === "agents" || act === "back") setView("agents");
    else if (act === "jump") jumpTo(toastJump);
    else if (act === "down") step(1);
    else if (act === "up") step(-1);
    else if (act === "undo") undo();
    else if (act === "open") {
      const c = focusedCard();
      if (c) answer(c);
      else open(focusedItem());
    } else if (act === "done") markDone(focusedItem());
    else if (act === "copy") {
      const item = focusedItem();
      if (item?.links[0]) copyText(item.links[0].url);
      else if (item) showToast("This item has no link to copy.");
    }
  });

  paint();

  return {
    /** A new read of the Needs you file: `{path, text, problem, missing}`; `calm` shows the problem as a note. */
    updateNeeds(view_) {
      const { model, problem } = modelOf(view_.text);
      fileState = { text: view_.text ?? null, problem: problem ?? (view_.missing ? null : view_.problem ?? null), calm: problem ? false : view_.calm === true };
      needs = model;
      // A Done on its way stays hidden only while the file still holds the item.
      hidden = new Set([...hidden].filter((k) => needs.items.some((i) => i.key === k)));
      paint();
    },
    /** A new snapshot: its sessions, after the wall painted their cards. */
    updateSessions(sessions, { snapshot = true, typing = typingIn(doc.activeElement), modal = modalOpen() } = {}) {
      paint();
      // Only a snapshot moves the baseline: a tick or the paint before the first snapshot is no event.
      if (!snapshot) return;
      const events = transitions(before, sessions);
      before = new Map(sessions.map((s) => [s.session_id, s.status]));
      const first = events[0];
      if (!first) return;
      const c = cards().find((x) => x.id === first.id);
      const name = c?.name ?? "A session";
      if (first.kind === "blocked" && autoOpens({ layout, typing, modal })) {
        setView("needs", { focus: false });
        focusRow(`s:${first.id}`);
        return;
      }
      if (view === "needs" || layout === "E")
        showToast(first.kind === "blocked" ? `${name} needs you.` : `${name} finished.`, {
          action: "Show card",
          onAction: () => jumpTo(first.id),
          jump: first.id,
          ms: JUMP_MS,
        });
    },
    setLayout,
    setView,
    /** Open Needs you on session `id`'s blocked row. */
    showBlocked(id) {
      setView("needs", { focus: false });
      if (!focusRow(`s:${id}`)) room.focus({ preventScroll: true });
    },
    get layout() {
      return layout;
    },
    get view() {
      return view;
    },
    /** The header's count, as the pills show it. */
    count,
  };
}

/** A touch that moved `dx`, `dy` is a Done swipe: rightward, far enough, and mostly sideways. */
export const swipeDone = (dx, dy) => dx > 80 && Math.abs(dy) <= 24 && Math.abs(dy) <= dx / 2;
