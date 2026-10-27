// A card's Full text, on the phone wall. A pointer reads a cut-short line in
// its title on hover; a touch screen cannot, so a card that cuts text short
// shows a disclosure that unfolds it in place. It changes only what the card
// shows and reaches no session.

/** What a card cuts short: a line with an ellipsis, or a line clamp. wall.css unfolds each under `.open-text`. */
export const CUT = [".task", ".repo", ".branch span", ".ask .text > span", ".said p", ".wrapup"];

/** The "+N" chips, which name their repos only in a title and to screen readers. */
export const CHIPS = [".also-more", ".also-rest"];

/** Whether a box holds more than it shows. */
export const overflows = (box) => box.scrollWidth > box.clientWidth || box.scrollHeight > box.clientHeight;

/** Whether `card` cuts any text short; `shown(el)` says whether el is drawn. */
export const cutsText = (card, shown) =>
  [...card.querySelectorAll(CHIPS.join(", "))].some(shown) ||
  [...card.querySelectorAll(CUT.join(", "))].some((el) => shown(el) && overflows(el));
