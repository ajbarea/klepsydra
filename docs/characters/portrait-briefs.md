<!-- budget: 2600 words -->
# Portrait briefs: paste-ready kits

One kit per character painted for this app, for ChatGPT or Gemini: attach
the files in section 1, then paste sections 2, 3 and 4 as one message. Each
kit starts from the current portrait, so a redraw keeps the face. The other
ten characters come from kourai-khryseai, whose
`assets/avatars/originals/portrait-prompts.md` keeps every prompt verbatim.

## Cast canon

Adopted by AJ on 2026-11-01. Who a character is decides how they are drawn.

| Group | Characters | Drawn as |
|---|---|---|
| The gods who run the forge | Hephaestus, Athena | in flesh |
| The golden maidens, forged by Hephaestus | Techne, Metis, Mneme, Kallos, Dokimasia, Aidos | in gold or metal |
| Visitors to the forge | Hermes, Chronos, Argos, Elpis, Hesychia, Aletheia, Cupid, Puck | as themselves |

All share one rendering. A golden maiden attached as a reference lends
only her rendering and background, and the paste says so. Athena's
2026-10-30 portrait shows her in gold; her kit follows the canon.

## How the kits are built

- **Each attached image gets a role** in the paste; upload order alone
  does not tell the model which image is the face and which the style.
- **Each kit says what not to attach.** Elpis and Hesychia shared three
  references and came out with one face.
- **Re-attach the approved portrait** each round; feeding back the latest
  output drifts.
- **Hephaestus is the framing reference**: off centre, near shoulder toward
  the viewer, which the wall's crops assume.
- **Deliverable:** a square image, 1024 px or larger (the generators give
  1254 or 2048), and a transparent version if the generator makes one.
- **After AJ picks one:** the original and its prompt go to kourai-khryseai
  `assets/avatars/originals/`, the portrait it replaces stays there as
  `<name>-<date>`, and the crops go to the app.

