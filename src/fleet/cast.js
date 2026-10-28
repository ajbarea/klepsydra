// Who a keryx voice is in a character theme (themes/<id>.json, the cast),
// read the same way by the wall's cards, the strip and the ledger drawer.

/** `obj[key]` when `obj` is a plain object holding `key` itself; else undefined. */
export const ownValue = (obj, key) =>
  obj !== null && typeof obj === "object" && !Array.isArray(obj) && typeof key === "string" && Object.hasOwn(obj, key)
    ? obj[key]
    : undefined;

/** `voice`'s character in `cast`: an object with a name, held by the cast itself; else null. */
export function castCharacter(voice, cast) {
  const c = typeof voice === "string" && voice ? ownValue(cast?.characters, voice) : undefined;
  return c !== null && typeof c === "object" && typeof c.name === "string" && c.name ? c : null;
}

const FACES = "fleet/faces";
// A theme's faces folder and a character's face are path segments: lower-case letters, digits and "-".
const SEGMENT = /^[a-z0-9][a-z0-9-]*$/;

/**
 * Where `character`'s face files start in `cast`'s faces folder
 * ("fleet/faces/kourai/hermes"), to which "-96.webp", "-192.webp",
 * "-full.webp" and "-figure.webp" are added; null when the folder or the face
 * is not a plain path segment.
 */
export function castFiles(character, cast) {
  const dir = cast?.faces;
  const face = character?.face;
  return typeof dir === "string" && SEGMENT.test(dir) && typeof face === "string" && SEGMENT.test(face) ? `${FACES}/${dir}/${face}` : null;
}

/** A character's accent when it is a #rrggbb colour; else null. */
export const castAccent = (character) =>
  typeof character?.accent === "string" && /^#[0-9a-f]{6}$/i.test(character.accent) ? character.accent : null;

/** "am_fenrir" is "Fenrir"; a blend "af_bella(0.7)+af_heart(0.3)" is "Bella and Heart". */
export function voiceName(voice) {
  return String(voice)
    .split("+")
    .map((part) => {
      const label = part.replace(/\(.*$/, "").trim();
      const name = label.includes("_") ? label.slice(label.indexOf("_") + 1) : label;
      return name.charAt(0).toUpperCase() + name.slice(1);
    })
    .join(" and ");
}
