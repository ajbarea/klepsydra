import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  STATUS, shortAge, longAge, statusParts, voiceName, identity, accessibleName,
  statuses, startedNeeding, orderChanged, shouldSlide, transitionName, announcements, updatedText, badgeSvg, stripItems, card,
  askText, askParts, plainText, tally, crewOf, crewText, crewRing, crewRings, crewMarks, RINGS, RING_MAX, showsRingKey, alsoChip, ALSO_NAMED, pillWhen,
  BAND, accountsDiffer, castPicks,
} from "./fleet/model.js";
import { contrast } from "./fleet/contrast.js";
import { TONES, hash, initialOf, medallion, medallionSvg, toneOf } from "./fleet/medallion.js";

const NOW = 1_792_353_000_000; // fixed clock, ms
const ago = (s) => NOW / 1000 - s;
const statusLine = (s, nowMs) => statusParts(s, nowMs).join(" \u00b7 ");
const CAST = {
  faces: "kourai",
  characters: { am_michael: { name: "Hephaestus", face: "hephaestus" } },
};
const session = (over = {}) => ({
  session_id: "cb9fa591-1514-44d1-a31c-eba4a7cb41ed",
  name: "Plan the fleet visualizer",
  launch_dir: "/home/aj/ajsoftworks",
  voice: "am_michael",
  status: "needs_you",
  reason: "approve Bash",
  status_at: ago(120),
  active_at: ago(120),
  where: { repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer", at: ago(130) },
  touched: [{ repo: "ideas", at: ago(7200) }],
  prompt: { text: "i just want to be able to VIZ them", at: ago(200) },
  reply: { text: "That works with no model calls", at: ago(210) },
  error: null,
  updated_at: ago(120),
  ...over,
});

test("ages read at a glance, and a clock ahead reads as now", () => {
  assert.equal(shortAge(30_000), "<1m");
  assert.equal(shortAge(2 * 60_000), "2m");
  assert.equal(shortAge(60 * 60_000), "1h");
  assert.equal(shortAge(3 * 86_400_000), "3d");
  assert.equal(shortAge(-600_000), "<1m");
  assert.equal(longAge(2 * 60_000), "2 minutes");
  assert.equal(longAge(60 * 60_000), "1 hour");
  assert.equal(longAge(-5), "under a minute");
});

test("every status line carries its age", () => {
  for (const status of Object.keys(STATUS)) {
    const line = statusLine(session({ status, reason: null, status_at: ago(180) }), NOW);
    assert.equal(line, `${STATUS[status].label} \u00b7 3m`.replace("silent \u00b7 3m", "silent \u00b7 no word for 3m"), status);
  }
  assert.equal(statusLine(session(), NOW), "needs you \u00b7 approve Bash \u00b7 2m");
});

test("a session whose heartbeat stopped reads silent with how long, never working", () => {
  const s = session({ status: "silent", reason: null, status_at: ago(240) });
  assert.equal(statusLine(s, NOW), "silent \u00b7 no word for 4m");
  assert.doesNotMatch(statusLine(s, NOW), /working/);
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, silent, no word for 4 minutes");
});

test("a session with no prompt yet is not started", () => {
  assert.equal(statusLine(session({ status: "new", reason: null, status_at: ago(60) }), NOW), "not started \u00b7 1m");
});

test("badges carry shape, symbol and tone for every status", () => {
  const shapes = new Set();
  for (const [status, st] of Object.entries(STATUS)) {
    const svg = badgeSvg(status);
    assert.match(svg, new RegExp(`tone-${st.tone} shape-${st.shape}`), status);
    assert.match(svg, new RegExp(`>${st.symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}</text>`), status);
    assert.match(svg, /aria-hidden="true"/);
    shapes.add(`${st.shape}${st.symbol}`);
  }
  assert.equal(shapes.size, Object.keys(STATUS).length, "no two statuses look alike");
  assert.match(badgeSvg("needs_you"), /<path class="shape"/, "needs you is the diamond");
});

const quiet = (over = {}) => session({ status: "working", reason: null, status_at: ago(900), quiet_since: ago(720), ...over });

test("a working session quiet for over ten minutes reads working?, still a working circle", () => {
  const s = quiet();
  assert.equal(statusLine(s, NOW), "working? \u00b7 no activity for 12m");
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, working?, no activity for 12 minutes");
  const svg = badgeSvg("working", true);
  assert.match(svg, /tone-working shape-circle/);
  assert.match(svg, />\?<\/text>/);
  assert.doesNotMatch(svg, /\u2026/);
  assert.match(badgeSvg("working"), /\u2026<\/text>/, "unflagged working keeps its ellipsis");
  assert.notEqual(badgeSvg("working", true), badgeSvg("silent"), "quiet working is not silent");
});

test("a working session with no quiet_since is unchanged", () => {
  const s = session({ status: "working", reason: null, status_at: ago(180), quiet_since: null });
  assert.equal(statusLine(s, NOW), "working \u00b7 3m");
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, working, 3 minutes");
  assert.equal(stripItems([s], CAST, NOW)[0].quiet, false);
  assert.equal(card(s, CAST, NOW).quiet, false);
});

test("quiet_since means nothing unless the session is working or needs you", () => {
  const s = session({ status: "done", reason: null, quiet_since: ago(720) });
  assert.equal(statusLine(s, NOW), "done \u00b7 2m");
  assert.equal(card(s, CAST, NOW).quiet, false);
});

test("a needs-you session with no word for half an hour reads needs you?, still the diamond", () => {
  const s = session({ quiet_since: ago(31 * 60), status_at: ago(35 * 60) });
  assert.equal(statusLine(s, NOW), "needs you? \u00b7 approve Bash \u00b7 no word for 31m");
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, needs you?, approve Bash, no word for 31 minutes");
  const svg = badgeSvg("needs_you", true);
  assert.match(svg, /tone-needs shape-diamond/);
  assert.match(svg, />\?<\/text>/);
  assert.notEqual(svg, badgeSvg("needs_you"));
  assert.equal(stripItems([s], CAST, NOW)[0].badge, svg);
  assert.deepEqual(card(s, CAST, NOW).pill, { label: "needs you?", age: "no word for 31m", when: "31m quiet" });
  const fresh = session();
  assert.equal(startedNeeding(statuses([fresh]), [s]).size, 0, "going quiet is not a new need");
  assert.equal(startedNeeding(statuses([s]), [s]).size, 0, "staying quiet never pulses again");
  assert.equal(startedNeeding(statuses([s]), [fresh]).size, 0, "word again after quiet is not a new need");
  assert.deepEqual(announcements(statuses([fresh]), [s], CAST, NOW), ["Hephaestus, needs you?, approve Bash, no word for 31 minutes"]);
});

test("the strip item and card of a quiet session say so", () => {
  const item = stripItems([quiet()], CAST, NOW)[0];
  assert.equal(item.status, "working");
  assert.equal(item.quiet, true);
  assert.equal(item.label, "Hephaestus, working?, no activity for 12 minutes");
  const c = card(quiet(), CAST, NOW);
  assert.equal(c.status, "working");
  assert.equal(c.quiet, true);
  assert.deepEqual(c.pill, { label: "working?", age: "no activity for 12m", when: "12m quiet" });
  assert.equal(c.label, "Hephaestus, working?, no activity for 12 minutes");
});

test("a missing time reads unknown, never NaN and never 1970", () => {
  assert.equal(shortAge(NaN), "unknown");
  assert.equal(longAge(NaN), "unknown");
  for (const bad of [undefined, null, NaN, "x"]) {
    const s = session({ status: "working", reason: null, status_at: bad, updated_at: bad, touched: [{ repo: "ideas", at: bad }] });
    assert.equal(statusLine(s, NOW), "working \u00b7 unknown");
    assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, working, unknown");
    assert.equal(updatedText(s, NOW), "updated unknown");
    assert.deepEqual(card(s, CAST, NOW).also, ["also in ideas"]);
    const q = quiet({ quiet_since: bad ?? NaN, status_at: bad });
    assert.equal(statusLine(q, NOW), "working? \u00b7 no activity for unknown");
    assert.equal(accessibleName(q, CAST, NOW), "Hephaestus, working?, no activity for unknown");
    const silent = session({ status: "silent", status_at: bad });
    assert.equal(statusLine(silent, NOW), "silent \u00b7 no word for unknown");
    for (const text of [card(s, CAST, NOW).pill.age, card(q, CAST, NOW).pill.age, stripItems([s], CAST, NOW)[0].label]) {
      assert.doesNotMatch(text, /NaN|\d{4,}d/);
    }
  }
});

test("strip items and cards carry the badge, quiet mark included", () => {
  assert.equal(stripItems([quiet()], CAST, NOW)[0].badge, badgeSvg("working", true));
  assert.equal(card(quiet(), CAST, NOW).badge, badgeSvg("working", true));
  assert.equal(stripItems([session()], CAST, NOW)[0].badge, badgeSvg("needs_you"));
  assert.equal(card(session({ status: "working", quiet_since: null }), CAST, NOW).badge, badgeSvg("working"));
});

test("working to quiet working is announced; a new session is announced; no change is not", () => {
  const working = session({ status: "working", reason: null, status_at: ago(900), quiet_since: null });
  const q = quiet();
  assert.deepEqual(announcements(statuses([working]), [q], CAST, NOW), ["Hephaestus, working?, no activity for 12 minutes"]);
  assert.deepEqual(announcements(statuses([q]), [q], CAST, NOW), []);
  assert.deepEqual(announcements(statuses([]), [session()], CAST, NOW), ["Hephaestus, needs you, approve Bash"]);
  assert.equal(startedNeeding(statuses([q]), [session()]).size, 1, "quiet working then needs you still pulses");
  assert.equal(startedNeeding(statuses([session()]), [session()]).size, 0);
});

test("prompt, reply and error pass through card() as plain text", () => {
  const c = card(session({ status: "error", prompt: { text: "<img onerror=x>", at: 1 }, reply: { text: "</text><b>", at: 1 }, error: "<script>" }), CAST, NOW);
  assert.equal(c.prompt, "<img onerror=x>");
  assert.equal(c.reply, "</text><b>");
  assert.equal(c.error, "<script>");
  assert.doesNotMatch(c.badge, /onerror|<script|<b>/);
});

test("accessible names say who, what and how long", () => {
  assert.equal(accessibleName(session(), CAST, NOW), "Hephaestus, needs you, approve Bash, 2 minutes");
});

test("identity: a cast voice is its character", () => {
  assert.deepEqual(identity(session(), CAST), {
    name: "Hephaestus",
    voice: "Michael",
    face: "fleet/faces/kourai/hephaestus-96.webp",
    face2x: "fleet/faces/kourai/hephaestus-192.webp",
    full: "fleet/faces/kourai/hephaestus-full.webp",
    accent: null, // CAST here has no accent
    epithet: null,
    figure: null, // nor a head to place the figure by
  });
});

test("identity: a character brings its epithet, its figure placed by its head, and its full portrait", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/themes/kourai.json", import.meta.url), "utf8"));
  const who = identity(session(), cast);
  assert.equal(who.epithet, "Master of the Forge");
  assert.equal(who.full, "fleet/faces/kourai/hephaestus-full.webp");
  assert.equal(who.figure.src, "fleet/faces/kourai/hephaestus-figure.webp");
  assert.deepEqual(who.figure.head, cast.characters.am_michael.head);
  const bad = { characters: { am_michael: { name: "H", face: "hephaestus", head: [0.5, "x", 0.2] } } };
  assert.equal(identity(session(), bad).figure, null, "a malformed head shows no figure");
  for (const voice of ["bm_lewis", null, "af_heart(0.5)+af_bella(0.5)"]) {
    const m = identity(session({ voice }), cast);
    assert.deepEqual([m.epithet, m.figure, m.full], [null, null, null], `${voice}: a medallion has none`);
  }
});

