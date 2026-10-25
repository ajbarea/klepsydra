import { test } from "node:test";
import assert from "node:assert/strict";
import { GROUPS, askedNote, asking, isReady, listed, readiness, readyState, sessionRoute, wrapupAnnouncements, wrapupCopy, wrapupLine, wrapupLines } from "./fleet/wrapup.js";
import { endAllCopy } from "./fleet/end.js";
import { card } from "./fleet/model.js";

const fleet = { session_id: "s", tmux: { socket: "/tmp/tmux-1001/klepsydra", pane: "%3" }, distro: "Ubuntu", claude: { pid: 7, start: 9 } };
const outside = { ...fleet, tmux: { socket: "/tmp/tmux-1001/default", pane: "%3" } };
const AT = 1_792_600_000;
const REQUEST = { id: "1792600000000", at: AT, until: AT + 600, ids: ["s", "a", "b", "c", "d", "e", "f", "g"] };
const BEFORE = (REQUEST.until - 1) * 1000;
const AFTER = (REQUEST.until + 1) * 1000;
const ANSWERS = {
  asked: { state: "asked", at: AT },
  ready: { state: "ready", at: AT, settled_at: AT + 2 },
  blocked: { state: "blocked", reason: "a review of #70 is running, 20 min", at: AT },
  none: undefined,
};

test("the preview routes each status as wrapup.rs does, in klepsydra's tmux or not", () => {
  const want = {
    working: ["turn_end", "turn_end"],
    needs_you: ["after_answer", "after_answer"],
    done: ["type", "by_hand"],
    new: ["type", "by_hand"],
    error: ["type", "by_hand"],
    silent: ["by_hand", "by_hand"],
    ended: [null, null],
  };
  for (const [status, [inside, out]] of Object.entries(want)) {
    assert.equal(sessionRoute({ ...fleet, status }), inside, `${status} in the fleet`);
    assert.equal(sessionRoute({ ...outside, status }), out, `${status} outside`);
    assert.equal(sessionRoute({ status }), out, `${status} with no tmux`);
  }
  // In the fleet means what the actions menu needs: a known Claude process too.
  assert.equal(sessionRoute({ ...fleet, status: "done", claude: undefined }), "by_hand");
  assert.equal(sessionRoute({ ...fleet, status: "done", claude: { pid: 0, start: 9 } }), "by_hand");
  assert.equal(sessionRoute({ status: "weird" }), null);
  assert.equal(sessionRoute(null), null);
});

test("every answer and status reads its own line, before the window closes and after", () => {
  const rows = {
    // answer: status -> [before until, after until]
    ready: {
      working: ["Working again", "Working again"],
      needs_you: ["Ready once you answer it", "Ready once you answer it"],
      done: ["Ready", "Ready"],
      silent: ["Ready", "Ready"],
    },
    blocked: Object.fromEntries(["working", "needs_you", "done", "silent"].map((s) => [s, Array(2).fill("Not ready: a review of #70 is running, 20 min")])),
    asked: {
      working: ["Wrapping up…", "No answer"],
      needs_you: ["Answer it first; it wraps up after", "No answer"],
      done: ["Wrapping up…", "No answer"],
      silent: ["Wrapping up…", "No answer"],
    },
    none: {
      working: ["Wraps up when this turn ends", "No answer"],
      needs_you: ["Answer it first; it wraps up after", "No answer"],
      done: ["Ask by hand: /klepsydra-wrapup", "No answer"],
      silent: ["Ask by hand: /klepsydra-wrapup", "No answer"],
    },
  };
  for (const [answer, byStatus] of Object.entries(rows)) {
    for (const [status, [before, after]] of Object.entries(byStatus)) {
      for (const place of [fleet, outside]) {
        const s = { ...place, status, wrapup: ANSWERS[answer] };
        assert.equal(wrapupLine(s, REQUEST, BEFORE)?.text, before, `${answer} x ${status} before`);
        assert.equal(wrapupLine(s, REQUEST, AFTER)?.text, after, `${answer} x ${status} after`);
      }
    }
    // An ended card says nothing, whatever it answered.
    assert.equal(wrapupLine({ ...fleet, status: "ended", wrapup: ANSWERS[answer] }, REQUEST, BEFORE), null, `${answer} x ended`);
    assert.equal(wrapupLine({ ...fleet, status: "ended", wrapup: ANSWERS[answer] }, REQUEST, AFTER), null, `${answer} x ended after`);
  }
  assert.equal(wrapupLine({ ...fleet, status: "working", wrapup: ANSWERS.ready }, null, BEFORE), null, "no request, no line");
  assert.equal(wrapupLine({ ...fleet, status: "working", wrapup: ANSWERS.asked }, REQUEST, REQUEST.until * 1000)?.text, "Wrapping up…", "until itself still asks");
});

