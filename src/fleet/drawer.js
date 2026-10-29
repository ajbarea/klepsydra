// The Ledger: today's totals, tokens per character, attribution, the
// guardrail log and errors, on the shared side panel (sidepanel.js: shut to
// a tab, docked, or full). Every figure is set as text; the only markup is
// built here from constants.
import { identity } from "./model.js";
import { createSidePanel } from "./sidepanel.js";
import {
  activeTime, cacheShare, characterOf, costLine, costText, fullNumber, modelName, plural, rowLabels, sumTotals, todaySessions, tokensByCharacter,
  tokensByModel, topAttribution, totalTokens,
} from "./ledger.js";

const MIN_BAR_PX = 2; // a nonzero count never draws as nothing
/** An open Ledger reads the ledger again at most this often, however fast snapshots come. */
export const REFRESH_MS = 5000;

function el(tag, cls, text, attrs) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  for (const [k, v] of Object.entries(attrs ?? {})) node.setAttribute(k, v);
  return node;
}

/** A list of label and value pairs. */
function figures(pairs) {
  const dl = el("dl", "figures");
  for (const [label, value] of pairs) {
    const row = el("div");
    row.append(el("dt", null, label), el("dd", null, value));
    dl.append(row);
  }
  return dl;
}

/** Whether `node` can take focus back: still in the page and drawn. */
const usable = (node) =>
  Boolean(node?.isConnected) && (node.checkVisibility ? node.checkVisibility() : !node.closest("[hidden]"));

/** A section: an h3 that names its content, and the body. */
function section(id, title) {
  const root = el("section", "ledger-section", null, { "aria-labelledby": id });
  root.append(el("h3", null, title, { id }));
  return root;
}

/** A real table: `head` labels its columns; each row is its cells, a cell text or a node. */
function table(id, caption, head, rows, numeric = []) {
  const t = el("table", null, null, { id, "aria-labelledby": `${id}-caption` });
  t.append(el("caption", "visually-hidden", caption, { id: `${id}-caption` }));
  const tr = el("tr");
  for (const [i, label] of head.entries()) tr.append(el("th", numeric.includes(i) ? "num" : null, label, { scope: "col" }));
  const thead = el("thead");
  thead.append(tr);
  t.append(thead);
  const body = el("tbody");
  for (const row of rows) {
    const r = el("tr");
    row.forEach((cell, i) => {
      const td = el("td", numeric.includes(i) ? "num" : null);
      td.append(cell);
      r.append(td);
    });
    body.append(r);
  }
  t.append(body);
  return t;
}

