import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CUES, PEAK, RATE, samples, soundPath, wav } from "../scripts/make-sounds.mjs";

for (const [name, notes] of Object.entries(CUES)) {
  test(`${name}.wav is what make-sounds.mjs writes`, () => {
    assert.ok(readFileSync(soundPath(name)).equals(wav(samples(notes))), "run node scripts/make-sounds.mjs");
  });
}

test("each cue is short and stays under its peak", () => {
  for (const notes of Object.values(CUES)) {
    const pcm = samples(notes);
    assert.ok(pcm.length / RATE < 0.5, `${pcm.length / RATE} s`);
    const peak = Math.max(...pcm.map(Math.abs)) / 32767;
    assert.ok(peak <= PEAK && peak > PEAK * 0.8, `peak ${peak}`);
  }
});

test("each note fades out before the silence after it, so no note clicks", () => {
  for (const notes of Object.values(CUES)) {
    const pcm = [...samples(notes), 0];
    // Where each run of 10 or more zeros (a gap, or the end) begins.
    const ends = pcm.flatMap((s, i) => (s === 0 && pcm.slice(i, i + 10).every((z) => z === 0) && pcm[i - 1] !== 0 ? [i] : []));
    assert.equal(ends.length, notes.length);
    for (const e of ends) {
      const tail = Math.max(...pcm.slice(e - 20, e).map(Math.abs)) / 32767;
      assert.ok(tail < PEAK * 0.02, `tail ${tail} before sample ${e}`);
    }
  }
});

test("needs-you repeats one pitch and done rises", () => {
  assert.equal(new Set(CUES["needs-you"]).size, 1);
  assert.ok(CUES.done[1] > CUES.done[0]);
});
