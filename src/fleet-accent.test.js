// Contrast of every tone a card wears in its character's colour (#247), for
// every character in every theme: its edge, the rule under its band and its
// chips at 3:1 (WCAG 2.2, 1.4.11), the text over the band's wash at 4.5:1
// (1.4.3), and the two loud exceptions, needs-you and error.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { contrast, mix, mixOklab } from "./fleet/contrast.js";
import { BAND, LIGHT_SURFACES, accentLight } from "./fleet/model.js";

const css = readFileSync(new URL("fleet/wall.css", import.meta.url), "utf8");
const token = (name) => css.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`))[1].toLowerCase();
const characters = ["kourai", "professions", "dicebear"].flatMap((id) =>
  Object.values(JSON.parse(readFileSync(new URL(`fleet/themes/${id}.json`, import.meta.url), "utf8")).characters).map((c) => ({ theme: id, ...c })),
);
// The band's wash as wall.css draws it: its strength from its last stop on, and that stop clear of the text.
const wash = css.match(/var\(--band-gold\)\) (\d+)%, transparent\) (\d+)px/);
const WASH = Number(wash[1]) / 100;
const textFrom = Number(css.match(/padding: 0 var\(--space-8\) var\(--space-4\) (\d+)px; \/\* clear of the figure/)[1]);
test("#247: the band's text starts where the wash has faded", () => {
  assert.ok(Number(wash[2]) <= textFrom, `wash fades by ${wash[2]} px, text starts at ${textFrom} px`);
});
const LIGHT_AT_TEXT = (1 - (1 - BAND.glow) * (1 - BAND.rays)) * BAND.underText;
const lights = (accent) => [accent, BAND.needs, mixOklab(BAND.dimWith, accent, BAND.dimShare)];
// The band under its text: the plate, washed in the character's colour, then lit.
const washedGrounds = (accent) => lights(accent).map((light) => mix(mixOklab(BAND.plate, accent, WASH), light, LIGHT_AT_TEXT));

const rows = [];
const check = (who, what, fg, bg, min) => {
  const r = contrast(fg, bg);
  rows.push({ who, what, r });
  assert.ok(r >= min, `${who}: ${what} ${fg} on ${bg} is ${r.toFixed(2)}, under ${min}`);
};

test("#247: each character's edge, divider and button border hold 3:1 on the card, the band and the wall", () => {
  for (const c of characters) {
    const who = `${c.theme}/${c.name}`;
    check(who, "edge on the card", c.accent, token("--card-bg"), 3);
    check(who, "edge on the wall", c.accent, token("--wall-bg"), 3);
    check(who, "divider on the band", c.accent, BAND.plate, 3);
  }
});

test("#247: the name and the task hold 4.5:1 on the washed band", () => {
  for (const c of characters) {
    const who = `${c.theme}/${c.name}`;
    for (const g of washedGrounds(c.accent)) {
      check(who, "name on the washed band", token("--ivory"), g, 4.5);
      check(who, "task on the washed band", token("--text-dim"), g, 4.5);
    }
  }
});

test("#247/#248: the exceptions stay loud: amber and error frames at 3:1, ink on the amber pill at 4.5:1", () => {
  check("needs", "amber frame on the wall", BAND.needs, token("--wall-bg"), 3);
  check("needs", "ink on the amber pill", token("--needs-ink"), BAND.needs, 4.5);
  check("error", "error frame on the wall", "#d55e00", token("--wall-bg"), 3); // badge.css --badge-error
  check("error", "error frame on the card", "#d55e00", token("--card-bg"), 3);
});

// The light scheme (AJ 11-12: both themes): parchment surfaces, the band kept as the dark stage.
const lightBlock = css.slice(css.indexOf("@media (prefers-color-scheme: light)"));
const lightRoot = lightBlock.match(/:root:not\(\.served\) \{([^}]*)\}/)[1];
const lt = (name) => lightRoot.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`))[1].toLowerCase();
const bandScope = lightBlock.match(/\.card header, :root:not\(\.served\) #portrait \{([^}]*)\}/)[1];

test("light: the model's surfaces are the stylesheet's", () => {
  assert.deepEqual(LIGHT_SURFACES, ["--card-bg", "--card-quiet", "--wall-bg", "--button-bg", "--button-hover"].map(lt));
});

test("light: text holds 4.5:1 and the status frames 3:1 on every surface", () => {
  for (const bg of LIGHT_SURFACES) {
    for (const t of ["--text", "--text-dim", "--text-quiet", "--pill-age", "--text-error"]) check("light", `${t} on ${bg}`, lt(t), bg, 4.5);
    for (const t of ["--tone-needs", "--tone-done", "--tone-working"]) check("light", `${t} on ${bg}`, lt(t), bg, 3);
  }
  check("light", "ink on the amber pill", token("--needs-ink"), lt("--tone-needs"), 4.5);
});

test("light: each character keeps its hue, deepened to 3:1 for its edge, chips and marker", () => {
  for (const c of characters) for (const bg of LIGHT_SURFACES) check(`${c.theme}/${c.name}`, "light edge", accentLight(c.accent), bg, 3);
  assert.equal(accentLight("#2b2118"), "#2b2118", "a tone that already reads is kept");
});

test("light: the band and the portrait keep the dark stage's tokens", () => {
  for (const name of ["--text", "--text-dim", "--text-quiet", "--pill-age", "--tone-working", "--tone-quiet", "--button-bg", "--button-line", "--button-hover", "--card-focus"]) {
    assert.equal(bandScope.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`))[1].toLowerCase(), token(name), name);
  }
});

test("#247: the closest call for each tone", (t) => {
  const worst = new Map();
  for (const r of rows) if (!worst.has(r.what) || r.r < worst.get(r.what).r) worst.set(r.what, r);
  for (const [what, r] of worst) t.diagnostic(`worst ${what}: ${r.r.toFixed(2)} (${r.who})`);
});