test("a blocked answer without a reason still reads not ready, and the reason is kept as written", () => {
  const blocked = (reason) => wrapupLine({ session_id: "s", status: "done", wrapup: { state: "blocked", reason, at: AT } }, REQUEST, BEFORE).text;
  assert.equal(blocked(undefined), "Not ready");
  assert.equal(blocked("   "), "Not ready");
  assert.equal(blocked("<b>build</b> & deploy"), "Not ready: <b>build</b> & deploy", "text, never markup: the wall sets it as textContent");
});

test("Stop wrap-up shows only while sessions are still asked", () => {
  assert.equal(asking(null, BEFORE), false);
  assert.equal(asking(REQUEST, BEFORE), true);
  assert.equal(asking(REQUEST, REQUEST.until * 1000), true);
  assert.equal(asking(REQUEST, AFTER), false);
});

test("the bar counts live sessions only, and is safe only when every one, and at least one, is ready", () => {
  const ready = { session_id: "s", status: "done", wrapup: ANSWERS.ready };
  const as = (id, rest) => ({ ...rest, session_id: id });
  assert.deepEqual(readiness([], REQUEST), { ready: 0, live: 0, safe: false, text: "0 of 0 ready" }, "none live");
  assert.deepEqual(readiness([as("a", { status: "ended", wrapup: ANSWERS.ready })], REQUEST), { ready: 0, live: 0, safe: false, text: "0 of 0 ready" }, "only an ended card");
  assert.deepEqual(readiness([ready, as("a", { status: "done", wrapup: ANSWERS.asked })], REQUEST), { ready: 1, live: 2, safe: false, text: "1 of 2 ready" }, "one not ready");
  assert.deepEqual(readiness([ready, as("a", { status: "done", wrapup: ANSWERS.blocked })], REQUEST).safe, false, "one blocked");
  assert.deepEqual(readiness([ready, as("a", { status: "silent" })], REQUEST).safe, false, "one with no answer");
  assert.deepEqual(readiness([ready, as("a", ready), as("b", { status: "ended" })], REQUEST), { ready: 2, live: 2, safe: true, text: "2 of 2 ready" }, "an ended card ignored");
  assert.equal(readiness([ready, as("new", ready)], REQUEST).safe, false, "a session the request does not list is never ready");
  assert.equal(readiness([ready], { ...REQUEST, ids: undefined }).safe, false, "a request that lists nobody");
  assert.equal(readiness([ready], null).safe, false, "no request");
});

test("only listed sessions are asked: one started later reads Not asked", () => {
  assert.equal(listed({ session_id: "s" }, REQUEST), true);
  assert.equal(listed({ session_id: "zz" }, REQUEST), false);
  assert.equal(listed({ session_id: "s" }, { ...REQUEST, ids: "s" }), false, "ids must be a list");
  assert.deepEqual(wrapupLine({ ...fleet, session_id: "zz", status: "done", wrapup: ANSWERS.ready }, REQUEST, BEFORE), { state: "unasked", text: "Not asked" });
  assert.equal(wrapupLine({ ...fleet, session_id: "zz", status: "ended" }, REQUEST, BEFORE), null, "an ended one says nothing");
});

// One rule: a ready answer counts once the turn that gave it has ended (the
// Stop hook stamps settled_at), and only until the session starts another
// turn; a session still at work never counts.
test("a ready answer counts only once its turn has ended and until another begins", () => {
  const settled = AT + 10;
  const base = { ...fleet, status: "done", status_at: settled, turn_at: AT - 30, prompt: { text: "/klepsydra-wrapup", at: AT - 30 }, wrapup: { state: "ready", at: AT, settled_at: settled } };
  const rows = [
    // [what, session, readyState, line]
    ["settled, idle", base, "ready", "Ready"],
    ["reported, its turn still going (it ran ready and kept on)", { ...base, status: "working", status_at: AT - 30, wrapup: { state: "ready", at: AT } }, "finishing", "Finishing its turn"],
    ["reported, not settled, idle (an old file)", { ...base, wrapup: { state: "ready", at: AT } }, "finishing", "Finishing its turn"],
    ["settled, then a notification turn that waits on AJ", { ...base, status: "needs_you", turn_at: settled + 5 }, "stale", "Working again"],
    ["settled, then a notification turn that ended", { ...base, status: "done", turn_at: settled + 5, status_at: settled + 9 }, "stale", "Working again"],
    ["a turn that began the second it settled", { ...base, turn_at: settled }, "stale", "Working again"],
    ["settled, then a prompt (a file with no turn_at)", { ...base, turn_at: null, prompt: { text: "more", at: settled + 1 } }, "stale", "Working again"],
    ["settled with background work out", { ...base, status: "working", reason: "background" }, "background", "Ready once its background work ends"],
    ["settled, then a background agent's question", { ...base, status: "needs_you", asked_after_turn: true }, "waiting", "Ready once you answer it"],
    ["settled, working with no new turn recorded", { ...base, status: "working" }, "stale", "Working again"],
  ];
  for (const [what, s, state, line] of rows) {
    assert.equal(readyState(s), state, what);
    assert.equal(wrapupLine(s, REQUEST, BEFORE).text, line, what);
    assert.equal(isReady(s, REQUEST), state === "ready", what);
    assert.equal(readiness([s], REQUEST).safe, state === "ready", what);
  }
  assert.equal(readyState({ ...base, wrapup: { state: "blocked", reason: "x", at: AT } }), null, "only a ready answer has a ready state");
});

