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
const KOURAI = ["aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne"];
const NEW = ["argos", "chronos", "elpis", "hermes", "hesychia"];
// keryx hands af_nicole out only when the user pins it, so it is cast but not in the pool.
const PINNED = "af_nicole";
const PORTRAITS = [...KOURAI, ...NEW].sort();

test("the fifteen characters each have one voice of their gender: every pool voice, and af_nicole", () => {
  const entries = Object.entries(cast.characters);
  assert.deepEqual(entries.map(([, c]) => c.face).sort(), PORTRAITS);
  assert.equal(new Set(entries.map(([, c]) => c.name)).size, 15);
  assert.deepEqual(Object.keys(cast.characters).sort(), [...POOL, PINNED].sort(), "every pool voice has a character, and af_nicole is cast too");
  for (const [voice, c] of entries) {
    assert.ok(POOL.includes(voice) || voice === PINNED, `${voice} is neither in keryx's pool nor the pinned voice`);
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

// The ten kourai accents: kourai-khryseai shared/src/kourai_common/agents.py `hex_color`.
const CANON = {
  hephaestus: "#DA8C20", metis: "#C8B464", techne: "#FFC832", dokimasia: "#DA5032", kallos: "#FFDCA0",
  mneme: "#B496DC", puck: "#009E73", cupid: "#D55E00", aidos: "#56B4E9", aletheia: "#0072B2",
};

// The five new accents: Okabe-Ito yellow and reddish purple, kourai cream-gold, moonlit silver-blue
// (Hesychia, from her brief), and a burnt orange sampled from Hermes's cloak edge (portrait-briefs.md named #E69F00,
// which is the needs-you amber).
const ADDED = { chronos: "#F0E442", argos: "#CC79A7", hermes: "#E07B39", elpis: "#F1D2A1", hesychia: "#A9B8D0" };

test("every character has its accent, and nothing else is in an entry", () => {
  for (const c of Object.values(cast.characters)) {
    assert.match(c.accent, /^#[0-9A-Fa-f]{6}$/, `${c.name} accent`);
    assert.equal(c.accent, CANON[c.face] ?? ADDED[c.face], `${c.name} accent`);
    assert.deepEqual(Object.keys(c).sort(), ["accent", "face", "gender", "name"]);
  }
});

test("no new character's accent is a status tone, and Hermes's is clear of the needs amber", () => {
  const badge = readFileSync(new URL("./fleet/badge.css", import.meta.url), "utf8");
  const wall = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const tones = [...(badge + wall).matchAll(/--(?:badge|tone)-(?:needs|error|working|done):\s*(#[0-9a-f]{6})/gi)].map((m) => m[1].toLowerCase());
  assert.deepEqual([...new Set(tones)].sort(), ["#0072b2", "#009e73", "#56b4e9", "#d55e00", "#e69f00"]);
  for (const face of NEW) {
    const c = Object.values(cast.characters).find((x) => x.face === face);
    assert.ok(!tones.includes(c.accent.toLowerCase()), `${c.name} accent is a status tone`);
  }
  // Amber means "needs you": a character's orange must differ from it by more than a shade.
  const hue = (hex) => {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    const max = Math.max(r, g, b), d = max - Math.min(r, g, b);
    const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return ((h * 60) + 360) % 360;
  };
  const hermes = cast.characters.bm_fable.accent;
  assert.ok(Math.abs(hue(hermes) - hue("#e69f00")) >= 15, "hue 15 degrees from amber");
  assert.ok(contrast(hermes, "#e69f00") < 1.5 && Math.abs(hue(hermes) - hue("#e69f00")) > 0);
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
