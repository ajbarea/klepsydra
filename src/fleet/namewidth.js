// A compact card's name keeps its own width, up to 90 px, before the pill
// takes room from it (#535). CSS reads a text's width only through
// calc-size(), which Chromium has and WebKit and Gecko lack, so the wall sets
// each card's name width as --name-w and wall.css floors the name's column
// with it, the same in every engine.

/** A measurer of a text's laid-out width in CSS px, whole even where an ellipsis cuts it. */
export const rangeWidth = () => {
  const range = document.createRange();
  return (el) => {
    range.selectNodeContents(el);
    return range.getBoundingClientRect().width;
  };
};

const nameText = (card) => card.querySelector(".name")?.textContent ?? "";

/**
 * Sets --name-w on each card whose name's text, or `face` (what else sizes
 * its glyphs: the density, a font that loaded), changed since it was last
 * measured; `measured` (a WeakMap) remembers what each card was measured at.
 * Reads every width before writing any, so the wall lays out once. A name
 * measured at 0 px is not drawn yet and waits for the next pass; a card with
 * no name has no floor. Returns how many cards it changed.
 */
export function syncNameWidths(cards, face, measured, measure) {
  const stale = cards.filter((card) => {
    const was = measured.get(card);
    return !was || was.text !== nameText(card) || was.face !== face;
  });
  if (!stale.length) return 0;
  const width = measure ?? rangeWidth();
  const widths = stale.map((card) => (nameText(card) ? Math.ceil(width(card.querySelector(".name"))) : 0));
  let changed = 0;
  stale.forEach((card, i) => {
    const text = nameText(card);
    if (text && !(widths[i] > 0)) return;
    if (text) card.style.setProperty("--name-w", `${widths[i]}px`);
    else card.style.removeProperty("--name-w");
    measured.set(card, { text, face });
    changed++;
  });
  return changed;
}
