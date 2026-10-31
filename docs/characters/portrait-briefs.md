<!-- budget: 1300 words -->
# Five new kourai portraits: generation briefs

**Done.** The art exists as `assets/portraits/{chronos,argos,hermes,elpis,hesychia}.jpg`
(1024 px), `scripts/cut-portraits.py` cuts the faces, and `src/fleet/themes/kourai.json` holds all
sixteen characters. Hermes's accent is the burnt orange `#E07B39`, not the
`#E69F00` below, which is the needs-you amber. The briefs are kept as the record.

These five characters give the four keryx pool voices that had no portrait,
and keryx's specialty voice `af_nicole`, a face of their own. Each brief is one shared style block plus one character
block. Paste both into the image generator, attach the reference portraits
listed under each character, and iterate the way you did for the first ten.

## How many characters

Fifteen: one per voice in keryx's rotation pool (fourteen), plus Hesychia. The ten
kourai characters cover the first ten voices; these four cover the rest. Hesychia
is for `af_nicole`, which keryx hands out after the pool voices and before any
blend (keryx 0.9.3). Sessions past the fifteenth get blended voices and show a
medallion. A sixteenth, Athena (`bf_alice`, outside keryx's pool), is the
orchestrator's second face (#222): only the orchestrator wears her or Hephaestus.

## Reference portraits

The originals are in `kourai-khryseai/assets/avatars/vn/<name>_neutral.png`.
Always attach Hephaestus first: his off-centre, shoulder-in framing is the
crop the wall uses. Then add the two portraits listed for the character.

**Deliverable per character:** a 640×640 neutral portrait on a plain
background, like `assets/avatars/vn/<name>_neutral.png`, and a transparent
version if the generator can make one. I crop the head to the fleet's 96 and
192 px faces with `scripts/cut-portraits.py`. Hephaestus's "peeking"
shoulder comes from that crop, so ask for the figure to stand slightly right
of centre with one shoulder turned toward the viewer, and I can crop each
one the same way.

## Shared style block

> Painterly, semi-realistic character portrait. Digital painting with
> confident thick brushwork, bold clean silhouette, expressive face, and
> dramatic warm rim lighting. Ancient Greek myth recast as a divine
> forge-atelier: the character is an artisan or servant of a craft, not a
> warrior. Square 640×640 bust portrait, mid-torso up, three-quarter turn,
> the figure slightly right of centre with the near shoulder toward the
> viewer. The head sits in the upper middle of the frame. Plain deep
> charcoal background (#1A1A1A) with a soft gold glow behind the shoulders.
> Palette: honeyed gold (#C9944A), warm cream highlights (#F1D2A1), bronze,
> and the character's accent colour as the one cool or bright note. Match
> the rendering, lighting, framing and level of detail of the attached
> reference portraits exactly.

**Negative prompt (every brief):**

> anime, large eyes, chibi, pastel colour wash, photorealistic, 3D render,
> CGI, grimdark, blood, gore, armour, weapons, battle, text, watermark,
> logo, signature, border, frame, multiple characters, cropped head, full
> body, busy background.

## Chronos, Keeper of the Hours

- **Upload with the prompt:** `hephaestus_neutral.png` (a bearded, weathered man in warm rim light), `mneme_neutral.png` (scholarly, warm, holding objects), `metis_neutral.png` (composed gold palette)
- **Voice:** `bm_george` (British, mature male)
- **Accent:** Okabe-Ito yellow `#F0E442`
- **Role:** the klepsydra's own god, the patient keeper of every session's time.
- **Character block:**

> An elderly but vigorous man with a thick silver-grey beard, deep-set calm
> eyes, and a faint knowing smile. He wears a bronze-and-cream chiton with a
> heavy himation, pinned by a small bronze sundial brooch. In both hands he
> cradles a bronze klepsydra, an ancient two-vessel water clock, with a thin
> stream of glowing pale-gold water falling between the vessels. Behind his
> shoulders, a faint ring of zodiac signs in gold leaf, like a Greco-Roman
> mosaic of time turning the zodiac wheel. Accent glints in soft yellow
> (#F0E442) in the water and the zodiac ring. Patient, dry, unhurried.

- **Avoid:** scythe, hourglass, skeletal "Father Time". Those are
  Renaissance additions; Greco-Roman art showed him turning the zodiac
  wheel.

## Argos, the Hundred-Eyed Watch

- **Upload with the prompt:** `hephaestus_neutral.png` (broad male build), `dokimasia_neutral.png` (the guardian bearing), `puck_neutral.png` (male face rendering)
- **Voice:** `am_fenrir` (deep American male)
- **Accent:** Okabe-Ito reddish purple `#CC79A7`
- **Role:** the watchman who never sleeps. He watches the fleet.
- **Character block:**

> A tall, broad, calm watchman with close-cropped dark hair and a short
> beard, steady attentive eyes, and a quiet half smile. Small gilded eye
> motifs are inlaid like gold tattoos in rows across his shoulders and
> forearms, after the rows of eyes in Greek vase painting. They are
> ornamental gold patterns, never real eyes. Over a simple leather artisan's
> jerkin he wears a mantle of peacock feathers in iridescent reddish purple
> (#CC79A7) and teal, Hera's tribute to him. He holds a bronze lantern low
> at his side. Vigilant, steady, says little, notices everything.

- **Avoid:** body horror, real eyeballs, armour or spear.

## Hermes, Herald of the Gods

- **Upload with the prompt:** `hephaestus_neutral.png` (framing), `puck_neutral.png` (youthful, quick, sly), `techne_neutral.png` (confident pose, a tool held at shoulder height)
- **Voice:** `bm_fable` (British male storyteller)
- **Accent:** Okabe-Ito orange `#E69F00`
- **Role:** the messenger between sessions, and kin to keryx: the herald's
  staff is the *kerykeion*.
- **Character block:**

> A lean, youthful man with tousled bronze curls and a quick, sly smile,
> caught mid-turn as if about to speak. He wears a wide-brimmed petasos
> traveller's hat with small white wings at its sides, and a short chlamys
> cloak pinned at one shoulder and lifting with motion. He holds a golden
> kerykeion at shoulder height: a herald's staff with two entwined snakes and
> a pair of small wings at its top. Orange accent (#E69F00) in the cloak's
> edge and the light catching the staff. Quick, witty, warm.

- **Avoid:** a modern caduceus medical symbol on its own, or a sports-logo
  look.

## Elpis, Hope That Stayed

- **Upload with the prompt:** `hephaestus_neutral.png` (framing), `kallos_neutral.png` (elegant drape, soft glow), `aletheia_neutral.png` (serene, gentle)
- **Voice:** `af_alloy` (American female)
- **Accent:** kourai cream-gold `#F1D2A1`
- **Role:** the spirit that stayed in Pandora's jar after the others escaped.
  She is the steady encouragement when a long run stalls.
- **Character block:**

> A young woman with soft dark hair loosely bound, small white flowers woven
> through it, and a gentle, confident smile. She wears a cream-and-gold
> peplos. In one arm she holds a bronze pithos, a tall Greek storage jar,
> tilted open, with a soft golden light rising from inside it. A few white
> flowers rest in the crook of her other arm. Warm cream-gold glow (#F1D2A1)
> around her. Warm, steady, quietly bright.

- **Avoid:** a box (the jar is a pithos), sadness, a halo.

## Hesychia, Keeper of Quiet

- **Upload with the prompt:** `hephaestus_neutral.png` (framing), `aletheia_neutral.png` (serene), `kallos_neutral.png` (soft glow)
- **Voice:** `af_nicole` (soft, near-whisper; keryx hands it out fifteenth, after the pool)
- **Accent:** moonlit silver-blue `#A9B8D0`
- **Role:** the spirit of stillness and rest. In Pindar (Pythian 8) she is Dike's daughter and holds the keys of counsel and war.
- **Character block:**

> A woman of quiet, settled calm, with dark hair loosely bound low at the nape, eyes half-lowered, and a faint, closed-lipped smile, as if she has just heard a room fall silent. She wears a deep night-blue peplos edged in pale silver, with a fine silver-and-gold clasp at one shoulder. In one hand she holds a ring of two old golden keys on a dark cord, resting against her palm (the keys of counsel and war). Cool moonlit rim light on one side meets the warm gold glow behind her shoulders. Silver-blue accent (#A9B8D0) in the fabric's edge and the light on the keys. Still, attentive, unhurried.

- **Avoid:** a finger to the lips ("shh"), sleepiness, a halo, dark or gloomy styling.

## Athena, Strategist of the Forge

- **Upload with the prompt:** `hephaestus_neutral.png` (framing), `metis_neutral.png`, `mneme_neutral.png` (the golden automaton maidens set the look)
- **Voice:** `bf_alice` (outside keryx's pool, so no worker collides with her; `bf_lily` was the other candidate, both Kokoro grade D)
- **Accent:** olive `#7A8B3C` (the olive tree she gave Athens)
- **Role:** the orchestrator's other face: she and Hephaestus take turns as the orchestrator rotates (#157).
- **Original:** kourai-khryseai `assets/avatars/originals/athena.png` (1254 px, chosen 2026-10-30); `assets/portraits/athena.jpg` is it at 1024 px.
- **Character block:**

> A strikingly beautiful goddess-automaton in her late twenties, one of Hephaestus's golden maidens: smooth burnished-gold skin with fine filigree seams at the jaw, collarbone and wrists, and elegant mechanical joints at the elbows and fingers, like the attached Metis and Mneme. Sharp luminous grey eyes with a smouldering, direct gaze at the viewer, a sly confident half-smile, one brow faintly raised, head tilted slightly. High sculpted cheekbones. Long glossy black hair, half up under a slim gold olive-leaf circlet, the rest falling in loose waves over the near shoulder. A fitted one-shoulder peplos of deep olive (#7A8B3C) silk with gold meander trim, baring the near shoulder and collarbone, a gold cuff on the upper arm, and a cream himation draped low across the back. Athena is the goddess of weaving and strategy: from the fingertips of her raised hand run fine glowing olive threads that weave between three small floating translucent panels, star charts of the forge's plan, like Metis's floating blueprints. A small silver owl perches on a gold perch-ring at her far shoulder. Graceful, poised, in command, a little dangerous.

- **Avoid:** matronly, severe, stern, older, plain human skin, stiff pose, large flat tablet or board, helmet, spear, shield, aegis, armour, battle pose, nudity.

## Sources

- Chronos and Aion iconography: en.wikipedia.org/wiki/Chronos, en.wikipedia.org/wiki/Aion_(deity)
- Argos Panoptes, eyes in vase painting, Hera's peacock: theoi.com/Gigante/GiganteArgosPanoptes.html
- Hermes's kerykeion, petasos and talaria: web.uvic.ca/lancenrd/classical_myth/gods/hermes_i.html
- Elpis and Pandora's jar: theoi.com/Daimon/Elpis.html
- Hesychia: theoi.com/Daimon/Hesykhia.html (Pindar, Pythian 8)
- Kourai style: deleted `docs/art-direction.md` (`git show 0fe8f44a^:docs/art-direction.md`) and `assets/setting/setting-concepts.md`
