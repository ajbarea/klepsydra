// Draws the Professions and DiceBear themes' faces as SVG, one per character
// in src/fleet/themes/{professions,dicebear}.json, with the source and
// licence of each, for render-themes.py to rasterize. Run through
// scripts/render-themes.sh, which installs the pinned packages into a temp
// dir and passes it here.
// Usage: node scripts/render-themes.mjs <dir holding node_modules> <out dir>
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { contrast } from "../src/fleet/contrast.js";

export const PINS = { "@dicebear/core": "9.4.2", "@dicebear/lorelei": "9.4.2", "lucide-static": "1.55.0" };

// Each profession's Lucide glyph.
export const GLYPHS = {
  counsellor: "heart", foreman: "hammer", engineer: "wrench", reviewer: "eye", archivist: "archive",
  guide: "compass", inspector: "clipboard-check", editor: "pen-line", architect: "drafting-compass",
  researcher: "search", timekeeper: "clock", guard: "shield", messenger: "send", mentor: "sprout",
  librarian: "book-open",
};

// The ground DiceBear's Lorelei faces had before #37 (render-lorelei.mjs at 7976bf9^), seeded by the voice id.
const LORELEI_BACKGROUNDS = ["b6e3f4", "c0aede", "d1d4f9", "ffd5dc", "ffdfbf"];
const LORELEI = "DiceBear Lorelei, a remix of Lorelei by Lisa Wischofsky (https://www.dicebear.com/styles/lorelei/)";
const LUCIDE = "Lucide (https://lucide.dev)";
const ISC = "ISC (Lucide LICENSE, Copyright (c) Lucide Icons and Contributors)";
const MIT = "MIT (Feather, Copyright (c) 2013-present Cole Bemis; in Lucide's LICENSE)";
// The Lucide LICENSE, shipped beside the faces it covers.
export const LICENSE_FILE = "professions/LICENSE-lucide.txt";

/** The icons Lucide's LICENSE names as derived from Feather, which stay under Feather's MIT licence. */
export function featherIcons(license) {
  const list = license.match(/derived from the Feather project:\s*\n\s*\n([^\n]+)/)?.[1];
  if (!list) throw new Error("no Feather list in the Lucide LICENSE");
  return new Set(list.split(",").map((s) => s.trim()).filter(Boolean));
}

/** A glyph's licence: Feather's MIT for an icon derived from Feather, else Lucide's ISC. */
export const glyphLicense = (glyph, feather) => (feather.has(glyph) ? MIT : ISC);

/** The glyph's ink on an accent disc: the darker or lighter of two, whichever reads better. */
export const glyphInk = (accent) => (contrast("#11151b", accent) >= contrast("#ffffff", accent) ? "#11151b" : "#ffffff");

/** A profession's face: its accent disc, a thin darker rim, and its Lucide glyph centred in ink. */
export function professionSvg(accent, glyph) {
  const inner = glyph
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/^[\s\S]*?<svg[^>]*>/, "")
    .replace(/<\/svg>\s*$/, "")
    .trim();
  const ink = glyphInk(accent);
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">' +
    `<circle cx="48" cy="48" r="48" fill="${accent}"/>` +
    '<circle cx="48" cy="48" r="46.5" fill="none" stroke="#000" stroke-opacity=".18" stroke-width="3"/>' +
    `<g transform="translate(22 22) scale(2.1667)" fill="none" stroke="${ink}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</g>` +
    "</svg>"
  );
}

async function main([modules, out]) {
  if (!modules || !out) {
    console.error("usage: node scripts/render-themes.mjs <dir holding node_modules> <out dir>");
    process.exit(2);
  }
  const pkg = (name) => join(modules, "node_modules", ...name.split("/"));
  for (const [name, want] of Object.entries(PINS)) {
    const { version } = JSON.parse(readFileSync(join(pkg(name), "package.json"), "utf8"));
    if (version !== want) throw new Error(`${name} is ${version}, want ${want}`);
  }
  const { createAvatar } = await import(pathToFileURL(join(pkg("@dicebear/core"), "lib", "index.js")).href);
  const lorelei = await import(pathToFileURL(join(pkg("@dicebear/lorelei"), "lib", "index.js")).href);
  const theme = (id) => JSON.parse(readFileSync(new URL(`../src/fleet/themes/${id}.json`, import.meta.url), "utf8"));
  const manifest = {};
  const write = (file, svg, source, license) => {
    mkdirSync(join(out, file, ".."), { recursive: true });
    writeFileSync(join(out, file), svg);
    manifest[file] = { source, license };
  };

  const license = readFileSync(join(pkg("lucide-static"), "LICENSE"), "utf8");
  const feather = featherIcons(license);
  write(LICENSE_FILE, license, `lucide-static@${PINS["lucide-static"]} LICENSE`, "ISC AND MIT");
  const professions = theme("professions");
  for (const c of Object.values(professions.characters)) {
    const glyph = GLYPHS[c.face];
    if (!glyph) throw new Error(`no glyph for ${c.face}`);
    const svg = professionSvg(c.accent, readFileSync(join(pkg("lucide-static"), "icons", `${glyph}.svg`), "utf8"));
    const from = feather.has(glyph) ? `${LUCIDE} "${glyph}", derived from Feather (https://feathericons.com),` : `${LUCIDE} "${glyph}"`;
    write(`professions/${c.face}.svg`, svg, `${from} from lucide-static@${PINS["lucide-static"]}, on a ${c.accent} disc`, glyphLicense(glyph, feather));
  }
  const dicebear = theme("dicebear");
  for (const [voice, c] of Object.entries(dicebear.characters)) {
    const svg = createAvatar(lorelei, { seed: voice, backgroundColor: LORELEI_BACKGROUNDS }).toString();
    write(`dicebear/${c.face}.svg`, svg, `${LORELEI}, rendered with @dicebear/core@${PINS["@dicebear/core"]} and @dicebear/lorelei@${PINS["@dicebear/lorelei"]} from seed "${voice}"`, "CC0-1.0");
  }
  writeFileSync(join(out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`drew ${Object.keys(manifest).filter((f) => f.endsWith(".svg")).length} faces`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main(process.argv.slice(2));