const clock = (at) => new Date(at * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

const FIGURES = (totals) => {
  const t = totals.tokens;
  const share = cacheShare(t);
  return [
    ["Tokens", fullNumber(totalTokens(t))],
    ["Input", fullNumber(t.input)],
    ["Output", fullNumber(t.output)],
    ["Cache read", fullNumber(t.cache_read)],
    ["Cache creation", fullNumber(t.cache_creation)],
    ["Cache-read share of input", share === null ? "none yet" : `${Math.round(share * 100)}%`],
    ["Lines added", fullNumber(totals.lines_added)],
    ["Lines removed", fullNumber(totals.lines_removed)],
    ["Commits", fullNumber(totals.commits)],
    ["Pull requests", fullNumber(totals.pull_requests)],
    ["Active time, you", activeTime(totals.active.user_ms)],
    ["Active time, Claude Code", activeTime(totals.active.cli_ms)],
  ];
};

/**
 * Wire a drawer to `dialog`, toggled by `button` (which takes focus back when
 * the opener is gone) and reopened from `tab`, sharing `edge` with the other
 * side panels. `sessions()` gives the wall's current sessions, `cast()` the
 * character theme now worn, `fetchToday(session)` the ledger_today view;
 * `onResized()` runs once at the end of a drag of the separator.
 */
export function createDrawer({ dialog, button, tab, edge, sessions, cast, fetchToday, onResized }) {
  const content = dialog.querySelector(".ledger-content");
  const dayLabel = dialog.querySelector(".ledger-day");
  let filter = null; // a session id, or null for all
  let opener = null;
  let view = null; // the last good view, held while a refetch runs
  let turn = 0; // a newer fetch makes an older one stale
  let reading = Promise.resolve(); // the latest read, which open() hands back
  let readAt = -Infinity; // when the latest read started
  let later = 0; // a snapshot's read held back by REFRESH_MS
  let midnight = 0; // the read just past local midnight, when "today" turns over
  let readDay = ""; // the local date the latest read started on
  let painted = ""; // what the body shows, so an unchanged snapshot leaves it (and focus) alone

  const who = () => {
    const map = new Map();
    for (const s of sessions()) {
      const id = identity(s, cast());
      // What tells two cards of one character apart: the session's name, else its repo.
      // A character the wall cast (castPicks) names no voice: the Ledger names the card's.
      map.set(s.session_id, { name: id.name, accent: id.accent, label: s.name || s.where?.repo || null, cast: Boolean(s.pick) && id.voice === null });
    }
    return map;
  };

  function paint() {
    // A fetch can land after the drawer shut: a shut drawer neither paints nor takes focus.
    if (!view || !panel.isOpen) return;
    const names = who();
    // The theme too: a voice the wall no longer shows is still named by it.
    const key = JSON.stringify([view, filter, [...names], cast().label]);
    if (key === painted) return;
    painted = key;
    const { day, receiver, guardrails, guardrails_total: total } = view;
    // Today's recorded voice names a session; the wall only when the day has none.
    const homes = day.home_voices;
    const labels = rowLabels([...names].map(([id, n]) => [id, n.label]), day.labels);
    const nameOf = (id) =>
      names.get(id)?.cast ? names.get(id).name : characterOf(id, day.voices, cast(), names.get(id), { homes, label: labels.get(id) })?.name;
    const everyone = todaySessions(day);
    const shown = todaySessions(day, filter);
    const day_ = sumTotals(shown.map(([, t]) => t));
    const dayTokens = totalTokens(sumTotals(everyone.map(([, t]) => t)).tokens);
    dayLabel.textContent = day.day ? `Today, ${day.day}` : "Today";
    const out = [];

    if (receiver && !receiver.listening) {
      const note = el("p", "notice", null, { role: "status" });
      note.append(
        el("strong", null, "The ledger is not receiving telemetry. "),
        document.createTextNode(
          `klepsydra could not listen on ${receiver.addr}${receiver.error ? `: ${receiver.error}` : ""}. It tries again every 30 seconds.`,
        ),
      );
      out.push(note);
    }

    if (filter !== null) {
      const scope = el("p", "scope");
      scope.append(`Showing ${nameOf(filter) ?? "one session"} only. `);
      const all = el("button", "link", "Show all sessions", { type: "button", id: "ledger-show-all" });
      all.addEventListener("click", () => {
        filter = null;
        refresh();
      });
      scope.append(all);
      out.push(scope);
    }

    // Telemetry is on when today's file has anything, or a card carries a receipt from an earlier export.
    const today = everyone.length > 0 || total > 0 || day.no_session > 0;
    const before = sessions().some((s) => totalTokens(s.ledger?.tokens ?? {}) > 0);
    if (dayTokens === 0 && (today || before)) {
      out.push(el("p", "empty-state", "No token counts yet today."));
      if (everyone.length > 0) out.push(totalsSection(day_));
    } else if (dayTokens === 0) {
      out.push(
        el(
          "p",
          "empty-state",
          "No token counts yet today. Claude Code sends them once telemetry is on: the README section “The ledger” has the settings that turn it on. Start a new Claude Code session after you add them.",
        ),
      );
    } else if (filter !== null && totalTokens(day_.tokens) === 0) {
      out.push(el("p", "empty-state", "Nothing counted for this session today."));
    } else {
      out.push(totalsSection(day_), charactersSection(day, shown, labels, names), modelsSection(day, shown), attributionSection(day, shown));
    }
    out.push(blockedSection(guardrails, total, nameOf), errorsSection(day_));
    const cost = costLine(day_.cost_usd_estimate_micros);
    if (cost) out.push(el("p", "cost", cost));
    const focused = focusedId();
    content.replaceChildren(...out);
    keepFocus(focused);
  }

  function totalsSection(totals) {
    const s = section("ledger-totals", "Totals today");
    s.append(figures(FIGURES(totals)));
    return s;
  }

  // Other sessions says what it holds in its tooltip and, read once in full, its accessible name.
  function named(row) {
    if (!row.label) return row.name;
    const span = el("span");
    span.append(el("span", null, row.name, { title: row.label, "aria-hidden": "true" }), el("span", "visually-hidden", row.label));
    return span;
  }

  function charactersSection(day, shown, labels, names) {
    const s = section("ledger-characters", "Tokens by character");
    const rows = tokensByCharacter(shown, day.voices, cast(), { homes: day.home_voices, labels, wall: names });
    const max = Math.max(1, ...rows.map((r) => r.tokens));
    // The bar is decoration: the name and the count beside it are the data.
    const bar = (row) => {
      const track = el("span", "track", null, { "aria-hidden": "true" });
      const fill = el("span", "fill");
      if (row.accent) fill.style.setProperty("--accent", row.accent);
      fill.style.width = `max(${MIN_BAR_PX}px, ${((row.tokens / max) * 100).toFixed(1)}%)`;
      track.append(fill);
      return track;
    };
    const t = table(
      "ledger-characters-table",
      "Tokens today by character",
      ["Character", "", "Tokens"],
      rows.map((r) => [named(r), bar(r), fullNumber(r.tokens)]),
      [2],
    );
    // The bar column has no words, so it is out of the table's reading too.
    t.classList.add("chart");
    t.tHead.rows[0].cells[1].setAttribute("aria-hidden", "true");
    for (const r of t.tBodies[0].rows) {
      r.cells[1].setAttribute("aria-hidden", "true");
    }
    s.append(t);
    return s;
  }

  function modelsSection(day, shown) {
    const s = section("ledger-models", "Tokens by model");
    const rows = tokensByModel(day.models, shown.map(([id]) => id));
    if (!rows.length) {
      s.append(el("p", "none", "No tokens by model today."));
      return s;
    }
    s.append(el("p", "hint", "The estimate is Claude Code's local list-price figure, not your bill."));
    s.append(
      table(
        "ledger-models-table",
        "Tokens today by model",
        ["Model", "Tokens", "Estimate"],
        rows.map((r) => [modelName(r.name), fullNumber(r.tokens), costText(r.micros)]),
        [1, 2],
      ),
    );
    return s;
  }

  function attributionSection(day, shown) {
    const s = section("ledger-attribution", "Tokens by skill, plugin and MCP server");
    const ids = shown.map(([id]) => id);
    const kinds = [
      ["skills", "Skill", "skill"],
      ["plugins", "Plugin", "plugin"],
      ["mcp_servers", "MCP server", "MCP server"],
    ].map(([kind, title, noun]) => ({ kind, title, noun, top: topAttribution(day.attribution, kind, ids) }));
    if (kinds.every((k) => !k.top.rows.length)) {
      s.append(el("p", "none", "No tokens by skill, plugin or MCP server today."));
      return s;
    }
    s.append(
      el(
        "p",
        "hint",
        "Claude Code redacts the names of third-party plugins and their skills, and of MCP servers you configured, unless OTEL_LOG_TOOL_DETAILS is set; the README's settings leave it unset.",
      ),
    );
    for (const { kind, title, noun, top } of kinds) {
      if (!top.rows.length) {
        s.append(el("p", "none", `No tokens by ${noun} today.`));
        continue;
      }
      const rows = top.rows.map((r) => [r.name, fullNumber(r.tokens)]);
      if (top.more) rows.push([plural(top.more, "more name"), fullNumber(top.moreTokens)]);
      s.append(table(`ledger-${kind}`, `Tokens today by ${noun}`, [title, "Tokens"], rows, [1]));
    }
    return s;
  }

  function blockedSection(guardrails, total, nameOf) {
    const s = section("ledger-blocked", "Blocked today");
    const scope = filter === null ? "" : " in this session";
    if (!total) {
      s.append(el("p", "none", `No tool calls blocked today${scope}.`));
      return s;
    }
    const cut = total > guardrails.length ? `, the newest ${guardrails.length} below` : "";
    s.append(el("p", "hint", `${plural(total, "tool call")} blocked today${scope} by a config rule or a hook${cut}.`));
    if (filter !== null) {
      s.append(el("p", "hint", "The count on the card is the whole session; this list is today's."));
    }
    s.append(
      table(
        "ledger-blocked-table",
        "Tool calls blocked today",
        ["Time", "Character", "Tool", "Source"],
        guardrails.map((g) => {
          const time = el("time", null, clock(g.at), { datetime: new Date(g.at * 1000).toISOString() });
          return [time, nameOf(g.session_id) ?? "Earlier session", g.tool_name, g.source];
        }),
      ),
    );
    return s;
  }

  function errorsSection(totals) {
    const s = section("ledger-errors", "API errors and refusals");
    s.append(figures([["API errors", fullNumber(totals.api_errors)], ["API refusals", fullNumber(totals.api_refusals)]]));
    return s;
  }

  const focusedId = () => (content.contains(document.activeElement) ? document.activeElement.id : "");
  // A control that went with a repaint (Show all) hands focus to the title, inside the dialog.
  const keepFocus = (id) => {
    if (id) (document.getElementById(id) ?? dialog.querySelector("#ledger-title")).focus();
  };

  async function refresh() {
    clearTimeout(later);
    later = 0;
    readAt = performance.now();
    readDay = new Date().toDateString();
    const mine = ++turn;
    let next;
    try {
      next = await fetchToday(filter);
    } catch (err) {
      if (mine !== turn) return;
      painted = "";
      const focused = focusedId();
      content.replaceChildren(el("p", "notice", `The ledger could not be read: ${String(err)}`, { role: "status" }));
      keepFocus(focused);
      return;
    }
    if (mine !== turn) return;
    view = next;
    paint();
  }

  /**
   * Read again a second past the next local midnight, and again each night
   * after, while the drawer is open: an idle fleet sends no snapshot, and the
   * day would read yesterday's. Not held back by REFRESH_MS.
   */
  function atMidnight() {
    clearTimeout(midnight);
    const now = new Date();
    const next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 1);
    midnight = setTimeout(() => {
      refresh();
      atMidnight();
    }, next - now);
  }

  /** Read from the start: the drawer opened, or turned to another session. */
  function start() {
    atMidnight();
    view = null;
    painted = "";
    content.replaceChildren(el("p", "none", "Reading the ledger…", { role: "status" }));
    reading = refresh();
  }

  const panel = createSidePanel({
    name: "ledger", dialog, button, tab, edge, onResized,
    // Focus goes back to what opened it, or to the Ledger button once that is gone.
    returnTo: () => (usable(opener) ? opener : button),
    onOpen: start,
    onShut: () => {
      clearTimeout(later);
      clearTimeout(midnight);
      later = 0;
      turn++; // an answer still on its way has nowhere to go
      filter = null;
      opener = null;
    },
  });

  return {
    /** Paint the last read again, in the theme now worn: a theme switch reads nothing. */
    repaint: () => paint(),
    /** Open for all sessions, or for one `session`; `from` is the button to give focus back to. */
    open(session, from) {
      filter = session ?? null;
      opener = from ?? null;
      // Shut, opening reads it (onOpen); open, it turns to the new session.
      if (panel.isOpen) start();
      panel.open();
      return reading;
    },
    /**
     * Read again if the local date moved on since the last read, while the
     * drawer is open. Timers stop while the PC sleeps, so the midnight read can
     * come late; the wall's tick and a page coming back into view catch it.
     */
    checkDay() {
      if (!panel.isOpen || new Date().toDateString() === readDay) return;
      atMidnight();
      refresh();
    },
    /**
     * Read again for a snapshot while the drawer is open: at once if the last
     * read is REFRESH_MS old, else once when it is, so a burst reads once.
     */
    refresh() {
      if (!panel.isOpen || later) return;
      const wait = readAt + REFRESH_MS - performance.now();
      if (wait <= 0) refresh();
      else later = setTimeout(refresh, wait);
    },
  };
}
