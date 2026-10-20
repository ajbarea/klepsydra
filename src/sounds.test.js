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

test("needs-you repeats one pitch and done rises", () => {
  assert.equal(new Set(CUES["needs-you"]).size, 1);
  assert.ok(CUES.done[1] > CUES.done[0]);
});
