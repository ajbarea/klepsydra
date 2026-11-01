// Contrast of every tone the #247 prototype (fleet/design-247.css) adds, for
// every character in every theme: borders and the divider at 3:1 (WCAG 2.2,
// 1.4.11), text at 4.5:1 (1.4.3), on the grounds a card can wear.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { contrast, mix, mixOklab } from "./fleet/contrast.js";
import { BAND } from "./fleet/model.js";

const css = readFileSync(new URL("fleet/wall.css", import.meta.url), "utf8");
const token = (name) => css.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`))[1].toLowerCase();
const characters = ["kourai", "professions", "dicebear"].flatMap((id) =>
  Object.values(JSON.parse(readFileSync(new URL(`fleet/themes/${id}.json`, import.meta.url), "utf8")).characters).map((c) => ({ theme: id, ...c })),
);
const WASH = 0.06; // design-247.css: the header wash from the text's edge on
const JUMP = 0.12; // design-247.css: the Open terminal button's tint
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
    check(who, "button border on the card", c.accent, token("--card-bg"), 3);
  }
});

test("#247: the name, the task and the button label hold 4.5:1 on the washed band and the tinted button", () => {
  for (const c of characters) {
    const who = `${c.theme}/${c.name}`;
    for (const g of washedGrounds(c.accent)) {
      check(who, "name on the washed band", token("--ivory"), g, 4.5);
      check(who, "task on the washed band", token("--text-dim"), g, 4.5);
    }
    check(who, "Open terminal label", token("--text"), mixOklab(token("--button-bg"), c.accent, JUMP), 4.5);
    check(who, "Open terminal label on hover", token("--text"), mixOklab(token("--button-hover"), c.accent, JUMP), 4.5);
  }
});

test("#247: needs you stays loud: amber frame at 3:1, ink on the filled pill at 4.5:1", () => {
  check("needs", "amber frame on the wall", BAND.needs, token("--wall-bg"), 3);
  check("needs", "ink on the amber pill", token("--needs-ink"), BAND.needs, 4.5);
});

test("#247: the closest call for each tone, for the Review issue", (t) => {
  const worst = new Map();
  for (const r of rows) if (!worst.has(r.what) || r.r < worst.get(r.what).r) worst.set(r.what, r);
  for (const [what, r] of worst) t.diagnostic(`worst ${what}: ${r.r.toFixed(2)} (${r.who})`);
});