test("a background agent's question after the turn ended is not promised a wrap-up after the answer", () => {
  const s = { ...fleet, status: "needs_you", asked_after_turn: true };
  assert.equal(wrapupLine(s, REQUEST, BEFORE).text, "Answer it, then ask by hand: /klepsydra-wrapup");
  assert.equal(wrapupLine({ ...s, asked_after_turn: false }, REQUEST, BEFORE).text, "Answer it first; it wraps up after");
  assert.equal(wrapupLine(s, REQUEST, AFTER).text, "No answer");
});

const model = (s) => card({ session_id: s.id, where: { repo: s.repo ?? "r" }, ...s }, {}, BEFORE, REQUEST);

test("the confirm groups who is asked by how, leaves out the ended, and counts the ones klepsydra asks", () => {
  const cards = [
    model({ id: "a", name: "A", status: "done", ...fleet }),
    model({ id: "b", name: "B", status: "working", ...fleet }),
    model({ id: "c", name: "C", status: "needs_you", ...fleet }),
    model({ id: "d", name: "D", status: "done", ...outside }),
    model({ id: "e", name: "E", status: "silent", ...fleet }),
    model({ id: "f", name: "F", status: "ended", ...fleet }),
    model({ id: "g", name: "G", status: "working", ...outside, repo: "papers" }),
  ];
  const copy = wrapupCopy(cards);
  assert.deepEqual(copy.groups, [
    { heading: "Typed now", names: ["A in r"] },
    { heading: "At the end of its turn", names: ["B in r", "G in papers"] },
    { heading: "After you answer", names: ["C in r"] },
    { heading: "Ask by hand: type /klepsydra-wrapup in its terminal", names: ["D in r", "E in r"] },
  ]);
  assert.equal(copy.confirm, "Ask 4 sessions");
  assert.equal(copy.count, 4);
  assert.equal(wrapupCopy(cards.slice(0, 1)).confirm, "Ask 1 session");
  assert.deepEqual(wrapupCopy([cards[5]]).groups, [], "an ended card is not listed");
  assert.equal(wrapupCopy([cards[3], cards[4]]).confirm, "Start wrap-up", "only sessions you ask by hand");
  assert.equal(copy.cancel, "Cancel");
  assert.match(copy.text, /"No answer" after 10 minutes/);
  assert.deepEqual(GROUPS.map(([r]) => r), ["type", "turn_end", "after_answer", "by_hand"]);
  for (const t of [copy.title, copy.text, ...copy.groups.map((g) => g.heading)]) assert.ok(!t.includes("—"), "no em-dash");
});

