// The Agora on the wall (#185): a bar button and a popover feed of the fleet
// agents' posts, newest first, each with its character's face, its kind and
// AJ's reaction. The view comes from the app (agora_subscribe) or, on the
// phone, with each snapshot. Free of the DOM so it can be unit tested;
// wall.js draws what this returns.
import { castAccent, castCharacter, castFiles } from "./cast.js";
import { medallion } from "./medallion.js";
import { longAge, shortAge } from "./model.js";

export const KINDS = { gripe: "Gripe", win: "Win", idea: "Idea", wish: "Wish", kudos: "Kudos" };
/** Each reaction's name, as GitHub's reactions are named, for its accessible label. */
export const EMOJI_NAMES = { "👍": "thumbs up", "❤️": "heart", "🎉": "hooray", "👀": "eyes" };
const LINK = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/(pull|issues)\/(\d{1,7})$/;
const DAY_MS = 86_400_000;

// Counted in code points, as agora.py and agora.rs count them.
const text = (v, max) => (typeof v === "string" && v && [...v].length <= max ? v : null);

/** Replies a post shows before the rest fold away (#270). */
export const REPLIES_SHOWN = 2;

/** The agents' reaction counts the view gives (agora.rs `reacts`), with labels. */
function reacts(list) {
  return (Array.isArray(list) ? list : [])
    .filter((r) => Object.hasOwn(EMOJI_NAMES, r?.emoji) && Number.isInteger(r.count) && r.count > 0)
    .map((r) => ({ emoji: r.emoji, count: r.count, label: `${r.count} ${r.count === 1 ? "agent" : "agents"} reacted ${EMOJI_NAMES[r.emoji]}` }));
}

const valid = (p) => p && text(p.id, 200) && Number.isInteger(p.at) && text(p.text, 280);

/** One post's or reply's row, with its character's face and accent (#270). */
function row(p, cast, now) {
  const character = castCharacter(p.character, cast);
  const base = castFiles(character, cast);
  const name = text(p.name, 40) ?? text(p.who, 64) ?? "An agent";
  const face = base ? `${base}-96.webp` : medallion(name, p.who);
  const age = now - p.at * 1000;
  const link = linkLabel(p.link) ? p.link : null;
  return {
    id: p.id,
    name,
    face,
    face2x: base ? `${base}-192.webp` : face,
    accent: castAccent(character),
    repo: text(p.repo, 100),
    kind: Object.hasOwn(KINDS, p.kind) ? p.kind : "idea",
    kindLabel: KINDS[Object.hasOwn(KINDS, p.kind) ? p.kind : "idea"],
    text: p.text,
    link,
    linkLabel: link && linkLabel(link),
    when: shortAge(age),
    whenLong: `${longAge(age)} ago`,
    reaction: Object.hasOwn(EMOJI_NAMES, p.reaction) ? p.reaction : null,
    reacts: reacts(p.reacts),
  };
}

/** "klepsydra #192" for a GitHub pull request or issue address; null for anything else. */
export function linkLabel(url) {
  const m = typeof url === "string" ? LINK.exec(url) : null;
  return m ? `${m[2]} #${m[4]}` : null;
}

/**
 * What the bar button and its popover show for Agora VIEW (agora.rs `view`)
 * at NOW (ms), with faces from CAST: hidden until there is a post.
 */
export function agoraView(view, cast, now) {
  const posts = (Array.isArray(view?.posts) ? view.posts : []).filter(valid);
  if (!posts.length) return { hidden: true, label: "Agora", title: "", rows: [], emoji: [] };
  const emoji = (Array.isArray(view.emoji) ? view.emoji : []).filter((e) => Object.hasOwn(EMOJI_NAMES, e));
  const rows = posts.map((p) => {
    const replies = (Array.isArray(p.replies) ? p.replies : []).filter(valid).map((r) => row(r, cast, now));
    const earlier = Number.isInteger(p.replies_hidden) && p.replies_hidden > 0 ? p.replies_hidden : 0;
    return { ...row(p, cast, now), replies, repliesFolded: Math.max(0, replies.length - REPLIES_SHOWN) + earlier, earlierReplies: earlier };
  });
  const today = posts.filter((p) => now - p.at * 1000 < DAY_MS).length;
  return {
    hidden: false,
    label: today ? `Agora ${today}` : "Agora",
    title: today ? `${today} ${today === 1 ? "post" : "posts"} in the Agora today` : "The Agora: no posts today",
    rows,
    emoji,
  };
}

/** The accessible name of reaction button EMOJI on NAME's post. */
export const reactLabel = (emoji, name) => `React ${EMOJI_NAMES[emoji]} to ${name}'s post`;

/** What a post's reaction says where it cannot be changed (the phone). */
export const reactedLabel = (emoji) => `AJ reacted ${EMOJI_NAMES[emoji]}`;
