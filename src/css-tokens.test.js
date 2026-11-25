import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// A var() naming a custom property no stylesheet of its page defines (and no
// script sets) resolves to nothing, or silently to its fallback: a toggle
// whose knob is transparent passes every other test. Each page's stylesheets
// and scripts must define every property they use.
const SRC = new URL("./", import.meta.url).pathname;
const read = (rel) => readFileSync(join(SRC, rel), "utf8");
const strip = (css) => css.replace(/\/\*[\s\S]*?\*\//g, "");

function files(dir, ext, out = []) {
  for (const e of readdirSync(join(SRC, dir), { withFileTypes: true })) {
    const rel = join(dir, e.name);
    if (e.isDirectory()) files(rel, ext, out);
    else if (e.name.endsWith(ext) && !e.name.endsWith(`.test${ext}`)) out.push(rel);
  }
  return out;
}

/** The custom properties `css` uses in a var(), each with whether it gave a fallback. */
export function used(css) {
  return [...strip(css).matchAll(/var\(\s*(--[\w-]+)\s*(,?)/g)].map((m) => ({ name: m[1], fallback: m[2] === "," }));
}

/** The custom properties `css` declares. */
export function declared(css) {
  return new Set([...strip(css).matchAll(/(?:^|[{;\s])(--[\w-]+)\s*:/g)].map((m) => m[1]));
}

/** The custom properties the scripts set: any string literal naming one. */
const scripted = new Set(files(".", ".js").flatMap((f) => [...read(f).matchAll(/["'`](--[\w-]+)["'`]/g)].map((m) => m[1])));

const PAGES = readdirSync(SRC).filter((f) => f.endsWith(".html"));

test("the token check catches an undefined property, with or without a fallback", () => {
  const css = ":root { --text: #fff; } .a { color: var(--text); background: var(--ink); border-color: var(--gold, #c9a24a); }";
  const missing = used(css).filter((u) => !declared(css).has(u.name)).map((u) => u.name);
  assert.deepEqual(missing, ["--ink", "--gold"]);
});

for (const page of PAGES) {
  test(`${page}: every custom property its stylesheets use is defined for it`, () => {
    const html = read(page);
    const sheets = [...html.matchAll(/<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g)].map((m) => m[1]).filter((h) => !/^https?:/.test(h));
    const css = sheets.map(read).join("\n") + [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n");
    const defined = new Set([...declared(css), ...scripted]);
    const missing = [...new Set(used(css).filter((u) => !defined.has(u.name)).map((u) => u.name))];
    assert.deepEqual(missing, [], `${page} uses properties nothing defines`);
  });
}

test("every stylesheet is loaded by a page, so the check above reads it", () => {
  const loaded = new Set(PAGES.flatMap((p) => [...read(p).matchAll(/<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g)].map((m) => join(".", m[1]))));
  for (const sheet of files(".", ".css")) assert.ok(loaded.has(sheet), `${sheet} is loaded by no page`);
});
