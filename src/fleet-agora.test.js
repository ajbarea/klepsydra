import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { agoraView, linkLabel, reactLabel, reactedLabel } from "./fleet/agora.js";

const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const NOW = 1_800_000_000_000;
const cast = { faces: "kourai", characters: { am_michael: { name: "Hephaestus", face: "hephaestus" } } };
const post = (over = {}) => ({
  id: "heph@1799999400", at: 1_799_999_400, who: "heph", name: "Hephaestus", character: "am_michael",
  repo: "klepsydra", kind: "gripe", text: "The lock held 40 minutes.", link: "https://github.com/ajbarea/klepsydra/pull/192",
  reaction: null, ...over,
});

test("without a post the button stays hidden", () => {
  for (const v of [null, undefined, "x", {}, { posts: [] }, { posts: [{ id: "a@1" }] }]) assert.equal(agoraView(v, cast, NOW).hidden, true);
});

test("a post shows its character's face, kind, repo, age, text and link", () => {
  const v = agoraView({ posts: [post()], emoji: ["👍", "🎉"] }, cast, NOW);
  assert.deepEqual([v.hidden, v.label, v.title], [false, "Agora 1", "1 post in the Agora today"]);
  const r = v.rows[0];
  assert.equal(r.face, "fleet/faces/kourai/hephaestus-96.webp");
  assert.equal(r.face2x, "fleet/faces/kourai/hephaestus-192.webp");
  assert.deepEqual([r.name, r.kind, r.kindLabel, r.repo, r.when], ["Hephaestus", "gripe", "Gripe", "klepsydra", "10m"]);
  assert.equal(r.whenLong, "10 minutes ago");
  assert.deepEqual([r.link, r.linkLabel], ["https://github.com/ajbarea/klepsydra/pull/192", "klepsydra #192"]);
  assert.deepEqual(v.emoji, ["👍", "🎉"]);
});

test("a character the theme lacks gets a medallion, never a broken image", () => {
  const r = agoraView({ posts: [post({ character: "af_nobody" })] }, cast, NOW).rows[0];
  assert.match(r.face, /^data:image\/svg\+xml/);
  assert.equal(r.face2x, r.face);
});

test("odd fields fall back, and only a GitHub pull or issue address is a link", () => {
  const v = agoraView({ posts: [post({ kind: "rant", link: "javascript:alert(1)", reaction: "💩" })], emoji: ["👍", "<b>"] }, cast, NOW);
  assert.deepEqual([v.rows[0].kind, v.rows[0].link, v.rows[0].reaction], ["idea", null, null]);
  assert.deepEqual(v.emoji, ["👍"], "only the named reactions are offered");
  for (const [url, label] of [
    ["https://github.com/o/r/issues/7", "r #7"],
    ["https://github.com/o/r/pull/7/files", null],
    ["https://github.com.evil/o/r/pull/7", null],
    ["x https://github.com/o/r/pull/7", null],
  ]) assert.equal(linkLabel(url), label, url);
});

test("an older post still shows, but only today's count on the button", () => {
  const v = agoraView({ posts: [post({ at: 1_799_000_000 })] }, cast, NOW);
  assert.deepEqual([v.hidden, v.label], [false, "Agora"]);
});

test("reactions have stable names; the pressed state carries the choice", () => {
  assert.equal(reactLabel("🎉", "Hephaestus"), "React hooray to Hephaestus's post");
  assert.equal(reactedLabel("👀"), "AJ reacted eyes");
});

test("the wall wires the feed to the app and the phone, and the app registers the commands", () => {
  const wall = read("./fleet/wall.js");
  assert.match(wall, /if \(inTauri\) follow\("agora_subscribe", showAgora\)/);
  assert.match(wall, /if \(served && "agora" in \(message \?\? \{\}\)\) showAgora\(message\.agora\);/);
  assert.match(wall, /if \(inTauri && emoji\.length\)/, "reactions only where they can be saved");
  assert.match(wall, /invoke\("agora_react", \{ id: b\.dataset\.id, emoji: b\.dataset\.emoji \}\)/);
  const html = read("./wall.html");
  assert.match(html, /<button type="button" id="agora-open" popovertarget="agora" data-phone hidden>Agora<\/button>/);
  assert.ok(html.indexOf('id="agora-open"') < html.indexOf('class="tools"'), "outside the desktop tool group, which the phone hides");
  const main = read("../src-tauri/src/main.rs");
  assert.match(main, /fleet::agora_subscribe,\s*fleet::agora_react,/);
  assert.match(main, /fleet::start_agora\(app\.handle\(\), klepsydra_dir\(app\.handle\(\)\)\);/);
});
