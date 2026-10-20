// WCAG 2.2 contrast, shared by the card's accent ink and the style tests.

/** Relative luminance of "#rrggbb". */
export function luminance(hex) {
  const [r, g, b] = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** "#000000" or "#ffffff", whichever reads better on `hex`. The hook computes the same choice in jq. */
export const inkOn = (hex) => (contrast(hex, "#000000") >= contrast(hex, "#ffffff") ? "#000000" : "#ffffff");
