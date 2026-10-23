// Wrapping up: who gets the request and how, and what each card and the bar
// say while one is shown. DOM-free. ROUTES mirrors wrapup.rs route(), and
// guards.test.js parses both.
import { cardWho, inFleet, sessionCount } from "./end.js";

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

/** The route for `status`, in klepsydra's tmux or not; null for an ended or unknown status. */
export const route = (status, fleet) => ROUTES[status]?.[fleet ? 0 : 1] ?? null;

/** How session `s` gets the request, judged as the app judges it when it asks. */
export const sessionRoute = (s) => route(s?.status, inFleet(s));

/** The confirm's groups, in the order the app asks. */
export const GROUPS = [
  ["type", "Typed now"],
  ["turn_end", "At the end of its turn"],
  ["after_answer", "After you answer"],
  ["by_hand", "Ask by hand: type /klepsydra-wrapup in its terminal"],
];

const BY_HAND = "Ask by hand: /klepsydra-wrapup";

/**
 * What session `s`'s card says about `request` at `nowMs`: {state, text}, or
 * null with no request or once ended. Silence past `until` is "No answer",
 * never ready. A typed route with no answer is one whose typing failed.
 */
export function wrapupLine(s, request, nowMs) {
  if (!request || s?.status === "ended") return null;
  const answer = s.wrapup?.state;
  if (answer === "ready") return { state: "ready", text: "Ready" };
  if (answer === "blocked") {
    const reason = typeof s.wrapup.reason === "string" && s.wrapup.reason.trim() ? s.wrapup.reason.trim() : null;
    return { state: "blocked", text: reason ? `Not ready: ${reason}` : "Not ready" };
  }
  if (!(nowMs <= request.until * 1000)) return { state: "none", text: "No answer" };
  if (s.status === "needs_you") return { state: "waiting", text: "Answer it first; it wraps up after" };
  if (answer === "asked") return { state: "asked", text: "Wrapping up…" };
  if (sessionRoute(s) === "turn_end") return { state: "waiting", text: "Wraps up when this turn ends" };
  return { state: "by_hand", text: BY_HAND };
}

/** Whether the request still asks sessions at `nowMs`: Stop wrap-up shows only then. */
export const asking = (request, nowMs) => Boolean(request) && nowMs <= request.until * 1000;

/** The bar's count while a request is shown: ready live sessions of all live ones; safe only when every one, and at least one, is ready. */
export function readiness(sessions) {
  const live = sessions.filter((s) => s.status !== "ended");
  const ready = live.filter((s) => s.wrapup?.state === "ready").length;
  return { ready, live: live.length, safe: live.length > 0 && ready === live.length, text: `${ready} of ${live.length} ready` };
}

/**
 * The Wrap up confirm's words for `cards` (model cards with a `wrapupRoute`):
 * who is asked, grouped by how. Its button counts the ones klepsydra asks;
 * the by-hand group is yours.
 */
export function wrapupCopy(cards) {
  const listed = cards.filter((c) => c.wrapupRoute);
  const groups = GROUPS.map(([r, heading]) => ({ heading, names: listed.filter((c) => c.wrapupRoute === r).map(cardWho) })).filter(
    (g) => g.names.length,
  );
  const count = listed.filter((c) => c.wrapupRoute !== "by_hand").length;
  return {
    title: "Ask every session to wrap up?",
    text: `Each one finishes or checkpoints its current step, records what is still running, updates its handoff, commits and pushes, then says whether it is safe to stop. Each card shows its answer, or "No answer" after ${WINDOW_S / 60} minutes.`,
    groups,
    warn: null,
    confirm: count ? `Ask ${sessionCount(count)}` : "Start wrap-up",
    cancel: "Cancel",
    count,
  };
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
