// The character themes (#135): Kourai, Professions and DiceBear, as data.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DEFAULT_THEME, THEMES, keeperOf, themeId, themeOf } from "./fleet/theme.js";
import { castFiles } from "./fleet/cast.js";
import { card, identity, stripItems } from "./fleet/model.js";
import { characterOf, tokensByCharacter } from "./fleet/ledger.js";
import { contrast } from "./fleet/contrast.js";
import { GLYPHS, PINS, glyphInk } from "../scripts/render-themes.mjs";

const ROOT = join(import.meta.dirname, "..");
const read = (f) => readFileSync(join(ROOT, f), "utf8");
const kourai = THEMES.kourai;
const VOICES = Object.keys(kourai.characters).sort();
const IDS = ["kourai", "professions", "dicebear"];
const NOW = Date.UTC(2026, 9, 27, 12);
const demo = JSON.parse(read("scripts/fixtures/fleet-demo.json"));
const shifted = demo.sessions.map((s) => ({ ...s }));

test("three themes, one data file each under themes/, Kourai first and the default", () => {
  assert.deepEqual(Object.keys(THEMES), IDS);
  assert.equal(DEFAULT_THEME, "kourai");
  assert.deepEqual(readdirSync(join(ROOT, "src/fleet/themes")).sort(), IDS.map((id) => `${id}.json`).sort());
  for (const id of IDS) assert.deepEqual(THEMES[id], JSON.parse(read(`src/fleet/themes/${id}.json`)), id);
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

test("a switch changes only the look: every voice keeps its accent and gender in every theme", () => {
  for (const [id, t] of Object.entries(THEMES)) {
    for (const voice of VOICES) {
      assert.equal(t.characters[voice].accent, kourai.characters[voice].accent, `${id} ${voice} accent`);
      assert.equal(t.characters[voice].gender, kourai.characters[voice].gender, `${id} ${voice} gender`);
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
    assert.equal(themeOf(bad), kourai, String(bad));
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
const LOOK = new Set(["name", "face", "face2x", "full", "epithet", "figure", "label", "remoteLabel", "playLabel", "stopLabel", "menuLabel", "jumpLabel"]);

test("switching themes changes only each card's look: accents, rings, tone, actions and order stay", () => {
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
  for (const [name, version] of Object.entries(PINS)) {
    assert.match(version, /^\d+\.\d+\.\d+$/, `${name} is pinned exactly`);
    assert.ok(sh.includes(`${name}@${version}`), `render-themes.sh installs ${name}@${version}`);
  }
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
  assert.deepEqual([...theme.matchAll(/from "\.\/themes\/([a-z]+)\.json"/g)].map((m) => m[1]), IDS);
});

test("the wall, the strip and the drawer read the theme now worn, not a fixed cast", () => {
  const wall = read("src/fleet/wall.js");
  assert.doesNotMatch(wall, /cast\.json/);
  assert.match(wall, /cast: \(\) => cast,/, "the drawer asks for the theme each time");
  assert.match(wall, /subscribeTheme\(\(id\) => wearTheme\(id\)\)/);
  assert.match(wall, /if \(served && Array\.isArray\(message\?\.sessions\)\) wearTheme\(message\.theme, false\);/, "the phone wears the snapshot's theme");
  assert.match(wall, /invoke\("set_theme", \{ theme: id \}\)/);
  assert.doesNotMatch(read("src/fleet/strip.js"), /cast\.json|import cast/);
  assert.match(read("src/main.js"), /subscribeTheme\(\(id\) => \{\s*if \(themeOf\(id\) === theme\) return;\s*theme = themeOf\(id\);\s*render\(\);\s*\}\);/, "the gauge's strip redraws on a switch");
  assert.match(read("src/main.js"), /cast: \(\) => theme,/, "and draws the theme now worn");
  const html = read("src/wall.html");
  assert.match(html, /<label class="theme-pick"[^>]*><span class="visually-hidden">Characters<\/span><select id="theme"><\/select><\/label>/);
  assert.match(read("src/fleet/wall.css"), /\.served \.theme-pick,/, "no picker on the phone");
});
