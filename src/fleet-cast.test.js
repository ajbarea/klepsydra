import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const cast = JSON.parse(readFileSync(new URL("./fleet/cast.json", import.meta.url), "utf8"));
const faces = new URL("./fleet/faces/", import.meta.url);
const exists = (file) => existsSync(new URL(file, faces));

// keryx's rotation pool (keryx src/keryx/voices.py POOL, 0.9.0): the only
// voices keryx hands a terminal unasked.
const POOL = [
  "af_heart", "am_michael", "bf_emma", "bm_george", "af_bella", "am_fenrir", "bf_isabella",
  "bm_fable", "am_puck", "af_aoede", "af_kore", "af_sarah", "af_alloy", "af_nova",
];
// Every voice in Kokoro v1.0's voices-v1.0.bin, the file keryx loads; any of
// them can be a terminal's voice through keryx's `voice` setting.
const KOKORO = [
  "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
  "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
  "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
  "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis",
  "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune",
  "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni",
  "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
];
const PORTRAITS = ["aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne"];

test("the ten kourai characters each have one pool voice of their gender", () => {
  const entries = Object.entries(cast.characters);
  assert.deepEqual(entries.map(([, c]) => c.face).sort(), PORTRAITS);
  assert.equal(new Set(entries.map(([, c]) => c.name)).size, 10);
  for (const [voice, c] of entries) {
    assert.ok(POOL.includes(voice), `${voice} is not in keryx's pool`);
    assert.equal(voice[1], c.gender, `${c.name} cast against gender`);
  }
});

test("kourai's named Kokoro seeds are kept", () => {
  assert.equal(cast.characters.am_michael.name, "Hephaestus");
  assert.equal(cast.characters.am_puck.name, "Puck");
});

test("every Kokoro voice has a Lorelei face, and every face file exists", () => {
  assert.deepEqual([...cast.lorelei].sort(), KOKORO);
  for (const voice of cast.lorelei) assert.ok(exists(`lorelei/${voice}.svg`), voice);
  for (const c of Object.values(cast.characters)) {
    for (const size of [96, 192]) assert.ok(exists(`kourai/${c.face}-${size}.webp`), `${c.face} ${size}`);
  }
  assert.equal(cast.fallbacks, 24);
  for (let i = 0; i < cast.fallbacks; i++) assert.ok(exists(`fallback/${String(i).padStart(2, "0")}.svg`), String(i));
});
