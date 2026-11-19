import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DEFAULT_OPACITY, FULL_INK_BELOW, HALO_BELOW, REDUCED_TRANSPARENCY, STEP, applyOpacity, inkFor, snap, subscribeOpacity, wantsSolid } from "./opacity.js";

const root = () => {
  const props = {};
  return { props, dataset: {}, style: { setProperty: (k, v) => (props[k] = v) } };
};

test("snap: the slider's grid, 0 to 100 in steps of 5", () => {
  for (const [v, want] of [[0, 0], [2.4, 0], [2.5, 5], [82, 80], [83, 85], [100, 100], [140, DEFAULT_OPACITY], [-3, DEFAULT_OPACITY], [Number.NaN, DEFAULT_OPACITY], ["50", DEFAULT_OPACITY], [null, DEFAULT_OPACITY]]) {
    assert.equal(snap(v), want, String(v));
  }
});

test("the default matches the app's (klepsydra_fleet::opacity::DEFAULT)", () => {
  const rust = readFileSync(new URL("../src-tauri/fleet/src/opacity.rs", import.meta.url), "utf8");
  assert.equal(Number(rust.match(/pub const DEFAULT: u8 = (\d+);/)[1]), DEFAULT_OPACITY);
  assert.equal(Number(rust.match(/pub const STEP: u8 = (\d+);/)[1]), STEP, "the app snaps to the slider's step");
  const css = readFileSync(new URL("./style.css", import.meta.url), "utf8");
  assert.equal(Number(css.match(/--panel-alpha: ([\d.]+);/)[1]), DEFAULT_OPACITY / 100, "the panel before the first message wears the default");
  const wall = readFileSync(new URL("./wall.html", import.meta.url), "utf8");
  assert.equal(Number(wall.match(/id="gauge-opacity"[^>]*value="(\d+)"/)[1]), DEFAULT_OPACITY, "the slider before the first message");
  assert.equal(Number(wall.match(/id="gauge-opacity"[^>]*step="(\d+)"/)[1]), STEP, "the slider steps as the app snaps");
});

test("ink: the theme's own at 85% and up, full ink below, a dark halo below 65% (dark) or 50% (light)", () => {
  assert.equal(FULL_INK_BELOW, 85);
  assert.deepEqual(HALO_BELOW, { dark: 65, light: 50 });
  const dark = [[100, null], [85, null], [80, "full"], [65, "full"], [60, "halo"], [0, "halo"]];
  const light = [[100, null], [85, null], [80, "full"], [50, "full"], [45, "halo"], [0, "halo"]];
  for (const [o, want] of dark) assert.equal(inkFor(o, "dark"), want, `dark ${o}`);
  for (const [o, want] of light) assert.equal(inkFor(o, "light"), want, `light ${o}`);
  assert.equal(inkFor(60, "unknown"), "halo", "an unknown scheme reads as dark");
  assert.equal(inkFor(DEFAULT_OPACITY, "dark"), null, "the default keeps the theme's own ink");
});

test("applyOpacity sets the alpha, the ink and the clear flag, and clears them again", () => {
  const r = root();
  assert.equal(applyOpacity(r, 0, "dark"), "halo");
  assert.equal(r.props["--panel-alpha"], "0");
  assert.equal(r.dataset.ink, "halo");
  assert.equal("clear" in r.dataset, true, "nothing to blur at 0%");
  applyOpacity(r, 65, "dark");
  assert.equal(r.props["--panel-alpha"], "0.65");
  assert.equal(r.dataset.ink, "full");
  assert.equal("clear" in r.dataset, false);
  applyOpacity(r, 100, "light");
  assert.equal(r.props["--panel-alpha"], "1");
  assert.equal("ink" in r.dataset, false);
});

test("subscribeOpacity: the app's channel in Tauri, ?opacity= in a browser, else the default", async () => {
  const got = [];
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "?opacity=37" });
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "" });
  let sent;
  subscribeOpacity((v) => got.push(v), { inTauri: true, follow: (cmd, on) => ((sent = cmd), on(42), Promise.resolve()) });
  await subscribeOpacity((v) => got.push(v), { inTauri: true, follow: () => Promise.reject(new Error("no command")) });
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(sent, "opacity_subscribe");
  assert.deepEqual(got, [35, DEFAULT_OPACITY, 40, DEFAULT_OPACITY]);
});

test("solid: the system's reduced transparency draws the panel opaque, in the theme's own ink", () => {
  const r = root();
  assert.equal(applyOpacity(r, 0, "dark", true), null);
  assert.equal(r.props["--panel-alpha"], "1");
  assert.equal("ink" in r.dataset, false);
  assert.equal("clear" in r.dataset, false);
  assert.equal(wantsSolid({ matchMedia: (q) => ({ matches: q === REDUCED_TRANSPARENCY }) }), true);
  // High Contrast keeps a forced background's alpha (CSS Color Adjust), so it asks for solid too.
  assert.match(REDUCED_TRANSPARENCY, /^\(prefers-reduced-transparency: reduce\), \(forced-colors: active\)$/);
  assert.equal(wantsSolid({}), false, "no matchMedia: the slider decides");
});

