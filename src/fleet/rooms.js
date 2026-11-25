// Rooms: Needs you and Agents as two experiences, three layouts (#386).
// Replaces the stacked drawer with dedicated rooms:
// Layout B: "Two rooms" (chair's pick, default)
// Layout D: "Inbox and Floor" (vote winner)
// Layout E: "Amber Door" (right panel over dimmed wall)

import { asksCount, parse, toTree, sections } from "./queue.js";

export const LAYOUTS = ["B", "D", "E"];
export const DEFAULT_LAYOUT = "B";

/** Parse saved layout preference; default to B. */
export function parseLayout(val) {
  return LAYOUTS.includes(val) ? val : DEFAULT_LAYOUT;
}

const DONE_PREFIX = "✅";
const PENDING_PREFIX = "📋";

/**
 * Extract links from a markdown string: [label](url).
 * Returns array of { label, url, kind }.
 */
export function extractLinks(text) {
  if (!text) return [];
  const links = [];
  const re = /\[([^\]]+)\]\(([^)]+)\)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const label = m[1].trim();
    const url = m[2].trim();
    let kind = "web";
    if (/\.(md|txt|rs|js|json|toml|py|sh|pdf)$/i.test(url) || url.startsWith("file://") || url.startsWith("~/")) kind = "file";
    else if (/\/$/.test(url) || url.includes("folder")) kind = "folder";
    else if (/#\d+/.test(label) || url.includes("/pull/")) kind = "pr";
    else if (/issues\/\d+/.test(url)) kind = "issue";
    links.push({ label, url, kind });
  }
  return links;
}

/**
 * Clean title and detail from a list item line.
 * Input: "- 📋 **Title:** detail text [link](url)"
 */
export function cleanItemText(raw) {
  let s = raw.replace(/^[-*+]\s*/, "").trim();
  s = s.replace(/^(?:📋|✅)\s*/u, "").trim();

  let title = "";
  let detail = "";

  // Check for bold title at start: **Title** or **Title:**
  const boldMatch = s.match(/^\*\*([^*]+)\*\*(?::?\s*(.*))?$/s);
  if (boldMatch) {
    title = boldMatch[1].trim();
    detail = (boldMatch[2] || "").trim();
  } else {
    // Look for first colon or period
    const colonIdx = s.indexOf(":");
    if (colonIdx > 0 && colonIdx < 80) {
      title = s.slice(0, colonIdx).trim();
      detail = s.slice(colonIdx + 1).trim();
    } else {
      title = s;
      detail = "";
    }
  }

  // Strip trailing colon from title if any
  if (title.endsWith(":")) title = title.slice(0, -1).trim();

  // Strip markdown link markup from title if present
  title = title.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").replace(/[*_`]/g, "").trim();
  return { title, detail };
}

/**
 * Parse needs-you.md markdown text into structured items grouped by section.
 * Completed items (with ✅) are omitted.
 */
export function parseNeedsItems(text) {
  if (!text) return [];
  const lines = text.split(/\r?\n/);
  const items = [];
  let currentSection = "Today";

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();

    if (trimmed.startsWith("## ")) {
      currentSection = trimmed.slice(3).trim();
      continue;
    }

    if (!trimmed.startsWith("- ") && !trimmed.startsWith("* ") && !/^\d+\.\s/.test(trimmed)) {
      continue;
    }

    // Done items are never shown
    if (trimmed.includes(DONE_PREFIX)) {
      continue;
    }

    const links = extractLinks(line);
    const { title, detail } = cleanItemText(trimmed);

    // Grouping
    let group = currentSection;
    if (/today/i.test(currentSection)) group = "Today";
    else if (/coming up|next 7|this week/i.test(currentSection)) group = "Coming up";
    else if (/when convenient|later|anytime/i.test(currentSection)) group = "When convenient";

    items.push({
      lineIndex: i,
      rawLine: line,
      title: title || trimmed,
      detail,
      links,
      group,
      section: currentSection,
    });
  }

  return items;
}

/**
 * Parse queue.md "Running now" section into items without session cards.
 */
