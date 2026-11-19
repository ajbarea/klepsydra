// The wall's "Gauge background" slider (#438): each step is saved and sent to
// the gauge at once (set_gauge_opacity), and the slider follows the saved value
// (opacity_subscribe). While saves are in flight the app's echoes of earlier
// steps are held, so a fast drag never jumps back; once the last save settles,
// the slider shows what was saved, which after a failed save is the old value.
import { snap } from "../opacity.js";

/**
 * `input`: the range; `value`: its visible "80%"; `invoke(command, args)`;
 * `subscribe(onValue)`: the saved opacity, now and after each change;
 * `log`: where a failed save is reported.
 */
export function wireOpacityPick({ input, value, invoke, subscribe, log }) {
  let heard = null; // the saved value, as the app last said
  let pending = 0; // saves not yet answered
  let sent = null; // the last step asked for

  const show = (v) => {
    input.value = String(v);
    input.setAttribute("aria-valuetext", `${v}%`);
    value.textContent = `${v}%`;
  };

  subscribe((v) => {
    heard = v;
    if (pending === 0) {
      sent = v;
      show(v);
    }
  });

  input.addEventListener("input", () => {
    const v = snap(Number(input.value));
    show(v);
    if (v === sent) return; // the thumb moved within one step
    sent = v;
    pending += 1;
    invoke("set_gauge_opacity", { opacity: v })
      .catch((err) => log.warn(`the gauge background could not be saved at ${v}%, so it keeps the saved value`, err))
      .finally(() => {
        pending -= 1;
        if (pending === 0 && heard !== null) {
          sent = heard;
          show(heard);
        }
      });
  });
}
