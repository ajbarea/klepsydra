// The character themes (#135): Kourai, Professions and DiceBear, as data.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DEFAULT_THEME, THEME_LABELS, keeperName, keeperOf, loadTheme, loadedTheme, themeId } from "./fleet/theme.js";
import { castFiles } from "./fleet/cast.js";
import { card, identity, stripItems } from "./fleet/model.js";
import { characterOf, tokensByCharacter } from "./fleet/ledger.js";
import { contrast, markerWidth, MARKER_PX, oklab } from "./fleet/contrast.js";
import { BUTTON_BGS } from "./fleet/model.js";
import { GLYPHS, LICENSE_FILE, PINS, featherIcons, glyphInk, glyphLicense } from "../scripts/render-themes.mjs";

const ROOT = join(import.meta.dirname, "..");
const read = (f) => readFileSync(join(ROOT, f), "utf8");
// The theme files as they are on disk; the page loads them through theme.js.
const IDS = ["kourai", "professions", "dicebear"];
const THEMES = Object.fromEntries(IDS.map((id) => [id, JSON.parse(readFileSync(join(import.meta.dirname, "fleet", "themes", `${id}.json`), "utf8"))]));
const kourai = THEMES.kourai;
const VOICES = Object.keys(kourai.characters).sort();
const NOW = Date.UTC(2026, 9, 27, 12);
const demo = JSON.parse(read("scripts/fixtures/fleet-demo.json"));
const shifted = demo.sessions.map((s) => ({ ...s }));

test("three themes, one data file each under themes/, Kourai first and the default", () => {
  assert.deepEqual(Object.keys(THEME_LABELS), IDS);
  assert.equal(DEFAULT_THEME, "kourai");
  assert.deepEqual(readdirSync(join(ROOT, "src/fleet/themes")).sort(), IDS.map((id) => `${id}.json`).sort());
  for (const id of IDS) assert.equal(THEME_LABELS[id], THEMES[id].label, `${id}: the picker's name is the file's`);
});

test("a page loads the default theme with itself and any other once, the first time it is worn", async () => {
  assert.deepEqual(loadedTheme("kourai"), kourai, "Kourai comes with the page");
  assert.equal(loadedTheme("professions"), null, "not fetched until worn");
  const [a, b] = await Promise.all([loadTheme("professions"), loadTheme("professions")]);
  assert.equal(a, b, "one load for two asks");
  assert.deepEqual(a, THEMES.professions);
  assert.equal(loadedTheme("professions"), a, "kept once loaded");
  assert.deepEqual(await loadTheme("dicebear"), THEMES.dicebear);
  assert.equal(await loadTheme("no-such-theme"), loadedTheme("kourai"), "an unknown theme is the default");
});

test("every theme has cast.json's shape and covers every voice in the cast, and no other", () => {
  const ALLOWED = ["accent", "epithet", "face", "gender", "head", "name"];
  for (const [id, t] of Object.entries(THEMES)) {
    assert.deepEqual(Object.keys(t).sort(), ["characters", "faces", "keeper", "label", "v"], id);
    assert.equal(t.v, 1, id);
    assert.equal(t.faces, id, `${id}: its faces folder is its id`);
    assert.deepEqual(Object.keys(t.characters).sort(), VOICES, `${id} covers every voice`);
    assert.ok(Object.hasOwn(t.characters, t.keeper), `${id}: the keeper is in its cast`);
    const names = Object.values(t.characters).map((c) => c.name);
    assert.equal(new Set(names).size, names.length, `${id}: every name its own`);
    for (const [voice, c] of Object.entries(t.characters)) {
      for (const k of ["name", "face", "accent", "gender"]) assert.ok(typeof c[k] === "string" && c[k], `${id} ${voice} ${k}`);
      assert.deepEqual(Object.keys(c).filter((k) => !ALLOWED.includes(k)), [], `${id} ${voice}`);
      assert.ok(castFiles(c, t), `${id} ${voice}: its face is a plain path segment`);
    }
  }
});

