import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { TONES, medallionSvg } from "./fleet/medallion.js";
import { contrast, mix, mixOklab, readableOn } from "./fleet/contrast.js";
import { BAND, PLATE_BG, RINGS, bandGrounds } from "./fleet/model.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const badgeCss = read("./fleet/badge.css");
const token = (css, name) => css.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim();

/** Columns that `repeat(auto-fill, minmax(min, 1fr))` makes in a viewport `width` wide. */
const columnsAt = (width, { min, gap, pad }) => Math.max(1, Math.floor((width - 2 * pad + gap) / (min + gap)));

/** `rgba(r, g, b, a)` laid over an opaque "#rrggbb", as "#rrggbb". */
function over(rgba, hex) {
  const [r, g, b, a] = rgba.match(/[\d.]+/g).map(Number);
  const base = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return `#${[r, g, b].map((c, i) => Math.round(c * a + base[i] * (1 - a)).toString(16).padStart(2, "0")).join("")}`;
}

/** Each tone's shape fill and stroke and its ink, resolved through badge.css's tokens. */
function tones(css) {
  const value = (decl, prop) => decl.match(new RegExp(`${prop}:\\s*var\\((--[\\w-]+)\\)`))?.[1];
  const ring = token(css, "--badge-ring");
  const out = {};
  for (const [, tone, part, decl] of css.matchAll(/\.tone-(\w+) \.(shape|ink) \{([^}]*)\}/g)) {
    out[tone] ??= { fill: null, stroke: ring, ink: null };
    if (part === "shape") {
      out[tone].fill = token(css, value(decl, "fill"));
      if (value(decl, "stroke")) out[tone].stroke = token(css, value(decl, "stroke"));
    } else out[tone].ink = token(css, value(decl, "fill"));
  }
  return { ring, tones: out };
}

test("every badge meets 3:1 against the strip's backdrop, and its symbol against the badge", () => {
  const { ring, tones: all } = tones(badgeCss);
  assert.deepEqual(Object.keys(all).sort(), ["done", "error", "needs", "quiet", "working"]);
  // The ring is the panel's own colour: what every badge sits on.
  const panel = token(read("./style.css"), "--panel-bg");
  assert.equal(over(panel, ring), ring.toLowerCase(), "ring matches the panel over a dark desktop");
  const onWhite = over(panel, "#ffffff");
  for (const [tone, t] of Object.entries(all)) {
    const edge = tone === "quiet" ? t.stroke : t.fill;
    assert.ok(contrast(edge, ring) >= 3, `${tone} against the ring: ${contrast(edge, ring).toFixed(2)}`);
    if (tone === "quiet") {
      assert.ok(contrast(edge, onWhite) >= 3, `quiet outline over a light desktop: ${contrast(edge, onWhite).toFixed(2)}`);
    }
    assert.ok(contrast(t.ink, t.fill) >= 3, `${tone} symbol: ${contrast(t.ink, t.fill).toFixed(2)}`);
  }
});

test("the Okabe-Ito tones are the spec's", () => {
  assert.deepEqual(
    ["--badge-needs", "--badge-error", "--badge-working", "--badge-done"].map((t) => token(badgeCss, t)),
    ["#e69f00", "#d55e00", "#0072b2", "#009e73"],
  );
});

