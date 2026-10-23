import { test } from "node:test";
import assert from "node:assert/strict";
import { GROUPS, asking, readiness, sessionRoute, wrapupAnnouncements, wrapupCopy, wrapupLine, wrapupLines } from "./fleet/wrapup.js";
import { endAllCopy } from "./fleet/end.js";
import { card } from "./fleet/model.js";

const fleet = { tmux: { socket: "/tmp/tmux-1001/klepsydra", pane: "%3" }, distro: "Ubuntu", claude: { pid: 7, start: 9 } };
const outside = { ...fleet, tmux: { socket: "/tmp/tmux-1001/default", pane: "%3" } };
const AT = 1_792_600_000;
const REQUEST = { id: "1792600000000", at: AT, until: AT + 600 };
const BEFORE = (REQUEST.until - 1) * 1000;
const AFTER = (REQUEST.until + 1) * 1000;
const ANSWERS = {
  asked: { state: "asked", at: AT },
  ready: { state: "ready", at: AT },
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
    ready: { working: ["Ready", "Ready"], needs_you: ["Ready", "Ready"], done: ["Ready", "Ready"], silent: ["Ready", "Ready"] },
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
  const blocked = (reason) => wrapupLine({ status: "done", wrapup: { state: "blocked", reason, at: AT } }, REQUEST, BEFORE).text;
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
  const ready = { status: "working", wrapup: ANSWERS.ready };
  assert.deepEqual(readiness([]), { ready: 0, live: 0, safe: false, text: "0 of 0 ready" }, "none live");
  assert.deepEqual(readiness([{ status: "ended", wrapup: ANSWERS.ready }]), { ready: 0, live: 0, safe: false, text: "0 of 0 ready" }, "only an ended card");
  assert.deepEqual(readiness([ready, { status: "done", wrapup: ANSWERS.asked }]), { ready: 1, live: 2, safe: false, text: "1 of 2 ready" }, "one not ready");
  assert.deepEqual(readiness([ready, { status: "done", wrapup: ANSWERS.blocked }]).safe, false, "one blocked");
  assert.deepEqual(readiness([ready, { status: "silent" }]).safe, false, "one with no answer");
  assert.deepEqual(readiness([ready, ready, { status: "ended" }]), { ready: 2, live: 2, safe: true, text: "2 of 2 ready" }, "an ended card ignored");
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
