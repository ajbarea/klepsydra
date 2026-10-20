import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { contrast, inkOn, markerWidth, MARKER_PX, MARKER_WIDE_PX } from "./fleet/contrast.js";
import { BUTTON_BGS } from "./fleet/model.js";

const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
const faces = new URL("./fleet/faces/", import.meta.url);
const exists = (file) => existsSync(new URL(file, faces));

// keryx's rotation pool (keryx src/keryx/voices.py POOL, 0.9.0): the only
// voices keryx hands a terminal unasked.
const POOL = [
  "af_heart", "am_michael", "bf_emma", "bm_george", "af_bella", "am_fenrir", "bf_isabella",
  "bm_fable", "am_puck", "af_aoede", "af_kore", "af_sarah", "af_alloy", "af_nova",
];
const PORTRAITS = ["aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne"];

test("the ten kourai characters each have one pool voice of their gender", () => {
  const entries = Object.entries(cast.characters);
  assert.deepEqual(entries.map(([, c]) => c.face).sort(), PORTRAITS);
  assert.equal(new Set(entries.map(([, c]) => c.name)).size, 10);
  for (const [voice, c] of entries) {
    assert.ok(POOL.includes(voice), `${voice} is not in keryx's pool`);
    assert.equal(voice[1], c.gender, `${c.name} cast against gender`);
  }
});

test("kourai's named Kokoro seeds are kept", () => {
  assert.equal(cast.characters.am_michael.name, "Hephaestus");
  assert.equal(cast.characters.am_puck.name, "Puck");
});

test("every character has both portrait files, and the cast holds nothing else", () => {
  assert.deepEqual(Object.keys(cast).sort(), ["characters", "v"]);
  for (const c of Object.values(cast.characters)) {
    for (const size of [96, 192]) assert.ok(exists(`kourai/${c.face}-${size}.webp`), `${c.face} ${size}`);
  }
});

// kourai-khryseai shared/src/kourai_common/agents.py `hex_color`.
const CANON = {
  hephaestus: "#DA8C20", metis: "#C8B464", techne: "#FFC832", dokimasia: "#DA5032", kallos: "#FFDCA0",
  mneme: "#B496DC", puck: "#009E73", cupid: "#D55E00", aidos: "#56B4E9", aletheia: "#0072B2",
};

test("every character has its canon accent, and nothing else is in an entry", () => {
  for (const c of Object.values(cast.characters)) {
    assert.match(c.accent, /^#[0-9A-Fa-f]{6}$/, `${c.name} accent`);
    assert.equal(c.accent, CANON[c.face], `${c.name} canon colour`);
    assert.deepEqual(Object.keys(c).sort(), ["accent", "face", "gender", "name"]);
  }
});

test("each accent's left marker is 3:1 on the button, or widened to 6 px where it is not", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const token = (name) => css.match(new RegExp(`${name}:\\s*(#[0-9a-f]{6})`, "i"))[1];
  const bgs = [token("--button-bg"), token("--button-hover")];
  assert.deepEqual(bgs, BUTTON_BGS, "the model's button backgrounds are the stylesheet's");
  const widened = [];
  for (const c of Object.values(cast.characters)) {
    const low = Math.min(...bgs.map((bg) => contrast(c.accent, bg)));
    const w = markerWidth(c.accent, bgs);
    assert.equal(w, low >= 3 ? MARKER_PX : MARKER_WIDE_PX, `${c.name} ${low.toFixed(2)}:1`);
    if (low < 3) widened.push(c.name);
  }
  assert.deepEqual(widened.sort(), ["Aletheia", "Dokimasia"], "accents under 3:1 on rest or hover");
  for (const c of Object.values(cast.characters)) {
    assert.ok(contrast(c.accent, bgs[0]) >= 2.5, `${c.name} stays visible at rest`);
  }
});

test("the needs fill carries 4.5:1 ink, at rest and on hover", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const badge = readFileSync(new URL("./fleet/badge.css", import.meta.url), "utf8");
  const needs = badge.match(/--badge-needs:\s*(#[0-9a-f]{6})/i)[1];
  const ink = css.match(/--needs-ink:\s*(#[0-9a-f]{6})/i)[1];
  assert.match(css, /--tone-needs: var\(--badge-needs\)/, "the fill is the needs pill's token");
  assert.equal(ink.toLowerCase(), inkOn(needs));
  assert.ok(contrast(ink, needs) >= 4.5, contrast(ink, needs).toFixed(2));
  const rest = css.match(/\.jump\[data-kind="needs"\] \{([^}]*)\}/)[1];
  const hover = css.match(/\.jump\[data-kind="needs"\]:hover[^{]*\{([^}]*)\}/)[1];
  assert.match(rest, /background: var\(--tone-needs\); color: var\(--needs-ink\)/);
  assert.match(hover, /background: var\(--tone-needs\)/, "hover keeps the fill");
  assert.doesNotMatch(hover, /\bcolor\s*:/);
});

test("only an enabled needs button is filled; the marker rule sets a shadow and no fill", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const fills = [...css.matchAll(/(\.jump[^{]*)\{([^}]*background:[^}]*)\}/g)].map((m) => m[1].trim());
  assert.deepEqual(fills, ['.jump[data-kind="needs"]', '.jump[data-kind="needs"]:hover:not([aria-disabled="true"])']);
  const mark = css.match(/\.jump\[data-kind="accent"\] \{([^}]*)\}/)[1];
  assert.match(mark, /box-shadow: inset var\(--mark-w\) 0 0 var\(--accent\)/);
  assert.doesNotMatch(mark, /background|border/);
});
