import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DEFAULT_OPACITY, FULL_INK_BELOW, HALO_BELOW, REDUCED_TRANSPARENCY, applyOpacity, inkFor, snap, subscribeOpacity, wantsSolid } from "./opacity.js";

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
  assert.equal(Number(rust.match(/pub const STEP: u8 = (\d+);/)[1]), 5);
  const css = readFileSync(new URL("./style.css", import.meta.url), "utf8");
  assert.equal(Number(css.match(/--panel-alpha: ([\d.]+);/)[1]), DEFAULT_OPACITY / 100, "the panel before the first message wears the default");
  const wall = readFileSync(new URL("./wall.html", import.meta.url), "utf8");
  assert.equal(Number(wall.match(/id="gauge-opacity"[^>]*value="(\d+)"/)[1]), DEFAULT_OPACITY, "the slider before the first message");
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
  assert.equal(wantsSolid({}), false, "no matchMedia: the slider decides");
});

test("an empty ?opacity= is the default, not 0%", () => {
  const got = [];
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "?opacity=" });
  subscribeOpacity((v) => got.push(v), { inTauri: false, search: "?opacity=0" });
  assert.deepEqual(got, [DEFAULT_OPACITY, 0]);
});

// Round 2: every small word the ink is meant to reach (WCAG 1.4.3).
test("stronger ink reaches the resets and the route word", () => {
  const css = readFileSync(new URL("./style.css", import.meta.url), "utf8");
  assert.match(css, /:root\[data-ink\] #panel :is\(\.when, \.cell \.t\) \{ opacity: 1; \}/, "the resets' 0.86 fade is lifted under any ink");
  const lightFull = css.match(/@media \(prefers-color-scheme: light\) \{\s*\/\*[^*]*\*\/\s*:root\[data-ink="full"\] #panel \{([^}]*)\}/);
  assert.ok(lightFull, "the light full-ink rule");
  for (const token of ["--text", "--text-dim", "--route"]) assert.match(lightFull[1], new RegExp(`${token}: #120c07`), token);
});
