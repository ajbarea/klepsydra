// Settings page view and controller for klepsydra (#384), Design A.
// Data-driven rendering from src/settings/registry.js with instant apply and search filtering.

import { SECTIONS, ROWS, filterRows } from "../settings/registry.js";
import { createLog } from "../log.js";

const log = createLog("fleet/settings");

/**
 * Mount the settings view into container element.
 *
 * @param {Object} options
 * @param {HTMLElement} options.container - The root element (e.g. #settings)
 * @param {Function} options.invoke - Tauri IPC invoke function
 * @param {Function} options.onBack - Callback when Back button or Esc is pressed
 * @param {Function} [options.onSettingChanged] - Optional callback when setting changes (e.g. density/theme sync)
 * @returns {Object} Controller object with destroy, refresh, and sync methods
 */
export function mountSettings({ container, invoke, onBack, onSettingChanged }) {
  const rowElements = new Map();
  const sectionElements = new Map();

  // Build shell HTML
  container.innerHTML = `
    <div class="set-a">
      <header class="settings-top">
        <button type="button" class="back-btn" id="settings-back" aria-label="Back to the wall">
          <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg>
        </button>
        <h1>Settings</h1>
        <div class="settings-search" role="search">
          <svg class="search-icon" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>
          <input type="search" class="search-input" id="settings-search-input" placeholder="Search settings (/)" aria-label="Search settings" autocomplete="off" spellcheck="false" />
          <kbd class="search-kbd" aria-hidden="true">/</kbd>
          <button type="button" class="search-clear" id="settings-search-clear" aria-label="Clear search" hidden>&times;</button>
        </div>
      </header>

      <nav class="settings-nav" aria-label="Settings sections">
        ${SECTIONS.map((s) => `<a href="#sec-${s.id}" class="nav-item">${s.title}</a>`).join("")}
      </nav>

      <div class="settings-sections">
        ${SECTIONS.map(
          (s) => `
          <section id="sec-${s.id}" class="settings-section" aria-labelledby="heading-${s.id}">
            <h2 id="heading-${s.id}">${s.title}</h2>
            <div class="settings-rows" data-section="${s.id}"></div>
          </section>
        `,
        ).join("")}
      </div>

      <p class="settings-empty" id="settings-no-results" role="status" hidden>
        No settings match &ldquo;<span class="search-term"></span>&rdquo;.
      </p>
    </div>
  `;

  // Index section containers
  for (const s of SECTIONS) {
    const secEl = container.querySelector(`#sec-${s.id}`);
    if (secEl) sectionElements.set(s.id, secEl);
  }

  // Render rows into sections
  for (const row of ROWS) {
    const secContainer = container.querySelector(`.settings-rows[data-section="${row.section}"]`);
    if (!secContainer) continue;

    const rowEl = document.createElement("div");
    rowEl.className = "settings-row";
    rowEl.id = `row-${row.id}`;
    rowEl.dataset.rowId = row.id;

    const infoEl = document.createElement("div");
    infoEl.className = "settings-row-info";
    infoEl.innerHTML = `
      <span class="settings-row-label">${row.label}</span>
      <span class="settings-row-desc">${row.description}</span>
    `;
    rowEl.appendChild(infoEl);

    const ctrlEl = document.createElement("div");
    ctrlEl.className = "settings-row-control";

    renderControl(ctrlEl, row, invoke, onSettingChanged);
    rowEl.appendChild(ctrlEl);

    secContainer.appendChild(rowEl);
    rowElements.set(row.id, rowEl);
  }

  // Load live initial values
  loadValues(ROWS, invoke, container);

  // Wire back button
  const backBtn = container.querySelector("#settings-back");
  backBtn?.addEventListener("click", () => onBack?.());

  // Wire search input & shortcuts
  const searchInput = container.querySelector("#settings-search-input");
  const searchKbd = container.querySelector(".search-kbd");
  const searchClear = container.querySelector("#settings-search-clear");
  const emptyState = container.querySelector("#settings-no-results");
  const searchTerm = emptyState?.querySelector(".search-term");

  function applySearch(query) {
    const matches = new Set(filterRows(ROWS, query).map((r) => r.id));
    const activeQuery = Boolean(query && query.trim());

    if (searchClear) searchClear.hidden = !activeQuery;
    if (searchKbd) searchKbd.hidden = activeQuery;

    let totalVisible = 0;
    for (const [secId, secEl] of sectionElements.entries()) {
      let secVisible = 0;
      const rowsInSec = ROWS.filter((r) => r.section === secId);
      for (const r of rowsInSec) {
        const rowEl = rowElements.get(r.id);
        if (!rowEl) continue;
        const visible = !activeQuery || matches.has(r.id);
        rowEl.hidden = !visible;
        if (visible) secVisible++;
      }
      secEl.hidden = secVisible === 0;
      totalVisible += secVisible;
    }

    if (emptyState) {
      emptyState.hidden = totalVisible > 0;
      if (searchTerm) searchTerm.textContent = query.trim();
    }
  }

  searchInput?.addEventListener("input", (e) => {
    applySearch(e.target.value);
  });

  searchClear?.addEventListener("click", () => {
    if (searchInput) {
      searchInput.value = "";
      applySearch("");
      searchInput.focus();
    }
  });

  // Global keydown handler inside settings view
  function onKeyDown(e) {
    if (container.hidden) return;

    if (e.key === "/" && document.activeElement !== searchInput) {
      e.preventDefault();
      searchInput?.focus();
      return;
    }

    if (e.key === "Escape") {
      if (searchInput && (searchInput.value || document.activeElement === searchInput)) {
        e.preventDefault();
        searchInput.value = "";
        applySearch("");
        searchInput.blur();
      } else {
        e.preventDefault();
        onBack?.();
      }
    }
  }

  window.addEventListener("keydown", onKeyDown);

  return {
    destroy() {
      window.removeEventListener("keydown", onKeyDown);
      container.innerHTML = "";
    },
    refresh() {
      loadValues(ROWS, invoke, container);
    },
    sync(rowId, val) {
      updateControlValue(container, rowId, val);
    },
  };
}

