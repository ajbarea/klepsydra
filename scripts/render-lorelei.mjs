// Renders the fleet's DiceBear Lorelei faces into src/fleet/faces, with a
// LICENSES.json entry for each: one per Kokoro voice in cast.json, and the
// fallbacks. Run through scripts/render-faces.sh, which installs the pinned
// DiceBear packages into a temp dir and passes it here.
// Usage: node scripts/render-lorelei.mjs <dir holding node_modules> <faces dir>
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const VERSION = "9.4.2";
const ARTWORK = "DiceBear Lorelei by Lisa Wischofsky (https://www.figma.com/community/file/1198749693280469639)";
// Light grounds, so the line art reads against the dark strip.
const BACKGROUNDS = ["b6e3f4", "c0aede", "d1d4f9", "ffd5dc", "ffdfbf"];

const [modules, faces] = process.argv.slice(2);
if (!modules || !faces) {
  console.error("usage: node scripts/render-lorelei.mjs <dir holding node_modules> <faces dir>");
  process.exit(2);
}
const load = (pkg) => import(pathToFileURL(join(modules, "node_modules", pkg, "lib", "index.js")).href);
const { createAvatar } = await load("@dicebear/core");
const lorelei = await load("@dicebear/lorelei");
for (const pkg of ["core", "lorelei"]) {
  const { version } = JSON.parse(readFileSync(join(modules, "node_modules", "@dicebear", pkg, "package.json"), "utf8"));
  if (version !== VERSION) throw new Error(`@dicebear/${pkg} is ${version}, want ${VERSION}`);
}

const cast = JSON.parse(readFileSync(new URL("../src/fleet/cast.json", import.meta.url), "utf8"));
const licensesPath = join(faces, "LICENSES.json");
const licenses = JSON.parse(readFileSync(licensesPath, "utf8"));
const pad = (n) => String(n).padStart(2, "0");

function render(file, seed) {
  const svg = createAvatar(lorelei, { seed, backgroundColor: BACKGROUNDS }).toString();
  mkdirSync(join(faces, file, ".."), { recursive: true });
  writeFileSync(join(faces, file), `${svg}\n`);
  licenses[file] = {
    source: `${ARTWORK}, rendered with @dicebear/core@${VERSION} and @dicebear/lorelei@${VERSION} from seed "${seed}"`,
    license: "CC0-1.0",
  };
}

for (const voice of cast.lorelei) render(`lorelei/${voice}.svg`, voice);
for (let i = 0; i < cast.fallbacks; i++) render(`fallback/${pad(i)}.svg`, `klepsydra-fallback-${pad(i)}`);

const sorted = Object.fromEntries(Object.entries(licenses).sort(([a], [b]) => a.localeCompare(b)));
writeFileSync(licensesPath, `${JSON.stringify(sorted, null, 2)}\n`);
console.log(`rendered ${cast.lorelei.length} voice faces and ${cast.fallbacks} fallbacks`);