/** The SVG inside a medallion's data URL. */
const svgOf = (url) => {
  assert.match(url, /^data:image\/svg\+xml,/);
  return decodeURIComponent(url.slice(url.indexOf(",") + 1));
};
const letterOn = (url) => svgOf(url).match(/<text[^>]*>([^<]*)<\/text>/)?.[1] ?? null;

test("identity: another voice is a medallion with its initial and its capitalised name", () => {
  const who = identity(session({ voice: "bm_fable" }), CAST);
  assert.deepEqual([who.name, who.voice], ["Fable", null]);
  assert.equal(who.face2x, who.face, "one drawing at every size");
  assert.equal(letterOn(who.face), "F");
  assert.equal(voiceName("am_fenrir"), "Fenrir");
});

test("identity: a blend is named by its voices, and the same voice keeps one face", () => {
  const blend = "af_bella(0.7)+af_heart(0.3)";
  const who = identity(session({ voice: blend }), CAST);
  assert.equal(who.name, "Bella and Heart");
  assert.equal(letterOn(who.face), "B");
  assert.equal(identity(session({ voice: blend, session_id: "x" }), CAST).face, who.face, "same voice, same face");
});

test("identity: no voice is named by the session, else its folder, else its id", () => {
  const a = identity(session({ voice: null }), CAST);
  assert.deepEqual([a.name, letterOn(a.face)], ["Plan the fleet visualizer", "P"]);
  const b = identity(session({ voice: null, name: null }), CAST);
  assert.deepEqual([b.name, letterOn(b.face)], ["ajsoftworks", "A"]);
  const c = identity(session({ voice: null, name: null, launch_dir: null }), CAST);
  assert.deepEqual([c.name, letterOn(c.face)], ["cb9fa591", "C"]);
});

