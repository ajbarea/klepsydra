import { test } from "node:test";
import assert from "node:assert/strict";
import { clipUrl, createReplayer } from "./fleet/replay.js";
import { card } from "./fleet/model.js";

const A = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
const B = "0b6e1c5a-1111-4222-8333-444455556666";

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
}

function setup({ app = true, invoke, audio = new FakeAudio() } = {}) {
  const changes = [];
  const urls = [];
  const revoked = [];
  const r = createReplayer({
    audio,
    app,
    invoke: invoke ?? (async (cmd, args) => (cmd === "reply_clip" ? new Uint8Array([82, 73, 70, 70]).buffer : Promise.reject(new Error(`${cmd} ${args}`)))),
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
  const { r, audio, urls, changes } = setup({ invoke: async (cmd, args) => (asked.push([cmd, args]), new ArrayBuffer(8)) });
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
      return new ArrayBuffer(8);
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
