// The face of a session whose voice has no kourai character: a forge
// medallion, a dark disc in a metal laurel ring around one serif initial.
// Each identity is struck in one of six kourai metals, from kourai-khryseai's
// gold (#C9944A, highlight #F1D2A1, shadow #AA771C) to a verdigris bronze, so
// two voices with one initial still differ. One template drawn in a 96-unit
// viewBox, so the strip's 28 px and the wall's 66 px are the same drawing.

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
function branch(mirror, stemColour) {
  const leaves = [];
  for (let deg = 162; deg >= 66; deg -= 16) leaves.push(leaf(deg, 38, mirror), leaf(deg - 6, -38, mirror));
  leaves.push(leaf(52, 0, mirror));
  const [x0, y0] = onRing(168);
  const [x1, y1] = onRing(54);
  const sx = (x) => r1(mirror ? 2 * C - x : x);
  const stem = `<path fill="none" stroke="${stemColour}" stroke-width="1.3" d="M${sx(x0)} ${r1(y0)}A${LAUREL_R} ${LAUREL_R} 0 0 ${mirror ? 1 : 0} ${sx(x1)} ${r1(y1)}"/>`;
  return stem + leaves.join("");
}

/**
 * The metals, each a disc (centre, middle, edge), a laurel (highlight, body,
 * shadow) and an initial (top, bottom). The disc's centre is its lightest
 * colour; the contrast test holds every initial to 4.5:1 against every stop.
 */
export const TONES = [
  { name: "gold", disc: ["#3a2818", "#2a1f16", "#161311"], laurel: ["#f1d2a1", "#c9944a", "#aa771c"], ink: ["#f1d2a1", "#c9944a"] },
  { name: "bronze", disc: ["#2e2618", "#221c13", "#12100d"], laurel: ["#d6b27c", "#977035", "#5a421d"], ink: ["#e6c99c", "#bb9460"] },
  { name: "copper", disc: ["#3e1d12", "#2b150e", "#160f0c"], laurel: ["#f7b48c", "#d4642e", "#8a3414"], ink: ["#f9c3a2", "#e78457"] },
  { name: "rose gold", disc: ["#3a1f2a", "#2a171f", "#151013"], laurel: ["#f7c9cf", "#d98d98", "#94505d"], ink: ["#f9d5da", "#e3a3ad"] },
  { name: "pale gold", disc: ["#2d2c28", "#1f1e1c", "#111111"], laurel: ["#f6f1e0", "#cdc6ad", "#8a8470"], ink: ["#f6f1e0", "#d2cbb2"] },
  { name: "verdigris", disc: ["#1a2d27", "#13211d", "#0e1311"], laurel: ["#c6ead6", "#5fae8c", "#2f6650"], ink: ["#d2efdf", "#86c9a8"] },
];

/** FNV-1a over UTF-16 code units: a stable hash for picking a tone. */
export function hash(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

/** The tone index for an identity key: the voice label, else the session id. */
export const toneOf = (key) => hash(String(key ?? "")) % TONES.length;

const stops = (offsets, colours) => colours.map((c, i) => `<stop offset="${offsets[i]}" stop-color="${c}"/>`).join("");
const laurelRing = (stemColour) =>
  `${branch(false, stemColour)}${branch(true, stemColour)}<circle cx="48" cy="${r1(C + LAUREL_R + 1)}" r="2.2"/>`;
const headOf = ({ disc, laurel, ink }) =>
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">'
  + "<defs>"
  + `<radialGradient id="disc" cx="40" cy="36" r="62" gradientUnits="userSpaceOnUse">${stops([0, 0.62, 1], disc)}</radialGradient>`
  + `<linearGradient id="metal" x1="0" y1="8" x2="0" y2="88" gradientUnits="userSpaceOnUse">${stops([0, 0.28, 1], laurel)}</linearGradient>`
  + `<linearGradient id="ink" x1="0" y1="30" x2="0" y2="66" gradientUnits="userSpaceOnUse">${stops([0, 1], ink)}</linearGradient>`
  + '<radialGradient id="glow" cx="48" cy="48" r="48" gradientUnits="userSpaceOnUse"><stop offset=".7" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".45"/></radialGradient>'
  + '<filter id="lift" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="1.2" stdDeviation=".8" flood-color="#000" flood-opacity=".6"/></filter>'
  + "</defs>"
  + '<circle cx="48" cy="48" r="48" fill="url(#disc)"/>'
  + '<circle cx="48" cy="48" r="48" fill="url(#glow)"/>'
  + `<circle cx="48" cy="48" r="45.6" fill="none" stroke="${laurel[2]}" stroke-width="1.6"/>`
  + `<circle cx="48" cy="48" r="43.4" fill="none" stroke="${laurel[1]}" stroke-width=".6" stroke-opacity=".7"/>`
  + `<g fill="url(#metal)" stroke="#000" stroke-opacity=".4" stroke-width=".35" filter="url(#lift)">${laurelRing(laurel[2])}</g>`;
const HEADS = TONES.map(headOf);
const TAIL = "</svg>";
const letterSvg = (letter, { disc }) =>
  `<text x="48" y="49" text-anchor="middle" dominant-baseline="central" font-family="'Palatino Linotype',Palatino,P052,'Book Antiqua',Georgia,'DejaVu Serif',serif" font-size="44" font-weight="600" fill="url(#ink)" filter="url(#lift)" stroke="${disc[2]}" stroke-width="1.4" paint-order="stroke">${letter}</text>`;

/** The one character the medallion may show: the name's first, upper-cased, if it is A-Z or 0-9; else "". */
export function initialOf(name) {
  const first = typeof name === "string" ? name.charAt(0).toUpperCase() : "";
  return /^[A-Z0-9]$/.test(first) ? first : "";
}

/** The medallion's SVG markup for `name` in tone `tone`: its initial, or the laurel alone. */
export function medallionSvg(name, tone = 0) {
  const t = TONES[tone] ? tone : 0;
  const letter = initialOf(name);
  return HEADS[t] + (letter ? letterSvg(letter, TONES[t]) : "") + TAIL;
}

const urls = new Map();
/** The medallion for `name`, toned by `key` (the voice label, else the session id), as a data URL built once per initial and tone. */
export function medallion(name, key) {
  const letter = initialOf(name);
  const tone = toneOf(key);
  const id = `${letter}|${tone}`;
  if (!urls.has(id)) urls.set(id, `data:image/svg+xml,${encodeURIComponent(medallionSvg(letter, tone))}`);
  return urls.get(id);
}
