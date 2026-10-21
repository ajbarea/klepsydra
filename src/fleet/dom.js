// Keep `parent`'s children in step with `items`, one element per item, matched
// by key: elements are reused, moved only when out of place, and removed when
// their item is gone. `make(item)` builds an element; `update(el, item)` fills it.
export function syncChildren(parent, items, key, make, update) {
  const existing = new Map([...parent.children].map((el) => [el.dataset.key, el]));
  items.forEach((item, i) => {
    const k = String(key(item));
    let el = existing.get(k);
    if (el) existing.delete(k);
    else {
      el = make(item);
      el.dataset.key = k;
    }
    update(el, item);
    if (parent.children[i] !== el) parent.insertBefore(el, parent.children[i] ?? null);
  });
  for (const gone of existing.values()) gone.remove();
}

// A button's result or error stays in its note this long.
export const NOTE_MS = 8000;
const timers = new WeakMap();

/** Show `text` in `note` for `ms`, or until replaced when `ms` is 0; a newer text restarts the clock. */
export function say(note, text, ms = NOTE_MS) {
  clearTimeout(timers.get(note));
  // The title holds the whole text where a narrow card cuts it short.
  note.textContent = note.title = text ?? "";
  if (text && ms) timers.set(note, setTimeout(() => { note.textContent = note.title = ""; }, ms));
}

// Off is aria-disabled, never the disabled property, so a focused button keeps focus.
const refresh = (button) => {
  if (button.dataset.busy || button.dataset.off) button.setAttribute("aria-disabled", "true");
  else button.removeAttribute("aria-disabled");
};

/** Mark `button` unavailable or not; it stays off while a call runs either way. */
export function setOff(button, off) {
  if (off) button.dataset.off = "1";
  else delete button.dataset.off;
  refresh(button);
}

/** Run `call` for `button`, one at a time, and show its result or error in `note`. */
export async function press(button, note, call, pending) {
  if (button.getAttribute("aria-disabled") === "true") return;
  button.dataset.busy = "1";
  refresh(button);
  say(note, pending, 0);
  try {
    say(note, await call());
  } catch (err) {
    say(note, String(err));
  } finally {
    delete button.dataset.busy;
    refresh(button);
  }
}

/** A live region's announcer. The same words twice in a row are announced again: cleared, then set. */
export function announcer(live) {
  let again = 0; // a repeat waiting to be set; a newer announcement cancels it
  return function announce(text) {
    clearTimeout(again);
    if (live.textContent !== text) live.textContent = text;
    else {
      live.textContent = "";
      again = setTimeout(() => { live.textContent = text; }, 100);
    }
  };
}
