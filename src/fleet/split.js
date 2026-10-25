// Split mode (Windows): the wall on the left half of its monitor's work area,
// the fleet terminal on the right. The app places both windows and remembers
// the choice; this wires the wall's toggle to it. Free of the DOM so it can be
// unit tested with stand-ins.
import { press } from "./dom.js";

/** The toggle's name, the same pressed or not (a toggle button's state is aria-pressed). */
export const SPLIT_LABEL = "Split with terminal";

/**
 * Wire `button` (a toggle button) and its `note` to the app's split commands
 * through `invoke`. Hidden unless `app` and get_split_mode answers, which it
 * does only on Windows. Pressed only once a split has landed; a saved choice
 * is applied when the wall loads. Resolves once the saved choice has loaded.
 */
export function wireSplit({ button, note, invoke, app }) {
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
      if (saved === true) turn(true);
    },
    () => {},
  );
}
