import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { GOLD, GOLD_LIGHT, RATE, SPEAK_FADE_MS, SPEAK_HOLD_MS, STILL, Speaker, WAVE, levelAt, speakingNow, waves } from "./fleet/speaking.js";
import { contrast } from "./fleet/contrast.js";

const T0 = 1_792_520_221; // seconds
const ms = (s) => s * 1000;
// Epoch seconds as floats lose a few microseconds; a level is good to 0.001.
const near = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-3, `${a} vs ${b} ${msg ?? ""}`);
/** A sentence of `id` from `from` for `secs` seconds, at `level` throughout. */
const line = (id, from, secs, level = 0.5) => ({
  session_id: id,
  started_at: from,
  ends_at: from + secs,
  envelope: Array(Math.ceil(secs * RATE)).fill(level),
});

test("the gap hold is a named 600 ms", () => {
  assert.equal(SPEAK_HOLD_MS, 600);
});

test("the level is the envelope sample at (now - started_at) * 20, read between samples", () => {
  const l = { session_id: "a", started_at: T0, ends_at: T0 + 0.2, envelope: [0, 1, 0.5, 0.25] };
  assert.equal(levelAt(l, ms(T0)), 0);
  near(levelAt(l, ms(T0 + 0.05)), 1);
  near(levelAt(l, ms(T0 + 0.025)), 0.5, "halfway between 0 and 1");
  near(levelAt(l, ms(T0 + 0.15)), 0.25);
  assert.equal(levelAt(l, ms(T0 - 0.01)), 0, "before the line");
  assert.equal(levelAt(l, ms(T0 + 0.2)), 0, "after the line, or in a gap");
  assert.equal(levelAt({ ...l, envelope: [] }, ms(T0)), 0);
  assert.equal(levelAt(null, ms(T0)), 0);
  assert.equal(levelAt({ ...l, envelope: [3] }, ms(T0)), 1, "held to the loudest");
});

test("one utterance is announced once, however many sentences it has", () => {
  const sp = new Speaker();
  assert.equal(sp.update(line("a", T0, 2), ms(T0)), "a");
  assert.equal(sp.update(line("a", T0, 2), ms(T0 + 1)), null, "the same snapshot again");
  // The next sentence lands 0.4 s after the first ended: inside the hold.
  assert.equal(sp.update(line("a", T0 + 2.4, 1.5), ms(T0 + 2.4)), null);
  assert.equal(sp.frame(ms(T0 + 2.2)).alpha, 1);
});

test("sentence gaps under the hold keep the waves up; then they fade and stop", () => {
  const sp = new Speaker();
  sp.update(line("a", T0, 2), ms(T0));
  sp.update(null, ms(T0 + 2.1)); // the reader dropped the ended clip during the gap
  const inGap = sp.frame(ms(T0 + 2) + SPEAK_HOLD_MS - 1);
  assert.deepEqual([inGap.id, inGap.level, inGap.alpha], ["a", 0, 1]);
  const fading = sp.frame(ms(T0 + 2) + SPEAK_HOLD_MS + SPEAK_FADE_MS / 2);
  assert.ok(fading.alpha > 0 && fading.alpha < 1, String(fading.alpha));
  assert.equal(sp.frame(ms(T0 + 2) + SPEAK_HOLD_MS + SPEAK_FADE_MS), null);
  assert.equal(sp.showing(ms(T0 + 10)), false);
  // A sentence after a longer gap is a new utterance.
  assert.equal(sp.update(line("a", T0 + 4, 1), ms(T0 + 4)), "a");
});

test("a cut-off fades at once, and a new line after it is announced", () => {
  const sp = new Speaker();
  sp.update(line("a", T0, 3), ms(T0));
  sp.update(null, ms(T0 + 1));
  assert.ok(sp.frame(ms(T0 + 1) + 1).alpha < 1, "fading from the cut");
  assert.equal(sp.frame(ms(T0 + 1) + SPEAK_FADE_MS), null);
  sp.update(line("a", T0, 3), ms(T0));
  sp.update(null, ms(T0 + 1));
  assert.equal(sp.update(line("a", T0 + 1.2, 1), ms(T0 + 1.2)), "a", "cut off, so a new line");
});

