// Who a keryx voice is in the kourai cast (cast.json), read the same way by
// the wall's cards and the ledger drawer.

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
