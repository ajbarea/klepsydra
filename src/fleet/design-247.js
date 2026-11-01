// Design prototype for #247 and #248, worn only in a browser with ?design=b or
// ?design=c, never inside the app: the A/B shots for AJ's pick. Variant B
// dresses each card in its character's colour and groups the bar; C adds the
// figure breaking the frame. Deleted or folded into wall.css once AJ picks.

const design = new URLSearchParams(location.search).get("design");

if (design === "b" || design === "c") {
  document.documentElement.dataset.design = design;
  const css = document.createElement("link");
  css.rel = "stylesheet";
  css.href = "fleet/design-247.css";
  document.head.append(css);

  // #248's bar: status on the left; the panels and + New session on the right;
  // the density and theme pickers behind one gear.
  const bar = document.querySelector(".bar");
  const right = document.createElement("div");
  right.className = "bar-right";
  right.append(document.querySelector(".tools"), document.querySelector("#new-session"));
  const gear = document.createElement("details");
  gear.className = "gear";
  gear.innerHTML = '<summary aria-label="View settings" title="View settings"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/></svg></summary>';
  gear.append(document.querySelector(".view"));
  right.append(gear);
  bar.append(right);

  // Each card names its character, so a style can reach one (Cupid's wide cut in C).
  const wall = document.querySelector("#wall");
  const tag = () => {
    for (const card of wall.querySelectorAll(".card")) {
      const face = card.querySelector(".figure")?.getAttribute("src")?.match(/([a-z]+)-figure\.webp$/)?.[1] ?? "";
      if (card.dataset.face !== face) card.dataset.face = face;
    }
  };
  new MutationObserver(tag).observe(wall, { childList: true, subtree: true, attributes: true, attributeFilter: ["src"] });
}
