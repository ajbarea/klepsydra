import { test } from "node:test";
import assert from "node:assert/strict";
import { clipUrl, createReplayer, wavBytes } from "./fleet/replay.js";
import { card } from "./fleet/model.js";

const A = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
const B = "0b6e1c5a-1111-4222-8333-444455556666";

/** A 44-byte RIFF/WAVE header and two silent samples, as reply_clip sends it. */
function wav() {
  const b = new Uint8Array(48);
  b.set([..."RIFF"].map((c) => c.charCodeAt(0)), 0);
  b.set([..."WAVEfmt "].map((c) => c.charCodeAt(0)), 8);
  b.set([..."data"].map((c) => c.charCodeAt(0)), 36);
  return b.buffer;
}

/** Just enough of an HTMLAudioElement: records what it was given and played. */
class FakeAudio {
  constructor({ refuse = false } = {}) {
    this.src = null;
    this.played = [];
    this.paused = true;
    this.refuse = refuse;
    this.listeners = {};
  }
  addEventListener(name, fn) {
    this.listeners[name] = fn;
  }
  removeAttribute(name) {
    if (name === "src") this.src = null;
  }
  pause() {
    this.paused = true;
  }
  play() {
    if (this.refuse) return Promise.reject(new Error("NotAllowedError"));
    this.played.push(this.src);
    this.paused = false;
    return Promise.resolve();
  }
  end() {
    this.listeners.ended?.();
  }
  fail() {
    this.listeners.error?.();
  }
}

function setup({ app = true, invoke, audio = new FakeAudio() } = {}) {
  const changes = [];
  const urls = [];
  const revoked = [];
  const r = createReplayer({
    audio,
    app,
    invoke: invoke ?? (async (cmd, args) => (cmd === "reply_clip" ? wav() : Promise.reject(new Error(`${cmd} ${args}`)))),
    onChange: (id) => changes.push(id),
    objectUrl: (blob) => {
      urls.push(blob);
      return `blob:${urls.length}`;
    },
    revoke: (u) => revoked.push(u),
  });
  return { r, audio, changes, urls, revoked };
}

test("the phone plays a clip from its own server, by session and reply time", () => {
  assert.equal(clipUrl(A, 1792520221), `/audio/${A}?at=1792520221`);
  assert.equal(clipUrl("a/../b", "1&x"), "/audio/a%2F..%2Fb?at=1%26x");
});

test("in the app a press reads the clip through reply_clip and plays it as a WAV object URL", async () => {
  const asked = [];
  const { r, audio, urls, changes } = setup({ invoke: async (cmd, args) => (asked.push([cmd, args]), wav()) });
  assert.equal(await r.toggle(A, 5), null);
  assert.deepEqual(asked, [["reply_clip", { id: A }]]);
  assert.equal(urls[0].type, "audio/wav");
  assert.deepEqual(audio.played, ["blob:1"]);
  assert.ok(r.playing(A) && !r.playing(B));
  assert.deepEqual(changes, [A]);
});

test("on the phone a press plays the server's address", async () => {
  const { r, audio } = setup({ app: false });
  await r.toggle(A, 7);
  assert.deepEqual(audio.played, [`/audio/${A}?at=7`]);
});

test("a second press stops it; the end of the clip stops it too; each frees its URL", async () => {
  const { r, audio, changes, revoked } = setup();
  await r.toggle(A, 5);
  assert.equal(await r.toggle(A, 5), null);
  assert.ok(!r.playing(A) && audio.paused && audio.src === null);
  assert.deepEqual(revoked, ["blob:1"]);
  await r.toggle(A, 5);
  audio.end();
  assert.ok(!r.playing(A));
  assert.deepEqual(revoked, ["blob:1", "blob:2"]);
  assert.deepEqual(changes, [A, A, A, A]);
});

test("one clip at a time: another card's press stops the first", async () => {
  const { r, changes } = setup();
  await r.toggle(A, 5);
  await r.toggle(B, 5);
  assert.ok(r.playing(B) && !r.playing(A));
  assert.deepEqual(changes, [A, A, B]);
});