test("identity: a voice named like an Object property is still a medallion", () => {
  const who = identity(session({ voice: "constructor" }), CAST);
  assert.deepEqual([who.name, letterOn(who.face)], ["Constructor", "C"]);
});

test("the medallion shows only A-Z or 0-9, and the laurel alone for anything else", () => {
  for (const [name, letter] of [["fable", "F"], ["9lives", "9"], ["Zeta", "Z"]]) assert.equal(initialOf(name), letter, name);
  for (const name of ["", "<script>", "\"x", "&amp;", "\u00e9lan", "\u00df", "\u{1F525}fire", " lead", null, undefined, 7]) {
    assert.equal(initialOf(name), "", String(name));
    assert.equal(letterOn(medallion(name)), null, String(name));
  }
  const svg = svgOf(medallion("<b onload=alert(1)>"));
  assert.doesNotMatch(svg, /onload|alert|<b\b/);
});

test("the medallion is one template: a tone changes only colours, a name only the letter", () => {
  const colourless = (svg) => svg.replace(/#[0-9a-f]{6}\b/g, "#");
  const bare = medallionSvg("", 0);
  for (let t = 0; t < TONES.length; t++) {
    assert.equal(colourless(medallionSvg("", t)), colourless(bare), TONES[t].name);
    for (const name of ["Fable", "ajsoftworks", "0"]) {
      assert.equal(medallionSvg(name, t).replace(/<text[^>]*>[A-Z0-9]<\/text>/, ""), medallionSvg("", t), `${name} ${t}`);
    }
  }
  assert.equal(new Set(TONES.map((_, t) => medallionSvg("A", t))).size, TONES.length, "every tone is its own drawing");
  assert.match(bare, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" viewBox="0 0 96 96">/);
  assert.doesNotMatch(bare.slice(0, bare.indexOf(">")), /\b(width|height)=/, "no fixed size, so the img's box sizes it");
  assert.doesNotMatch(bare, /\b(href|src)=|url\((?!#)|var\(/, "loads nothing and needs no CSS");
});

test("two uncast voices with one initial differ by their metal", () => {
  assert.deepEqual([hash(""), hash("a")], [0x811c9dc5, 0xe40c292c], "FNV-1a's published 32-bit vectors");
  assert.deepEqual([toneOf("bm_fable"), toneOf("am_fenrir")], [3, 2], "rose gold and copper");
  const fable = identity(session({ voice: "bm_fable" }), CAST);
  const fenrir = identity(session({ voice: "am_fenrir" }), CAST);
  assert.deepEqual([letterOn(fable.face), letterOn(fenrir.face)], ["F", "F"]);
  assert.notEqual(toneOf("bm_fable"), toneOf("am_fenrir"));
  assert.notEqual(fable.face, fenrir.face);
});

test("a session keeps its metal: the voice picks it, else the session id", () => {
  const a = identity(session({ voice: "bm_fable", session_id: "one" }), CAST);
  const b = identity(session({ voice: "bm_fable", session_id: "two", name: "Other" }), CAST);
  assert.equal(a.face, b.face, "same voice, same face, whatever the session");
  const plain = (id) => identity(session({ voice: null, name: null, session_id: id }), CAST).face;
  assert.equal(plain("s1"), plain("s1"));
  const metals = new Set(Array.from({ length: 200 }, (_, i) => toneOf(`s${i}`)));
  assert.equal(metals.size, TONES.length, "every metal is reachable");
  const faces = new Set(Array.from({ length: 200 }, (_, i) => plain(`s${i}`)));
  assert.equal(faces.size, TONES.length, "unnamed ajsoftworks sessions spread over the metals, one drawing each");
});

test("the portrait never changes with state", () => {
  for (const voice of ["am_michael", "bm_fable", "af_bella(0.5)+af_heart(0.5)", null]) {
    const faces = new Set(Object.keys(STATUS).map((status) => identity(session({ voice, status }), CAST).face));
    assert.equal(faces.size, 1, String(voice));
  }
});

test("one pulse when a session starts needing AJ, none on the first look", () => {
  const working = [session({ status: "working" })];
  const needing = [session()];
  assert.equal(stripItems(needing, CAST, NOW, undefined)[0].pulse, false);
  assert.equal(stripItems(needing, CAST, NOW, statuses(working))[0].pulse, true);
  assert.equal(stripItems(needing, CAST, NOW, statuses(needing))[0].pulse, false, "then static");
  assert.deepEqual([...startedNeeding(statuses([]), needing)], [needing[0].session_id], "a new session that needs AJ");
});

test("the strip keeps the reader's order", () => {
  const list = ["c", "a", "b"].map((id) => session({ session_id: id, voice: null, name: id }));
  assert.deepEqual(stripItems(list, CAST, NOW).map((i) => i.id), ["c", "a", "b"]);
});

test("the wall announces changes, not the first look", () => {
  const before = statuses([session({ status: "working" })]);
  assert.deepEqual(announcements(undefined, [session()], CAST), []);
  assert.deepEqual(announcements(before, [session()], CAST), ["Hephaestus, needs you, approve Bash"]);
  assert.deepEqual(announcements(statuses([session()]), [session()], CAST), []);
});

test("updated shows once the newest field is over five minutes old", () => {
  assert.equal(updatedText(session({ updated_at: ago(299) }), NOW), null);
  assert.equal(updatedText(session({ updated_at: ago(420) }), NOW), "updated 7m ago");
  const ended = session({ status: "ended", status_at: ago(360), updated_at: ago(360) });
  assert.equal(card(ended, CAST, NOW).updated, null, "an ended card's pill already says how long");
  assert.equal(card({ ...ended, status: "done" }, CAST, NOW).updated, "updated 6m ago");
});

test("a card holds what the wall shows", () => {
  const c = card(session(), CAST, NOW);
  assert.equal(c.name, "Hephaestus");
  assert.equal(c.session, "Plan the fleet visualizer");
  for (const gone of ["statusLine", "where", "voice", "touched"]) assert.ok(!(gone in c), `card.${gone} is gone`);
  assert.equal(c.prompt, "i just want to be able to VIZ them");
  assert.equal(c.reply, "That works with no model calls");
  assert.deepEqual(c.jump, { enabled: true, why: null });
  assert.equal(c.jumpLabel, "Open terminal, Hephaestus");
  const other = card(session({ voice: "af_bella" }), CAST, NOW);
  assert.notEqual(other.jumpLabel, c.jumpLabel, "each Jump button is named for its session");
  assert.deepEqual(card(session({ name: null }), CAST, NOW).jump, { enabled: false, why: "no session name yet" });
  const inTmux = { name: null, tmux: { socket: "/tmp/tmux-1001/klepsydra", pane: "%3" }, claude: { pid: 2231, start: 8717628 }, distro: "Ubuntu" };
  assert.deepEqual(card(session(inTmux), CAST, NOW).jump, { enabled: true, why: null }, "tmux finds an unnamed session by its pane");
  for (const missing of ["tmux", "claude", "distro"]) {
    assert.deepEqual(card(session({ ...inTmux, [missing]: null }), CAST, NOW).jump,
      { enabled: false, why: "no session name yet" }, `without ${missing}`);
  }
  assert.deepEqual(card(session({ ...inTmux, status: "ended" }), CAST, NOW).jump, { enabled: false, why: "session ended" });
  assert.deepEqual(card(session({ status: "ended" }), CAST, NOW).jump, { enabled: false, why: "session ended" });
  assert.equal(card(session({ status: "error", error: "API Error: Rate limit reached" }), CAST, NOW).error,
    "API Error: Rate limit reached");
  assert.equal(card(session({ error: "old" }), CAST, NOW).error, null, "only an error shows its error");
});

test("the model reads the cast the app ships", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/themes/kourai.json", import.meta.url), "utf8"));
  assert.equal(identity(session(), cast).name, "Hephaestus");
});

test("a kourai card carries its accent; any other card has none", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/themes/kourai.json", import.meta.url), "utf8"));
  assert.equal(card(session(), cast, NOW).accent, "#DA8C20");
  assert.equal(card(session({ voice: "aletheia" }), CAST, NOW).accent, null, "no character, no accent");
  for (const voice of ["bm_lewis", null, "af_heart(0.5)+af_bella(0.5)"]) {
    assert.equal(card(session({ voice }), cast, NOW).accent, null, String(voice));
  }
  const bad = { characters: { am_michael: { name: "H", face: "hephaestus", accent: "red; x" } } };
  assert.equal(identity(session(), bad).accent, null, "a malformed accent is dropped");
});

test("a character's card carries its epithet ink at 4.5:1 on the nameplate; a medallion's carries none", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/themes/kourai.json", import.meta.url), "utf8"));
  for (const voice of Object.keys(cast.characters)) {
    const c = card(session({ voice }), cast, NOW);
    assert.ok(contrast(c.accentInk, BAND.plate) >= 4.5, `${c.name}: ${c.accentInk}`);
    assert.equal(c.epithet, cast.characters[voice].epithet);
    assert.ok(c.figure && c.full, c.name);
  }
  const m = card(session({ voice: "bm_lewis" }), cast, NOW);
  assert.deepEqual([m.accentInk, m.epithet, m.figure, m.full], [null, null, null, null]);
});

test("the Open terminal button: fill only for needs-you, a marker for a character, plain for a medallion, nothing when off", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/themes/kourai.json", import.meta.url), "utf8"));
  const style = (o, c = cast) => {
    const k = card(session(o), c, NOW);
    return [k.jumpKind, k.jumpMark];
  };
  assert.deepEqual(style({ status: "working" }), ["accent", { color: "#DA8C20", width: 4 }]);
  assert.deepEqual(style({ status: "done" })[0], "accent");
  assert.deepEqual(style({ status: "working", voice: "af_nova" }), ["accent", { color: "#0072B2", width: 6 }], "a dim accent is wider");
  assert.deepEqual(style({ status: "needs_you" }), ["needs", null], "no marker on the filled button");
  assert.deepEqual(style({ status: "needs_you", quiet_since: NOW - 1000 })[0], "needs", "needs you? is filled too");
  assert.deepEqual(style({ status: "working", voice: "bm_lewis" }), ["plain", null], "a medallion has no marker");
  assert.deepEqual(style({ status: "needs_you", voice: "bm_lewis" }), ["needs", null]);
  assert.deepEqual(style({ status: "ended" }), ["off", null], "disabled: no marker, no fill");
  assert.deepEqual(style({ status: "needs_you", name: null }), ["off", null], "disabled needs-you stays quiet");
});

test("only an ended or silent card offers Clear", () => {
  for (const status of ["ended", "silent"]) assert.equal(card(session({ status }), CAST, NOW).clear, true, status);
  for (const status of ["working", "needs_you", "done", "new", "error"]) {
    assert.equal(card(session({ status }), CAST, NOW).clear, false, status);
  }
});

test("the crew reads only whole positive counts, and none from an old snapshot", () => {
  assert.deepEqual(crewOf(session({ background: { agents: 2, shells: 1 } })), { agents: 2, shells: 1, tasks: 0 });
  for (const background of [undefined, null, "3", { agents: -1, shells: 1.5 }, { agents: "2", shells: NaN }]) {
    assert.deepEqual(crewOf(session({ background })), { agents: 0, shells: 0, tasks: 0 }, JSON.stringify(background));
  }
  assert.equal(crewText({ agents: 2, shells: 1 }), "2 agents, 1 shell");
  assert.equal(crewText({ agents: 1, shells: 0 }), "1 agent");
  assert.equal(crewText({ agents: 0, shells: 3 }), "3 shells");
  assert.equal(crewText({ agents: 0, shells: 0 }), null);
});

test("another background task reads as a task and draws shell-style", () => {
  const crew = crewOf(session({ background: { agents: 1, shells: 1, tasks: 2 } }));
  assert.deepEqual(crew, { agents: 1, shells: 1, tasks: 2 });
  assert.equal(crewText(crew), "1 agent, 1 shell, 2 tasks");
  assert.deepEqual(crewRing(crew).segments.map((s) => s.kind), ["agent", "shell", "shell", "shell"]);
  const s = session({ status: "working", reason: "background", background: { agents: 0, shells: 0, tasks: 1 } });
  assert.match(accessibleName(s, CAST, NOW), /^Hephaestus, 1 task running in background, working, prompt free/);
  assert.equal(card(s, CAST, NOW).promptFree, true);
});

const kinds = (crew) => crewRing(crew).segments.map((s) => s.kind[0]).join("");

test("the ring draws an arc per piece of work, agents first, at most five", () => {
  assert.deepEqual(crewRing({ agents: 0, shells: 0 }), { segments: [], more: 0 });
  assert.equal(kinds({ agents: 2, shells: 1 }), "aas");
  assert.equal(kinds({ agents: 1, shells: 2 }), "ass", "agents first, then shells, clockwise");
  assert.equal(crewRing({ agents: 2, shells: 1 }).more, 0);
  assert.equal(kinds({ agents: 5, shells: 0 }), "aaaaa");
  assert.equal(crewRing({ agents: 5, shells: 0 }).more, 0, "five fit");
  assert.equal(kinds({ agents: 10, shells: 0 }), "aaaaa");
  assert.equal(crewRing({ agents: 10, shells: 0 }).more, 5);
  assert.equal(kinds({ agents: 7, shells: 3 }), "aaaas", "past five, a shell keeps one arc");
  assert.equal(crewRing({ agents: 7, shells: 3 }).more, 5);
  assert.equal(kinds({ agents: 1, shells: 12 }), "assss");
  assert.equal(crewRing({ agents: 1, shells: 12 }).more, 8);
  assert.equal(RING_MAX, 5);
  for (const g of Object.values(RINGS)) assert.deepEqual(crewRing({ agents: 7, shells: 3 }, g).segments.length, 5);
});

test("the crew marks are the ring unrolled: the same kinds in the same order, the same +N", () => {
  for (const crew of [{ agents: 0, shells: 0 }, { agents: 2, shells: 1 }, { agents: 7, shells: 3 }, { agents: 1, shells: 12, tasks: 2 }]) {
    const ring = crewRing(crew);
    assert.deepEqual(crewMarks(crew), { kinds: ring.segments.map((s) => s.kind), more: ring.more }, JSON.stringify(crew));
  }
  const c = card(session({ background: { agents: 2, shells: 1 } }), CAST, NOW);
  assert.deepEqual(c.marks, { kinds: ["agent", "agent", "shell"], more: 0 });
  const marks = crewMarks({ agents: 2, shells: 1 });
  assert.deepEqual(crewRing({ agents: 9, shells: 9 }, RINGS.compact, marks).segments.map((s) => s.kind), marks.kinds, "the ring lays out the marks it is given");
});

test("an agent's arc is thick and a shell's thin, in screen px for each portrait", () => {
  const px = (density, kind) => (RINGS[density][kind] * { comfortable: 80, compact: 64 }[density]) / 80;
  assert.deepEqual([px("comfortable", "agent"), px("comfortable", "shell")], [7, 3]);
  assert.deepEqual([px("compact", "agent"), px("compact", "shell")].map((v) => Number(v.toFixed(6))), [5.5, 2.5]);
  for (const [density, g] of Object.entries(RINGS)) {
    const { segments } = crewRing({ agents: 1, shells: 2 }, g);
    assert.deepEqual(segments.map((s) => s.width), [g.agent, g.shell, g.shell].map((v) => Number(v.toFixed(2))), density);
    assert.equal(g.r + g.agent / 2, 40, `${density}: the thick arc's outer edge is the portrait's`);
  }
});

test("arcs sit on the ring with even gaps of a fixed length on the page, a lone one too", () => {
  const ends = (d, g) => {
    const r = Number(g.r.toFixed(2));
    const m = d.match(new RegExp(`^M ([\\d.]+) ([\\d.]+) A ${r} ${r} 0 ([01]) 1 ([\\d.]+) ([\\d.]+)$`));
    assert.ok(m, d);
    return [[Number(m[1]), Number(m[2])], [Number(m[4]), Number(m[5])]];
  };
  const angle = ([x, y], g) => (Math.atan2(y - g.cy, x - g.cx) * 180) / Math.PI;
  for (const [density, g] of Object.entries(RINGS)) {
    const facePx = { comfortable: 80, compact: 64 }[density];
    // The gap is gapPx along the ring on the page: 14 px comfortable, 11 px compact.
    const gapOnPage = ((g.gapDeg * Math.PI) / 180) * g.r * (facePx / 80);
    assert.ok(Math.abs(gapOnPage - { comfortable: 14, compact: 11 }[density]) < 1e-9, `${density}: ${gapOnPage}`);
    assert.ok(g.gapDeg >= 20, `${density}: ${g.gapDeg} degrees reads as a gap`);
    for (const n of [2, 3, 5]) {
      const { segments } = crewRing({ agents: n, shells: 0 }, g);
      assert.equal(segments.length, n);
      for (const { d } of segments) {
        for (const p of ends(d, g)) assert.ok(Math.abs(Math.hypot(p[0] - g.cx, p[1] - g.cy) - g.r) < 0.01, `${density} ${n}: on the ring`);
      }
      // Each gap between neighbours is gapDeg wide, the one at 12 o'clock too.
      for (let i = 0; i < n; i++) {
        const end = angle(ends(segments[i].d, g)[1], g);
        const next = angle(ends(segments[(i + 1) % n].d, g)[0], g);
        const gap = (((next - end) % 360) + 360) % 360;
        assert.ok(Math.abs(gap - g.gapDeg) < 0.1, `${density} ${n}: gap ${i} is ${gap}`);
      }
      assert.ok(Math.abs(angle(ends(segments[0].d, g)[0], g) - (-90 + g.gapDeg / 2)) < 0.1, `${density} ${n}: starts half a gap after 12`);
    }
    // A lone item keeps its one gap at 12 o'clock: one long arc, never a closed ring.
    const [one] = crewRing({ agents: 0, shells: 1 }, g).segments;
    const [a, b] = ends(one.d, g);
    assert.ok(Math.abs(a[0] - g.cx - (g.cx - b[0])) < 0.02 && Math.abs(a[1] - b[1]) < 0.02 && a[1] < g.cy, `${density}: symmetric about 12`);
    assert.match(one.d, / 0 1 1 /, "the long way round");
  }
});

test("the ring key shows while any card has background work, and only then", () => {
  const withCrew = (background) => card(session({ background }), CAST, NOW);
  assert.equal(showsRingKey([]), false, "an empty wall");
  assert.equal(showsRingKey([withCrew({ agents: 0, shells: 0 }), withCrew(undefined)]), false, "a quiet wall stays clean");
  assert.equal(showsRingKey([withCrew({ agents: 0, shells: 0 }), withCrew({ agents: 0, shells: 1 })]), true);
  assert.equal(showsRingKey([withCrew({ agents: 0, shells: 0, tasks: 1 })]), true, "another task draws a thin arc");
  assert.deepEqual(Object.keys(crewRings({ agents: 1, shells: 0 })), ["comfortable", "compact"]);
});

test("the pill stays the plain status; the crew line says what is out", () => {
  const background = { agents: 2, shells: 1 };
  for (const reason of [null, "background"]) {
    const c = card(session({ status: "working", reason, background }), CAST, NOW);
    assert.deepEqual(c.pill, { label: "working", age: "2m", when: "2m" }, String(reason));
    assert.equal(c.crew, "2 agents, 1 shell");
    assert.equal(c.rings.comfortable.segments.length, 3);
    assert.equal(c.tone, "working");
  }
  const none = card(session({ status: "working", reason: null }), CAST, NOW);
  assert.deepEqual([none.pill.label, none.crew, none.promptFree, none.rings.comfortable.segments.length], ["working", null, false, 0]);
  const needs = card(session({ background }), CAST, NOW);
  assert.equal(needs.pill.label, "needs you");
  assert.equal(needs.rings.comfortable.segments.length, 3, "its ring still shows the crew");
});

test("prompt free shows only once the turn ended with work out, never for a subagent mid-turn", () => {
  // A foreground subagent inside a turn: the hook leaves the reason null until Stop.
  const mid = card(session({ status: "working", reason: null, background: { agents: 1, shells: 0 } }), CAST, NOW);
  assert.deepEqual([mid.crew, mid.promptFree, mid.rings.comfortable.segments.length], ["1 agent", false, 1]);
  assert.doesNotMatch(mid.label, /prompt free/);
  const after = card(session({ status: "working", reason: "background", background: { agents: 1, shells: 0 } }), CAST, NOW);
  assert.equal(after.promptFree, true);
  assert.match(after.label, /prompt free/);
  const stale = card(session({ status: "working", reason: "background", background: { agents: 0, shells: 0 } }), CAST, NOW);
  assert.equal(stale.promptFree, false, "no hint with nothing out");
});

test("the crew is in the accessible name, and the ring takes the character's colour or none", () => {
  const cast = { faces: "kourai", characters: { am_michael: { name: "Hermes", face: "hermes", accent: "#3a7bd5" } } };
  const s = session({ status: "working", reason: "background", status_at: ago(120), background: { agents: 2, shells: 1 } });
  assert.equal(accessibleName(s, cast, NOW), "Hermes, 2 agents and 1 shell running in background, working, prompt free, 2 minutes");
  assert.equal(card(s, cast, NOW).label, accessibleName(s, cast, NOW));
  assert.equal(card(s, cast, NOW).ringColor, "#3a7bd5");
  assert.equal(card(session({ voice: null }), CAST, NOW).ringColor, null, "a medallion's agents are gold (wall.css)");
  assert.equal(accessibleName(session({ status: "done", reason: null, status_at: ago(60) }), CAST, NOW), "Hephaestus, done, 1 minute");
});

test("the tally counts a session working in background as working", () => {
  const t = tally([session({ status: "working", reason: "background", background: { agents: 1, shells: 0 } })]);
  assert.equal(t.working, 1);
});

test("the ask line says what a session waits for", () => {
  assert.equal(askText("approve Bash"), "Waiting for you to approve Bash");
  assert.equal(askText("approve plan"), "Waiting for you to approve the plan");
  assert.equal(askText("question"), "Waiting for your answer");
  assert.equal(askText(null), "Waiting for you");
});

test("the ask line keeps the tool's own name for the end a cut leaves in view", () => {
  const lead = "Waiting for you to approve ";
  const cases = [
    ["approve mcp__plugin_playwright_playwright__browser_navigate", [`${lead}mcp__plugin_playwright_playwright__`, "browser_navigate"]],
    ["approve mcp__github__search", [`${lead}mcp__github__`, "search"]],
    ["approve mcp__claude_ai_Gmail__apply_sensitive_message_label", [`${lead}mcp__claude_ai_Gmail__`, "apply_sensitive_message_label"]],
    ["approve Bash", [lead, "Bash"]],
    ["approve a tool", [lead, "a tool"]],
    // No name past the last "__", or nothing before it: the whole tool is kept.
    ["approve mcp__github__", [lead, "mcp__github__"]],
    ["approve __search", [lead, "__search"]],
    ["approve mcp__a__b__c", [`${lead}mcp__a__b__`, "c"]],
    ["approve plan", ["Waiting for you to approve the plan", ""]],
    ["question", ["Waiting for your answer", ""]],
    ["review", ["Waiting for you to review", ""]],
    [null, ["Waiting for you", ""]],
    ["", ["Waiting for you", ""]],
  ];
  for (const [reason, want] of cases) {
    const parts = askParts(reason);
    assert.deepEqual(parts, want, String(reason));
    assert.equal(parts.join(""), askText(reason), `${reason}: the two parts are the whole line`);
  }
});

test("a needs-you card carries its ask in parts; any other has none", () => {
  const asking = card(session({ status: "needs_you", reason: "approve mcp__github__search" }), CAST, NOW);
  assert.deepEqual(asking.askParts, ["Waiting for you to approve mcp__github__", "search"]);
  assert.equal(asking.ask, asking.askParts.join(""));
  const working = card(session({ status: "working", reason: "approve Bash" }), CAST, NOW);
  assert.deepEqual([working.ask, working.askParts], [null, null]);
});

test("a card carries pill, ask, tone, dim, place and its voice as a tooltip", () => {
  const c = card(session(), CAST, NOW);
  assert.deepEqual(c.pill, { label: "needs you", age: "2m", when: "2m" });
  assert.equal(c.ask, "Waiting for you to approve Bash");
  assert.equal(c.tone, "needs");
  assert.equal(c.dim, false);
  assert.equal(c.task, "Plan the fleet visualizer");
  assert.deepEqual(c.place, { repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer" });
  assert.deepEqual(c.also, ["also in ideas"]);
  assert.equal(c.voiceTitle, "Voice: Michael");
  const quiet = card(session({ status: "silent", status_at: ago(360), name: null }), CAST, NOW);
  assert.deepEqual(quiet.pill, { label: "silent", age: "no word for 6m", when: "6m" });
  assert.equal(quiet.dim, true);
  assert.equal(quiet.ask, null);
  assert.equal(quiet.task, "No session name yet");
  const idle = card(session({ status: "working", status_at: ago(900), quiet_since: ago(720) }), CAST, NOW);
  assert.deepEqual(idle.pill, { label: "working?", age: "no activity for 12m", when: "12m quiet" });
});

test("the pill's age: ended, error and a quiet needs-you card", () => {
  assert.deepEqual(card(session({ status: "ended", reason: "closed", status_at: ago(360) }), CAST, NOW).pill,
    { label: "ended \u00b7 closed", age: "6m", when: "6m" });
  assert.deepEqual(card(session({ status: "error", reason: "rate limit", status_at: ago(180) }), CAST, NOW).pill,
    { label: "error \u00b7 rate limit", age: "3m", when: "3m" });
  assert.deepEqual(card(session({ quiet_since: ago(31 * 60), status_at: ago(35 * 60) }), CAST, NOW).pill,
    { label: "needs you?", age: "no word for 31m", when: "31m quiet" });
});

test("also lists each other repo once, never the current one", () => {
  for (const touched of [[], undefined, null]) assert.deepEqual(card(session({ touched }), CAST, NOW).also, [], String(touched));
  const touched = [{ repo: "ideas", at: ago(60) }, { repo: "ideas", at: ago(30) }, { repo: "klepsydra", at: ago(10) }, { repo: "talks", at: 1 }];
  assert.deepEqual(card(session({ touched }), CAST, NOW).also, ["also in ideas", "also in talks"]);
  assert.deepEqual(card(session({ touched, where: null }), CAST, NOW).also, ["also in ideas", "also in klepsydra", "also in talks"]);
});

test("the tally counts what the bar shows", () => {
  const t = tally([
    session({ status: "needs_you" }), session({ status: "working" }), session({ status: "working" }),
    session({ status: "done" }), session({ status: "error" }), session({ status: "new" }),
    session({ status: "silent" }), session({ status: "ended" }),
  ]);
  assert.deepEqual(t, { needs: 1, working: 2, done: 1, error: 1, idle: 3 });
});

test("an ended or error pill names its reason", () => {
  for (const [status, reason, label] of [
    ["ended", "gone", "ended \u00b7 gone"],
    ["ended", "exited", "ended \u00b7 exited"],
    ["error", "rate limit", "error \u00b7 rate limit"],
    ["ended", null, "ended"],
    ["error", null, "error"],
  ]) {
    assert.equal(card(session({ status, reason }), CAST, NOW).pill.label, label, `${status} ${reason}`);
  }
  assert.equal(card(session({ status: "needs_you", reason: "approve Bash" }), CAST, NOW).pill.label, "needs you",
    "a needs-you reason is the ask line's");
});

test("only a session that newly needs you pulses, and never on the first look", () => {
  const working = session({ session_id: "w", status: "working", reason: null });
  const needs = session({ session_id: "n", status: "needs_you" });
  const was = statuses([working, needs]);
  assert.equal(startedNeeding(undefined, [needs]).size, 0, "first render");
  assert.deepEqual([...startedNeeding(was, [{ ...working, status: "needs_you" }, needs])], ["w"]);
  assert.equal(startedNeeding(was, [working, needs]).size, 0, "already needing");
});

test("only a change in membership or order counts as a reorder", () => {
  assert.equal(orderChanged(["a", "b"], ["a", "b"]), false, "a time-only tick");
  assert.equal(orderChanged(["a", "b"], ["b", "a"]), true);
  assert.equal(orderChanged(["a"], ["a", "b"]), true);
  assert.equal(orderChanged(["a", "b"], ["a"]), true);
  assert.equal(orderChanged([], []), false);
});

test("a first render, a reload and a tick never slide; a reorder on a live wall does", () => {
  assert.equal(shouldSlide([], ["a", "b"], new Set()), false, "empty wall");
  assert.equal(shouldSlide(["a", "b"], ["b", "a"], undefined), false, "a tick has no snapshot");
  assert.equal(shouldSlide(["a", "b"], ["a", "b"], new Set()), false, "same order");
  assert.equal(shouldSlide(["a", "b"], ["b", "a"], new Set()), true);
});

test("only a uuid-shaped id becomes a view-transition name", () => {
  const id = "123e4567-e89b-12d3-a456-426614174000";
  assert.equal(transitionName(id), `card-${id}`);
  for (const bad of ["demo-1-am_michael", "x; color: red", "", `${id}0`]) assert.equal(transitionName(bad), "");
});

test("plainText: AJ's real strings", () => {
  // "Status: - item" is a list item flattened onto one line; the dash goes.
  assert.equal(
    plainText("Filed as **techne #182**. Status: - \u2705 **#34 colours are live:** your fleet windows"),
    "Filed as techne #182. Status: \u2705 #34 colours are live: your fleet windows",
  );
  assert.equal(plainText("Welcome back. ** \u2705 Done while you were out**"), "Welcome back. \u2705 Done while you were out");
});

test("plainText: inline markup", () => {
  assert.equal(plainText("__a__ *b* _c_ ~~d~~ ***e*** **f *g* h**"), "a b c d e f g h");
  assert.equal(plainText("run `npm test` now"), "run npm test now");
  assert.equal(plainText("`**not bold**`"), "**not bold**");
  assert.equal(plainText("see [the docs](https://x.io/a_b) and <https://y.io>"), "see the docs and https://y.io");
});

test("plainText: block markup", () => {
  assert.equal(plainText("# Title\n> quoted\n- one\n* two\n+ three\n1. four\n---\ntail"), "Title quoted one two three four tail");
  assert.equal(plainText("before\n```js\nconst a_b = 2 * 3;\n```\nafter"), "before const a_b = 2 * 3; after");
  assert.equal(plainText("a\n\n\n  b   c"), "a b c");
});

test("plainText: text that merely looks like markup survives", () => {
  for (const s of ["snake_case_name", "a*b", "2 * 3", "2*3*4", "src/fleet/model.js", "a - b", "keep \u2705 and \ud83d\udccb"]) {
    assert.equal(plainText(s), s);
  }
});

test("plainText: null and empty", () => {
  assert.equal(plainText(null), null);
  assert.equal(plainText(undefined), undefined);
  assert.equal(plainText(""), "");
});

test("card: prompt and reply are plain text", () => {
  const c = card({ session_id: "x", status: "idle", prompt: { text: "**hi** `x`" }, reply: { text: "- [a](u)" } }, {}, NOW);
  assert.equal(c.prompt, "hi x");
  assert.equal(c.reply, "a");
});

test("the compact card folds the also-in list into a +N chip that names every repo", () => {
  assert.equal(alsoChip([]), null);
  assert.deepEqual(alsoChip(["ideas"]), { text: "+1", label: "Also in ideas" });
  assert.deepEqual(alsoChip(["ideas", "talks"]), { text: "+2", label: "Also in ideas and talks" });
  assert.deepEqual(alsoChip(["ideas", "talks", "papers"]), { text: "+3", label: "Also in ideas, talks and papers" });
  const touched = [{ repo: "ideas", at: ago(60) }, { repo: "klepsydra", at: ago(60) }, { repo: "ideas", at: ago(30) }, { repo: "talks", at: ago(9) }];
  const c = card(session({ touched }), CAST, NOW);
  assert.deepEqual(c.alsoChip, { text: "+2", label: "Also in ideas and talks" }, "each other repo once, never the current one");
  assert.equal(c.also.length, 2, "the chip counts what the full card lists");
  assert.equal(card(session({ touched: [] }), CAST, NOW).alsoChip, null);
  // The full card names the first ALSO_NAMED and a "+N" chip names the rest; compact's chip counts all.
  const many = ["a", "b", "c", "d", "e", "f"].map((repo) => ({ repo, at: 1 }));
  const full = card(session({ touched: many }), CAST, NOW);
  assert.deepEqual(full.also, ["also in a", "also in b", "also in c", "also in d"]);
  assert.deepEqual(full.alsoRest, { text: "+2", label: "Also in e and f" });
  assert.deepEqual(full.alsoPast, ["also in e", "also in f"], "the rest, named while a phone card shows its full text");
  assert.deepEqual(card(session({ touched: many.slice(0, ALSO_NAMED) }), CAST, NOW).alsoPast, []);
  assert.equal(full.alsoChip.text, "+6");
  assert.equal(card(session({ touched: many.slice(0, ALSO_NAMED) }), CAST, NOW).alsoRest, null, "no chip while every repo is named");
});

test("the compact pill's time takes in updated, which has no line of its own there", () => {
  const working = (over) => session({ status: "working", reason: null, ...over });
  // Fresh: the status age alone, as on the full card.
  assert.equal(pillWhen(working({ status_at: ago(120), updated_at: ago(60) }), NOW), "2m");
  // Over five minutes since anything, and the same age: said once.
  const stale = working({ status_at: ago(420), updated_at: ago(420) });
  assert.equal(card(stale, CAST, NOW).updated, "updated 7m ago");
  assert.equal(pillWhen(stale, NOW), "7m");
  // In this state 30m, updated 7m ago: both, the status age first.
  const both = working({ status_at: ago(1800), updated_at: ago(420) });
  assert.equal(card(both, CAST, NOW).pill.age, "30m", "the full card keeps its pill");
  assert.equal(card(both, CAST, NOW).pill.when, "30m \u00b7 7m ago");
  // The boundary is updated's own: at five minutes it is not shown, so the pill holds the status age.
  assert.equal(pillWhen(working({ status_at: ago(1800), updated_at: ago(300) }), NOW), "30m");
  // An ended card's pill already says how long; an unknown time is not folded in.
  assert.equal(pillWhen(session({ status: "ended", reason: "closed", status_at: ago(1800), updated_at: ago(420) }), NOW), "30m");
  assert.equal(pillWhen(working({ status_at: ago(1800), updated_at: "x" }), NOW), "30m");
  // Quiet and silent cards shorten the full card's phrase.
  assert.equal(pillWhen(working({ status_at: ago(1800), updated_at: ago(900), quiet_since: ago(720) }), NOW), "12m quiet");
  assert.equal(statusParts(working({ quiet_since: ago(720) }), NOW).at(-1), "no activity for 12m");
  assert.equal(pillWhen(session({ status: "silent", reason: null, status_at: ago(7200), updated_at: ago(7200) }), NOW), "2h");
});

test("Open terminal's accessible name carries the reason it is off", () => {
  assert.equal(card(session({ status: "working" }), CAST, NOW).jumpLabel, "Open terminal, Hephaestus");
  const unnamed = card(session({ name: null, tmux: null }), CAST, NOW);
  assert.equal(unnamed.jump.enabled, false);
  assert.equal(unnamed.jumpLabel, "Open terminal, Hephaestus, unavailable: no session name yet");
  const ended = card(session({ status: "ended", reason: "closed" }), CAST, NOW);
  assert.equal(ended.jumpLabel, "Open terminal, Hephaestus, unavailable: session ended");
});

test("a card names its account, and the wall shows it only while live cards differ in it", () => {
  const rit = { id: "96130a18-106b-49a2-9b8e-a0b4d52aa214", label: "RIT-CS-DQL" };
  const me = { id: "6f5fe38b-9f23-4588-b57a-6efd1225cadd", label: "Personal" };
  const a = card(session({ account: rit }), CAST, NOW);
  assert.equal(a.account, "RIT-CS-DQL");
  assert.equal(a.accountId, rit.id);
  const b = card(session({ session_id: "b", account: me }), CAST, NOW);
  const none = card(session({ session_id: "c" }), CAST, NOW);
  assert.equal(none.account, null);
  assert.equal(accountsDiffer([a, b]), true);
  assert.equal(accountsDiffer([a, card(session({ session_id: "d", account: rit }), CAST, NOW)]), false, "one account: no chip");
  assert.equal(accountsDiffer([a, none]), false, "a card with no account says nothing of a second");
  assert.equal(accountsDiffer([a, card(session({ session_id: "e", account: me, status: "ended" }), CAST, NOW)]), false, "an ended card does not count");
});

test("#148: a session with no character of its own gets one no live card shows, never a medallion while the theme loads", () => {
  const cast = {
    faces: "kourai",
    characters: { v1: { name: "One", face: "one" }, v2: { name: "Two", face: "two" }, v3: { name: "Three", face: "three" } },
  };
  const at = (id, voice, started, over = {}) => session({ session_id: id, voice, started_at: started, ...over });
  const faces = (list) => Object.fromEntries(castPicks(list, cast).map((s) => [s.session_id, identity(s, cast).name]));

  // keryx muted, no home voice: a free character, and no keryx voice to name.
  const muted = castPicks([at("held", "v1", 1), at("cv", null, 2)], cast);
  assert.notEqual(identity(muted[1], cast).name, "One");
  assert.ok(["Two", "Three"].includes(identity(muted[1], cast).name));
  assert.equal(identity(muted[1], cast).voice, null);
  assert.equal(identity(muted[0], cast).voice, voiceName("v1"), "an own voice is still named");

  // Free characters go first; a second voiceless session takes the other one.
  const two = faces([at("held", "v1", 1), at("a", null, 2), at("b", null, 3)]);
  assert.deepEqual(new Set([two.a, two.b]), new Set(["Two", "Three"]));

  // Every character showing: one of the least shown is reused, not a medallion.
  const full = faces([at("x", "v1", 1), at("y", "v1", 2), at("z", "v2", 3), at("w", "v3", 4), at("n", null, 5)]);
  assert.ok(["Two", "Three"].includes(full.n), full.n);

  // An ended card holds its face until it leaves the wall; its departure frees it.
  const ended = faces([at("old", "v1", 1, { status: "ended" }), at("p", "v2", 2), at("q", "v3", 3), at("r", null, 4)]);
  assert.ok(["One", "Two", "Three"].includes(ended.r));
  assert.equal(faces([at("p", "v2", 2), at("q", "v3", 3), at("r", null, 4)]).r, "One");

  // A newer session whose own voice is an older card's pick shares it; the older card keeps its face.
  const olderPick = castPicks([at("o", null, 1)], cast)[0].pick;
  const shared = faces([at("o", null, 1), at("n", olderPick, 2)]);
  assert.equal(shared.o, shared.n, "the two share the character; the older one never moves");

  // An older card ending never moves a newer one's face.
  for (let i = 0; i < 200; i++) {
    const list = [at(`a${i}`, null, 1), at(`b${i}`, null, 2)];
    const live = faces(list)[`b${i}`];
    assert.equal(faces([{ ...list[0], status: "ended" }, list[1]])[`b${i}`], live);
  }

  // Stable: an older card keeps its face when a newer one arrives, whatever the order sessions come in.
  const before = faces([at("held", "v1", 1), at("older", null, 2)]);
  const after = faces([at("newer", null, 9), at("older", null, 2), at("held", "v1", 1)]);
  assert.equal(after.older, before.older);
  assert.notEqual(after.newer, after.older);

  // A voice the theme does not cast counts as none.
  assert.ok(["One", "Two", "Three"].includes(faces([at("odd", "zz_nobody", 1)]).odd));
});

test("#148: the medallion is only for a theme that did not load", () => {
  const s = session({ voice: null, name: "CV audit" });
  for (const none of [null, undefined, {}, { faces: "kourai", characters: {} }]) {
    const [picked] = castPicks([s], none);
    assert.equal(picked.pick, undefined);
    assert.equal(identity(picked, none).face, identity(s, null).face);
    assert.match(identity(picked, none).face, /^data:image\/svg\+xml/);
  }
});
