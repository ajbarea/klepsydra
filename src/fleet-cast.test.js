import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { contrast, inkOn } from "./fleet/contrast.js";

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

test("each accent carries 4.5:1 text in its ink", () => {
  for (const c of Object.values(cast.characters)) {
    const ink = inkOn(c.accent);
    assert.ok(contrast(ink, c.accent) >= 4.5, `${c.name} ${ink} on ${c.accent}: ${contrast(ink, c.accent).toFixed(2)}`);
  }
});

test("the hover state keeps each accent's fill, so its ink holds 4.5:1", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const rules = [...css.matchAll(/\.jump\[data-accent\]:hover[^{]*\{([^}]*)\}/g)].map((m) => m[1]);
  assert.equal(rules.length, 1);
  assert.doesNotMatch(rules[0], /filter|opacity|background|color\s*:/, "hover changes no colour under the text");
  for (const c of Object.values(cast.characters)) {
    assert.ok(contrast(inkOn(c.accent), c.accent) >= 4.5, `${c.name} on hover`);
  }
});
