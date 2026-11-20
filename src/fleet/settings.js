// The settings page (#384, Design A): rows from settings/registry.js, applied
// at once, filtered by search. A row shows what its command returned, never
// what was asked for, so a held or refused change reads as it is.

import { createLog } from "../log.js";
import { filterRows, ROWS, SECTIONS } from "../settings/registry.js";

const log = createLog("fleet/settings");

/** A row's view, from what its command returned (registry.js `view`). */
export function viewOf(row, raw) {
  return row.view ? row.view(raw) : { value: raw };
}

/**
 * What `row` shows now: its binding's view (a control the wall has), or its
 * read's answer through `view`. Rejects when the row cannot be read.
 */
export async function readRow(row, invoke, bindings = {}) {
  if (row.bind) {
    const b = bindings[row.bind];
    if (!b) throw new Error(`no ${row.bind} control to bind`);
    return b.view();
  }
  return viewOf(row, await row.read(invoke));
}

/**
 * Apply `value` to `row` the one way it is applied: a bound row through the
 * wall's own function, which its toolbar or gear control calls too; any
 * other through its command. Resolves with what the row shows afterwards,
 * from the command's answer (or the shared state the function left), with
 * the app's message, if it sent one, as the note.
 */
export async function apply(row, invoke, value, bindings = {}) {
  return (await applied(row, invoke, value, bindings)).view;
}

/** `apply`, with the command's raw answer, which rows sharing it (registry `shares`) show too. */
async function applied(row, invoke, value, bindings) {
  if (row.bind) {
    const b = bindings[row.bind];
    const said = await b.write(value);
    const view = b.view();
    return { view: typeof said === "string" && said && !view.note ? { ...view, note: said } : view };
  }
  const raw = await row.write(invoke, value);
  return { view: viewOf(row, raw), raw };
}

/** The words of a refusal: a Tauri command rejects with a string. */
const why = (err) => (typeof err === "string" ? err : (err?.message ?? String(err)));

/**
 * Mount the page into `container`. `bindings` holds the wall's controls by
 * registry `bind` name, each { view(), write(value), flush?() }. Returns
 * { refresh, sync(rowId), destroy }: refresh reads every row (on each open),
 * sync re-reads one bound row after its control changed on the wall.
 */