test("another session's line moves the waves and is announced", () => {
  const sp = new Speaker();
  sp.update(line("a", T0, 2), ms(T0));
  assert.equal(sp.update(line("b", T0 + 1, 2), ms(T0 + 1)), "b");
  assert.equal(sp.frame(ms(T0 + 1.5)).id, "b");
});

test("a line already over when it arrives is not announced or shown", () => {
  const sp = new Speaker();
  assert.equal(sp.update(line("a", T0, 1), ms(T0 + 1) + SPEAK_HOLD_MS), null);
  assert.equal(sp.frame(ms(T0 + 1) + SPEAK_HOLD_MS), null);
  for (const bad of [{}, { session_id: "a" }, { ...line("a", T0, 1), started_at: "x" }, { ...line("a", T0, 1), envelope: null }]) {
    assert.equal(new Speaker().update(bad, ms(T0)), null);
  }
});

test("the waves sit outside the crew ring, inside the card's padding, and follow the loudness", () => {
  const at = (level, alpha = 1) => waves(level, alpha, 12_345);
  for (const level of [0, 0.5, 1]) {
    const rings = at(level);
    assert.equal(rings.length, WAVE.rings);
    for (const w of rings) {
      assert.ok(w.r - w.width / 2 >= 40, `inner edge ${w.r - w.width / 2} clears the crew ring`);
      assert.ok(w.r + w.width / 2 <= 52, `outer edge ${w.r + w.width / 2} inside the avatar's room`);
    }
  }
  const sum = (rings, k) => rings.reduce((s, w) => s + w[k], 0);
  for (const k of ["r", "width", "opacity"]) assert.ok(sum(at(1), k) > sum(at(0.1), k), `${k} grows with level`);
  assert.equal(sum(at(1, 0), "opacity"), 0, "a finished fade is invisible");
  assert.ok(at(0).every((w) => w.width >= 0.8), "thick enough to read");
  assert.ok(at(0)[0].width >= 2.5 && at(0)[0].opacity === 1, "the steady ring reads even in a gap");
  const ripple = (t) => waves(1, 1, t)[1];
  assert.equal(ripple(0).color.toLowerCase(), GOLD_LIGHT.toLowerCase(), "a ripple leaves the portrait light");
  assert.ok(ripple(WAVE.periodMs - 1).r > ripple(0).r, "and spreads");
  assert.equal(waves(1, 1, 0)[0].color, GOLD);
});

test("the golds read on the card and the strip, and are neither needs-you amber nor done green", () => {
  const wallCss = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const badgeCss = readFileSync(new URL("./fleet/badge.css", import.meta.url), "utf8");
  const styleCss = readFileSync(new URL("./style.css", import.meta.url), "utf8");
  const token = (css, name) => css.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim().toLowerCase();
  for (const g of [GOLD, GOLD_LIGHT]) {
    assert.ok(contrast(g, token(wallCss, "--card-bg")) >= 3, g);
    assert.ok(contrast(g, token(wallCss, "--card-quiet")) >= 3, g);
    for (const t of ["--badge-needs", "--badge-done"]) assert.notEqual(g.toLowerCase(), token(badgeCss, t));
  }
  assert.equal(token(styleCss, "--speak-gold"), GOLD.toLowerCase());
  assert.ok(contrast(GOLD, "#141414") >= 3, "on the strip's panel");
  assert.ok(STILL.width >= 3 && STILL.r - STILL.width / 2 >= 40);
});

test("the strip marks the speaking session through the hold only", () => {
  const l = line("a", T0, 2);
  assert.equal(speakingNow(l, ms(T0 + 1)), true);
  assert.equal(speakingNow(l, ms(T0 + 2) + SPEAK_HOLD_MS - 1), true);
  assert.equal(speakingNow(l, ms(T0 + 2) + SPEAK_HOLD_MS), false);
  assert.equal(speakingNow(null, ms(T0)), false);
});

