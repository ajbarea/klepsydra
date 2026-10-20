// The wall's card density: Comfortable (the full card), Compact (three short
// rows, so eight cards fit half a 1920x1080 screen), or Auto, the default,
// which picks between them. Kept free of the DOM so it can be unit tested.

/** The choices, as saved in prefs.json under `wall_density`. */
export const DENSITIES = ["auto", "comfortable", "compact"];

/** A saved choice, or Auto for anything else (no file yet, an old or hand-edited value). */
export const parseDensity = (value) => (DENSITIES.includes(value) ? value : "auto");

// Auto turns compact as soon as the comfortable grid would scroll, so no card
// is ever below the fold. It turns back only once the comfortable grid would
// still fit with this many more cards, as tall as its tallest. Rows hold
// whole cards, so a margin in pixels would not help: one card ending and the
// next starting at the boundary would flip the whole wall twice.
export const RETURN_SPARE_CARDS = 1;

/**
 * The density Auto shows next. `shown` is the density on screen now;
 * `fits(extra)` says whether the comfortable grid, with `extra` more cards,
 * fits the window without scrolling.
 */
export function autoDensity(shown, fits) {
  if (shown === "compact") return fits(RETURN_SPARE_CARDS) ? "comfortable" : "compact";
  return fits(0) ? "comfortable" : "compact";
}

/** The density to show for a saved `choice`: Auto decides, either other is shown as chosen. */
export const resolveDensity = (choice, shown, fits) =>
  parseDensity(choice) === "auto" ? autoDensity(shown, fits) : parseDensity(choice);
