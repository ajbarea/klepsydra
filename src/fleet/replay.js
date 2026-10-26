// Playing a session's latest spoken reply from its card (keryx's reply clips,
// keryx docs/reply-clips.md). One clip plays at a time, on this device: the
// app reads it through reply_clip, the phone from its server's /audio/<id>.

/** The phone server's address for session `id`'s clip, `at` (its reply_at) keeping a newer clip from an older copy. */
export const clipUrl = (id, at) => `/audio/${encodeURIComponent(id)}?at=${encodeURIComponent(String(at))}`;

/**
 * A player for `audio` (an HTMLAudioElement). `app`: read clips with
 * `invoke("reply_clip", {id})`; else from `clipUrl`. `onChange(id)` runs
 * whenever `id` starts or stops playing, so its card can repaint.
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

  /** Play `id`'s clip, or stop it when it is the one playing. Resolves to a note for its card, or null. */
  async function toggle(id, at) {
    if (current?.id === id) {
      finish();
      return null;
    }
    finish();
    const mine = { id, url: null };
    current = mine;
    onChange(id);
    try {
      if (app) {
        const bytes = await invoke("reply_clip", { id });
        if (current !== mine) return null; // another press came first
        mine.url = objectUrl(new Blob([bytes], { type: "audio/wav" }));
        audio.src = mine.url;
      } else {
        audio.src = clipUrl(id, at);
      }
      await audio.play();
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