test("a clip that cannot be read or played says so and plays nothing", async () => {
  const gone = setup({ invoke: async () => Promise.reject("No reply to play.") });
  assert.equal(await gone.r.toggle(A, 5), "Could not play the reply: No reply to play.");
  assert.ok(!gone.r.playing(A));
  const refused = setup({ audio: new FakeAudio({ refuse: true }) });
  assert.equal(await refused.r.toggle(A, 5), "Could not play the reply: NotAllowedError");
  assert.ok(!refused.r.playing(A));
  assert.deepEqual(refused.revoked, ["blob:1"]);
});

test("a press while the last read is pending wins; the stale read plays nothing", async () => {
  let release;
  const slow = new Promise((resolve) => (release = resolve));
  let first = true;
  const { r, audio } = setup({
    invoke: async () => {
      if (first) {
        first = false;
        await slow;
      }
      return wav();
    },
  });
  const pending = r.toggle(A, 5);
  await r.toggle(B, 5);
  release();
  assert.equal(await pending, null);
  assert.ok(r.playing(B));
  assert.equal(audio.played.length, 1);
});

test("a card that leaves the wall stops its clip", async () => {
  const { r } = setup();
  await r.toggle(A, 5);
  r.keep(new Set([A, B]));
  assert.ok(r.playing(A));
  r.keep(new Set([B]));
  assert.ok(!r.playing(A));
});

test("a card offers its clip only when keryx kept one", () => {
  const base = { session_id: A, status: "done", status_at: 1, updated_at: 1 };
  const cast = { characters: {} };
  assert.equal(card(base, cast, 2000).clip, null);
  assert.equal(card({ ...base, reply_at: 1792520221 }, cast, 2000).clip, 1792520221);
  for (const bad of ["1792520221", 1.5, null, -Infinity]) assert.equal(card({ ...base, reply_at: bad }, cast, 2000).clip, null, String(bad));
  const c = card({ ...base, reply_at: 9 }, cast, 2000);
  assert.match(c.playLabel, /^Play .+'s last reply$/);
  assert.match(c.stopLabel, /^Stop .+'s reply$/);
});

test("a clip that fails before it plays keeps its note; one that fails while playing frees the button", async () => {
  // As the spec orders it: the element's error fires, then play() rejects.
  const audio = new FakeAudio();
  audio.play = function () {
    this.fail();
    return Promise.reject(new Error("NotSupportedError"));
  };
  const early = setup({ audio });
  assert.equal(await early.r.toggle(A, 5), "Could not play the reply: NotSupportedError");
  assert.ok(!early.r.playing(A));
  const late = setup();
  await late.r.toggle(A, 5);
  late.audio.fail();
  assert.ok(!late.r.playing(A));
});

test("a clip plays whichever way Tauri's IPC delivers its bytes", async () => {
  // Custom protocol: an ArrayBuffer. postMessage fallback: an array of numbers.
  for (const answer of [wav(), new Uint8Array(wav()), [...new Uint8Array(wav())]]) {
    const { r, audio, urls } = setup({ invoke: async () => answer });
    assert.equal(await r.toggle(A, 5), null);
    assert.deepEqual(audio.played, ["blob:1"]);
    const sent = new Uint8Array(await urls[0].arrayBuffer());
    assert.deepEqual([...sent], [...new Uint8Array(wav())], "the Blob holds the WAV bytes, not their text");
  }
});

test("an answer that is not a WAV says so and plays nothing", async () => {
  const text = [...new TextEncoder().encode("82,73,70,70,0,0,0,0,87,65,86,69")];
  for (const answer of [new ArrayBuffer(48), text, "RIFF", null, [300, 1], new Uint8Array([82, 73, 70, 70])]) {
    const { r, audio, urls } = setup({ invoke: async () => answer });
    assert.equal(await r.toggle(A, 5), "Could not play the reply: the clip is not a WAV file.");
    assert.ok(!r.playing(A));
    assert.deepEqual([audio.played, urls], [[], []]);
  }
  assert.ok(wavBytes([...new Uint8Array(wav())]) instanceof Uint8Array);
});
