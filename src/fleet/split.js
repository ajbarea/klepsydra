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
 * is applied when the wall loads. Through `follow`, the app says when a
 * window left the split (the toggle turns off and the note says which
 * window, with nothing moved back) or when AJ snapped both windows into it
 * himself (the toggle turns on).
 *
 * Returns the one way to turn it, which the settings page uses too: `set(on)`
 * resolves with the app's message once the split landed; `view()` is what
 * the toggle shows; `onShow(fn)` hears each change; `ready` resolves once
 * the saved choice has loaded.
 */
export function wireSplit({ button, note, invoke, app, follow }) {
  button.hidden = true;
  const heard = new Set();
  const show = (on) => {
    button.setAttribute("aria-pressed", on ? "true" : "false");
    for (const f of heard) f(on);
  };
  show(false);
  // One call at a time from the toolbar and the settings page alike: a second
  // ask while one runs gets that one's answer.
  let flying = null;
  const set = (on) => {
    flying ??= invoke("set_split_mode", { on })
      .then((said) => {
        show(on);
        return said;
      })
      .finally(() => {
        flying = null;
      });
    return flying;
  };
  const turn = (on) => press(button, note, () => set(on));
  const split = {
    set,
    view: () => ({ value: button.getAttribute("aria-pressed") === "true", available: !button.hidden }),
    onShow: (f) => heard.add(f),
    ready: Promise.resolve(),
  };
  if (!app) return split;
  button.addEventListener("click", () => turn(button.getAttribute("aria-pressed") !== "true"));
  split.ready = invoke("get_split_mode").then(
    (saved) => {
      button.hidden = false;
      show(button.getAttribute("aria-pressed") === "true");
      follow?.("split_subscribe", (said) => {
        if (typeof said?.on !== "boolean") return;
        show(said.on);
        say(note, said.note);
      }).catch(() => {});
      if (saved === true) turn(true);
    },
    () => {},
  );
  return split;
}