test("every voice keeps its gender in every theme, and every character has a name of its own and an epithet", () => {
  for (const [id, t] of Object.entries(THEMES)) {
    for (const voice of VOICES) {
      const c = t.characters[voice];
      assert.equal(c.gender, kourai.characters[voice].gender, `${id} ${voice} gender`);
      assert.ok(typeof c.epithet === "string" && c.epithet.length >= 5, `${id} ${voice} has an epithet`);
      // Kourai's Puck is named for his Kokoro seed; the others name a character, not a voice.
      if (id !== "kourai") assert.notEqual(c.name.toLowerCase(), voice.slice(3), `${id} ${voice}: a character's name, not the voice's`);
    }
  }
  // One name, one voice, across every theme: a name another theme gave (the Queue's keeper) maps back.
  const owner = new Map();
  for (const t of Object.values(THEMES)) {
    for (const [voice, c] of Object.entries(t.characters)) {
      assert.ok(!owner.has(c.name) || owner.get(c.name) === voice, `${c.name} names two voices`);
      owner.set(c.name, voice);
    }
  }
});

// Machado, Oliveira and Fernandes (2009) dichromacy at severity 1, in linear sRGB.
const CVD = {
  protanopia: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
  deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.01182, 0.04294, 0.968881]],
  tritanopia: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.3039]],
};
const toLinear = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const toHex = (lin) => `#${lin.map((v) => { v = Math.min(1, Math.max(0, v)); v = v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055; return Math.round(v * 255).toString(16).padStart(2, "0"); }).join("")}`;
const seenAs = (hex, m) => {
  const c = [1, 3, 5].map((i) => toLinear(parseInt(hex.slice(i, i + 2), 16) / 255));
  return toHex(m.map((row) => row[0] * c[0] + row[1] * c[1] + row[2] * c[2]));
};
const apart = (a, b) => Math.hypot(...oklab(a).map((v, i) => v - oklab(b)[i]));
const nearest = (list) => Math.min(...list.flatMap((a, i) => list.slice(i + 1).map((b) => apart(a, b))));

test("each theme has its own accents; Professions' and DiceBear's clear 3:1 on every surface and read apart, also to a colour-blind eye", () => {
  const css = read("src/fleet/wall.css");
  const token = (name) => css.match(new RegExp(`${name}:\\s*(#[0-9a-f]{6})`, "i"))[1];
  const surfaces = ["--card-bg", "--plinth-bg", ...["--button-bg", "--button-hover"]].map(token);
  assert.deepEqual(surfaces.slice(2), BUTTON_BGS);
  const statuses = ["#E69F00", "#D55E00", "#0072B2", "#009E73"];
  const accents = (id) => VOICES.map((v) => THEMES[id].characters[v].accent);
  assert.notDeepEqual(accents("professions"), accents("kourai"));
  assert.notDeepEqual(accents("dicebear"), accents("kourai"));
  assert.notDeepEqual(accents("dicebear"), accents("professions"));
  for (const id of ["professions", "dicebear"]) {
    const list = accents(id);
    assert.equal(new Set(list).size, 15, `${id}: fifteen accents`);
    for (const a of list) {
      for (const bg of surfaces) assert.ok(contrast(a, bg) >= 3, `${id} ${a} on ${bg}: ${contrast(a, bg).toFixed(2)} (WCAG 1.4.11)`);
      assert.equal(markerWidth(a, BUTTON_BGS), MARKER_PX, `${id} ${a}: the plain marker`);
      for (const st of statuses) assert.ok(apart(a, st) >= 0.05, `${id} ${a} looks like the status tone ${st}`);
    }
    // Hue tells them apart; lightness, in three steps, still does where hue fails.
    assert.ok(nearest(list) >= 0.08, `${id}: nearest pair ${nearest(list).toFixed(3)}`);
    for (const [kind, m] of Object.entries(CVD)) {
      const near = nearest(list.map((a) => seenAs(a, m)));
      assert.ok(near >= 0.015, `${id} under ${kind}: nearest pair ${near.toFixed(3)}`);
    }
  }
});

