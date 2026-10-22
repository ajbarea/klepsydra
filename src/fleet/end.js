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

/**
 * What a card's actions menu offers. The menu exists only for a live session in
 * klepsydra's tmux whose Claude process is known (the launcher refuses the rest);
 * Interrupt only while it works.
 */
export function sessionActions(s) {
  const uint = (n, max) => Number.isInteger(n) && n >= 0 && n <= max;
  const str = (v) => typeof v === "string";
  // launch::target() needs these, and pane_args() refuses a zero pid.
  const named = str(s?.tmux?.socket) && str(s?.tmux?.pane) && str(s?.distro);
  const known = uint(s?.claude?.pid, 0xffff_ffff) && s.claude.pid > 0 && uint(s?.claude?.start, Number.MAX_SAFE_INTEGER);
  const fleet = named && s.tmux.socket.split("/").pop() === FLEET_SOCKET;
  const menu = s?.status !== "ended" && fleet && known;
  return { menu, interrupt: menu && s.status === "working" };
}

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

/** The card's line while the undo window runs. */
export const endingText = (name, secondsLeft) => `Ending ${name} in ${secondsLeft} s`;

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
  function expire(id, { onSend, onDone }) {
    pending.get(id).sent = true;
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
    /** Open the undo window for `id`; false when one is already open. `onTick(secondsLeft)` runs now and each second; `onSend()` as the call goes out, `onDone({ok, text})` once it answers; the end is pending until then. */
    start(id, { onTick, onSend, onDone }) {
      if (pending.has(id)) return false;
      const seconds = UNDO_MS / SECOND_MS;
      // Every second's timer is set now, so a late tick cannot push the end past UNDO_MS.
      const entry = { timers: [] };
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
    /** The ends still inside their window; one already sent is past cancelling. */
    ids: () => [...pending].filter(([, e]) => !e.sent).map(([id]) => id),
  };
}
