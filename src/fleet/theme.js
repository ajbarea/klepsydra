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
 * The Queue's keeper as `theme` names them. Only a `voice` the fleet hook
 * recorded (the session that set the file) makes a character: its name in
 * the theme, keeping what follows a name the label gave that voice in any
 * theme ("Hermes (orchestrator)" is "Messenger (orchestrator)"). Without one,
 * the label stays as typed, whatever it says.
 */
export function keeperName(label, voice, theme) {
  const now = castCharacter(voice, theme)?.name;
  if (!now) return label;
  const [, name, rest] = typeof label === "string" ? label.match(/^(.*?)( \(.*\))?$/) : [];
  return VOICE_OF.get(name) === voice ? `${now}${rest ?? ""}` : now;
}
