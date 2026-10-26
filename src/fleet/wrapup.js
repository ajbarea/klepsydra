// Wrapping up: who gets the request and how, and what each card and the bar
// say while one is shown. DOM-free. ROUTES mirrors wrapup.rs route(), and
// guards.test.js parses both.
import { cardWho, inFleet, listWords, sessionCount } from "./end.js";

/** How long sessions have to answer, in seconds (wrapup.rs WINDOW). */
export const WINDOW_S = 600;

/** How a session with each status gets the request: [in klepsydra's tmux, outside it]; none once ended. */
export const ROUTES = {
  needs_you: ["after_answer", "after_answer"],
  error: ["type", "by_hand"],
  working: ["turn_end", "turn_end"],
  done: ["type", "by_hand"],
  new: ["type", "by_hand"],
  silent: ["by_hand", "by_hand"],
  ended: [null, null],
};

/** The reason of a working session whose turn is over with background work out (wrapup.rs AFTER_TURN): idle at its prompt, its Stop already run. */
export const AFTER_TURN = "background";

/** How such a session gets the request: as an idle one. */
export const AFTER_TURN_ROUTES = ["type", "by_hand"];

/** The route for `status` and `reason`, in klepsydra's tmux or not; null for an ended or unknown status. */
export const route = (status, fleet, reason = null) =>
  (status === "working" && reason === AFTER_TURN ? AFTER_TURN_ROUTES : ROUTES[status])?.[fleet ? 0 : 1] ?? null;

/** How session `s` gets the request, judged as the app judges it when it asks. */
export const sessionRoute = (s) => route(s?.status, inFleet(s), s?.reason ?? null);

/** The confirm's groups, in the order the app asks. */
export const GROUPS = [
  ["type", "Typed now"],
  ["turn_end", "At the end of its turn"],
  ["after_answer", "After you answer"],
  ["by_hand", "Ask by hand: type /klepsydra-wrapup in its terminal"],
];

const BY_HAND = "Ask by hand: /klepsydra-wrapup";

/** Whether `request` lists session `s`: only listed sessions are asked, and a request that names none lists nobody. */
export const listed = (s, request) => Array.isArray(request?.ids) && request.ids.includes(s?.session_id);

/**
 * Where session `s`'s ready answer stands, or null without one. It counts
 * ("ready") once the turn that gave it has ended (the Stop hook stamps
 * `settled_at`) and only until the session starts another turn (`turn_at`,
 * which background notifications move too, or a prompt), and never while
 * the session works or waits on AJ: "finishing" before it settles, "stale"
 * once a turn began after it, "background" while work it left out runs,
 * "waiting" while it waits on AJ with no new turn.
 */
export function readyState(s) {
  const a = s?.wrapup;
  if (a?.state !== "ready") return null;
  if (!Number.isFinite(a.settled_at)) return "finishing";
  if (s.turn_at >= a.settled_at || s.prompt?.at >= a.settled_at) return "stale";
  if (s.status === "working" && s.reason === AFTER_TURN) return "background";
  if (s.status === "needs_you") return "waiting";
  if (s.status === "working") return "stale";
  return "ready";
}

const READY_LINES = {
  ready: "Ready",
  finishing: "Finishing its turn",
  stale: "Worked since it answered; once idle, ask again: /klepsydra-wrapup",
  background: "Ready once its background work ends",
  waiting: "Ready once you answer it",
};

export const isReady = (s, request) => listed(s, request) && readyState(s) === "ready";

/**
 * What session `s`'s card says about `request` at `nowMs`: {state, text}, or
 * null with no request or once ended. Silence past `until` is "No answer",
 * never ready. The app marks every typed session asked before it types into
 * any, and unmarks one whose typing failed, unless it timed out (a timeout
 * may have typed it), so a typed route with no answer is one to ask by hand.
 */