test("an empty ?opacity= is the default, not 0%", () => {
  const got = [];
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "?opacity=" });
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "?opacity=0" });
  assert.deepEqual(got, [DEFAULT_OPACITY, 0]);
});

// Round 2: every small word the ink is meant to reach (WCAG 1.4.3).
/** Every rule in `css` as [selector, body], comments dropped. */
const rulesOf = (css) => [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^}]*)\}/g)].map(([, sel, body]) => [sel.trim().replace(/\s+/g, " "), body]);

test("the speaking ring's gap is the panel's solid colour, so it shows at 0% too", () => {
  const css = readFileSync(new URL("./style.css", import.meta.url), "utf8");
  // Every rule that styles a speaking face, not only the first (a later one would win).
  const rings = rulesOf(css).filter(([sel, body]) => /\.face\.speaking\b/.test(sel) && /box-shadow/.test(body));
  assert.ok(rings.length >= 1, "the ring's rule");
  for (const [sel, body] of rings) {
    assert.match(body, /box-shadow: 0 0 0 calc\(1\.5px \* var\(--scale\)\) var\(--panel-solid\), /, sel);
    assert.doesNotMatch(body, /--panel-bg/, `${sel}: the see-through colour vanishes as the panel thins`);
  }
  // The browser test (strip_words_keep_their_ink) reads the rendered gap.
});

test("no text colour carries alpha and no filter fades: words keep their ink by every route", () => {
  const sheets = ["./style.css", "./fleet/badge.css"].map((f) => readFileSync(new URL(f, import.meta.url), "utf8"));
  const alpha = /\/\s*0?\.\d|\/\s*\d{1,2}%|rgba\(|hsla\(|transparent|color-mix\(/;
  for (const [sel, body] of sheets.flatMap(rulesOf)) {
    for (const [, prop, value] of body.matchAll(/(?:^|[;\s])(color|-webkit-text-fill-color|filter):\s*([^;]+)/g)) {
      if (prop === "filter") assert.doesNotMatch(value, /opacity\(/, `${sel}: filter: opacity() fades its text`);
      else assert.doesNotMatch(value, alpha, `${sel}: ${prop} with alpha fades its text`);
    }
    // The ink tokens are opaque wherever they are set, so a colour taken through them is too.
    for (const [, token, value] of body.matchAll(/(--text(?:-dim)?|--route):\s*([^;]+)/g)) {
      assert.doesNotMatch(value, alpha, `${sel}: ${token} with alpha`);
    }
  }
  // The browser test (strip_words_keep_their_ink) multiplies what the page renders.
});

test("no word fades: every opacity under 1 in the stylesheet dims a part that is not text", () => {
  // The strip's sheet and the chips' (shared with the wall's header).
  const sheets = ["./style.css", "./fleet/chips.css"].map((f) => readFileSync(new URL(f, import.meta.url), "utf8"));
  // Every rule that sets an opacity below 1, by its selector, whatever form it takes.
  const fades = sheets.flatMap((sheet) => [...sheet.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^}]*)\}/g)])
    .filter(([, , body]) => [...body.matchAll(/(?:^|[;\s])opacity:\s*([^;]+)(?:;|$)/g)].some(([, v]) => v.trim() !== "1"))
    .map(([, sel]) => sel.trim().replace(/\s+/g, " "));
  assert.deepEqual(fades.sort(), [
    ".chips[data-layout=\"linear\"] .chip + .chip::before", // the bar between accounts
    ".chips[data-layout=\"stacked\"] .chip[data-stale] .cell .pip", // a stale window's pip
    "#panel[data-state=\"waiting\"] > :is(#grip, #content)", // no reading at all yet
    "#zoom", // the size readout, hidden until a scroll
    ".chips .chip[data-placeholder] .mark", // Copilot's icon until #323
    ".chips .chip[data-stale] :is(.pips, .mark svg)", // a stale chip's pips and icon; its words and monogram keep their ink (#486)
  ].sort());
  const lightFull = css.match(/@media \(prefers-color-scheme: light\) \{\s*\/\*[^*]*\*\/\s*:root\[data-ink="full"\] #panel \{([^}]*)\}/);
  assert.ok(lightFull, "the light full-ink rule");
  for (const token of ["--text", "--text-dim", "--route"]) assert.match(lightFull[1], new RegExp(`${token}: #120c07`), token);
});
