// The face of a session whose voice has no kourai character: a forge
// medallion, a dark bronze disc in a gold laurel ring around one serif
// initial, in kourai-khryseai's gold (#C9944A, highlight #F1D2A1, shadow
// #AA771C). One template drawn in a 96-unit viewBox, so the strip's 28 px
// and the wall's 66 px are the same drawing scaled.

const C = 48; // centre of the viewBox
const LAUREL_R = 36;

// A leaf in local coordinates, tip up.
const LEAF = "M0 0C2.9-2.6 3.3-6.2 0-10.4C-3.3-6.2-2.9-2.6 0 0Z";

const r1 = (n) => Math.round(n * 10) / 10;
const onRing = (deg, r = LAUREL_R) => {
  const t = (deg * Math.PI) / 180;
  return [C + r * Math.sin(t), C - r * Math.cos(t)];
};
/** A leaf at `deg` clockwise from the top, its tip turned `tilt` degrees off the branch toward the top. */
const leaf = (deg, tilt, mirror) => {
  const [x, y] = onRing(deg);
  const turn = deg - 90 + tilt; // along the branch toward the top; a positive tilt leans out
  return `<path d="${LEAF}" transform="translate(${r1(mirror ? 2 * C - x : x)} ${r1(y)}) rotate(${r1(mirror ? -turn : turn)})"/>`;
};

/** One branch, from the tie at the bottom up the right side; the left is its mirror. */
function branch(mirror) {
  const leaves = [];
  for (let deg = 162; deg >= 66; deg -= 16) leaves.push(leaf(deg, 38, mirror), leaf(deg - 6, -38, mirror));
  leaves.push(leaf(52, 0, mirror));
  const [x0, y0] = onRing(168);
  const [x1, y1] = onRing(54);
  const sx = (x) => r1(mirror ? 2 * C - x : x);
  const stem = `<path fill="none" stroke="#aa771c" stroke-width="1.3" d="M${sx(x0)} ${r1(y0)}A${LAUREL_R} ${LAUREL_R} 0 0 ${mirror ? 1 : 0} ${sx(x1)} ${r1(y1)}"/>`;
  return stem + leaves.join("");
}

// Exported for the contrast test, which reads the stops back out of the markup.
export const DISC = ["#3a2818", "#2a1f16", "#161311"];
export const INK = ["#f1d2a1", "#c9944a"];

const HEAD =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">'
  + "<defs>"
  + `<radialGradient id="disc" cx="40" cy="36" r="62" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${DISC[0]}"/><stop offset=".62" stop-color="${DISC[1]}"/><stop offset="1" stop-color="${DISC[2]}"/></radialGradient>`
  + '<linearGradient id="gold" x1="0" y1="8" x2="0" y2="88" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#f1d2a1"/><stop offset=".28" stop-color="#c9944a"/><stop offset="1" stop-color="#aa771c"/></linearGradient>'
  + `<linearGradient id="ink" x1="0" y1="30" x2="0" y2="66" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${INK[0]}"/><stop offset="1" stop-color="${INK[1]}"/></linearGradient>`
  + '<radialGradient id="glow" cx="48" cy="48" r="48" gradientUnits="userSpaceOnUse"><stop offset=".7" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".45"/></radialGradient>'
  + '<filter id="lift" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="1.2" stdDeviation=".8" flood-color="#000" flood-opacity=".6"/></filter>'
  + "</defs>"
  + '<circle cx="48" cy="48" r="48" fill="url(#disc)"/>'
  + '<circle cx="48" cy="48" r="48" fill="url(#glow)"/>'
  + '<circle cx="48" cy="48" r="45.6" fill="none" stroke="#aa771c" stroke-width="1.6"/>'
  + '<circle cx="48" cy="48" r="43.4" fill="none" stroke="#c9944a" stroke-width=".6" stroke-opacity=".7"/>'
  + `<g fill="url(#gold)" stroke="#5c3d12" stroke-width=".35" filter="url(#lift)">${branch(false)}${branch(true)}`
  + `<circle cx="48" cy="${r1(C + LAUREL_R + 1)}" r="2.2"/></g>`;
const TAIL = "</svg>";
const letterSvg = (letter) =>
  `<text x="48" y="49" text-anchor="middle" dominant-baseline="central" font-family="'Palatino Linotype',Palatino,P052,'Book Antiqua',Georgia,'DejaVu Serif',serif" font-size="44" font-weight="600" fill="url(#ink)" filter="url(#lift)" stroke="#1a1209" stroke-width="1.4" paint-order="stroke">${letter}</text>`;

/** The one character the medallion may show: the name's first, upper-cased, if it is A-Z or 0-9; else "". */
export function initialOf(name) {
  const first = typeof name === "string" ? name.charAt(0).toUpperCase() : "";
  return /^[A-Z0-9]$/.test(first) ? first : "";
}

/** The medallion's SVG markup for `name`: its initial, or the laurel alone. */
export const medallionSvg = (name) => {
  const letter = initialOf(name);
  return HEAD + (letter ? letterSvg(letter) : "") + TAIL;
};

const urls = new Map();
/** The medallion for `name` as a data URL, built once per initial. */
export function medallion(name) {
  const letter = initialOf(name);
  if (!urls.has(letter)) urls.set(letter, `data:image/svg+xml,${encodeURIComponent(medallionSvg(letter))}`);
  return urls.get(letter);
}
