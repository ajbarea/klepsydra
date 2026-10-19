import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  STATUS, shortAge, longAge, statusLine, voiceName, hash, identity, accessibleName,
  statuses, startedNeeding, announcements, whereText, updatedText, badgeSvg, stripItems, card,
} from "./fleet/model.js";

const NOW = 1_792_353_000_000; // fixed clock, ms
const ago = (s) => NOW / 1000 - s;
const CAST = {
  characters: { am_michael: { name: "Hephaestus", face: "hephaestus" } },
  lorelei: ["am_fenrir", "am_michael"],
  fallbacks: 24,
};
const session = (over = {}) => ({
  session_id: "cb9fa591-1514-44d1-a31c-eba4a7cb41ed",
  name: "Plan the fleet visualizer",
  launch_dir: "/home/aj/ajsoftworks",
  voice: "am_michael",
  status: "needs_you",
  reason: "approve Bash",
  status_at: ago(120),
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
  assert.equal(statusLine(s, NOW), "needs you? \u00b7 no word for 31m");
  assert.equal(accessibleName(s, CAST, NOW), "Hephaestus, needs you?, no word for 31 minutes");
  const svg = badgeSvg("needs_you", true);
  assert.match(svg, /tone-needs shape-diamond/);
  assert.match(svg, />\?<\/text>/);
  assert.notEqual(svg, badgeSvg("needs_you"));
  assert.equal(stripItems([s], CAST, NOW)[0].badge, svg);
  assert.equal(card(s, CAST, NOW).statusLine, "needs you? \u00b7 no word for 31m");
  const fresh = session();
  assert.equal(startedNeeding(statuses([fresh]), [s]).size, 0, "going quiet is not a new need");
  assert.deepEqual(announcements(statuses([fresh]), [s], CAST, NOW), ["Hephaestus, needs you?, no word for 31 minutes"]);
});

test("the strip item and card of a quiet session say so", () => {
  const item = stripItems([quiet()], CAST, NOW)[0];
  assert.equal(item.status, "working");
  assert.equal(item.quiet, true);
  assert.equal(item.label, "Hephaestus, working?, no activity for 12 minutes");
  const c = card(quiet(), CAST, NOW);
  assert.equal(c.status, "working");
  assert.equal(c.quiet, true);
  assert.equal(c.statusLine, "working? \u00b7 no activity for 12m");
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
    assert.deepEqual(card(s, CAST, NOW).touched, ["ideas \u00b7 unknown"]);
    const q = quiet({ quiet_since: bad ?? NaN, status_at: bad });
    assert.equal(statusLine(q, NOW), "working? \u00b7 no activity for unknown");
    assert.equal(accessibleName(q, CAST, NOW), "Hephaestus, working?, no activity for unknown");
    const silent = session({ status: "silent", status_at: bad });
    assert.equal(statusLine(silent, NOW), "silent \u00b7 no word for unknown");
    for (const text of [card(s, CAST, NOW).statusLine, card(q, CAST, NOW).statusLine, stripItems([s], CAST, NOW)[0].label]) {
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
  });
});

test("identity: another voice is its Lorelei face and capitalised name", () => {
  const who = identity(session({ voice: "am_fenrir" }), CAST);
  assert.deepEqual([who.name, who.face], ["Fenrir", "fleet/faces/lorelei/am_fenrir.svg"]);
});

test("identity: a blend or an unrendered voice falls back by a hash of the voice", () => {
  const blend = "af_bella(0.7)+af_heart(0.3)";
  const who = identity(session({ voice: blend }), CAST);
  assert.equal(who.name, "Bella and Heart");
  assert.equal(who.face, `fleet/faces/fallback/${String(hash(blend) % 24).padStart(2, "0")}.svg`);
  assert.equal(identity(session({ voice: blend, session_id: "x" }), CAST).face, who.face, "same voice, same face");
  assert.equal(voiceName("am_fenrir"), "Fenrir");
});

test("identity: no voice falls back by a hash of the session, named by the session", () => {
  const a = identity(session({ voice: null }), CAST);
  assert.equal(a.name, "Plan the fleet visualizer");
  assert.match(a.face, /^fleet\/faces\/fallback\/\d\d\.svg$/);
  assert.equal(identity(session({ voice: null, name: null }), CAST).name, "ajsoftworks");
  const faces = new Set(Array.from({ length: 500 }, (_, i) => identity(session({ voice: null, session_id: `s${i}` }), CAST).face));
  assert.equal(faces.size, 24, "every fallback face is reachable");
});

test("the portrait never changes with state", () => {
  for (const voice of ["am_michael", "am_fenrir", "af_bella(0.5)+af_heart(0.5)", null]) {
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

test("where, touched and updated", () => {
  assert.equal(whereText(session().where), "klepsydra \u00b7 fleet \u00b7 feat/fleet-visualizer");
  assert.equal(whereText({ repo: "notes", worktree: null, branch: null, at: 1 }), "notes");
  assert.equal(whereText(null), "");
  assert.equal(updatedText(session({ updated_at: ago(299) }), NOW), null);
  assert.equal(updatedText(session({ updated_at: ago(420) }), NOW), "updated 7m ago");
});

test("a card holds what the wall shows", () => {
  const c = card(session(), CAST, NOW);
  assert.equal(c.name, "Hephaestus");
  assert.equal(c.voice, "Michael");
  assert.equal(c.session, "Plan the fleet visualizer");
  assert.equal(c.statusLine, "needs you \u00b7 approve Bash \u00b7 2m");
  assert.deepEqual(c.touched, ["ideas \u00b7 2h"]);
  assert.equal(c.prompt, "i just want to be able to VIZ them");
  assert.equal(c.reply, "That works with no model calls");
  assert.deepEqual(c.jump, { enabled: true, why: null });
  assert.equal(c.jumpLabel, "Jump to terminal, Hephaestus");
  const other = card(session({ voice: "af_bella" }), CAST, NOW);
  assert.notEqual(other.jumpLabel, c.jumpLabel, "each Jump button is named for its session");
  assert.deepEqual(card(session({ name: null }), CAST, NOW).jump, { enabled: false, why: "no session name yet" });
  assert.deepEqual(card(session({ status: "ended" }), CAST, NOW).jump, { enabled: false, why: "session ended" });
  assert.equal(card(session({ status: "error", error: "API Error: Rate limit reached" }), CAST, NOW).error,
    "API Error: Rate limit reached");
  assert.equal(card(session({ error: "old" }), CAST, NOW).error, null, "only an error shows its error");
});

test("the model reads the cast the app ships", () => {
  const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
  assert.equal(identity(session(), cast).name, "Hephaestus");
});