export function parseQueueNow(text) {
  if (!text) return [];
  const lines = text.split(/\r?\n/);
  const items = [];
  let inNow = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("## ")) {
      inNow = /running now/i.test(line);
      continue;
    }
    if (!inNow) continue;
    if (!line.startsWith("- ") && !line.startsWith("* ")) continue;

    const links = extractLinks(line);
    const { title, detail } = cleanItemText(line);
    let state = "working";
    if (/review/i.test(line)) state = "review";
    else if (/scheduled/i.test(line)) state = "scheduled";
    else if (/parked/i.test(line)) state = "parked";
    else if (/done/i.test(line) || line.includes(DONE_PREFIX)) state = "done";

    items.push({
      title: title || line,
      note: detail,
      links,
      state,
    });
  }

  return items;
}

/**
 * Remove an item from needs-you.md text when marked done.
 * Returns { newText, removedLine }.
 */
export function markItemDone(text, lineIndex) {
  if (!text) return { newText: "", removedLine: "" };
  const lines = text.split(/\r?\n/);
  if (lineIndex < 0 || lineIndex >= lines.length) return { newText: text, removedLine: "" };
  const removedLine = lines[lineIndex];
  lines.splice(lineIndex, 1);
  return { newText: lines.join("\n"), removedLine };
}

/**
 * Restore a removed line at lineIndex.
 */
export function undoItemDone(text, lineIndex, removedLine) {
  if (!text && !removedLine) return "";
  const lines = (text || "").split(/\r?\n/);
  const idx = Math.max(0, Math.min(lineIndex, lines.length));
  lines.splice(idx, 0, removedLine);
  return lines.join("\n");
}

/**
 * Compute total needs count: open asks in needs-you.md + sessions blocked on AJ.
 */
export function needsCount(needsText, sessions = []) {
  let asks = 0;
  if (needsText) {
    const parsed = sections(toTree(parse(needsText)));
    asks = asksCount(parsed) ?? parseNeedsItems(needsText).length;
  }
  const blocked = sessions.filter((s) => s.status === "needs_you").length;
  return asks + blocked;
}

/**
 * Count working sessions.
 */
export function workingCount(sessions = []) {
  return sessions.filter((s) => s.status === "working").length;
}

/**
 * Create the Rooms manager that binds Needs you and Agents views.
 */