test("End all ready names every session it ends, warns of any mid-turn, and counts the rest", () => {
  const cards = [
    { name: "Hermes", status: "done", place: { repo: "klepsydra" } },
    { name: "Metis", status: "working", place: { repo: "ideas" } },
    { name: "Elpis", status: "done", place: null },
  ];
  const copy = endAllCopy(cards);
  assert.equal(copy.title, "End 3 sessions?");
  assert.equal(copy.confirm, "End 3 sessions");
  assert.deepEqual(copy.groups, [{ heading: null, names: ["Hermes in klepsydra", "Metis in ideas", "Elpis"] }]);
  assert.match(copy.text, /as if you typed \/exit in its terminal\. Each card counts down 5 s with its own Undo before anything is sent\.$/);
  assert.equal(copy.warn, "Metis is mid-turn: the turn stops and its unfinished work is lost.");
  assert.equal(endAllCopy([cards[0]]).warn, null);
  assert.equal(endAllCopy([cards[0]]).confirm, "End 1 session");
  assert.match(endAllCopy(cards, 2).text, /Not listed: 2 sessions outside klepsydra's tmux, which you end from their own terminals\.$/);
  assert.match(endAllCopy(cards, 1).text, /Not listed: 1 session outside klepsydra's tmux, which you end from its own terminal\.$/);
  assert.equal(endAllCopy([cards[1], { ...cards[1], name: "Aidos" }]).warn, "Metis and Aidos are mid-turn: the turn stops and its unfinished work is lost.");
  for (const t of [copy.title, copy.text, copy.warn, copy.confirm]) assert.ok(!t.includes("—"), "no em-dash");
});

test("a model card carries its route, its line, and the line in its accessible name", () => {
  const c = model({ id: "a", name: "A", status: "done", ...fleet, wrapup: ANSWERS.blocked });
  assert.equal(c.wrapupRoute, "type");
  assert.deepEqual(c.wrapup, { state: "blocked", text: "Not ready: a review of #70 is running, 20 min" });
  assert.match(c.label, /, Not ready: a review of #70 is running, 20 min$/);
  const quiet = card({ session_id: "a", status: "done", ...fleet }, {}, BEFORE);
  assert.equal(quiet.wrapup, null, "no request, no line");
  assert.doesNotMatch(quiet.label, /ready|wrap/i);
});

test("a changed line is announced once, never on the first look or as a request appears", () => {
  const at = (texts) => texts.map(([id, name, text]) => ({ id, name, wrapup: text ? { text } : null }));
  const first = at([["a", "A", "Wrapping up…"], ["b", "B", "Wraps up when this turn ends"]]);
  assert.deepEqual(wrapupAnnouncements(undefined, first), [], "first look");
  assert.deepEqual(wrapupAnnouncements(wrapupLines(at([["a", "A", null]])), first), [], "the request appears");
  const next = at([["a", "A", "Ready"], ["b", "B", "Wraps up when this turn ends"]]);
  assert.deepEqual(wrapupAnnouncements(wrapupLines(first), next), ["A: Ready"]);
  assert.deepEqual(wrapupAnnouncements(wrapupLines(next), next), [], "the same lines again: a tick says nothing");
});

test("a session idle at its prompt with background work out is typed into, since no Stop is coming", () => {
  const bg = { ...fleet, status: "working", reason: "background" };
  assert.equal(sessionRoute(bg), "type");
  assert.equal(sessionRoute({ ...outside, status: "working", reason: "background" }), "by_hand");
  assert.equal(sessionRoute({ ...fleet, status: "working", reason: null }), "turn_end");
  assert.equal(sessionRoute({ ...fleet, status: "done", reason: "background" }), "type");
  assert.equal(sessionRoute({ ...fleet, status: "needs_you", reason: "background" }), "after_answer");
  assert.equal(wrapupLine(bg, REQUEST, BEFORE).text, "Ask by hand: /klepsydra-wrapup", "unmarked: its typing failed");
  assert.equal(wrapupLine({ ...bg, wrapup: ANSWERS.asked }, REQUEST, BEFORE).text, "Wrapping up…");
  assert.notEqual(wrapupLine(bg, REQUEST, BEFORE).text, "Wraps up when this turn ends");
});

test("Wrap up while one is still asking says it starts over and clears the answers so far", () => {
  const cards = [model({ id: "a", name: "A", status: "done", ...fleet })];
  const fresh = wrapupCopy(cards);
  assert.equal(fresh.warn, null);
  const again = wrapupCopy(cards, true);
  assert.equal(again.title, "Start the wrap-up over?");
  assert.equal(again.warn, "A wrap-up is still asking. Starting over clears every answer so far, and sessions that already answered are asked again.");
  assert.equal(again.confirm, "Start over: ask 1 session");
  assert.ok(!again.warn.includes("—") && !again.title.includes("—"));
});

test("the note after Wrap up counts the sessions typed into now, those asked at turn end, and names each failure", () => {
  const names = { a: "Hermes", b: "Metis", c: "Elpis", d: "Aidos", e: "Nike" };
  const nameOf = (id) => names[id];
  const typed = (id) => ({ id, route: "type", error: null, typed: true });
  const ok = (id, route) => ({ id, route, error: null, typed: false });
  const bad = (id) => ({ id, route: "type", error: "The prompt did not read /klepsydra-wrapup", typed: false });
  assert.equal(askedNote([typed("a"), ok("b", "turn_end"), ok("c", "by_hand")], nameOf), "Typed into 1 session; 1 asked when its turn ends; 1 to ask by hand");
  assert.equal(askedNote([typed("a"), ok("b", "type")], nameOf), "Typed into 1 session; 1 already asked", "an ask carried over, or an answer, is not typed again");
  assert.equal(askedNote([typed("a"), bad("b")], nameOf), "Typed into 1 session; not typed into Metis, see its card");
  assert.equal(askedNote([ok("a", "turn_end"), ok("b", "after_answer"), bad("b"), bad("d"), ok("e", "by_hand")], nameOf), "Typed into 0 sessions; 2 asked when their turn ends; 1 to ask by hand; not typed into Metis and Aidos, see their cards");
  assert.equal(askedNote([], nameOf), "Typed into 0 sessions");
  assert.equal(askedNote([bad("zz")], nameOf), "Typed into 0 sessions; not typed into a session, see its card", "a card gone since");
});