Files to attach are in kourai-khryseai: `assets/avatars/vn/<name>_neutral.png`
and `assets/avatars/originals/<name>.jpg` (Athena's is a `.png`).

## Chronos, Keeper of the Hours (visitor)

Voice `bm_george` · accent Okabe-Ito yellow `#F0E442` · the klepsydra's own
god, keeper of every session's time.

### 1. Attach

- `chronos.jpg`, his current portrait: keep his face.
- `hephaestus_neutral.png`: framing only.
- `metis_neutral.png`: rendering and background only.
- Do not attach: Hephaestus's or Argos's portrait as a face reference (two
  more bearded men pull the faces together).

### 2. Paste: style block

> Image 1 is Chronos: keep his face, hair and beard exactly. Image 2
> (Hephaestus at his anvil) is for framing only, not his face. Image 3 (a
> golden maiden) is for rendering and background only, not her gold skin.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> ink-like outlines, bold clean silhouette, expressive face, soft rim
> light. Square bust portrait, mid-torso up, three-quarter turn, the figure
> slightly right of centre with the near shoulder toward the viewer, the
> head in the upper middle. Plain warm mid-grey background with soft
> visible brush texture, no glow behind the figure, nothing in the
> background. Natural skin: he visits the forge and is not one of its
> golden maidens.

### 3. Paste: character block

> An elderly but vigorous man with thick silver hair, a full silver beard,
> deep-set calm eyes and a faint knowing smile. He wears a cream chiton with
> a heavy ochre-bronze himation over one shoulder, pinned with a round
> bronze brooch. He holds a pewter hourglass upright in both hands, its sand
> glowing a pale gold (#F0E442). Patient, dry, unhurried.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, armour, weapons, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background, gold halo or glow behind the figure, gold skin,
> nudity, scythe, skeletal Father Time, zodiac ring

### 5. Tips

- If his face drifts, paste: "Keep the face from Image 1 exactly; change
  nothing else."

### 6. When you have one

Save it to `Downloads\chronos\` and tell Heph.

## Argos, the Hundred-Eyed Watch (visitor)

Voice `am_fenrir` · accent Okabe-Ito reddish purple `#CC79A7` · the
watchman who never sleeps; he watches the fleet.

### 1. Attach

- `argos.jpg`, his current portrait: keep his face.
- `hephaestus_neutral.png`: framing only.
- `puck_neutral.png`: rendering and background only.
- Do not attach: Chronos as a face reference, or the 2026-10-20 Argos (he
  read as a second Hephaestus).

### 2. Paste: style block

> Image 1 is Argos: keep his face, hair and beard exactly. Image 2
> (Hephaestus at his anvil) is for framing only, not his face. Image 3 is
> for rendering and background only.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> ink-like outlines, bold clean silhouette, expressive face, soft rim
> light. Square bust portrait, mid-torso up, three-quarter turn, the figure
> slightly right of centre with the near shoulder toward the viewer, the
> head in the upper middle. Plain warm mid-grey background with soft
> visible brush texture, no glow behind the figure, nothing in the
> background. Natural skin: he visits the forge and is not one of its
> golden maidens.

### 3. Paste: character block

> A lean, watchful man in his early thirties with short dark hair, a
> trimmed dark beard and steady attentive eyes. He wears a sleeveless brown
> leather jerkin with a strap across the chest, bare muscular arms, and over
> his far shoulder a mantle of peacock feathers in iridescent reddish
> purple (#CC79A7) and teal, Hera's tribute to him. He holds a bronze
> lantern low at his side, lit warm. Vigilant, steady, says little, notices
> everything.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, armour, weapons, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background, gold halo or glow behind the figure, gold skin,
> nudity, body horror, real eyeballs, spear

### 5. Tips

- If he ages or bulks up, paste: "Leaner and younger, like Image 1; he must
  not read as Hephaestus."
- For the hundred eyes, ask for small gold eye motifs woven into the
  feather mantle, never on the skin.

### 6. When you have one

Save it to `Downloads\argos\` and tell Heph.

## Hermes, Herald of the Gods (visitor)

Voice `bm_fable` · accent burnt orange `#E07B39` (never the needs-you amber
`#E69F00`) · the messenger between sessions, and kin to keryx: the herald's
staff is the *kerykeion*.

### 1. Attach

- `hermes.jpg`, his current portrait: keep his face.
- `hephaestus_neutral.png`: framing only.
- `techne_neutral.png`: rendering and background only.
- Do not attach: Puck as a face reference (two sly young men merge).

### 2. Paste: style block

> Image 1 is Hermes: keep his face, curls and grin exactly. Image 2
> (Hephaestus at his anvil) is for framing only, not his face. Image 3 (a
> golden maiden) is for rendering and background only, not her gold skin.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> ink-like outlines, bold clean silhouette, expressive face, soft rim
> light. Square bust portrait, mid-torso up, three-quarter turn, the figure
> slightly right of centre with the near shoulder toward the viewer, the
> head in the upper middle. Plain warm mid-grey background with soft
> visible brush texture, no glow behind the figure, nothing in the
> background. Natural skin: he visits the forge and is not one of its
> golden maidens.

### 3. Paste: character block

> A lean, youthful man with tousled bronze curls and a quick, sly smile,
> caught as if about to speak. He wears a wide-brimmed brown petasos with
> small white wings at its sides, a brown tunic, a cream cowl, and a short
> travelling cloak edged in burnt orange (#E07B39) that lifts with motion.
> He holds a golden kerykeion upright at his side: a herald's staff with two
> entwined snakes and a pair of small wings at its top. Quick, witty, warm.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, armour, weapons, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background, gold halo or glow behind the figure, gold skin,
> nudity, medical caduceus logo, sports-logo look

### 5. Tips

- If the hat's wings get cut off, paste: "Leave room above the hat; the
  wings stay in frame."

### 6. When you have one

Save it to `Downloads\hermes\` and tell Heph.

## Elpis, Hope That Stayed (visitor)

Voice `af_alloy` · accent kourai cream-gold `#F1D2A1` · the spirit that
stayed in Pandora's jar; the steady encouragement when a long run stalls.

### 1. Attach

- `elpis.jpg`, her current portrait: keep her face.
- `hephaestus_neutral.png`: framing only.
- `kallos_neutral.png`: rendering and background only.
- Do not attach: Hesychia, old or new, or Aletheia (the 2026-10-20 Elpis and
  Hesychia shared one face through these).

### 2. Paste: style block

> Image 1 is Elpis: keep her face, hair and smile exactly. Image 2
> (Hephaestus at his anvil) is for framing only, not his face. Image 3 (a
> golden maiden) is for rendering and background only, not her gold skin.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> ink-like outlines, bold clean silhouette, expressive face, soft rim
> light. Square bust portrait, mid-torso up, three-quarter turn, the figure
> slightly right of centre with the near shoulder toward the viewer, the
> head in the upper middle. Plain warm mid-grey background with soft
> visible brush texture, no glow behind the figure, nothing in the
> background. Natural skin: she visits the forge and is not one of its
> golden maidens.

### 3. Paste: character block

> A young woman with dark hair gathered up, small white flowers and a blue
> ribbon woven through it, and a gentle, confident smile. She wears a
> cream-and-gold peplos with a meander border and a blue sash. In one arm
> she holds a bronze pithos, a tall Greek storage jar, tilted open, with
> soft cream-gold (#F1D2A1) motes rising from inside it. White flowers rest
> in the crook of her other arm. Warm, steady, quietly bright.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, armour, weapons, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background, gold halo or glow behind the figure, gold skin,
> nudity, a box, sadness, a halo

### 5. Tips

- The jar is a pithos; if a box appears, paste: "A tall clay-and-bronze jar,
  not a box."

### 6. When you have one

Save it to `Downloads\elpis\` and tell Heph.

## Hesychia, Keeper of Quiet (visitor)

Voice `af_nicole` (keryx hands it out fifteenth, after the pool) · accent
moonlit silver-blue `#A9B8D0` · the spirit of stillness and rest; in Pindar
(Pythian 8) she is Dike's daughter and holds the keys of counsel and war.

### 1. Attach

- `hesychia.jpg`, her current portrait: keep her face.
- `hephaestus_neutral.png`: framing only.
- Do not attach: Elpis, Aletheia, Kallos or the 2026-10-20 Hesychia. Her old
  portrait copied their face.

### 2. Paste: style block

> Image 1 is Hesychia: keep her face, hair and veil exactly. Image 2
> (Hephaestus at his anvil) is for framing only, not his face.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> bold clean silhouette, expressive face. Square bust portrait, mid-torso
> up, three-quarter turn, the figure slightly right of centre with the near
> shoulder toward the viewer, the head in the upper middle. Plain deep
> charcoal background (#1A1A1A). Cool moonlight from the upper left is the
> main light; only a faint warm glow sits low behind the shoulders. Palette:
> moonlit silver-blue (#A9B8D0), night blue and pale silver, with small
> touches of honeyed gold (#C9944A).

### 3. Paste: character block

> A woman in her thirties with a long, calm face, a straight nose, level
> dark brows and dark hair worn up. She wears a silver-blue silk night
> chiton in a slip style, with thin straps and bare shoulders and arms, the
> silk catching the moonlight. A pale gauze veil has slipped back off her
> hair and drapes loosely from one shoulder. Her gaze is half-lidded and
> knowing, with a slow, faint smile. One hand rests at her collarbone,
> holding a ring of two old golden keys on a dark cord. Languid, elegant,
> unhurried.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, armour, weapons, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background, nudity, see-through fabric, explicit pose, a
> finger to the lips, flowers, a jar, loose hair framing the face, a halo

### 5. Tips

- If a generator refuses, drop "bare shoulders" first, then "slip style".
- Her three Gemini rounds are in kourai-khryseai's `portrait-prompts.md`.

### 6. When you have one

Save it to `Downloads\hesychia\` and tell Heph.

## Athena, Strategist of the Forge (god of the forge)

Voice `bf_alice` (outside keryx's pool, so no worker shares it) · accent
olive `#7A8B3C` (the olive tree she gave Athens) · the orchestrator's second
face: she and Hephaestus run the fleet in turn (#222).

### 1. Attach

- `athena.png`, her 2026-10-30 portrait: keep her face, hair, circlet,
  peplos and owl, not her gold skin.
- `hephaestus_neutral.png`: framing, and the other god of the forge in
  flesh. Not his face.
- Do not attach: Metis or Mneme. They made her a golden maiden.

### 2. Paste: style block

> Image 1 is Athena: keep her face, hair, olive-leaf circlet, peplos and
> owl exactly, and change her skin to natural skin. Image 2 is Hephaestus,
> the other god who runs the forge: match his rendering and framing, not
> his face.
> Painterly, semi-realistic character portrait: confident thick brushwork,
> ink-like outlines, bold clean silhouette, expressive face, soft rim
> light. Square bust portrait, mid-torso up, three-quarter turn, the figure
> slightly right of centre with the near shoulder toward the viewer, the
> head in the upper middle. Plain dark charcoal-grey background with soft
> visible brush texture, like Image 2. She is a goddess in flesh, not one
> of the golden maidens: natural skin, no metal seams or joints.

### 3. Paste: character block

> A strikingly beautiful goddess in her late twenties with sharp luminous
> grey eyes, a direct gaze at the viewer, a sly confident half-smile, one
> brow faintly raised and her head tilted slightly. High cheekbones. Long
> glossy black hair, half up under a slim gold olive-leaf circlet, the rest
> falling in loose waves over the near shoulder. A fitted one-shoulder
> peplos of deep olive (#7A8B3C) silk with gold meander trim, a gold cuff on
> the upper arm, and a cream himation draped low across the back. From the
> fingertips of her raised hand run fine glowing olive threads that weave
> between three small floating translucent star charts, the forge's plan. A
> small silver owl perches on her far shoulder. Graceful, poised, in
> command, a little dangerous.

### 4. Paste: negative prompt

> anime, large eyes, chibi, pastel colour wash, photorealistic, real person
> likeness, 3D render, CGI, grimdark, text, watermark, logo, signature,
> border, frame, multiple characters, cropped head, full body, busy
> background, gold halo or glow behind the figure, nudity, gold skin, metal
> seams, mechanical joints, matronly, stern, helmet, spear, shield, aegis,
> armour, battle pose, large flat tablet

### 5. Tips

- If gold creeps back into her skin, paste: "Natural skin everywhere; gold
  only in the circlet, cuff and trim."

### 6. When you have one

Save it to `Downloads\athena\` and tell Heph.

## Sources

- Reference roles: [fal, GPT Image 2 prompting guide](https://fal.ai/learn/tools/prompting-gpt-image-2) (label each input by role); [RunDiffusion, multi-image prompt guide](https://www.rundiffusion.com/multi-image-prompt-guide) (describe each image, upload order is not enough); [Aktagon, consistent imagery with Gemini](https://signals.aktagon.com/articles/2026/03/generating-consistent-imagery-with-gemini-a-practical-guide-to-building-a-prompt-based-generation-pipeline/) (reuse the original references; name fixed traits).
- Chronos and Aion iconography: en.wikipedia.org/wiki/Chronos, en.wikipedia.org/wiki/Aion_(deity)
- Argos Panoptes, eyes in vase painting, Hera's peacock: theoi.com/Gigante/GiganteArgosPanoptes.html
- Hermes's kerykeion, petasos and talaria: web.uvic.ca/lancenrd/classical_myth/gods/hermes_i.html
- Elpis and Pandora's jar: theoi.com/Daimon/Elpis.html
- Hesychia: theoi.com/Daimon/Hesykhia.html (Pindar, Pythian 8)
- The golden maidens (kourai khryseai) Hephaestus forged: Homer, *Iliad* 18.417-420
