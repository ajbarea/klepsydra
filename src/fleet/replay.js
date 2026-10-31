// Playing a session's latest spoken reply from its card (keryx's reply clips,
// keryx docs/reply-clips.md). One clip plays at a time, on this device: the
// app reads it through reply_clip and plays an object URL; the phone plays
// its server's /audio/<id> directly, its source set and play() called in the
// press itself, since Safari allows play() only there (WebKit bug 259925).

/**
 * reply_clip's answer as bytes, or null when it is no WAV. Through Tauri's
 * custom-protocol IPC it arrives as an ArrayBuffer; through its postMessage
 * fallback, as an array of numbers, which a Blob would turn into text.
 */
export function wavBytes(answer) {
  let bytes = null;
  if (answer instanceof ArrayBuffer) bytes = new Uint8Array(answer);
  else if (ArrayBuffer.isView(answer)) bytes = new Uint8Array(answer.buffer, answer.byteOffset, answer.byteLength);
  else if (Array.isArray(answer) && answer.every((b) => Number.isInteger(b) && b >= 0 && b < 256)) bytes = Uint8Array.from(answer);
  const tag = (from) => (bytes ? String.fromCharCode(...bytes.subarray(from, from + 4)) : "");
  return tag(0) === "RIFF" && tag(8) === "WAVE" ? bytes : null;
}

/** The phone server's address for session `id`'s clip, `at` (its reply_at) keeping a newer clip from an older copy. */
export const clipUrl = (id, at) => `/audio/${encodeURIComponent(id)}?at=${encodeURIComponent(String(at))}`;

/**
 * A player for `audio` (an HTMLAudioElement). `app`: read clips with
 * `invoke("reply_clip", {id})`; else play them from `clipUrl`. `onChange(id)`
 * runs whenever `id` starts or stops playing, so its card can repaint.
 */
export function createReplayer({ audio, app, invoke, onChange, objectUrl = URL.createObjectURL, revoke = URL.revokeObjectURL }) {
  let current = null; // { id, url }

  function finish() {
    if (!current) return;
    const was = current;
    current = null;
    audio.pause();
    audio.removeAttribute("src");
    if (was.url) revoke(was.url);
    onChange(was.id);
  }
  audio.addEventListener("ended", finish);
  // A clip that fails once playing; before that, play()'s rejection says why.
  // An error from a source already replaced is not this one's.
  audio.addEventListener("error", () => {
    if (current?.started && audio.src === current.src) finish();
  });

  /** Play `id`'s clip, or stop it when it is the one playing. Resolves to a note for its card, or null. */
  async function toggle(id, at) {
    if (current?.id === id) {
      finish();
      return null;
    }
    finish();
    const mine = { id, url: null, src: null, started: false };
    current = mine;
    onChange(id);
    try {
      if (app) {
        const bytes = wavBytes(await invoke("reply_clip", { id }));
        if (current !== mine) return null; // another press came first
        if (!bytes) throw new Error("the clip is not a WAV file.");
        mine.url = objectUrl(new Blob([bytes], { type: "audio/wav" }));
        audio.src = mine.url;
      } else {
        // No await before play(): it must run inside the press.
        audio.src = clipUrl(id, at);
      }
      mine.src = audio.src;
      await audio.play();
      mine.started = true;
      return null;
    } catch (err) {
      if (current !== mine) return null;
      finish();
      return `Could not play the reply: ${err?.message ?? err}`;
    }
  }

  return {
    toggle,
    playing: (id) => current?.id === id,
    /** Stop whatever plays when its card is gone from `ids`. */
    keep(ids) {
      if (current && !ids.has(current.id)) finish();
    },
  };
}
