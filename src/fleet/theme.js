// The character themes (#135): each a data file under themes/, shaped like
// the others and keyed by the same keryx voice ids, so a switch changes how a
// session looks (name, face, epithet, colour) and never which voice it is.
// The app keeps the choice in prefs.json (theme_subscribe, set_theme); the
// phone wall gets it on each snapshot; a browser page takes ?theme= (feed.js).
// A page loads the default theme with itself and any other the first time it
// is worn, so opening the wall fetches one theme file, as it fetched one cast.
import kourai from "./themes/kourai.json" with { type: "json" };
import { castCharacter, castFiles, ownValue } from "./cast.js";

/** Every theme's id and name, the default first (the fleet crate's theme.rs THEMES). */
export const THEME_LABELS = { kourai: "Kourai", professions: "Professions", dicebear: "DiceBear" };
export const DEFAULT_THEME = "kourai";
/** How long the wall's picker rests on a theme before the app saves it. */
export const THEME_SAVE_MS = 600;
/** The longest a paint waits for a theme's file: past it, the page paints in the theme it wears and says the theme is still loading. */
export const THEME_WAIT_MS = 3000;

/** `id` when it names a theme; else the default. */
export const themeId = (id) => (ownValue(THEME_LABELS, id) ? id : DEFAULT_THEME);

const loaded = new Map([[DEFAULT_THEME, kourai]]);
const loading = new Map();

/** Theme `id` (an unknown one is the default) if its file is loaded; else null. */
export const loadedTheme = (id) => loaded.get(themeId(id)) ?? null;

/** Theme `id`'s file, loaded once; an unknown id is the default. */
export function loadTheme(id) {
  const key = themeId(id);
  if (loaded.has(key)) return Promise.resolve(loaded.get(key));
  if (!loading.has(key)) {
    loading.set(
      key,
      import(`./themes/${key}.json`, { with: { type: "json" } }).then(
        (m) => {
          loaded.set(key, m.default);
          return m.default;
        },
        (err) => {
          loading.delete(key); // a later switch may try again
          throw err;
        },
      ),
    );
  }
  return loading.get(key);
}

/** The empty wall's keeper (#83): the full portrait of the theme's keeper voice, or null. */
export function keeperOf(theme) {
  const base = castFiles(castCharacter(theme?.keeper, theme), theme);
  return base && `${base}-full.webp`;
}

/**
 * The Queue's keeper as `theme` names them: the character a recorded `voice`
 * is (the hook names the keeper itself only when none was typed); without
 * one, the name as typed, whatever it says.
 */
export function keeperName(label, voice, theme) {
  return castCharacter(voice, theme)?.name ?? label;
}
