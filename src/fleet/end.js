// Ending a session from its card. DOM-free: which cards offer it, the words of
// the confirm step, and the undo window. The only call that ends a session is
// `expire`, run by the timer that Confirm starts; nothing a click or a key
// does reaches it sooner (guards.test.js scans for that).

/** How long a confirmed End waits, with Undo on the card, before anything is sent. */
export const UNDO_MS = 5000;
const SECOND_MS = 1000;
/** How long the dialog's End stays off after it opens, so the second click of a double-click lands on nothing (twice Windows' default double-click time). */
export const ARM_MS = 1000;

/** The tmux socket's name under which the launcher keeps its sessions (launch.rs FLEET_SOCKET). */
export const FLEET_SOCKET = "klepsydra";

/** Whether session `s` runs in klepsydra's tmux with a known Claude process: the panes the launcher types into. */
export function inFleet(s) {
  const uint = (n, max) => Number.isInteger(n) && n >= 0 && n <= max;
  const str = (v) => typeof v === "string";
  // launch::target() needs these, and pane_args() refuses a zero pid.
  const named = str(s?.tmux?.socket) && str(s?.tmux?.pane) && str(s?.distro);
  const known = uint(s?.claude?.pid, 0xffff_ffff) && s.claude.pid > 0 && uint(s?.claude?.start, Number.MAX_SAFE_INTEGER);
  return named && known && s.tmux.socket.split("/").pop() === FLEET_SOCKET;
}

/**
 * What a card's actions menu offers. The menu exists only for a live session in
 * klepsydra's tmux whose Claude process is known (the launcher refuses the rest);
 * Interrupt only while it works.
 */
export function sessionActions(s) {
  const menu = s?.status !== "ended" && inFleet(s);
  return { menu, interrupt: menu && s.status === "working" };
}

/** A card as a confirm lists it: the character, and the repo when known. */
export const cardWho = (c) => (c.place?.repo ? `${c.name} in ${c.place.repo}` : c.name);

/** "1 session", "3 sessions". */
export const sessionCount = (n) => `${n} session${n === 1 ? "" : "s"}`;

/** "a", "a and b", "a, b and c". */
export const listWords = (xs) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs.at(-1)}`);

/** The confirm dialog's words for card `c` (a model card: name, place, status). */
export function confirmCopy(c) {
  const extra = [c.place?.worktree && `worktree ${c.place.worktree}`, c.place?.branch && `branch ${c.place.branch}`].filter(Boolean);
  const where = c.place?.repo ? ` in ${c.place.repo}${extra.length ? ` (${extra.join(", ")})` : ""}` : "";
  return {
    title: `End ${c.name}'s session?`,
    text: `This ends ${c.name}'s Claude session${where}, as if you typed /exit in its terminal. Any unsent text in its prompt is dropped; the conversation can be resumed later.`,
    warn: c.status === "working" ? "It is mid-turn: the turn stops and its unfinished work is lost." : null,
    confirm: `End ${c.name}`,
    cancel: "Cancel",
  };
}

/**
 * The confirm's words for ending every card in `cards` at once (model cards),
 * each through its own undo window. `outside` counts the ready sessions that
 * klepsydra cannot end, which are not listed.
 */
export function endAllCopy(cards, outside = 0) {
  const n = cards.length;
  const busy = cards.filter((c) => c.status === "working").map((c) => c.name);
  const rest = outside ? ` Not listed: ${sessionCount(outside)} outside klepsydra's tmux, which you end from ${outside === 1 ? "its own terminal" : "their own terminals"}.` : "";
  return {
    title: `End ${sessionCount(n)}?`,
    text: `This ends each session below, as if you typed /exit in its terminal. Each card counts down ${UNDO_MS / SECOND_MS} s with its own Undo before anything is sent.${rest}`,
    groups: [{ heading: null, names: cards.map(cardWho) }],
    warn: busy.length ? `${listWords(busy)} ${busy.length === 1 ? "is" : "are"} mid-turn: the turn stops and its unfinished work is lost.` : null,
    confirm: `End ${sessionCount(n)}`,
    cancel: "Cancel",
  };
}

/** The card's line while the undo window runs. */
export const endingText = (name, secondsLeft) => `Ending ${name} in ${secondsLeft} s`;

/** The card's note when End all ready withdraws its end: the session is no longer ready. */
export const withdrawnText = (name) => `${name} is no longer ready; not ended`;

/** Said once, when the window opens: a live region that is not re-announced each second. */
export const endingAnnouncement = (name) => `Ending ${name} in ${UNDO_MS / SECOND_MS} seconds. Undo is available.`;

/**
 * The pending ends, one per card. `start` opens the undo window; `undo` and
 * `cancel` close it with no call; when it runs out `expire` calls `invoke`.
 * `timers` and `invoke` are injected for tests.
 */
export function createEnder({ invoke, timers = { setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (t) => clearTimeout(t) } }) {
  const pending = new Map(); // id -> { timers }

  // The end stays pending until the call answers: no second end and no menu meanwhile.
  // A bulk end whose condition no longer holds sends nothing.
  function expire(id, { onSend, onDone }) {
    const entry = pending.get(id);
    if (entry.holds && !entry.holds()) {
      pending.delete(id);
      entry.onSkip?.();
      return Promise.resolve();
    }
    entry.sent = true;
    onSend?.();
    const settle = (result) => {
      pending.delete(id);
      onDone(result);
    };
    return Promise.resolve()
      .then(() => invoke("end_session", { id }))
      .then((text) => settle({ ok: true, text }), (err) => settle({ ok: false, text: String(err) }));
  }

  return {
    pending: (id) => pending.has(id),
    /**
     * Open the undo window for `id`; false when one is already open. `onTick(secondsLeft)` runs now and each second; `onSend()` as the call goes out, `onDone({ok, text})` once it answers; the end is pending until then.
     * `holds()`, when given, is asked again as the window runs out: false sends nothing and calls `onSkip()` instead.
     */
    start(id, { onTick, onSend, onDone, holds, onSkip }) {
      if (pending.has(id)) return false;
      const seconds = UNDO_MS / SECOND_MS;
      // Every second's timer is set now, so a late tick cannot push the end past UNDO_MS.
      const entry = { timers: [], holds, onSkip };
      pending.set(id, entry);
      onTick(seconds);
      for (let n = 1; n < seconds; n++) entry.timers.push(timers.setTimeout(() => onTick(seconds - n), n * SECOND_MS));
      entry.timers.push(timers.setTimeout(() => expire(id, { onSend, onDone }), UNDO_MS));
      return true;
    },
    /** Close the window with no call; false when none was open. */
    cancel(id) {
      const entry = pending.get(id);
      if (!entry || entry.sent) return false;
      for (const t of entry.timers) timers.clearTimeout(t);
      pending.delete(id);
      return true;
    },
    /** Whether `id`'s end, if any, still meets the condition it was started on. */
    holds: (id) => !pending.get(id)?.holds || Boolean(pending.get(id).holds()),
    /** The ends still inside their window; one already sent is past cancelling. */
    ids: () => [...pending].filter(([, e]) => !e.sent).map(([id]) => id),
  };
}
