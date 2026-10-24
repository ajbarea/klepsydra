// The wall with nothing running: Hesychia's empty state, its start button and,
// while only ended cards remain, a link that clears them.

export const START = "Start a session";

/** "empty" with no sessions, "ended" when every one has ended, else "cards". */
export function wallState(sessions) {
  if (sessions.length === 0) return "empty";
  return sessions.every((s) => s.status === "ended") ? "ended" : "cards";
}

/** The ended sessions' ids, in the reader's order. */
export const endedIds = (sessions) => sessions.filter((s) => s.status === "ended").map((s) => s.session_id);

/** The start button's label: the launch folder when known. */
export const startLabel = (dir) => (typeof dir === "string" && dir.trim() ? `${START} in ${dir}` : START);

export const clearLabel = (n) => `Clear ${n} ended session${n === 1 ? "" : "s"}`;

/**
 * Clear each id with clear_session. Resolves to the note to show: empty when
 * every one cleared (the next snapshot takes the cards away), else how many
 * were left and the first reason.
 */
export async function clearAll(ids, invoke) {
  const results = await Promise.allSettled(ids.map((id) => invoke("clear_session", { id })));
  const failed = results.filter((r) => r.status === "rejected");
  return failed.length ? `${failed.length} of ${ids.length} not cleared: ${failed[0].reason}` : "";
}
