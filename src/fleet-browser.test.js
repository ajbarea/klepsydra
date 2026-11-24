import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { card } from "./fleet/model.js";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("card model passes browser holder to card", () => {
  const CAST = { characters: {} };
  const now = Date.now();

  const c1 = card({ session_id: "s1", browser: "worker1" }, CAST, now);
  assert.equal(c1.browser, "worker1");

  const c2 = card({ session_id: "s2" }, CAST, now);
  assert.equal(c2.browser, null);

  const c3 = card({ session_id: "s3", browser: "" }, CAST, now);
  assert.equal(c3.browser, null);
});

test("wall.html, wall.js and wall.css contain browser-chip elements and styling", () => {
  const html = read("./wall.html");
  assert.match(html, /<span class="browser-chip" hidden><\/span>/, "browser-chip in wall.html");
  assert.match(html, /<p class="where">[\s\S]*?<span class="browser-chip" hidden><\/span><\/p>/, "browser-chip inside where line");

  const css = read("./fleet/wall.css");
  assert.match(css, /\.browser-chip/, "browser-chip class styled in wall.css");
  assert.match(css, /\.branch,\s*\.acct,\s*\.browser-chip/, "styled matching branch and acct chips");

  const js = read("./fleet/wall.js");
  assert.match(js, /const BROWSER_ICON =/, "BROWSER_ICON defined in wall.js");
  assert.match(js, /browserChip\.title = c\.browser \? `MCP browser held by \$\{c\.browser\}` : "";/, "title tooltip sets holder");
});
