// Writes the two ping cues to src-tauri/sounds/. An alert repeats one pitch and
// a completion rises, after the Wayfindr sound guidelines.
// Run: node scripts/make-sounds.mjs
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const RATE = 22050;
/** Peak level, -3 dBFS. */
export const PEAK = 10 ** (-3 / 20);
const NOTE_S = 0.18;
const GAP_S = 0.04;
const ATTACK_S = 0.005;
const DECAY_S = 0.1;

/** Equal-tempered pitch of a MIDI note, A4 = 69 = 440 Hz. */
const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);
const A5 = 81;
const E5 = 76;

export const CUES = {
  "needs-you": [A5, A5],
  done: [E5, A5],
};

/** 16-bit mono PCM samples: each note a sine with a fast attack and an exponential decay. */
export function samples(notes) {
  const note = Math.round(NOTE_S * RATE);
  const gap = Math.round(GAP_S * RATE);
  const out = new Int16Array(notes.length * note + (notes.length - 1) * gap);
  notes.forEach((midi, n) => {
    const start = n * (note + gap);
    for (let i = 0; i < note; i++) {
      const t = i / RATE;
      const env = Math.min(1, t / ATTACK_S) * Math.exp(-t / DECAY_S);
      out[start + i] = Math.round(PEAK * env * Math.sin(2 * Math.PI * hz(midi) * t) * 32767);
    }
  });
  return out;
}

/** A RIFF WAVE file holding `pcm`. */
export function wav(pcm) {
  const data = pcm.length * 2;
  const b = Buffer.alloc(44 + data);
  b.write("RIFF", 0);
  b.writeUInt32LE(36 + data, 4);
  b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); // PCM
  b.writeUInt16LE(1, 22); // mono
  b.writeUInt32LE(RATE, 24);
  b.writeUInt32LE(RATE * 2, 28);
  b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34);
  b.write("data", 36);
  b.writeUInt32LE(data, 40);
  pcm.forEach((s, i) => b.writeInt16LE(s, 44 + i * 2));
  return b;
}

export const soundPath = (name) => fileURLToPath(new URL(`../src-tauri/sounds/${name}.wav`, import.meta.url));

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  for (const [name, notes] of Object.entries(CUES)) writeFileSync(soundPath(name), wav(samples(notes)));
}