export function wrapupLine(s, request, nowMs) {
  if (!request || s?.status === "ended") return null;
  if (!listed(s, request)) return { state: "unasked", text: "Not asked" };
  const answer = s.wrapup?.state;
  if (answer === "ready") {
    const state = readyState(s);
    return { state, text: READY_LINES[state] };
  }
  if (answer === "blocked") {
    const reason = typeof s.wrapup.reason === "string" && s.wrapup.reason.trim() ? s.wrapup.reason.trim() : null;
    return { state: "blocked", text: reason ? `Not ready: ${reason}` : "Not ready" };
  }
  if (!(nowMs <= request.until * 1000)) return { state: "none", text: "No answer" };
  // A question asked after its turn ended (a background agent's): no Stop follows the answer.
  if (s.status === "needs_you" && s.asked_after_turn) return { state: "by_hand", text: `Answer it, then ask by hand: /klepsydra-wrapup` };
  if (s.status === "needs_you") return { state: "waiting", text: "Answer it first; it wraps up after" };
  if (answer === "asked") return { state: "asked", text: "Wrapping up…" };
  if (sessionRoute(s) === "turn_end") return { state: "waiting", text: "Wraps up when this turn ends" };
  return { state: "by_hand", text: BY_HAND };
}

/** Whether the request still asks sessions at `nowMs`: Stop wrap-up shows only then. */
export const asking = (request, nowMs) => Boolean(request) && nowMs <= request.until * 1000;

/** The bar's count while a request is shown: ready live sessions of all live ones; safe only when every one, and at least one, is ready. */
export function readiness(sessions, request) {
  const live = sessions.filter((s) => s.status !== "ended");
  const ready = live.filter((s) => isReady(s, request)).length;
  return { ready, live: live.length, safe: live.length > 0 && ready === live.length, text: `${ready} of ${live.length} ready` };
}

/**
 * The Wrap up confirm's words for `cards` (model cards with a `wrapupRoute`):
 * who is asked, grouped by how. Its button counts the ones klepsydra asks;
 * the by-hand group is yours. `running`: a request is still asking, and this
 * one replaces it.
 */
export function wrapupCopy(cards, running = false) {
  const listed = cards.filter((c) => c.wrapupRoute);
  const groups = GROUPS.map(([r, heading]) => ({ heading, names: listed.filter((c) => c.wrapupRoute === r).map(cardWho) })).filter(
    (g) => g.names.length,
  );
  const count = listed.filter((c) => c.wrapupRoute !== "by_hand").length;
  return {
    title: running ? "Start the wrap-up over?" : "Ask every session to wrap up?",
    text: `Each one finishes or checkpoints its current step, records what is still running, updates its handoff and commits it, then says whether it is safe to stop. Each card shows its answer, or "No answer" after ${WINDOW_S / 60} minutes.`,
    groups,
    warn: running
      ? "A wrap-up is still asking. Starting over clears every answer so far, and sessions that already answered are asked again."
      : null,
    confirm: running ? (count ? `Start over: ask ${sessionCount(count)}` : "Start over") : count ? `Ask ${sessionCount(count)}` : "Start wrap-up",
    cancel: "Cancel",
    count,
  };
}

/**
 * The bar's note once start_wrapup answers with `asked` ({id, route, error,
 * typed}): the sessions typed into now, those already asked or answered,
 * those asked when their turn ends, those left to ask by hand, and by name
 * (`nameOf(id)`) each one whose typing failed.
 */
export function askedNote(asked, nameOf) {
  const typed = asked.filter((a) => a.typed).length;
  const already = asked.filter((a) => a.route === "type" && !a.typed && !a.error).length;
  const later = asked.filter((a) => a.route === "turn_end" || a.route === "after_answer").length;
  const hand = asked.filter((a) => a.route === "by_hand").length;
  const failed = asked.filter((a) => a.error);
  const names = failed.map((a) => nameOf(a.id) ?? "a session");
  return [
    `Typed into ${sessionCount(typed)}`,
    already && `${already} already asked`,
    later && `${later} asked when ${later === 1 ? "its turn ends" : "their turn ends"}`,
    hand && `${hand} to ask by hand`,
    failed.length && `not typed into ${listWords(names)}, see ${failed.length === 1 ? "its card" : "their cards"}`,
  ]
    .filter(Boolean)
    .join("; ");
}

/** Each card's wrap-up line by id, for the next look's `wrapupAnnouncements`. */
export const wrapupLines = (cards) => new Map(cards.filter((c) => c.wrapup).map((c) => [c.id, c.wrapup.text]));

/**
 * What the live region says for the wrap-up lines that changed since `before`
 * (id -> text, cards with a line only). Nothing on the first look or when a
 * request first appears: the Wrap up button's note says that.
 */
export function wrapupAnnouncements(before, cards) {
  if (!before?.size) return [];
  return cards.filter((c) => c.wrapup && before.get(c.id) !== c.wrapup.text).map((c) => `${c.name}: ${c.wrapup.text}`);
}
