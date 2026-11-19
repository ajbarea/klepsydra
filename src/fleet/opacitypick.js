// The wall's "Gauge background" slider (#438). Each step shows at once on the
// slider; it is saved (set_gauge_opacity, which the gauge follows) once the
// slider rests for OPACITY_SAVE_MS, or at once on release, blur or page hide,
// so a held arrow key or a slow drag writes prefs.json once, as the theme
// picker does. The app's pushes (opacity_subscribe) are held while a value is
// unsaved or a save is in flight, and Tauri does not order a channel push
// before a command's reply: after a save the slider keeps what was asked, and
// only a refused save puts it back to the value the app last pushed, saying
// why in the bar's note, as the theme picker does.
import { snap } from "../opacity.js";

export const OPACITY_SAVE_MS = 250;

/**
 * `input`: the range; `value`: its visible "80%"; `invoke(command, args)`;
 * `subscribe(onValue)`: the saved opacity, now and after each change;
 * `note(text)`: the bar's status line ("" clears it); `log`: where a refused
 * save is reported; `win`: for pagehide.
 */
export function wireOpacityPick({ input, value, invoke, subscribe, note, log, win = globalThis, wait = OPACITY_SAVE_MS }) {
  let heard = null; // the saved value, as the app last pushed it
  let asked = null; // shown on the slider, not saved yet
  let pending = 0; // saves not yet answered
  let timer = 0;

  const show = (v) => {
    input.value = String(v);
    input.setAttribute("aria-valuetext", `${v}%`);
    value.textContent = `${v}%`;
  };
  const settled = () => asked === null && pending === 0;

  subscribe((v) => {
    heard = v;
    if (settled()) show(v);
  });

  function save() {
    clearTimeout(timer);
    timer = 0;
    if (asked === null) return;
    const v = asked;
    asked = null;
    pending += 1;
    invoke("set_gauge_opacity", { opacity: v }).then(
      () => {
        pending -= 1;
        note("");
        if (settled()) show(v);
      },
      (err) => {
        pending -= 1;
        log.error(`set_gauge_opacity refused ${v}%, so the gauge keeps the saved value`, err);
        note(`Not saved: ${err}`);
        if (settled() && heard !== null) show(heard);
      },
    );
  }

  input.addEventListener("input", () => {
    const v = snap(Number(input.value));
    show(v);
    if (v === asked) return; // the thumb moved within one step
    asked = v;
    clearTimeout(timer);
    timer = setTimeout(save, wait);
  });
  input.addEventListener("pointerup", save);
  input.addEventListener("blur", save);
  win.addEventListener?.("pagehide", save);
}