test("every character in every theme has its face files, and a full picture for the portrait and the keeper", () => {
  const licenses = JSON.parse(read("src/fleet/faces/LICENSES.json"));
  for (const [id, t] of Object.entries(THEMES)) {
    for (const c of Object.values(t.characters)) {
      const base = castFiles(c, t).replace(/^fleet\//, "src/fleet/");
      const kinds = ["96", "192", "full", ...(c.head ? ["figure"] : [])];
      for (const kind of kinds) {
        const file = `${base}-${kind}.webp`;
        assert.ok(existsSync(join(ROOT, file)), file);
        assert.ok(licenses[file.replace("src/fleet/faces/", "")]?.license, `${file} licence`);
      }
    }
    const keeper = keeperOf(t);
    assert.ok(keeper && existsSync(join(ROOT, "src", keeper)), `${id} keeper ${keeper}`);
  }
  assert.equal(keeperOf(THEMES.kourai), "fleet/faces/kourai/hesychia-full.webp", "Hesychia keeps the Kourai wall");
});

test("only Kourai places a figure; the others fall back to the round portrait and its full picture", () => {
  for (const [id, t] of Object.entries(THEMES)) {
    for (const c of Object.values(t.characters)) assert.equal("head" in c, id === "kourai", `${id} ${c.name}`);
  }
  const s = { session_id: "x", voice: "am_michael" };
  for (const id of ["professions", "dicebear"]) {
    const who = identity(s, THEMES[id]);
    assert.equal(who.figure, null, id);
    assert.equal(who.full, `fleet/faces/${id}/${THEMES[id].characters.am_michael.face}-full.webp`, id);
  }
});

test("an unknown theme is Kourai, an Object property included", () => {
  for (const id of IDS) assert.equal(themeId(id), id);
  for (const bad of ["Professions", "", "lorelei", "__proto__", "constructor", "toString", "hasOwnProperty", null, undefined, 3, {}, ["kourai"]]) {
    assert.equal(themeId(bad), "kourai", String(bad));
    assert.deepEqual(loadedTheme(bad), kourai, String(bad));
  }
});

test("the theme ids and names are the fleet crate's (theme.rs THEMES), the default first", () => {
  const rs = read("src-tauri/fleet/src/theme.rs");
  const block = rs.match(/pub const THEMES: \[\(&str, &str\); (\d+)\] = \[([\s\S]*?)\];/);
  const pairs = [...block[2].matchAll(/\("([^"]+)", "([^"]+)"\)/g)].map((m) => [m[1], m[2]]);
  assert.equal(Number(block[1]), pairs.length);
  assert.deepEqual(pairs, Object.entries(THEMES).map(([id, t]) => [id, t.label]));
});

/** A card's fields that may differ between two themes: who the session is, never what it does. */
const LOOK = new Set(["name", "face", "face2x", "full", "epithet", "figure", "accent", "accentInk", "ringColor", "jumpMark", "label", "remoteLabel", "playLabel", "stopLabel", "menuLabel", "jumpLabel"]);

test("switching themes changes only each card's look (name, face, epithet, accent); rings, tone, actions and order stay", () => {
  const cards = (id) => shifted.map((s) => card(s, THEMES[id], NOW));
  const base = cards("kourai");
  for (const id of ["professions", "dicebear"]) {
    const other = cards(id);
    assert.deepEqual(other.map((c) => c.id), base.map((c) => c.id));
    for (const [i, c] of other.entries()) {
      for (const k of Object.keys(c)) {
        if (!LOOK.has(k)) assert.deepEqual(c[k], base[i][k], `${id} ${c.id} ${k}`);
      }
    }
    assert.ok(other.some((c, i) => c.name !== base[i].name), `${id} changes some name`);
    assert.ok(other.some((c, i) => c.accent && c.accent !== base[i].accent), `${id} changes some accent`);
  }
});

test("a voice outside the cast is the same medallion in every theme", () => {
  for (const voice of ["bm_lewis", null, "af_heart(0.5)+af_bella(0.5)"]) {
    const s = { session_id: "cb9fa591-1514-44d1-a31c-eba4a7cb41ed", name: "Fix the build", voice };
    const looks = IDS.map((id) => identity(s, THEMES[id]));
    for (const who of looks) assert.deepEqual(who, looks[0], String(voice));
    assert.match(looks[0].face, /^data:image\/svg\+xml,/);
  }
});

test("the strip and the ledger drawer name a voice by the theme worn", () => {
  const s = { session_id: "a", voice: "bm_fable", status: "working", status_at: NOW / 1000 };
  for (const id of IDS) {
    const name = THEMES[id].characters.bm_fable.name;
    const [item] = stripItems([s], THEMES[id], NOW, null);
    assert.match(item.label, new RegExp(`^${name},`), id);
    assert.equal(characterOf("a", { a: "bm_fable" }, THEMES[id]).name, name, id);
    assert.equal(tokensByCharacter([["a", { tokens: { input: 1 } }]], { a: "bm_fable" }, THEMES[id])[0].name, name, id);
  }
});

test("a face folder or face that is not a plain path segment shows the medallion, never a path", () => {
  const s = { session_id: "x", voice: "am_michael" };
  const good = { faces: "kourai", characters: { am_michael: { name: "H", face: "hephaestus", accent: "#DA8C20" } } };
  assert.equal(identity(s, good).face, "fleet/faces/kourai/hephaestus-96.webp");
  for (const faces of ["../kourai", "Kourai", "", "a/b", "kourai/", null, 1, ".hidden"]) {
    const who = identity(s, { ...good, faces });
    assert.match(who.face, /^data:image\/svg\+xml,/, String(faces));
    assert.equal(who.full, null, String(faces));
  }
  for (const face of ["../x", "a/b", "", "X", null]) {
    const who = identity(s, { ...good, characters: { am_michael: { ...good.characters.am_michael, face } } });
    assert.match(who.face, /^data:image\/svg\+xml,/, String(face));
  }
  assert.equal(keeperOf({ ...good, keeper: "am_michael", faces: "../x" }), null);
  assert.equal(keeperOf({ ...good, keeper: "nobody" }), null);
});

test("each profession's glyph reads on its disc at 3:1 or more (WCAG 2.2, 1.4.11)", () => {
  for (const c of Object.values(THEMES.professions.characters)) {
    assert.ok(GLYPHS[c.face], `${c.face} has a glyph`);
    const ratio = contrast(glyphInk(c.accent), c.accent);
    assert.ok(ratio >= 3, `${c.name}: ${ratio.toFixed(2)}:1`);
  }
  assert.deepEqual(Object.keys(GLYPHS).sort(), Object.values(THEMES.professions.characters).map((c) => c.face).sort());
  assert.equal(new Set(Object.values(GLYPHS)).size, Object.keys(GLYPHS).length, "every profession its own glyph");
});

test("the faces are rendered offline from exactly pinned packages; nothing calls an avatar service", () => {
  const sh = read("scripts/render-themes.sh");
  const manifest = JSON.parse(read("scripts/render-themes/package.json"));
  assert.deepEqual(manifest.dependencies, PINS, "the render's package.json is the script's pins");
  for (const [name, version] of Object.entries(PINS)) assert.match(version, /^\d+\.\d+\.\d+$/, `${name} is pinned exactly`);
  // Every package, transitive ones too, at one version and hash: a rerender installs the same tree.
  const lock = JSON.parse(read("scripts/render-themes/package-lock.json"));
  assert.equal(lock.lockfileVersion, 3);
  assert.deepEqual(lock.packages[""].dependencies, PINS);
  for (const [name, version] of Object.entries(PINS)) assert.equal(lock.packages[`node_modules/${name}`]?.version, version, name);
  for (const [path, entry] of Object.entries(lock.packages).filter(([k]) => k)) {
    assert.match(entry.integrity ?? "", /^sha512-/, `${path} has its hash`);
    assert.match(entry.resolved ?? "", /^https:\/\/registry\.npmjs\.org\//, `${path} from the npm registry`);
  }
  assert.match(sh, /npm ci --prefix "\$tmp" [^\n]*--ignore-scripts/, "installed from the lockfile, no install scripts");
  assert.doesNotMatch(sh, /npm install/, "never an unlocked install");
  const pkg = JSON.parse(read("package.json"));
  const deps = { ...pkg.dependencies, ...pkg.devDependencies };
  assert.deepEqual(Object.keys(deps).filter((d) => /dicebear|lucide/.test(d)), [], "no avatar library in the app");
  const frontend = (dir) =>
    readdirSync(join(ROOT, dir), { recursive: true })
      .map((f) => `${dir}/${f}`)
      .filter((f) => /\.(js|mjs|html|css|json)$/.test(f) && !f.endsWith(".test.js") && !f.startsWith(`${dir}/fleet/faces/`));
  for (const f of [...frontend("src"), "src-tauri/tauri.conf.json"]) {
    assert.doesNotMatch(read(f), /dicebear\.com|api\.dicebear|@dicebear|lucide/i, f);
  }
  const csp = JSON.parse(read("src-tauri/tauri.conf.json")).app.security.csp;
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /img-src 'self' data:;/, "faces load from the bundle only");
});

test("one loader: only theme.js names a theme's file, and no frontend code branches on a theme", () => {
  const src = readdirSync(join(ROOT, "src/fleet")).filter((f) => f.endsWith(".js")).map((f) => `src/fleet/${f}`);
  // Code only: a comment may name a theme.
  const code = (f) => read(f).replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|\s)\/\/.*$/gm, "");
  for (const f of [...src, "src/main.js", "src/wall.html"]) {
    const text = code(f);
    if (f === "src/fleet/theme.js") continue;
    assert.doesNotMatch(text, /themes\/|\b(professions|dicebear)\b|["']kourai["']|faces\/kourai/i, f);
  }
  const theme = read("src/fleet/theme.js");
  // Only the default is part of the page; the others are fetched by id when first worn.
  assert.deepEqual([...theme.matchAll(/from "\.\/themes\/([a-z]+)\.json"/g)].map((m) => m[1]), ["kourai"]);
  assert.match(theme, /import\(`\.\/themes\/\$\{key\}\.json`, \{ with: \{ type: "json" \} \}\)/);
});

test("the wall, the strip and the drawer read the theme now worn, not a fixed cast", () => {
  const wall = read("src/fleet/wall.js");
  assert.doesNotMatch(wall, /cast\.json/);
  assert.match(wall, /cast: \(\) => cast,/, "the drawer asks for the theme each time");
  assert.match(wall, /subscribeTheme\(\(id\) => \{\s*if \(!saving\) wearTheme\(id\);\s*\}\);/, "the app's word, unless a choice waits to be saved");
  assert.match(wall, /document\.documentElement\.dataset\.theme = next;/, "html[data-theme] names the theme, as a CSS colour theme");
  assert.match(wall, /if \(served && Array\.isArray\(message\?\.sessions\)\) wearTheme\(message\.theme, false\);/, "the phone wears the snapshot's theme");
  assert.match(wall, /saving = setTimeout\(saveTheme, THEME_SAVE_MS\);/, "saved where the picker rests");
  for (const [target, event] of [["themePicker", "blur"], ["", "blur"], ["", "pagehide"]]) {
    assert.match(wall, new RegExp(`${target ? `${target}\\.` : "\\n"}addEventListener\\("${event}", flushTheme\\);`), `a waiting choice is saved on ${target || "window"} ${event}`);
  }
  assert.match(wall, /if \(document\.hidden\) flushTheme\(\);/);
  assert.match(wall, /setText\(themeNote, `Not saved: \$\{err\}`\);/, "a refused save says so");
  assert.doesNotMatch(read("src/fleet/strip.js"), /cast\.json|import cast/);
  assert.match(read("src/main.js"), /subscribeTheme\(\(id\) => \{\s*wanted = id;\s*loadTheme\(id\)\.then\(\(next\) => \{\s*if \(wanted !== id \|\| next === theme\) return;\s*theme = next;\s*render\(\);/, "the gauge's strip redraws on a switch, once the theme is loaded");
  assert.match(read("src/main.js"), /cast: \(\) => theme,/, "and draws the theme now worn");
  const html = read("src/wall.html");
  assert.match(html, /<label class="theme-pick"[^>]*><span>Characters<\/span><select id="theme"><\/select><\/label>/);
  assert.match(wall, /refillPortrait\(\);\n  drawer\.repaint\(\);\n  queue\.retheme\(\);/, "a switch refills an open portrait, the Ledger and the Queue's keeper, reading nothing");
  const drawer = read("src/fleet/drawer.js");
  assert.match(drawer, /const key = JSON\.stringify\(\[view, filter, \[\.\.\.names\], cast\(\)\.label\]\);/, "the Ledger repaints for a new theme");
  assert.match(drawer, /repaint: \(\) => paint\(\),/);
  assert.match(read("src/fleet/queuepanel.js"), /const name = keeperName\(keptBy, keptVoice, cast\(\)\);/);
  assert.match(wall, /if \(said\.length\) announce\(said\.join\("\. "\)\);\n    refillPortrait\(\);/, "and so does a snapshot, the phone's theme with it");
  assert.match(read("src/fleet/wall.css"), /\.served \.theme-pick,/, "no picker on the phone");
});

test("each profession's glyph carries its own licence: Feather's MIT where Lucide's LICENSE says it derives from Feather", () => {
  const license = read(`src/fleet/faces/${LICENSE_FILE}`);
  assert.match(license, /^ISC License/, "Lucide's LICENSE ships beside the faces");
  const feather = featherIcons(license);
  assert.ok(feather.size > 100 && feather.has("compass") && feather.has("airplay"), `the Feather list read whole (${feather.size})`);
  const licenses = JSON.parse(read("src/fleet/faces/LICENSES.json"));
  assert.equal(licenses[LICENSE_FILE]?.license, "ISC AND MIT");
  const fromFeather = [];
  for (const c of Object.values(THEMES.professions.characters)) {
    const glyph = GLYPHS[c.face];
    for (const size of ["96", "192", "full"]) {
      const entry = licenses[`professions/${c.face}-${size}.webp`];
      assert.equal(entry.license, glyphLicense(glyph, feather), `${c.face} ${size}`);
      assert.equal(/Feather/.test(entry.source), feather.has(glyph), `${c.face} ${size}: the source names Feather when it is`);
      assert.ok(entry.source.includes(`on a ${c.accent} disc`), `${c.face} ${size}: drawn on its accent (${entry.source})`);
    }
    if (feather.has(glyph)) fromFeather.push(glyph);
  }
  assert.deepEqual(fromFeather.sort(), ["clock", "compass", "search"], "Lucide 1.55.0 lists these three as Feather's");
  assert.match(glyphLicense("compass", feather), /^MIT \(Feather, Copyright \(c\) 2013-present Cole Bemis/);
  assert.match(glyphLicense("hammer", feather), /^ISC /);
  assert.match(read("README.md"), /\[Feather\]\(https:\/\/feathericons\.com\) \(MIT licence,\s+Copyright \(c\) 2013-present Cole Bemis\)/, "the README credits Feather");
});

test("the Queue's keeper is a character only by the voice the hook recorded; a typed name stays as typed", () => {
  for (const id of IDS) {
    const t = THEMES[id];
    // The hook named the keeper (no --by, in a voiced session): the theme names that voice.
    assert.equal(keeperName("Hephaestus", "am_michael", t), t.characters.am_michael.name, id);
    assert.equal(keeperName(null, "am_michael", t), t.characters.am_michael.name, id);
    // Typed with --by (no voice recorded), or a voice no theme casts: as typed, even another theme's name.
    for (const typed of ["Editor", "Max", "Heph (orchestrator)", "Hermes (orchestrator)", "Guard", "AJ"]) {
      assert.equal(keeperName(typed, null, t), typed, `${id}: ${typed}`);
      assert.equal(keeperName(typed, "bm_lewis", t), typed, `${id}: ${typed} with an uncast voice`);
    }
  }
  assert.equal(keeperName(null, null, THEMES.kourai), null);
});
