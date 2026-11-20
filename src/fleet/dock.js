// The gauges docked in the wall's header (#421, AJ's pick on #459): the
// floating strip's chips, drawn by the strip's own code from the same rows,
// between the tally and the tools. The chevron hides them and the gear's
// "Gauges in wall header" brings them back. The choice is prefs.json's
// `gauges_in_header` (klepsydra_fleet::toggles), saved with set_gauge_toggle
// and pushed by toggles_subscribe. The phone is read-only (no gear, no
// buttons but its own), so there the gauges always show, opening the page
// under its sticky tally (wall.js).
import { WAITING } from "../gauge.js";
import { toChips } from "./chips.js";
import { syncChips } from "./chipview.js";

/** prefs.json's key. */
export const DOCK_KEY = "gauges_in_header";

/** How often the wall reads usage while its header shows the gauges: the floating strip's pace. */
export const DOCK_USAGE_MS = 5_000;

/** The saved choice in a toggles message: on unless it says false. */
export const dockOn = (message) => message?.[DOCK_KEY] !== false;

/**
 * Wire the dock. `els`: { dock, chips, wait, hide, pick, gear }; `invoke` and
 * `follow` are the app's (unused on the phone); `look()` gives { stops, mode }
 * for the ramp; `onChange(on)` runs after the choice changes, so the wall can
 * read usage at the dock's pace.
 * Returns paint(rows, now): rows from toRows, or null when there is no
 * usage source (the dock then stays hidden).
 */
export function wireDock({ els, inTauri, invoke, follow, log, look, onChange = () => {} }) {
  let on = true;
  let heard = null; // the saved choice, as the app last pushed it
  let pending = 0; // saves not yet answered
  let rows = null;
  let at = Date.now();

  function paint(nextRows = rows, now = at) {
    rows = nextRows;
    at = now;
    els.pick.checked = on;
    els.dock.hidden = !on || rows === null;
    if (els.dock.hidden) return;
    // With no reading at all the dock waits; the Copilot placeholder alone is not a reading.
    const chips = rows.length ? toChips(rows, now) : [];
    els.wait.hidden = chips.length > 0;
    if (els.wait.textContent !== WAITING) els.wait.textContent = WAITING; // a same-text write still replaces the node
    syncChips(els.chips, chips, { now, layout: "linear", ...look() });
  }

  function wear(next) {
    const changed = next !== on;
    on = next;
    paint();
    if (changed) onChange(on);
  }

  function choose(next) {
    pending += 1;
    wear(next);
    invoke("set_gauge_toggle", { key: DOCK_KEY, on: next }).then(
      () => {
        pending -= 1;
      },
      (err) => {
        pending -= 1;
        log.warn(`the header gauges could not be turned ${next ? "on" : "off"}, so they keep the saved choice`, err);
        if (pending === 0 && heard !== null) wear(heard);
      },
    );
  }

  if (!inTauri) return { paint, isOn: () => on };
  follow("toggles_subscribe", (message) => {
    heard = dockOn(message);
    if (pending === 0) wear(heard);
  }).catch((err) => log.warn("toggles_subscribe failed, so the header gauges stay on", err));

  els.pick.addEventListener("change", () => choose(els.pick.checked));
  els.hide.addEventListener("click", () => {
    choose(false);
    // The chevron leaves with the dock: focus goes to the gear, which brings it back.
    els.gear.focus();
  });

  return { paint, isOn: () => on };
}