export function createRooms({
  wallContainer,
  headerNav,
  needsRoomContainer,
  phoneTabBar,
  getSessions = () => [],
  getCast = () => null,
  onTerminal = () => {},
  onSaveNeeds = () => {},
  onLayoutChanged = () => {},
}) {
  let currentView = "agents"; // "agents" | "needs"
  let currentLayout = parseLayout(localStorage.getItem("needs_layout"));
  let needsText = "";
  let needsPath = "";
  let queueText = "";
  let focusedIndex = 0;
  let undoTimer = null;
  let lastUndo = null; // { text, lineIndex, removedLine }
  let jumpToastTimer = null;
  let jumpSessionId = null;
  let lastSessionStatuses = new Map();

  // Storage / Prefs
  function setLayout(layout) {
    currentLayout = parseLayout(layout);
    localStorage.setItem("needs_layout", currentLayout);
    if (typeof window !== "undefined" && window.__TAURI__?.core?.invoke) {
      window.__TAURI__.core.invoke("set_needs_layout", { layout: currentLayout }).catch(() => {});
    }
    renderViews();
    onLayoutChanged(currentLayout);
  }

  function getLayout() {
    return currentLayout;
  }

  // Toast notification
  function showToast(message, actionLabel, onAction, durationMs = 5000) {
    const existing = document.querySelector(".room-toast");
    if (existing) existing.remove();

    const toast = document.createElement("div");
    toast.className = "room-toast";
    toast.setAttribute("role", "status");

    const textSpan = document.createElement("span");
    textSpan.textContent = message;
    toast.append(textSpan);

    if (actionLabel && onAction) {
      const actBtn = document.createElement("button");
      actBtn.type = "button";
      actBtn.className = "toast-action";
      actBtn.textContent = actionLabel;
      actBtn.addEventListener("click", () => {
        onAction();
        toast.remove();
      });
      toast.append(actBtn);
    }

    document.body.append(toast);
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => {
      toast.classList.add("toast-leaving");
      setTimeout(() => toast.remove(), 250);
    }, durationMs);

    return toast;
  }

  // Switch between "agents" and "needs" views
  function switchView(view) {
    currentView = view === "needs" ? "needs" : "agents";
    focusedIndex = 0;
    renderViews();
  }

  // Build the Header Pills
  function updateHeader() {
    if (!headerNav) return;
    const sessions = getSessions();
    const n = needsCount(needsText, sessions);
    const m = workingCount(sessions);

    headerNav.innerHTML = `
      <button type="button" id="btn-needs-room" class="room-pill room-needs ${n > 0 ? "is-amber" : "is-calm"}" aria-current="${currentView === "needs" ? "page" : "false"}" aria-keyshortcuts="N" title="Needs you (N)">
        <span class="rt">Needs you</span>
        <span class="rc-count ${n > 0 ? "count-amber" : "count-calm"}">${n > 0 ? n : (currentLayout === "D" ? "All clear" : "0")}</span>
        <span class="kbd">N</span>
      </button>
      <button type="button" id="btn-agents-room" class="room-pill room-agents" aria-current="${currentView === "agents" ? "page" : "false"}" aria-keyshortcuts="A" title="Agents (A)">
        <span class="rt">Agents</span>
        <span class="rc">${m} working</span>
        <span class="kbd">A</span>
      </button>
    `;

    headerNav.querySelector("#btn-needs-room")?.addEventListener("click", () => switchView("needs"));
    headerNav.querySelector("#btn-agents-room")?.addEventListener("click", () => switchView("agents"));

    // Update phone tabbar
    if (phoneTabBar) {
      phoneTabBar.hidden = false;
      phoneTabBar.innerHTML = `
        <button type="button" id="ptab-agents" class="ptab-btn" aria-current="${currentView === "agents" ? "page" : "false"}">
          <span class="pico">◐</span>
          <span class="plabel">Agents</span>
        </button>
        <button type="button" id="ptab-needs" class="ptab-btn" aria-current="${currentView === "needs" ? "page" : "false"}">
          <span class="pico">✋${n > 0 ? `<span class="pbadge">${n}</span>` : ""}</span>
          <span class="plabel">Needs you</span>
        </button>
      `;
      phoneTabBar.querySelector("#ptab-agents")?.addEventListener("click", () => switchView("agents"));
      phoneTabBar.querySelector("#ptab-needs")?.addEventListener("click", () => switchView("needs"));
    }
  }

  // Mark an item done with 5s undo
  function handleMarkDone(lineIndex) {
    const { newText, removedLine } = markItemDone(needsText, lineIndex);
    lastUndo = {
      prevText: needsText,
      lineIndex,
      removedLine,
    };
    needsText = newText;
    onSaveNeeds(newText, needsPath);

    updateHeader();
    renderNeedsRoom();

    showToast("Marked done", "Undo (5s)", () => {
      if (lastUndo) {
        needsText = lastUndo.prevText;
        onSaveNeeds(needsText, needsPath);
        lastUndo = null;
        updateHeader();
        renderNeedsRoom();
      }
    }, 5000);
  }

  // Trigger undo manually (via key U)
  function handleUndo() {
    if (lastUndo) {
      needsText = lastUndo.prevText;
      onSaveNeeds(needsText, needsPath);
      lastUndo = null;
      updateHeader();
      renderNeedsRoom();
      showToast("Restored item", null, null, 2000);
    }
  }

  // Render the Needs you view
  function renderNeedsRoom() {
    if (!needsRoomContainer) return;

    const sessions = getSessions();
    const blocked = sessions.filter((s) => s.status === "needs_you");
    const items = parseNeedsItems(needsText);
    const total = blocked.length + items.length;

    // Adjust focus index
    if (focusedIndex >= total) focusedIndex = Math.max(0, total - 1);

    // Group items
    const groups = new Map();
    for (const it of items) {
      const g = it.group || "Other";
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(it);
    }

    let html = "";

    // Header of Needs you room
    html += `
      <div class="needs-room-header">
        <h1 class="needs-room-title">Needs you</h1>
        <p class="needs-room-subtitle">${total > 0 ? `${total} open, soonest first. Done removes a line from needs-you.md.` : "Nothing waits on you."}</p>
      </div>
    `;

    if (total === 0) {
      // Find any future item or first dated item if available
      const nextItem = items[0];
      html += `
        <div class="needs-all-clear">
          <div class="all-clear-icon">✓</div>
          <h2>${currentLayout === "D" ? "All clear" : "Nothing waits on you"}</h2>
          <p class="all-clear-sub">${nextItem ? `Next item: <strong>${nextItem.title}</strong> (${nextItem.group})` : "New asks and sessions waiting on your review land here first."}</p>
        </div>
      `;
    } else {
      let currentIndex = 0;

      // 1. Blocked sessions group
      if (blocked.length > 0) {
        html += `<div class="needs-group-header">Sessions blocked on you <span class="group-count">${blocked.length}</span></div>`;
        html += `<ul class="needs-list blocked-list">`;
        for (const s of blocked) {
          const isFocused = currentIndex === focusedIndex;
          const who = s.identity?.name || s.name || "Agent";
          const epithet = s.identity?.epithet || "";
          const reason = s.reason || s.needs?.tool || s.task || "Waiting on input";
          const face = s.identity?.face ? `faces/${s.identity.face}-figure.webp` : "";

          html += `
            <li class="needs-row blocked-row ${isFocused ? "is-focused" : ""}" data-idx="${currentIndex}" data-session-id="${s.id}">
              <div class="blocked-portrait">
                ${face ? `<img src="${face}" alt="" class="blocked-fig" />` : `<div class="blocked-disc">!</div>`}
              </div>
              <div class="blocked-body">
                <div class="blocked-name"><strong>${who}</strong> <span class="blocked-epi">${epithet}</span></div>
                <div class="blocked-task">${reason}</div>
              </div>
              <div class="blocked-actions">
                <button type="button" class="btn btn-answer" data-act="answer" data-session-id="${s.id}">Answer</button>
                <button type="button" class="btn btn-term" data-act="terminal" data-session-id="${s.id}">Open terminal</button>
              </div>
            </li>
          `;
          currentIndex++;
        }
        html += `</ul>`;
      }

      // 2. Sections from needs-you.md
      if (currentLayout === "E" && items.length > 0) {
        // Layout E Focus Card at top + compact list below
        const focusItemIndex = Math.min(items.length - 1, Math.max(0, focusedIndex - blocked.length));
        const curItem = items[focusItemIndex] || items[0];
        const focusLinksHtml = curItem.links.map((l) => `<a class="chip" href="${l.url}" target="_blank" rel="noopener"><i>${l.kind === "file" ? "▤" : l.kind === "folder" ? "▱" : l.kind === "pr" ? "⑂" : "↗"}</i>${l.label}</a>`).join("");
        const isToday = /today/i.test(curItem.group);

        html += `
          <div class="focus-card">
            <div class="focus-card-meta">
              <span class="focus-due ${isToday ? "due-today" : ""}">${curItem.group}</span>
              <span class="focus-prog">${focusItemIndex + 1} of ${items.length}</span>
            </div>
            <h2 class="focus-title">${curItem.title}</h2>
            ${curItem.detail ? `<p class="focus-detail">${curItem.detail}</p>` : ""}
            ${curItem.links.length > 0 ? `<div class="focus-links">${focusLinksHtml}</div>` : ""}
            <div class="focus-bar">
              <button type="button" class="done-btn focus-action-done" data-act="done" data-line="${curItem.lineIndex}">Done <span class="kbd">E</span></button>
              ${curItem.links[0] ? `<a class="btn focus-action-open" href="${curItem.links[0].url}" target="_blank" rel="noopener">Open <span class="kbd">Enter</span></a>` : ""}
              <button type="button" class="btn focus-action-copy" data-act="copy" data-text="${curItem.links[0]?.url || curItem.title}">Copy <span class="kbd">C</span></button>
              <span class="focus-sp"></span>
              <button type="button" class="btn btn-step" data-step="-1" title="Previous (K)">▲</button>
              <button type="button" class="btn btn-step" data-step="1" title="Next (J)">▼</button>
            </div>
          </div>
          <div class="focus-subhead">All asks</div>
          <ul class="needs-list focus-sublist">
            ${items.map((it, idx) => {
              const itIdx = blocked.length + idx;
              const isFoc = itIdx === focusedIndex;
              return `
                <li class="needs-row focus-row ${isFoc ? "is-focused" : ""}" data-idx="${itIdx}" data-line="${it.lineIndex}">
                  <span class="focus-row-due">${it.group}</span>
                  <span class="focus-row-title">${it.title}</span>
                  <button type="button" class="done-btn tick-only" data-act="done" data-line="${it.lineIndex}" aria-label="Done: ${it.title}"></button>
                </li>
              `;
            }).join("")}
          </ul>
        `;
      } else {
        // Layout B & D: Render sections
        for (const [groupName, groupItems] of groups.entries()) {
          html += `<div class="needs-group-header">${groupName} <span class="group-count">${groupItems.length}</span></div>`;
          html += `<ul class="needs-list">`;
          for (const it of groupItems) {
            const isFocused = currentIndex === focusedIndex;
            const isToday = /today/i.test(it.group);
            const linksHtml = it.links.map((l) => `<a class="chip" href="${l.url}" target="_blank" rel="noopener" data-url="${l.url}"><i>${l.kind === "file" ? "▤" : l.kind === "folder" ? "▱" : l.kind === "pr" ? "⑂" : "↗"}</i>${l.label}</a>`).join("");

            html += `
              <li class="needs-row ${isToday ? "is-today" : ""} ${isFocused ? "is-focused" : ""}" data-idx="${currentIndex}" data-line="${it.lineIndex}">
                <div class="needs-row-lead">
                  <span class="row-due ${isToday ? "due-today" : ""}">${isToday ? "Today" : it.group}</span>
                </div>
                <div class="needs-row-body">
                  <h3 class="row-title">${it.title}</h3>
                  ${it.detail ? `<p class="row-detail">${it.detail}</p>` : ""}
                  ${it.links.length > 0 ? `<div class="row-links">${linksHtml}</div>` : ""}
                </div>
                <div class="needs-row-actions">
                  <button type="button" class="done-btn" data-act="done" data-line="${it.lineIndex}" aria-label="Mark done: ${it.title}">Done</button>
                </div>
              </li>
            `;
            currentIndex++;
          }
          html += `</ul>`;
        }
      }
    }

    needsRoomContainer.innerHTML = html;

    // Attach event listeners for mouse actions in Needs room
    needsRoomContainer.querySelectorAll(".done-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const line = Number(btn.dataset.line);
        handleMarkDone(line);
      });
    });

    needsRoomContainer.querySelectorAll("[data-act='terminal']").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        onTerminal(btn.dataset.sessionId);
      });
    });

    needsRoomContainer.querySelectorAll("[data-act='answer']").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        onTerminal(btn.dataset.sessionId);
      });
    });

    needsRoomContainer.querySelectorAll(".btn-step").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const step = Number(btn.dataset.step) || 0;
        focusedIndex = Math.max(0, Math.min(total - 1, focusedIndex + step));
        renderNeedsRoom();
      });
    });

    needsRoomContainer.querySelectorAll("[data-act='copy']").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const copyText = btn.dataset.text;
        if (copyText) {
          navigator.clipboard.writeText(copyText).then(() => {
            showToast("Copied to clipboard", null, null, 1500);
          }).catch(() => {});
        }
      });
    });

    needsRoomContainer.querySelectorAll(".needs-row").forEach((row) => {
      row.addEventListener("click", () => {
        const idx = Number(row.dataset.idx);
        if (!isNaN(idx)) {
          focusedIndex = idx;
          needsRoomContainer.querySelectorAll(".needs-row").forEach((r, i) => {
            r.classList.toggle("is-focused", i === focusedIndex);
          });
        }
      });
    });

    // Mobile swipe to mark done
    needsRoomContainer.querySelectorAll(".needs-row[data-line]").forEach((row) => {
      let touchStartX = 0;
      row.addEventListener("touchstart", (e) => {
        touchStartX = e.touches[0].clientX;
      }, { passive: true });
      row.addEventListener("touchend", (e) => {
        const touchEndX = e.changedTouches[0].clientX;
        if (touchEndX - touchStartX > 80) { // Swiped right
          const line = Number(row.dataset.line);
          handleMarkDone(line);
        }
      }, { passive: true });
    });
  }

  // Render the Agents view (Lanes + Fleet queue)
  function renderAgentsView() {
    if (!wallContainer) return;

    const qItems = parseQueueNow(queueText);
    const existingFq = document.getElementById("fleet-queue-lanes");
    if (existingFq) existingFq.remove();
    const existingPhoneAgents = document.getElementById("phone-agents-list");
    if (existingPhoneAgents) existingPhoneAgents.remove();

    const isPhone = typeof window !== "undefined" && window.matchMedia("(max-width: 640px)").matches;
    const sessions = getSessions();

    if (isPhone) {
      // Phone: Agents is one row per agent with portrait and status
      const phoneList = document.createElement("section");
      phoneList.id = "phone-agents-list";
      phoneList.className = "phone-agents-list";
      phoneList.innerHTML = `
        <div class="phone-agents-head">Agents <span class="group-count">${sessions.length}</span></div>
        <div class="phone-agents-rows">
          ${sessions.map((s) => {
            const who = s.identity?.name || s.name || "Agent";
            const face = s.identity?.face ? `faces/${s.identity.face}-figure.webp` : "";
            const status = s.status || "idle";
            const task = s.task || s.reason || "Active session";
            return `
              <div class="phone-agent-row" data-id="${s.id}">
                <div class="phone-agent-pic">
                  ${face ? `<img src="${face}" alt="" />` : `<div class="blocked-disc">A</div>`}
                </div>
                <div class="phone-agent-info">
                  <div class="phone-agent-title"><b>${who}</b> <span class="pill ${status}">${status}</span></div>
                  <div class="phone-agent-task">${task}</div>
                </div>
              </div>
            `;
          }).join("")}
        </div>
      `;
      wallContainer.after(phoneList);
    } else if (currentLayout === "B") {
      // Desktop Layout B: Lanes Live (wall cards), In review, Scheduled/Parked, Done today (collapsed to a count)
      const inReview = qItems.filter((q) => q.state === "review");
      const schedParked = qItems.filter((q) => q.state === "scheduled" || q.state === "parked");
      const doneToday = qItems.filter((q) => q.state === "done");

      const fqSec = document.createElement("section");
      fqSec.id = "fleet-queue-lanes";
      fqSec.className = "fq-lanes lanes-b";

      let lanesHtml = "";

      if (inReview.length > 0) {
        lanesHtml += `
          <div class="lane-block">
            <div class="lane-header"><span class="pill review">In review</span> <span class="group-count">${inReview.length}</span></div>
            <div class="lane-items">
              ${inReview.map((q) => `
                <div class="lane-slim-row">
                  <span class="slim-title"><b>${q.title}</b>${q.note ? ` <span>${q.note}</span>` : ""}</span>
                  <div class="links">${q.links.map((l) => `<a class="chip" href="${l.url}" target="_blank" rel="noopener"><i>⑂</i>${l.label}</a>`).join("")}</div>
                </div>
              `).join("")}
            </div>
          </div>
        `;
      }

      if (schedParked.length > 0) {
        lanesHtml += `
          <div class="lane-block">
            <div class="lane-header"><span class="pill scheduled">Scheduled / Parked</span> <span class="group-count">${schedParked.length}</span></div>
            <div class="lane-items">
              ${schedParked.map((q) => `
                <div class="lane-slim-row">
                  <span class="slim-title"><b>${q.title}</b>${q.note ? ` <span>${q.note}</span>` : ""}</span>
                  <div class="links">${q.links.map((l) => `<a class="chip" href="${l.url}" target="_blank" rel="noopener"><i>↗</i>${l.label}</a>`).join("")}</div>
                </div>
              `).join("")}
            </div>
          </div>
        `;
      }

      if (doneToday.length > 0) {
        lanesHtml += `
          <details class="lane-block done-today-lane">
            <summary class="lane-header done-summary">
              <span class="pill done">Done today</span>
              <span class="group-count">${doneToday.length}</span>
              <span class="done-hint">collapsed</span>
            </summary>
            <div class="lane-items">
              ${doneToday.map((q) => `
                <div class="lane-slim-row is-done-row">
                  <span class="slim-title"><b>${q.title}</b>${q.note ? ` <span>${q.note}</span>` : ""}</span>
                  <div class="links">${q.links.map((l) => `<a class="chip" href="${l.url}" target="_blank" rel="noopener"><i>✓</i>${l.label}</a>`).join("")}</div>
                </div>
              `).join("")}
            </div>
          </details>
        `;
      }

      if (lanesHtml) {
        fqSec.innerHTML = `<div class="fq-head">Plan & Queue <em>from queue.md</em></div>${lanesHtml}`;
        wallContainer.after(fqSec);
      }
    } else if (currentLayout === "D") {
      // Desktop Layout D: The wall itself + "No session" strip below
      const noSessionItems = qItems.filter((q) => ["review", "scheduled", "parked", "done"].includes(q.state));

      // Style wall cards in Layout D: amber edge on needs_you, dimmed on done
      if (wallContainer) {
        wallContainer.querySelectorAll(".card").forEach((c) => {
          const s = sessions.find((item) => item.id === c.dataset.id);
          if (s) {
            c.classList.toggle("card-needs-edge", s.status === "needs_you");
            c.classList.toggle("card-done-dimmed", s.status === "done");
          }
        });
      }

      if (noSessionItems.length > 0) {
        const stripSec = document.createElement("section");
        stripSec.id = "fleet-queue-lanes";
        stripSec.className = "no-session-strip";
        stripSec.innerHTML = `
          <div class="strip-head">No session <em>review, scheduled, parked, done today (links only)</em></div>
          <div class="strip-chips">
            ${noSessionItems.map((q) => {
              const url = q.links[0]?.url || "#";
              const label = q.links[0]?.label || q.title;
              const ico = q.state === "review" ? "⑂" : q.state === "done" ? "✓" : "↗";
              return `<a class="chip strip-chip ${q.state}" href="${url}" target="_blank" rel="noopener" title="${q.title}"><i>${ico}</i>${label}</a>`;
            }).join("")}
          </div>
        `;
        wallContainer.after(stripSec);
      }
    }
  }

  // Main render coordinator
  function renderViews() {
    updateHeader();

    document.body.dataset.layout = currentLayout;
    document.body.dataset.view = currentView;

    const fqLanes = document.getElementById("fleet-queue-lanes");

    if (currentLayout === "B" || currentLayout === "D") {
      // Full screen rooms
      if (currentView === "needs") {
        if (wallContainer) wallContainer.hidden = true;
        if (fqLanes) fqLanes.hidden = true;
        if (needsRoomContainer) needsRoomContainer.hidden = false;
        renderNeedsRoom();
      } else {
        if (wallContainer) wallContainer.hidden = false;
        if (fqLanes) fqLanes.hidden = false;
        if (needsRoomContainer) needsRoomContainer.hidden = true;
        renderAgentsView();
      }
    } else if (currentLayout === "E") {
      // Amber Door: Wall is always visible; Needs you is 1/3 right panel
      if (wallContainer) wallContainer.hidden = false;
      if (fqLanes) fqLanes.hidden = false;
      renderAgentsView();

      if (currentView === "needs") {
        if (needsRoomContainer) {
          needsRoomContainer.hidden = false;
          needsRoomContainer.classList.add("amber-door-open");
        }
        renderNeedsRoom();
      } else {
        if (needsRoomContainer) {
          needsRoomContainer.hidden = true;
          needsRoomContainer.classList.remove("amber-door-open");
        }
      }
    }
  }

  // Check for status changes to trigger jump toasts
  function checkStatusChanges(sessions) {
    const curStatuses = new Map(sessions.map((s) => [s.id, s.status]));
    if (lastSessionStatuses.size > 0 && currentView === "needs") {
      for (const [id, status] of curStatuses) {
        const prev = lastSessionStatuses.get(id);
        const s = sessions.find((item) => item.id === id);
        const name = s?.identity?.name || s?.name || "An agent";

        if (status === "needs_you" && prev !== "needs_you") {
          jumpSessionId = id;
          if (currentLayout === "E") {
            switchView("needs");
          } else {
            showToast(`${name} needs your answer`, "Enter to jump", () => {
              switchView("agents");
            }, 6000);
          }
          break;
        } else if (status === "done" && prev !== "done") {
          jumpSessionId = id;
          showToast(`${name} finished`, "Enter to jump", () => {
            switchView("agents");
          }, 6000);
          break;
        }
      }
    }
    lastSessionStatuses = curStatuses;
  }

  // Global Keyboard Navigation
  function handleKeyDown(e) {
    // If typing in input, ignore shortcuts
    if (["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName)) return;

    if (e.key === "n" || e.key === "N") {
      if (!e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        if (currentLayout === "D" && currentView === "needs") {
          switchView("agents");
        } else {
          switchView("needs");
        }
        return;
      }
    }

    if (e.key === "a" || e.key === "A") {
      if (!e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        switchView("agents");
        return;
      }
    }

    if (e.key === "Escape") {
      if (currentView === "needs") {
        e.preventDefault();
        switchView("agents");
        return;
      }
    }

    if (e.key === "Enter") {
      const activeToast = document.querySelector(".room-toast .toast-action");
      if (activeToast) {
        e.preventDefault();
        activeToast.click();
        return;
      }
    }

    if (currentView === "needs") {
      const sessions = getSessions();
      const blocked = sessions.filter((s) => s.status === "needs_you");
      const items = parseNeedsItems(needsText);
      const total = blocked.length + items.length;

      if (e.key === "j" || e.key === "ArrowDown") {
        e.preventDefault();
        focusedIndex = Math.min(focusedIndex + 1, total - 1);
        renderNeedsRoom();
      } else if (e.key === "k" || e.key === "ArrowUp") {
        e.preventDefault();
        focusedIndex = Math.max(focusedIndex - 1, 0);
        renderNeedsRoom();
      } else if (e.key === "e") {
        e.preventDefault();
        if (focusedIndex >= blocked.length) {
          const itemIdx = focusedIndex - blocked.length;
          const item = items[itemIdx];
          if (item) handleMarkDone(item.lineIndex);
        }
      } else if (e.key === "u") {
        e.preventDefault();
        handleUndo();
      } else if (e.key === "o" || e.key === "Enter") {
        e.preventDefault();
        if (focusedIndex < blocked.length) {
          const s = blocked[focusedIndex];
          if (s) onTerminal(s.id);
        } else {
          const itemIdx = focusedIndex - blocked.length;
          const item = items[itemIdx];
          if (item && item.links.length > 0) {
            window.open(item.links[0].url, "_blank", "noopener");
          }
        }
      } else if (e.key === "c") {
        e.preventDefault();
        if (focusedIndex >= blocked.length) {
          const itemIdx = focusedIndex - blocked.length;
          const item = items[itemIdx];
          if (item) {
            const copyText = item.links[0]?.url || item.title;
            navigator.clipboard.writeText(copyText).then(() => {
              showToast("Copied to clipboard", null, null, 1500);
            }).catch(() => {});
          }
        }
      }
    }
  }

  window.addEventListener("keydown", handleKeyDown);
  updateHeader();

  return {
    updateSessions(sessions) {
      checkStatusChanges(sessions);
      updateHeader();
      if (currentView === "needs") renderNeedsRoom();
      else renderAgentsView();
    },
    updateNeeds(view) {
      needsText = view.text || "";
      needsPath = view.path || "";
      updateHeader();
      if (currentView === "needs") renderNeedsRoom();
    },
    updateQueue(view) {
      queueText = view.text || "";
      if (currentView === "agents") renderAgentsView();
    },
    switchView,
    setLayout,
    getLayout,
    getView: () => currentView,
    destroy() {
      window.removeEventListener("keydown", handleKeyDown);
    },
  };
}