export function mountSettings({ container, invoke, bindings = {}, onBack }) {
  const rows = new Map(); // row id -> { row, el, label, note, control, show(view) }
  const labels = new Map(); // row id -> the label shown now
  const unavailable = new Set(); // rows whose read failed: hidden
  const sections = new Map();

  container.innerHTML = `
    <div class="set-a">
      <header class="settings-top">
        <button type="button" class="back-btn" id="settings-back" aria-label="Back to the wall">
          <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg>
        </button>
        <h1 id="settings-title">Settings</h1>
        <div class="settings-search" role="search">
          <svg class="search-icon" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>
          <input type="search" class="search-input" id="settings-search-input" placeholder="Search settings" aria-label="Search settings" aria-keyshortcuts="/" autocomplete="off" spellcheck="false" />
          <kbd class="search-kbd" aria-hidden="true">/</kbd>
          <button type="button" class="search-clear" id="settings-search-clear" aria-label="Clear search" hidden>&times;</button>
        </div>
      </header>
      <nav class="settings-nav" aria-label="Settings sections">
        ${SECTIONS.map((s) => `<a href="#sec-${s.id}" class="nav-item" data-section="${s.id}">${s.title}</a>`).join("")}
      </nav>
      <div class="settings-sections">
        ${SECTIONS.map(
          (s) => `<section id="sec-${s.id}" class="settings-section" aria-labelledby="heading-${s.id}">
            <h2 id="heading-${s.id}">${s.title}</h2>
            <div class="settings-rows" data-section="${s.id}"></div>
          </section>`,
        ).join("")}
      </div>
      <p class="settings-empty" id="settings-no-results" role="status" hidden>
        No settings match &ldquo;<span class="search-term"></span>&rdquo;.
      </p>
    </div>
  `;
  for (const s of SECTIONS) sections.set(s.id, container.querySelector(`#sec-${s.id}`));
  // The section links scroll the page, not the URL: #settings stays the page's hash.
  container.querySelector(".settings-nav").addEventListener("click", (e) => {
    const a = e.target.closest(".nav-item");
    if (!a) return;
    e.preventDefault();
    sections.get(a.dataset.section)?.scrollIntoView({ block: "start" });
  });

  for (const row of ROWS) {
    const el = document.createElement("div");
    el.className = "settings-row";
    el.id = `row-${row.id}`;
    el.dataset.rowId = row.id;
    const info = document.createElement("div");
    info.className = "settings-row-info";
    const label = Object.assign(document.createElement("span"), { className: "settings-row-label", id: `label-${row.id}`, textContent: row.label });
    const desc = Object.assign(document.createElement("span"), { className: "settings-row-desc", id: `desc-${row.id}`, textContent: row.description });
    const note = Object.assign(document.createElement("span"), { className: "settings-row-note", id: `note-${row.id}` });
    note.setAttribute("role", "status");
    info.append(label, desc, note);
    const ctrl = document.createElement("div");
    ctrl.className = "settings-row-control";
    el.append(info, ctrl);
    const entry = { row, el, label, note, ctrl };
    entry.show = control(entry, invoke, bindings);
    container.querySelector(`.settings-rows[data-section="${row.section}"]`).append(el);
    rows.set(row.id, entry);
  }

  /** Show `view` on row `id`: its value, and its label, note and disabled state when given. */
  function show(id, view) {
    const e = rows.get(id);
    if (!e || !view) return;
    if (view.label) {
      e.label.textContent = view.label;
      labels.set(id, view.label);
    }
    if (view.available === false) unavailable.add(id);
    else unavailable.delete(id);
    // Rewritten only when it changes: a status note is read out each time it is.
    if ("note" in view && e.note.textContent !== (view.note ?? "")) e.note.textContent = view.note ?? "";
    e.show(view);
    applySearch();
  }

  /** Read every row afresh, all at once; reads that share a command share one call. */
  async function refresh() {
    const asked = new Map();
    const once = (cmd, args) => {
      const key = `${cmd} ${JSON.stringify(args ?? null)}`;
      if (!asked.has(key)) asked.set(key, invoke(cmd, args));
      return asked.get(key);
    };
    await Promise.all(
      ROWS.filter((r) => r.read || r.bind).map((r) =>
        readRow(r, once, bindings).then(
          (view) => show(r.id, view),
          (err) => {
            // The app refuses what this system lacks (Ping, Split off Windows): no row for it.
            log.info(`settings: ${r.id} hidden: ${why(err)}`);
            show(r.id, { available: false });
          },
        ),
      ),
    );
  }

  const search = container.querySelector("#settings-search-input");
  const kbd = container.querySelector(".search-kbd");
  const clear = container.querySelector("#settings-search-clear");
  const empty = container.querySelector("#settings-no-results");

  function applySearch() {
    const query = search.value;
    const matches = new Set(filterRows(ROWS, query, labels).map((r) => r.id));
    const active = Boolean(query.trim());
    clear.hidden = !active;
    kbd.hidden = active;
    let total = 0;
    for (const [id, sec] of sections) {
      let shown = 0;
      for (const r of ROWS.filter((x) => x.section === id)) {
        const on = matches.has(r.id) && !unavailable.has(r.id);
        rows.get(r.id).el.hidden = !on;
        if (on) shown++;
      }
      sec.hidden = shown === 0;
      container.querySelector(`.nav-item[data-section="${id}"]`).hidden = shown === 0;
      total += shown;
    }
    empty.hidden = total > 0 || !active;
    empty.querySelector(".search-term").textContent = query.trim();
  }

  search.addEventListener("input", applySearch);
  clear.addEventListener("click", () => {
    search.value = "";
    applySearch();
    search.focus();
  });

  container.querySelector("#settings-back").addEventListener("click", () => onBack?.());

  function onKeyDown(e) {
    if (container.hidden || e.defaultPrevented) return;
    const typing = e.target instanceof HTMLElement && e.target.matches("input, select, textarea");
    if (e.key === "/" && !typing) {
      e.preventDefault();
      search.focus();
    } else if (e.key === "Escape") {
      // A select's own Escape closes its list; it never leaves the page.
      if (e.target instanceof HTMLElement && e.target.matches("select")) return;
      e.preventDefault();
      if (e.target === search && search.value) {
        search.value = "";
        applySearch();
      } else onBack?.();
    }
  }
  window.addEventListener("keydown", onKeyDown);

  return {
    refresh,
    /** Row `id`'s bound control changed on the wall: show it as the wall does. */
    sync(id) {
      const e = rows.get(id);
      if (!e?.row.bind || !bindings[e.row.bind]) return;
      show(id, bindings[e.row.bind].view());
    },
    destroy() {
      window.removeEventListener("keydown", onKeyDown);
      container.replaceChildren();
    },
  };

  /** Build row `e`'s control in its cell; returns how it shows a view. */
  function control(e, invoke, bindings) {
    const { row } = e;
    const labelled = (el) => {
      el.setAttribute("aria-labelledby", `label-${row.id}`);
      el.setAttribute("aria-describedby", `desc-${row.id} note-${row.id}`);
      return el;
    };
    // One call at a time per row: a choice made while one runs waits, and only
    // the last such choice is sent (a held arrow key sends two, not one a step).
    let running = null;
    let next = null; // { value } waiting for the running call
    /** Apply `value` and show what came back; a refusal keeps what was shown and says why. */
    const run = (value, busy) => {
      if (running) {
        next = { value };
        return running;
      }
      running = (async () => {
        busy.setAttribute("aria-busy", "true");
        let view = null;
        try {
          let ask = { value };
          while (ask) {
            view = await once(ask.value);
            ask = next;
            next = null;
          }
        } finally {
          busy.removeAttribute("aria-busy");
          running = null;
        }
        return view;
      })();
      return running;
    };
    const once = async (value) => {
      try {
        const { view, raw } = await applied(row, invoke, value, bindings);
        show(row.id, view);
        if (row.shares) for (const r of ROWS) if (r !== row && r.shares === row.shares) show(r.id, viewOf(r, raw));
        return view;
      } catch (err) {
        log.warn(`settings: ${row.id} was not changed`, err);
        // A bound control may have changed the wall before its save failed: show it as it is.
        if (row.bind) show(row.id, bindings[row.bind].view());
        e.note.textContent = `${row.bind ? "Not saved" : "Not changed"}: ${why(err)}`;
        return null;
      }
    };
    const type = row.control.type;

    if (type === "toggle") {
      const tog = labelled(Object.assign(document.createElement("button"), { type: "button", className: "tog", innerHTML: "<i></i>" }));
      tog.setAttribute("role", "switch");
      tog.setAttribute("aria-checked", "false");
      tog.addEventListener("click", async () => {
        if (tog.getAttribute("aria-disabled") === "true" || tog.getAttribute("aria-busy") === "true") return;
        const want = tog.getAttribute("aria-checked") !== "true";
        const view = await run(want, tog);
        if (view && Boolean(view.value) !== want && !view.note) e.note.textContent = `Not changed: the app kept it ${view.value ? "on" : "off"}.`;
      });
      e.ctrl.append(tog);
      return (view) => {
        if ("value" in view) tog.setAttribute("aria-checked", view.value ? "true" : "false");
        if ("disabled" in view) tog.setAttribute("aria-disabled", view.disabled ? "true" : "false");
      };
    }

    if (type === "seg") {
      // A radio group (WAI-ARIA APG): one tab stop, arrows move and choose.
      const seg = labelled(Object.assign(document.createElement("span"), { className: "seg" }));
      seg.setAttribute("role", "radiogroup");
      const radios = row.control.options.map((opt) => {
        const b = Object.assign(document.createElement("button"), { type: "button", textContent: opt.label });
        b.setAttribute("role", "radio");
        b.setAttribute("aria-checked", "false");
        b.tabIndex = -1;
        b.dataset.value = opt.value;
        b.addEventListener("click", () => {
          if (b.getAttribute("aria-checked") === "true") return;
          // Checked as chosen while the app answers; its answer then shows.
          for (const r of radios) r.setAttribute("aria-checked", r === b ? "true" : "false");
          stop();
          run(opt.value, seg);
        });
        return b;
      });
      const stop = () => {
        const on = radios.find((b) => b.getAttribute("aria-checked") === "true") ?? radios[0];
        for (const b of radios) b.tabIndex = b === on ? 0 : -1;
      };
      seg.addEventListener("keydown", (ev) => {
        const at = radios.indexOf(document.activeElement);
        const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[ev.key];
        const to = step ? (at + step + radios.length) % radios.length : { Home: 0, End: radios.length - 1 }[ev.key];
        if (to === undefined) return;
        ev.preventDefault();
        radios[to].focus();
        radios[to].click();
      });
      seg.append(...radios);
      stop();
      e.ctrl.append(seg);
      return (view) => {
        if (!("value" in view)) return;
        for (const b of radios) b.setAttribute("aria-checked", b.dataset.value === String(view.value) ? "true" : "false");
        stop();
      };
    }

    if (type === "select") {
      const sel = labelled(Object.assign(document.createElement("select"), { className: "sel-control" }));
      sel.addEventListener("change", () => run(sel.value, sel));
      // A choice still waiting to be saved (the theme's) is saved as the select lets go.
      sel.addEventListener("blur", () => row.bind && bindings[row.bind]?.flush?.());
      e.ctrl.append(sel);
      let listed = "";
      return (view) => {
        if (view.options) {
          const value = String(view.value ?? "");
          const options = view.options.some((o) => o.value === value) ? view.options : [...view.options, { value, label: value }];
          // Rebuilt only when the list changes: a rebuild closes a list the user has open.
          const key = JSON.stringify(options);
          if (key !== listed) {
            listed = key;
            sel.replaceChildren(...options.map((o) => Object.assign(document.createElement("option"), { value: o.value, textContent: o.label })));
          }
        }
        if ("value" in view) sel.value = String(view.value ?? "");
        if ("disabled" in view) sel.disabled = Boolean(view.disabled);
      };
    }

    if (type === "button") {
      const btn = Object.assign(document.createElement("button"), { type: "button", className: "btn-action", textContent: row.control.label });
      btn.setAttribute("aria-describedby", `desc-${row.id} note-${row.id}`);
      btn.addEventListener("click", () => run(undefined, btn));
      e.ctrl.append(btn);
      return () => {};
    }

    // A path and the button that picks another.
    const wrap = Object.assign(document.createElement("div"), { className: "path-wrap" });
    const path = Object.assign(document.createElement("span"), { className: "path-val", textContent: "—" });
    const btn = Object.assign(document.createElement("button"), { type: "button", className: "btn-action small", textContent: row.control.buttonLabel });
    btn.setAttribute("aria-label", `${row.control.buttonLabel.replace("…", "")} ${row.label}`);
    btn.setAttribute("aria-describedby", `label-${row.id} note-${row.id}`);
    btn.addEventListener("click", () => {
      if (btn.getAttribute("aria-busy") !== "true") run(undefined, btn);
    });
    wrap.append(path, btn);
    e.ctrl.append(wrap);
    return (view) => {
      if (!("value" in view)) return;
      path.textContent = view.value || "—";
      path.title = view.value || "";
    };
  }
}
