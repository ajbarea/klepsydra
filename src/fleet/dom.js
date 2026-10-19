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