test("badges take their size from where they sit", () => {
  assert.doesNotMatch(badgeCss.replace(/\/\*[\s\S]*?\*\//g, ""), /\d+(\.\d+)?px/);
});

/** wall.css's tokens for a density, var() references resolved to px. */
function densityPx(css, density) {
  const block = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[[\]"=]/g, "\\$&")} \\{([^}]*)\\}`))?.[1] ?? "";
  const tokens = (b) => Object.fromEntries([...b.matchAll(/(--[\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
  const set = { ...tokens(block(":root")), ...(density === "compact" ? tokens(block('[data-density="compact"]')) : {}) };
  const px = (v) => v.replace(/var\((--[\w-]+)\)/g, (_, n) => px(set[n])).trim();
  return (name) => px(set[name]).split(/\s+/).map(parseFloat);
}

test("the wall fits four columns at 1920 px and reflows below, in either density", () => {
  const wallCss = read("./fleet/wall.css");
  const SCROLLBAR = 17;
  for (const density of ["comfortable", "compact"]) {
    const px = densityPx(wallCss, density);
    const tokens = { min: px("--card-min")[0], gap: px("--card-gap")[0], pad: px("--wall-pad")[0] };
    assert.equal(columnsAt(1920 - SCROLLBAR, tokens), 4, density);
    assert.equal(columnsAt(1920, tokens), 4, `${density}, no scrollbar`);
    assert.equal(columnsAt(960, tokens), 2, `${density}, half the screen`);
    assert.equal(columnsAt(800 - SCROLLBAR, tokens), 1, density);
  }
  assert.equal(columnsAt(1280 - SCROLLBAR, { min: 420, gap: 16, pad: 28 }), 2);
});

test("both densities step on one spacing scale, and compact is the 12 px grid the issue asks for", () => {
  const css = read("./fleet/wall.css");
  const scale = [...css.matchAll(/--space-\d+:\s*([\d.]+)px;/g)].map((m) => Number(m[1]));
  assert.ok(scale.length >= 6 && scale.every((v, i) => i === 0 || v > scale[i - 1]), "an ascending scale");
  const compact = css.match(/\n\[data-density="compact"\] \{([^}]*)\}/)[1];
  for (const [, name, value] of compact.matchAll(/(--[\w-]+):\s*([^;]+);/g)) {
    if (["--wall-face", "--face-inset", "--band-h"].includes(name)) continue; // portrait and band geometry, not spacing
    assert.match(value, /^(var\(--space-\d+\)\s*)+$/, `${name} steps on the scale`);
  }
  const comfortable = densityPx(css, "comfortable");
  const tight = densityPx(css, "compact");
  assert.deepEqual([comfortable("--card-gap")[0], comfortable("--wall-pad")[0]], [16, 28], "comfortable is unchanged");
  assert.deepEqual([tight("--card-gap")[0], tight("--wall-pad")[0]], [12, 12]);
  assert.deepEqual(comfortable("--card-pad"), [0, 18, 14], "comfortable's band takes the top");
  assert.equal(comfortable("--wall-face")[0], 80);
  assert.equal(tight("--wall-face")[0], 64, "the compact face grew for #44");
});

test("compact keeps Open terminal, Clear and the density choices at 24x24 px or more", () => {
  const css = read("./fleet/wall.css");
  const rule = (sel) => css.match(new RegExp(`${sel.replace(/[.[\]"=]/g, "\\$&")} \\{([^}]*)\\}`))?.[1] ?? "";
  const px = (decl, prop) => parseFloat(decl.match(new RegExp(`(?:^|[\\s;])${prop}:\\s*([\\d.]+)px`))?.[1] ?? "NaN");
  const buttons = rule('[data-density="compact"] .jump,\n[data-density="compact"] .clear');
  assert.ok(px(buttons, "min-height") >= 24 && px(buttons, "min-width") >= 24, "Open terminal and Clear");
  assert.ok(px(rule(".density label"), "min-height") >= 24, "a density choice");
  // The needs fill and the accent marker are the base rules', untouched by compact.
  assert.doesNotMatch(buttons, /background|box-shadow|border/);
  assert.doesNotMatch(css, /\[data-density="compact"\][^{]*\.jump\[data-kind/);
});

test("the wall's text meets 4.5:1 on live and quiet cards", () => {
  const css = read("./fleet/wall.css");
  for (const bg of ["--card-bg", "--card-quiet"]) {
    for (const fg of ["--text", "--text-dim", "--text-error", "--text-quiet"]) {
      const r = contrast(token(css, fg), token(css, bg));
      assert.ok(r >= 4.5, `${fg} on ${bg}: ${r.toFixed(2)}`);
    }
  }
  assert.ok(contrast(token(css, "--tone-working"), token(css, "--card-bg")) >= 3, "working edge");
  assert.doesNotMatch(css.replace(/\/\*[\s\S]*?\*\//g, ""), /opacity:/, "dimming is by colour, so dimmed text keeps its contrast");
});

test("the ring's fades and the dimming respect reduced motion and keep the face visible", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /@media \(prefers-reduced-motion: reduce\) \{\s*\* \{ transition: none !important; animation: none !important; \}/);
  assert.match(css, /\.card\.dim \.face \{[^}]*filter:/);
  assert.match(read("./fleet/wall.js"), /if \(reducedMotion\(\)\) path\.remove\(\)/, "a leaving segment goes at once");
});

test("an agent's arc differs from a shell's by width alone: solid, one colour, no dash", () => {
  const css = read("./fleet/wall.css");
  const rule = (sel) => css.match(new RegExp(`${sel.replace(/\./g, "\\.")} \\{([^}]*)\\}`))?.[1] ?? "";
  assert.doesNotMatch(css, /stroke-dasharray/, "no dashes anywhere on the wall");
  assert.match(rule(".ring .seg"), /stroke: var\(--crew\)/, "one colour for both kinds");
  assert.doesNotMatch(css, /\.ring \.seg\.(agent|shell)/, "no rule tells the kinds apart but their width");
  // The key draws the same two widths as the comfortable ring.
  const px = (sel) => parseFloat(rule(sel).match(/stroke-width: ([\d.]+)px/)[1]);
  assert.deepEqual([px(".ring-key path.agent"), px(".ring-key path.shell")], [RINGS.comfortable.agent, RINGS.comfortable.shell]);
  assert.match(css, /\.ring-key svg \{ width: 32px; height: 18px;/, "drawn 1:1 with its 32x18 viewBox");
  assert.match(read("./wall.html"), /<svg viewBox="0 0 32 18"><path class="agent"/);
});

test("an agent with no character is gold, not the needs-you amber, and reads on the card", () => {
  const css = read("./fleet/wall.css");
  const gold = token(css, "--crew-gold");
  assert.notEqual(gold.toLowerCase(), token(badgeCss, "--badge-needs").toLowerCase(), "amber means needs you");
  assert.ok(contrast(gold, token(css, "--card-bg")) >= 3);
  assert.ok(contrast(token(css, "--ring-track"), token(css, "--card-bg")) < 1.5, "an empty ring stays quiet");
});

test("a badge on the wall is ringed in its card's colour", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /\.card \{[^}]*--badge-ring: var\(--card-bg\)/);
  assert.match(css, /\.card\.dim \{[^}]*--badge-ring: var\(--card-quiet\)/);
});

test("the wall's error text is readable on its card at 14 px", () => {
  const wallCss = read("./fleet/wall.css");
  const ratio = contrast(token(wallCss, "--text-error"), token(wallCss, "--card-bg"));
  assert.ok(ratio >= 4.5, `error text on the card: ${ratio.toFixed(2)}`);
  assert.match(wallCss, /\.error \{ color: var\(--text-error\)/);
});

test("a portrait is 28 px at 100%, and the strip's rules are in the zoomed stylesheet", () => {
  const css = read("./style.css");
  assert.equal(token(css, "--face-size"), "28px");
  for (const rule of ["#frame {", "#strip {", ".face {", ".face .badge {"]) assert.ok(css.includes(rule), rule);
});

test("the strip starts hidden, so the gauge looks as before until a fleet arrives", () => {
  assert.match(read("./index.html"), /<div id="strip"[^>]*\shidden>/);
  assert.match(read("./main.js"), /try\s*\{[\s\S]{0,80}?import\(\s*["']\.\/fleet\/strip\.js["']\s*\)/);
  assert.match(read("./index.html"), /href="fleet\/badge\.css"/);
});

test("every set_size and set_grip call carries the strip", () => {
  const calls = [...read("./main.js").matchAll(/invoke\(\s*"(set_size|set_grip)"\s*,\s*\{([^}]*)\}/g)];
  assert.equal(calls.length, 2);
  for (const [, name, args] of calls) assert.match(args, /\bstrip\b/, name);
});

test("the focus ring is neutral, not the needs tone, and meets 3:1 on the wall and the card", () => {
  const css = read("./fleet/wall.css");
  const ring = token(css, "--card-focus");
  assert.match(ring, /^#[0-9a-f]{6}$/i);
  assert.notEqual(ring.toLowerCase(), token(badgeCss, "--badge-needs").toLowerCase(), "amber means needs you");
  assert.ok(contrast(ring, token(css, "--wall-bg")) >= 3);
  assert.ok(contrast(ring, token(css, "--card-bg")) >= 3);
  assert.match(css, /button:focus-visible \{ outline: 2px solid var\(--card-focus\); outline-offset: 2px; \}/);
});

test("the needs pulse plays only where motion is allowed, once", () => {
  const css = read("./fleet/wall.css");
  const block = css.match(/@media \(prefers-reduced-motion: no-preference\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
  assert.match(block, /@keyframes card-pulse/);
  assert.match(block, /\.card\.pulse \{[^}]*animation: card-pulse 1200ms ease-out 1;/);
  assert.ok(!/@keyframes card-pulse/.test(css.replace(block, "")), "keyframes only inside no-preference");
  assert.match(css, /prefers-reduced-motion: reduce\) \{[^}]*animation: none/);
});

test("the reorder slide is bounded, and cards keep their own transition names", () => {
  const css = read("./fleet/wall.css");
  assert.match(css, /::view-transition-group\(\*\)\s*\{[^}]*animation-duration:\s*\d+ms/);
});

test("a disabled button reads as off: no fill, a quieter border, a label still at 4.5:1", () => {
  const css = read("./fleet/wall.css");
  const rule = css.match(/button\[aria-disabled="true"\], #new-session\[aria-disabled="true"\] \{([^}]*)\}/)?.[1] ?? "";
  // #new-session (1 id) outranks button[...] (1 type, 1 attr): the id form must be listed and come last.
  assert.ok(css.indexOf('#new-session[aria-disabled="true"]') > css.indexOf("#new-session {"));
  assert.match(rule, /background: transparent/);
  assert.match(rule, /border-color: var\(--card-line\)/);
  assert.ok(contrast(token(css, "--text-dim"), token(css, "--card-bg")) >= 4.5);
});

test("each medallion metal's initial meets 4.5:1 against every colour of its disc", () => {
  assert.equal(TONES.length, 6);
  for (let t = 0; t < TONES.length; t++) {
    const svg = medallionSvg("W", t);
    const stops = (id) =>
      [...(svg.match(new RegExp(`<(?:radial|linear)Gradient id="${id}"[^>]*>(.*?)</(?:radial|linear)Gradient>`))?.[1] ?? "")
        .matchAll(/stop-color="(#[0-9a-f]{6}|#000)"/g)].map((m) => m[1]);
    const disc = stops("disc");
    const ink = stops("ink");
    assert.deepEqual([disc, ink], [TONES[t].disc, TONES[t].ink], TONES[t].name);
    assert.match(svg, /<text[^>]*fill="url\(#ink\)"[^>]*>W<\/text>/, "the letter is painted with the ink gradient");
    // The one layer over the disc is a black vignette, which only darkens it.
    assert.deepEqual(stops("glow"), ["#000", "#000"]);
    for (const fg of ink) {
      for (const bg of disc) assert.ok(contrast(fg, bg) >= 4.5, `${TONES[t].name}: ${fg} on ${bg}: ${contrast(fg, bg).toFixed(2)}`);
    }
  }
});

test("the focus ring never sits on the marker or the needs fill", () => {
  const css = read("./fleet/wall.css");
  // The ring is offset 2px, on the card's colour, so it need not contrast with either; it does contrast with the card.
  assert.match(css, /button:focus-visible \{[^}]*outline-offset: 2px/);
  assert.ok(contrast(token(css, "--card-focus"), token(css, "--card-bg")) >= 3);
});

test("hover keeps 4.5:1 text on the neutral button", () => {
  const css = read("./fleet/wall.css");
  assert.ok(contrast(token(css, "--text"), token(css, "--button-hover")) >= 4.5);
  assert.ok(contrast(token(css, "--text"), token(css, "--button-bg")) >= 4.5);
});

// ---- The header band (#62) ----
const wallCss = () => read("./fleet/wall.css");
const bandTokens = () => {
  const css = wallCss();
  const pct = (name) => parseFloat(token(css, name)) / 100;
  return {
    plate: token(css, "--plate-bg"),
    glow: pct("--glow-alpha"),
    rays: pct("--rays-alpha"),
    underText: pct("--under-text"),
    dimWith: token(css, "--dim-light-with"),
    dimShare: pct("--dim-light-share"),
  };
};

test("the band's constants in the model are the stylesheet's", () => {
  const t = bandTokens();
  assert.deepEqual(
    { plate: BAND.plate, glow: BAND.glow, rays: BAND.rays, underText: BAND.underText, dimWith: BAND.dimWith, dimShare: BAND.dimShare },
    t,
  );
  assert.equal(BAND.needs, token(badgeCss, "--badge-needs"), "a needs-you band is lit amber");
  assert.equal(PLATE_BG, BAND.plate);
});

test("text on the band reads at 4.5:1 under every light that can reach it", () => {
  const css = wallCss();
  const cast = JSON.parse(read("./fleet/cast.json"));
  const ivory = token(css, "--ivory");
  const dim = token(css, "--text-dim");
  for (const c of Object.values(cast.characters)) {
    const ink = readableOn(c.accent, bandGrounds(c.accent));
    for (const ground of bandGrounds(c.accent)) {
      for (const [what, fg] of [["name", ivory], ["task", dim], ["epithet", ink]]) {
        const r = contrast(fg, ground);
        assert.ok(r >= 4.5, `${c.name} ${what} on ${ground}: ${r.toFixed(2)}`);
      }
      // The pill: its tone at 16% over the band, its label the tone mixed 70% with white (wall.css .pill).
      const age = token(css, "--pill-age");
      for (const tone of ["--tone-needs", "--tone-working", "--tone-done", "--tone-error", "--tone-quiet"]) {
        const hex = token(css, tone).startsWith("var(") ? token(badgeCss, token(css, tone).slice(4, -1)) : token(css, tone);
        const pill = mix(ground, hex, 0.16);
        const label = mixOklab("#ffffff", hex, 0.7);
        assert.ok(contrast(label, pill) >= 4.5, `${c.name} ${tone} pill: ${contrast(label, pill).toFixed(2)}`);
        assert.ok(contrast(age, pill) >= 4.5, `${c.name} ${tone} pill age: ${contrast(age, pill).toFixed(2)}`);
      }
    }
  }
});

test("the band caps its light under text with the mask, and lights needs-you amber and a quiet card dim", () => {
  const css = wallCss();
  const stage = css.match(/\.stage \{([^}]*)\}/)?.[1] ?? "";
  assert.match(stage, /mask-image: linear-gradient\(90deg, #000 var\(--fade-from\), rgb\(0 0 0 \/ var\(--under-text\)\) var\(--fade-to\)\)/);
  assert.match(css, /\.card\.tone-needs \{[^}]*--light: var\(--tone-needs\)/);
  assert.match(css, /\.card\.dim \{[^}]*--light: color-mix\(in oklab, var\(--accent, var\(--band-gold\)\) var\(--dim-light-share\), var\(--dim-light-with\)\)/);
});

test("crew marks on the plinth are 3:1 against it for every character", () => {
  const plinth = token(wallCss(), "--plinth-bg");
  const cast = JSON.parse(read("./fleet/cast.json"));
  for (const c of Object.values(cast.characters)) {
    assert.ok(contrast(c.accent, plinth) >= 3, `${c.name}: ${contrast(c.accent, plinth).toFixed(2)}`);
  }
});

test("on a figure the crew rides the plinth and the ring steps aside; the waves stay behind the figure", () => {
  const css = wallCss();
  assert.match(css, /\.has-figure \.portrait \.ring,\s*\.has-figure \.portrait \.face \{ display: none; \}/);
  assert.match(css, /\[data-density="compact"\] \.has-figure \.portrait \.ring,\s*\[data-density="compact"\] \.has-figure \.portrait \.face \{ display: block; \}/);
  assert.match(css, /\.marks \{[^}]*display: none;/, "no marks unless a figure shows");
  assert.match(css, /\[data-density="compact"\] \.has-figure \.marks:not\(:empty\),[^{]*\{ display: none; \}/, "nor on a compact card, whose ring shows them");
  const figure = css.match(/\n\.has-figure \.look \{([^}]*)\}/)?.[1] ?? "";
  const portrait = css.match(/\n\.has-figure \.aura \{([^}]*)\}/)?.[1] ?? "";
  assert.ok(Number(figure.match(/z-index: (-?\d+)/)[1]) > Number(portrait.match(/z-index: (-?\d+)/)[1]), "waves behind the figure");
});

test("the arrival plays only where motion is allowed, and dims nothing by opacity", () => {
  const css = wallCss().replace(/\/\*[\s\S]*?\*\//g, "");
  const block = css.match(/@media \(prefers-reduced-motion: no-preference\) \{[\s\S]*?\n\}/g).join("\n");
  for (const name of ["figure-arrive", "light-rise"]) {
    assert.match(block, new RegExp(`@keyframes ${name}`));
    assert.equal(css.split(`@keyframes ${name}`).length, 2, `${name} is defined once`);
  }
  assert.equal((css.match(/\.arriving/g) ?? []).length, (block.match(/\.arriving/g) ?? []).length, "no arrival outside it");
});

test("the nameplate's face is bundled, with its licence", () => {
  const css = wallCss();
  assert.match(css, /@font-face \{[^}]*font-family: "Cinzel";[^}]*src: url\("fonts\/cinzel-latin-wght-normal\.woff2"\)/);
  assert.match(read("./fleet/fonts/OFL.txt"), /SIL Open Font License, Version 1\.1/);
});
