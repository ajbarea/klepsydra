// The ramp the chips colour their pips with, read from the page's tokens
// (fleet/chips.css), for the floating strip (main.js) and the wall's header.

/** The ramp's stops, from the --ramp-* tokens on `root`. */
export function readStops(root = document.documentElement) {
  const s = getComputedStyle(root);
  return {
    low: s.getPropertyValue("--ramp-low"),
    mid: s.getPropertyValue("--ramp-mid"),
    high: s.getPropertyValue("--ramp-high"),
    midAt: parseFloat(s.getPropertyValue("--ramp-mid-at")),
    highAt: parseFloat(s.getPropertyValue("--ramp-high-at")),
  };
}

/** --ramp-mode on `root`, unless `query` names one. */
export function readMode(root = document.documentElement, query = null) {
  return query || getComputedStyle(root).getPropertyValue("--ramp-mode").trim();
}
