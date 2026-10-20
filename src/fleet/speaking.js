// Who is speaking, and how loud: keryx's line as the reader passes it on
// ({session_id, envelope, started_at, ends_at}), turned into the waves around
// that card's portrait. Kept free of the DOM so it can be unit tested.

/** Envelope samples a second, as keryx writes them. */
export const RATE = 20;
/** A gap between sentences shorter than this keeps the waves up, so one line reads as one. */
export const SPEAK_HOLD_MS = 600;
/** How long the waves take to fade once the line is over. */
export const SPEAK_FADE_MS = 300;
// The kourai forge golds: green means done on the wall.
export const GOLD = "#C9944A";
export const GOLD_LIGHT = "#F1D2A1";
// In the portrait's 80-unit viewBox: the crew ring's outer edge is at 40, the
// card's padding allows 58. A steady ring hugs the crew ring and swells with
// the voice; `ripples` rings leave it and fade.
export const WAVE = { cx: 40, cy: 40, rings: 3, ripples: 2, periodMs: 1300, steadyR: 43.5, r0: 46.5, r1: 56 };
/** The still ring shown instead of waves under reduced motion. */
export const STILL = { r: WAVE.steadyR, width: 4 };

const finite = (x) => typeof x === "number" && Number.isFinite(x);
const clamp01 = (x) => Math.min(1, Math.max(0, x));

/** A line the wall can use; anything else is no line. */
export function validLine(s) {
  return Boolean(
    s && typeof s.session_id === "string" && s.session_id && finite(s.started_at) && finite(s.ends_at)
      && Array.isArray(s.envelope),
  );
}

/** The envelope at `nowMs`, read between its 50 ms samples; 0 before the line, after it, or in a gap. */
export function levelAt(line, nowMs) {
  const env = line?.envelope;
  if (!Array.isArray(env) || env.length === 0) return 0;
  const x = (nowMs / 1000 - line.started_at) * RATE;
  if (!(x >= 0) || x >= env.length) return 0;
  const i = Math.floor(x);
  const a = Number(env[i]) || 0;
  const b = Number(env[Math.min(i + 1, env.length - 1)]) || 0;
  return clamp01(a + (b - a) * (x - i));
}

/**
 * Follows the speaking line across snapshots. `update` takes each snapshot's
 * `speaking` (or null) and says whom to announce: once per utterance, so the
 * next sentence of the same line, arriving within the hold, says nothing.
 * `frame` gives what to draw at a moment, or null once the waves are gone.
 */
export class Speaker {
  constructor() {
    this.line = null;
    this.endMs = 0; // when the hold ends and the fade starts
  }

  /** Whether waves still show at `nowMs`, fade included. */
  showing(nowMs) {
    return this.line !== null && nowMs < this.endMs + SPEAK_FADE_MS;
  }

  update(speaking, nowMs) {
    if (validLine(speaking) && nowMs < speaking.ends_at * 1000 + SPEAK_HOLD_MS) {
      const same = this.line?.session_id === speaking.session_id && nowMs < this.endMs;
      this.line = speaking;
      this.endMs = speaking.ends_at * 1000 + SPEAK_HOLD_MS;
      return same ? null : speaking.session_id;
    }
    // No file. Mid-clip, keryx cut the line off: fade now. After the clip's
    // end it is a gap or the end of the line: the hold decides.
    if (this.line && nowMs < this.line.ends_at * 1000) this.endMs = Math.min(this.endMs, nowMs);
    return null;
  }

  /** {id, level, alpha} at `nowMs`; null when nothing shows. */
  frame(nowMs) {
    if (!this.showing(nowMs)) {
      this.line = null;
      return null;
    }
    const alpha = nowMs < this.endMs ? 1 : clamp01(1 - (nowMs - this.endMs) / SPEAK_FADE_MS);
    return { id: this.line.session_id, level: levelAt(this.line, nowMs), alpha };
  }
}

const mix = (a, b, t) => {
  const ch = (hex, i) => parseInt(hex.slice(1 + 2 * i, 3 + 2 * i), 16);
  const c = [0, 1, 2].map((i) => Math.round(ch(a, i) + (ch(b, i) - ch(a, i)) * t));
  return `#${c.map((v) => v.toString(16).padStart(2, "0")).join("")}`;
};

/**
 * The rings at `nowMs` for a line at `level` (0-1), faded by `alpha`: a steady
 * gold ring that swells with the voice, and ripples that leave it light,
 * darken and thin as they spread, then fade. A louder moment sends them further, thicker
 * and brighter; a gap leaves them faint and close in.
 */
export function waves(level, alpha, nowMs) {
  const loud = clamp01(level);
  const a = clamp01(alpha);
  const round = (x, d = 2) => Number(x.toFixed(d));
  const steady = { r: WAVE.steadyR, width: round(2.5 + 1.5 * loud), opacity: round(a, 3), color: GOLD };
  const reach = (WAVE.r1 - WAVE.r0) * (0.35 + 0.65 * loud);
  const ripples = Array.from({ length: WAVE.ripples }, (_, k) => {
    const phase = (((nowMs / WAVE.periodMs + k / WAVE.ripples) % 1) + 1) % 1;
    return {
      r: round(WAVE.r0 + reach * phase),
      width: round((2.5 + 2 * loud) * (1 - 0.6 * phase)),
      // Full strength for most of the way, so the gold stays gold on the dark card.
      opacity: round(a * Math.min(1, 2.5 * (1 - phase)) * (0.6 + 0.4 * loud), 3),
      color: mix(GOLD_LIGHT, GOLD, phase),
    };
  });
  return [steady, ...ripples];
}

/** Whether `speaking` still marks its session at `nowMs`: through the hold, not the fade. */
export const speakingNow = (speaking, nowMs) => validLine(speaking) && nowMs < speaking.ends_at * 1000 + SPEAK_HOLD_MS;
