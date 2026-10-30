// Split mode (Windows): the wall on the left half of its monitor's work area,
// the fleet terminal on the right. The app places both windows and remembers
// the choice; this wires the wall's toggle to it. Free of the DOM so it can be
// unit tested with stand-ins.
import { press, say } from "./dom.js";

/** The toggle's name, the same pressed or not (a toggle button's state is aria-pressed). */
export const SPLIT_LABEL = "Split with terminal";

/**
 * Wire `button` (a toggle button) and its `note` to the app's split commands
 * through `invoke`. Hidden unless `app` and get_split_mode answers, which it
 * does only on Windows. Pressed only once a split has landed; a saved choice
 * is applied when the wall loads. Resolves once the saved choice has loaded.
 * Through `follow`, the app says when a window left the split (the toggle
 * turns off and the note says which window, with nothing moved back) or when
 * AJ snapped both windows into it himself (the toggle turns on).
 */
export function wireSplit({ button, note, invoke, app, follow }) {
  button.hidden = true;
  const show = (on) => button.setAttribute("aria-pressed", on ? "true" : "false");
  show(false);
  if (!app) return Promise.resolve();
  const turn = (on) =>
    press(button, note, async () => {
      const said = await invoke("set_split_mode", { on });
      show(on);
      return said;
    });
  button.addEventListener("click", () => turn(button.getAttribute("aria-pressed") !== "true"));
  return invoke("get_split_mode").then(
    (saved) => {
      button.hidden = false;
      follow?.("split_subscribe", (said) => {
        if (typeof said?.on !== "boolean") return;
        show(said.on);
        say(note, said.note);
      }).catch(() => {});
      if (saved === true) turn(true);
    },
    () => {},
  );
}