/**
 * Render individual control into container based on control.type
 */
function renderControl(container, row, invoke, onSettingChanged) {
  const { type } = row.control;

  if (type === "toggle") {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "tog";
    btn.setAttribute("role", "switch");
    btn.setAttribute("aria-checked", "false");
    btn.setAttribute("aria-label", row.label);
    btn.innerHTML = "<i></i>";

    btn.addEventListener("click", async () => {
      const now = btn.getAttribute("aria-checked") === "true";
      const next = !now;
      btn.setAttribute("aria-checked", String(next));
      try {
        await row.write(invoke, next);
        onSettingChanged?.(row.id, next);
      } catch (err) {
        log.error(`Settings: failed to write toggle ${row.id}`, err);
        btn.setAttribute("aria-checked", String(now));
      }
    });

    container.appendChild(btn);
  } else if (type === "seg") {
    const span = document.createElement("span");
    span.className = "seg";
    span.setAttribute("role", "radiogroup");
    span.setAttribute("aria-label", row.label);

    const options = row.control.options || [];
    for (let i = 0; i < options.length; i++) {
      const opt = options[i];
      const optBtn = document.createElement("button");
      optBtn.type = "button";
      optBtn.setAttribute("role", "radio");
      optBtn.setAttribute("aria-checked", i === 0 ? "true" : "false");
      optBtn.dataset.value = opt.value;
      optBtn.textContent = opt.label;

      optBtn.addEventListener("click", async () => {
        const prev = span.querySelector('button[aria-checked="true"]');
        for (const b of span.querySelectorAll("button")) {
          b.setAttribute("aria-checked", b === optBtn ? "true" : "false");
        }
        try {
          await row.write(invoke, opt.value);
          onSettingChanged?.(row.id, opt.value);
        } catch (err) {
          log.error(`Settings: failed to write seg ${row.id}`, err);
          if (prev) {
            for (const b of span.querySelectorAll("button")) {
              b.setAttribute("aria-checked", b === prev ? "true" : "false");
            }
          }
        }
      });

      span.appendChild(optBtn);
    }
    container.appendChild(span);
  } else if (type === "select") {
    const sel = document.createElement("select");
    sel.className = "sel-control";
    sel.setAttribute("aria-label", row.label);

    const options = row.control.options || [];
    for (const opt of options) {
      const optEl = document.createElement("option");
      optEl.value = opt.value;
      optEl.textContent = opt.label;
      sel.appendChild(optEl);
    }

    sel.addEventListener("change", async () => {
      try {
        await row.write(invoke, sel.value);
        onSettingChanged?.(row.id, sel.value);
      } catch (err) {
        log.error(`Settings: failed to write select ${row.id}`, err);
      }
    });

    container.appendChild(sel);
  } else if (type === "button") {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn-action";
    btn.textContent = row.control.label;

    btn.addEventListener("click", async () => {
      try {
        await row.write(invoke);
        onSettingChanged?.(row.id);
      } catch (err) {
        log.error(`Settings: failed to trigger button ${row.id}`, err);
      }
    });

    container.appendChild(btn);
  } else if (type === "path") {
    const wrap = document.createElement("div");
    wrap.className = "path-wrap";

    const pathSpan = document.createElement("span");
    pathSpan.className = "path-val";
    pathSpan.textContent = "—";
    pathSpan.title = "";
    wrap.appendChild(pathSpan);

    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn-action small";
    btn.textContent = row.control.buttonLabel || "Choose…";

    btn.addEventListener("click", async () => {
      try {
        await row.write(invoke);
        // Path choices are async; re-read after a short delay
        setTimeout(async () => {
          if (row.read) {
            const p = await row.read(invoke);
            if (p) {
              pathSpan.textContent = p;
              pathSpan.title = p;
            }
          }
        }, 500);
      } catch (err) {
        log.error(`Settings: failed to choose path ${row.id}`, err);
      }
    });
    wrap.appendChild(btn);

    container.appendChild(wrap);
  }
}

/**
 * Load initial values from backend and update DOM controls
 */
async function loadValues(rows, invoke, container) {
  for (const row of rows) {
    if (!row.read) continue;
    try {
      const val = await row.read(invoke);
      updateControlValue(container, row.id, val);
    } catch (err) {
      log.warn(`Settings: could not read initial value for ${row.id}`, err);
    }
  }
}

/**
 * Update DOM element for rowId to match val
 */
function updateControlValue(container, rowId, val) {
  const rowEl = container.querySelector(`#row-${rowId}`);
  if (!rowEl) return;

  const tog = rowEl.querySelector(".tog");
  if (tog) {
    tog.setAttribute("aria-checked", Boolean(val) ? "true" : "false");
    return;
  }

  const seg = rowEl.querySelector(".seg");
  if (seg) {
    for (const b of seg.querySelectorAll("button")) {
      b.setAttribute("aria-checked", b.dataset.value === String(val) ? "true" : "false");
    }
    return;
  }

  const sel = rowEl.querySelector(".sel-control");
  if (sel) {
    sel.value = String(val ?? "");
    return;
  }

  const pathVal = rowEl.querySelector(".path-val");
  if (pathVal && typeof val === "string") {
    pathVal.textContent = val || "—";
    pathVal.title = val || "";
  }
}
