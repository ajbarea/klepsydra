// The character themes (#135): each a data file under themes/, shaped like
// the others and keyed by the same keryx voice ids, so a switch changes how a
// session looks (name, face, epithet) and never which voice it is. The app
// keeps the choice in prefs.json (theme_subscribe, set_theme); the phone
// wall gets it on each snapshot; a browser page takes ?theme= (feed.js).
import kourai from "./themes/kourai.json" with { type: "json" };
import professions from "./themes/professions.json" with { type: "json" };
import dicebear from "./themes/dicebear.json" with { type: "json" };
import { castCharacter, castFiles, ownValue } from "./cast.js";

/** Every theme by id, the default first (the fleet crate's theme.rs THEMES). */
export const THEMES = { kourai, professions, dicebear };
export const DEFAULT_THEME = "kourai";
/** How long the wall's picker rests on a theme before the app saves it. */
export const THEME_SAVE_MS = 600;

/** `id` when it names a theme; else the default. */
export const themeId = (id) => (ownValue(THEMES, id) ? id : DEFAULT_THEME);

/** The theme `id` names, else the default's. */
export const themeOf = (id) => THEMES[themeId(id)];

/** The empty wall's keeper (#83): the full portrait of the theme's keeper voice, or null. */
export function keeperOf(theme) {
  const base = castFiles(castCharacter(theme?.keeper, theme), theme);
  return base && `${base}-full.webp`;
}

// Every theme's character names, each to its voice (a test holds one name to one voice).
const VOICE_OF = new Map(Object.values(THEMES).flatMap((t) => Object.entries(t.characters).map(([voice, c]) => [c.name, voice])));

/**
 * `label` (a name a session gave itself, such as the Queue's keeper,
 * "Hermes (orchestrator)") with a leading character name from any theme
 * replaced by the name `theme` gives the same voice; anything else as written.
 */
export function themeName(label, theme) {
  if (typeof label !== "string") return label;
  const [, name, rest] = label.match(/^(.*?)( \(.*\))?$/);
  const voice = VOICE_OF.get(name);
  const now = voice && castCharacter(voice, theme)?.name;
  return now ? `${now}${rest ?? ""}` : label;
}