test("frames run only while someone speaks, and reduced motion gets a still ring", () => {
  const src = readFileSync(new URL("./fleet/wall.js", import.meta.url), "utf8");
  const draw = src.slice(src.indexOf("function drawSpeaking"), src.indexOf("function receive"));
  // The waves' frames, and one frame for Auto's density check after the wall resizes.
  assert.equal((src.match(/requestAnimationFrame\(/g) ?? []).length, 2, "two places schedule frames");
  assert.match(src, /densityFrame = requestAnimationFrame\(showDensity\)/, "the density check is one frame, never a loop");
  assert.ok(draw.indexOf("if (!f) return;") < draw.indexOf("requestAnimationFrame("), "idle stops the loop");
  assert.match(draw, /reducedMotion\(\)[\s\S]*circles\(svg, "still", 1\)[\s\S]*return;/);
  assert.match(src, /said\.push\(`\$\{identity\(who, cast\)\.name\} speaking`\)/);
  assert.match(readFileSync(new URL("./wall.html", import.meta.url), "utf8"), /<svg class="waves"[^>]*aria-hidden="true">/);
});

test("the waves stay clear of the nameplate and the next card: on the band, and on a compact card", () => {
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
  const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.[\]"=:()]/g, "\\$&")} \\{([^}]*)\\}`))?.[1] ?? "";
  const tokens = (block) => Object.fromEntries([...block.matchAll(/(--[\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
  const root = tokens(rule(":root"));
  const px = (set, name) => {
    const v = set[name] ?? root[name];
    const ref = v.match(/^var\((--[\w-]+)\)$/);
    return ref ? px(set, ref[1]) : parseFloat(v);
  };
  assert.match(rule(".portrait .waves"), /--reach: calc\(var\(--wall-face\) \* 12 \/ 80\)/, "the waves scale with the portrait");
  // How far the waves reach past the portrait's edge, in its 80 units, at their loudest.
  let reach = 0;
  for (const level of [0, 0.5, 1]) {
    for (let t = 0; t < WAVE.periodMs; t += 10) for (const w of waves(level, 1, t)) reach = Math.max(reach, w.r + w.width / 2 - 40);
  }

  // The band: a figure's waves ride its head, in an aura clipped where the figure breaks the edge.
  const header = tokens(rule(".card header"));
  const fig = parseFloat(header["--fig"]);
  const figLeft = parseFloat(header["--fig-left"]);
  const textLeft = parseFloat(rule(".card header").match(/padding: 0 var\(--space-8\) var\(--space-4\) (\d+)px/)[1]);
  assert.match(rule(".has-figure .aura"), /inset: calc\(var\(--band-h\) - var\(--fig\)\) 0 0 0;[^}]*overflow: hidden;/);
  const face = px({}, "--wall-face");
  const out = face / 2 + (reach * face) / 80;
  for (const c of Object.values(cast.characters)) {
    const right = figLeft + c.head[0] * fig + out;
    assert.ok(right <= textLeft, `${c.name}'s waves end at ${right.toFixed(1)} px, the nameplate starts at ${textLeft}`);
  }
  // A medallion on the band keeps its round portrait, inside the band.
  const medallion = rule(".card:not(.has-figure) .portrait").match(/left: (\d+)px; top: (\d+)px/).slice(1).map(Number);
  const edge = (reach * face) / 80;
  assert.ok(medallion[0] + face + edge <= textLeft, "a medallion's waves stay off the nameplate");
  assert.ok(medallion[1] - edge >= 0 && medallion[1] + face + edge <= px({}, "--band-h"), "and inside the band");

  // Compact: the room the head gap and the row gap leave.
  const compact = tokens(rule('[data-density="compact"]'));
  assert.match(rule('[data-density="compact"] .name'), /margin-left: var\(--head-gap\)/);
  assert.match(rule('[data-density="compact"] .meta'), /margin-top: var\(--card-rows\)/);
  const room = Math.min(px(compact, "--head-gap"), px(compact, "--card-rows"));
  const tight = (reach * px(compact, "--wall-face")) / 80;
  assert.ok(tight <= room, `compact: ${tight} past the portrait, ${room} free`);
});

test("the reader keeps a half-read line as long as the wall holds a gap", () => {
  const rs = readFileSync(new URL("../src-tauri/fleet/src/speaking.rs", import.meta.url), "utf8");
  assert.equal(Number(rs.match(/pub const HOLD_SECS: f64 = ([\d.]+);/)[1]) * 1000, SPEAK_HOLD_MS);
});
