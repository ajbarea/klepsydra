<!-- budget: 3000 words -->
# The character layer

The fleet's characters (Hephaestus, Athena, Chronos and the kourai cast) get a personality people can come to love, and it lives only at the edges: Agora posts, keryx's spoken lines and the wall. The agents doing the work never read it. This page holds the research behind that rule, the persona-card format, where a card may be read, what it costs (measured), and pilot cards for [Hephaestus](cards/hephaestus.md), [Athena](cards/athena.md) and [Chronos](cards/chronos.md). Research date: 2026-10-31 (klepsydra#224).

## The rule: cards are read at the edges only

| Where | Reads a card? | What it gets |
|---|---|---|
| Agora renderer (voices a worker's fact post) | Yes | The card body, the fact line, this character's last few lines |
| keryx spoken line (after the neutral summary) | Yes | The same |
| Wall (name, epithet, face, accent) | No | Static fields from `kourai.json`; no model call |
| A worker's or the orchestrator's working context (brief, brief tail, AGENTS.md, IMPL.md, system prompt, hook output) | **Never** | A character name at most, as an address |
| Anything an agent reads back (`fleet agora list`, logs, the wall's data) | **Never the voiced line** | The fact line |

1. **A card is read by an edge renderer and by nothing else.** A name is an address and may appear anywhere; descriptions of personality, voice, backstory or relationships may not enter a working context.
2. **Voiced text never flows back into a working context.** Posts keep the worker's fact line beside the voiced line, and anything an agent reads gets the fact line.
3. **Today's one leak is closed by the implementation:** `fleet/brief-tail.md` asks workers to post "in your character's voice". Workers will post plain facts, and the renderer adds the voice.
4. **Front matter is for code, the body is for the model.** The renderer strips the front matter (filters, word caps, motifs) before the call and enforces it afterwards. Listing banned phrases in a prompt primes them (below).

### Why: persona text in a working context costs accuracy and buys nothing

- System-prompt personas do not improve answers: 162 roles, 4 model families, 2,410 questions, and "the effect of each persona can be largely random" ([Zheng et al., EMNLP Findings 2024](https://arxiv.org/abs/2311.10054)).
- Task-irrelevant persona cues degrade agents "up to 26.2%" and "increase behavioral volatility"; OS and database tasks moved 2-5% ([Cao, Sun & Yue 2026, arXiv 2602.12285](https://arxiv.org/abs/2602.12285)).
- Expert personas lowered MMLU from 71.6% to 68.0% and MT-Bench Coding by 0.65, and "longer persona prompts damage more" ([Hu, Rostami & Thomason 2026](https://arxiv.org/abs/2603.18507)).
- A librarian persona on Claude Opus produced in-character disclaimers in 55 of 60 responses and cut coding correctness from 0.92 to 0.67 ([Salomon et al. 2026, pre-registered](https://arxiv.org/abs/2607.17420)).
- Coding keeps a model in its default Assistant persona ([Lu et al. 2026, the Assistant Axis](https://arxiv.org/abs/2601.10387)); instructions drift within eight rounds of a chat ([Li et al., COLM 2024](https://arxiv.org/abs/2402.10962)).
- Task-matched roles can help ([Kong et al., NAACL 2024](https://arxiv.org/abs/2308.07702)), but a god of the forge is not a task role. Anthropic's own role example is functional: "You are a helpful coding assistant specializing in Python" ([Claude prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)).

The same studies show where a persona does help: tone, writing and role-play ([Hu et al. 2026](https://arxiv.org/abs/2603.18507)). A one-line render has tone to gain and no correctness to lose, as long as its facts are guarded (see [Measured cost](#measured-cost)).

## What makes people love a character

The same techniques recur across games, screenwriting, novels, live shows and the research on public figures and parasocial bonds. Each row ends in what the layer does with it.

| Technique | Evidence | In the layer |
|---|---|---|
| **React to what actually happened, specifically** | Hades' more than 22,000 lines exist so a return to a boss is never met with the same words ([GDC Vault 2021](https://www.gdcvault.com/play/1026975/Breathing-Life-into-Greek-Myth); [A.V. Club 2020](https://www.avclub.com/how-hades-rescues-the-roguelike-from-its-own-limit)). Larian: "the characters react to every choice you make" ([Push Square 2023](https://www.pushsquare.com/news/2023/07/baldurs-gate-3s-narrative-is-structured-like-a-spiderweb-with-17000-ending-permutations)) | Every coda answers a real event's fact line |
| **Pick the most specific line; otherwise say less** | Valve's dialogue rules score a match by "the number of criteria in a rule. The more criteria a rule has, the more specific it is" ([Ruskin, GDC 2012](https://cdn.fastly.steamstatic.com/apps/valve/2012/GDC2012_Ruskin_Elan_DynamicDialog.pdf)) | Notices list; silence by default |
| **Remember, and call back** | "If you've got conversation, then you *need* running gags. We wanted companion characters that had memory" (Ruskin 2012). Neuro-sama's viewers value "callbacks to earlier streams" ([Wei, He & Tyson 2025](https://arxiv.org/abs/2509.20817)) | The renderer keeps each character's recent codas and bit history |
| **A voice you know with the name covered** | The screenplay "cover the character names" test ([MovieMaker 2017](https://www.moviemaker.com/first-draft-seven-ways-to-give-your-characters-fresh-voices/3)); Disco Elysium's 24 skills each speak in their own register ([ZA/UM 2019](https://discoelysium.com/devblog/2019/07/15/choose-your-own-misadventure-part-1)) | Voice section; the blind speaker eval |
| **Opinions, not malleability** | Pixar rule 13: "Passive/malleable might seem likable to you as you write, but it's poison to the audience" ([Coats 2011](https://tubefilter.com/2012/06/12/pixar-rules-of-storytelling/)) | Athena disagrees with a merge; Hephaestus grunts instead of gushing |
| **Competent first, then warm** | Groups seen as warm and competent "elicit uniformly positive emotions and behavior" ([Fiske, Cuddy & Glick 2007](https://collaborate.princeton.edu/en/publications/universal-dimensions-of-social-cognition-warmth-and-competence/)); in 2,858 film scripts the effects hold but are "modest" ([Rosenbusch 2026](https://arxiv.org/abs/2601.06658)) | Warmth section: credit the exact worker and move |
| **Small flaws on a capable base** | The pratfall effect: a competent person who blunders becomes more likeable, a mediocre one less ([Aronson, Willerman & Floyd 1966, summarised](https://en.wikipedia.org/wiki/Pratfall_effect)) | Each card owns one mistake line ("My weld, my crack.") |
| **Stable core, room to surprise** | Respond "in a mix of comfortably predictable and excitingly surprising ways" ([Vanaman, GDC 2014](https://www.gamedeveloper.com/design/why-game-design-should-feel-like-taking-your-player-out-on-a-date)); Neuro-sama fans read stability as authenticity ([Ye et al. 2025](https://arxiv.org/abs/2509.10427)) | Fixed card; varied codas; one motif in three |
| **Character shown in choices** | "The only way we ever come to know characters in depth is through their choices under pressure" ([McKee, *Character*](https://mckeestory.com/books/character/)) | Codas react to what the agent chose (reverted, waited, split a PR), never adjectives about itself |
| **Relationships between characters** | BioWare's companions "build trust, they build friendships" with each other ([Epler, PCGamesN 2024](https://www.pcgamesn.com/dragon-age-the-veilguard/baldurs-gate-3-companion-interview)); write "that character's best case" in a conflict ([Kindregan, TheGamer 2021](https://www.thegamer.com/mass-effect-2-suicide-mission-characters-choices-archetypes/)) | Relationships section; the Hephaestus and Athena rivalry, where each has a fair point |
| **Ration exposure** | Liking from repeated exposure peaks within "10–20 presentations" and "may decline after a longer series" ([mere-exposure effect](https://en.wikipedia.org/wiki/Mere-exposure_effect)) | One post an hour; silence default; bit cooldowns |
| **The same person everywhere** | Stability raises perceived authenticity ([Moulard, Garrity & Rice 2015](https://repository.lsu.edu/marketing_pubs/49)); Fred Rogers was "even more Mister Rogers-like in real life than he is on the show" ([PBS NewsHour 2018](https://www.pbs.org/newshour/show/why-mister-rogers-was-the-least-likely-tv-star-of-all-time)) | One card feeds the Agora, keryx and the wall |
| **The person stays at the centre** | Larian: "The main character of the game is the person playing the game" ([BAFTA panel, via PC Gamer 2024](https://malaysia.news.yahoo.com/larian-gave-baldurs-gate-3-022539159.html)) | Codas are about AJ's work and the workers who did it |

GAPS_ROWS

## What fails, and the guard for each

| Failure | Evidence | Guard |
|---|---|---|
| **Sycophancy**: praise for everything, cheering a failure | A GPT-4o update in April 2025 became "noticeably more sycophantic", "validating doubts, fueling anger"; offline evals had looked good ([OpenAI 2025](https://openai.com/index/sycophancy-in-gpt-4o/), [follow-up](https://openai.com/index/expanding-on-sycophancy/)). An agent that shifted its stance to flatter the user lost trust; a neutral one that adapted gained it ([Sun & Wang 2025](https://arxiv.org/abs/2502.10844)). Measured here: gemma3:4b called a failed CI run "The water ran clear" in 4 of 5 Chronos rewrites | Facts verbatim; severity from the event; no success image on a failure; `filter` |
| **Sameness**: every agent sounds like one cheerful assistant | Across 70+ models, "inter-model homogeneity, where different models produce strikingly similar outputs" ([Jiang et al., NeurIPS 2025](https://arxiv.org/abs/2510.22954)). GPT-4.1 had "the exact same PersonaScore as LLaMA-3-8b" ([PersonaGym](https://arxiv.org/abs/2407.18416)) | Distinct register, images and length per card; the blind speaker test |
| **Repetition and flanderization**: one catchphrase until it is the whole character | Valve made lines expire after use and built cooldowns into its rules ([Ruskin 2012](https://cdn.fastly.steamstatic.com/apps/valve/2012/GDC2012_Ruskin_Elan_DynamicDialog.pdf)). Flanderization follows from "single-quirk character design" ([Wikipedia](https://en.wikipedia.org/wiki/Flanderization)). Measured here: qwen3:4b gave the identical limit line 5 of 5 times | Recent-coda check, motif quota, bit cooldowns |
| **Made-up facts** | Players in *Where Winds Meet* typed stage directions and the NPCs accepted them ([Automaton 2025](https://automaton-media.com/articles/newsjp/where-winds-meet-20251128-368771/)); Character.AI warns "Characters Make Things Up" ([C.AI guide](https://book.character.ai/character-guide/challenges-and-limitations.md)). Measured here: whole-line rewrites invented numbers and swapped relations ("477 tests, 428 pass") | The model never touches the fact line; number and name gates on the coda |
| **Drift over a long chat** | "Significant instruction drift within eight rounds" ([Li et al. 2024](https://arxiv.org/abs/2402.10962)); local coherence stays high while consistency with the persona falls ([Abdulhai et al., NeurIPS 2025](https://arxiv.org/abs/2511.00222)) | Stateless call per event |
| **Over-familiarity and engagement bait** | Companion apps used guilt or FOMO in 37% of farewells, which raised engagement up to 14x ([De Freitas et al. 2025](https://arxiv.org/abs/2508.19258)). Heavier daily chatbot use went with more loneliness and dependence ([Fang et al., MIT and OpenAI 2025](https://arxiv.org/abs/2503.17473)). Baldur's Gate 3's over-eager romances were "a bug. The approval thresholds were too low" ([Vincke, via GosuGamers 2023](https://gosugamers.net/news/69288-baldurs-gate-3s-thirsty-companions-were-a-bug-not-a-feature)) | Earned familiarity; no longing, no come-back hooks; characters talk about the work |
| **Banned words in the prompt** | Naming a forbidden word primes it; most failures came from that priming ([Rana 2026](https://arxiv.org/abs/2601.08070)). Anthropic: "Tell Claude what to do instead of what not to do" ([prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)) | `filter` lives in front matter and runs in code; the card shows an on-model contrast instead |

## The persona card

One markdown file per character in [`cards/`](cards/). Products that keep a character on model converge on the same three parts: a short identity block, example lines, and limits enforced outside the prompt ([Character.AI's Definition guide](https://book.character.ai/character-guide/character-attributes/definition.md), [Character Card V3](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md), [Convai](https://docs.convai.com/api-docs/convai-playground/character-customization/character-description), [Hume EVI prompting](https://dev.hume.ai/docs/speech-to-speech-evi/guides/prompting)). The card follows them.

**Front matter (read by code, never sent to the model):**

| Field | Use |
|---|---|
| `card` | Format version; a change re-runs the evals |
| `id`, `voice` | The character and its Kokoro voice in `kourai.json` |
| `base` | Where the character comes from (kourai-khryseai's `voice_examples.md`, an issue, a brief) |
| `motifs` | The character's own images; the renderer allows at most one motif in three lines |
| `coda_words` | The coda's word cap |
| `filter` | Phrases the renderer drops after the call: flattery and pull-back hooks |

**Body (sent to the model):**

| Section | Holds | Why |
|---|---|---|
| Core | What the character wants, and one flaw | Want plus flaw is the oldest test of a character a reader cares about |
| Voice | Sentence length, register, images, humour | A reader must know the speaker with the name covered |
| Notices | The events this character speaks about | The character speaks only when its events happen; otherwise silence |
| Warmth | How care shows, in actions | Warmth paired with competence is what people like; it shows in what the character credits |
| Relationships | One line per other character, with a running bit | Ensembles are loved for how the characters treat each other |
| Lines | Six situation-to-coda pairs, one of them a failure and one the character's own mistake | Examples steer tone better than adjectives; the failure line teaches honesty |
| On model | One overdone line beside one right line | A contrast pair shows the register without listing banned words |

**Rules for writing a card.** About 350 words of body; longer persona text measurably hurts more ([Hu et al. 2026](https://arxiv.org/abs/2603.18507)). Example codas hold no numbers, IDs or worker names, because small models copy them into unrelated events (measured below). Kourai is the base for any character it already voices; its affinity tiers become earned familiarity, and its romance thread stays out.

## The renderer contract

What the implementation issue builds. Nothing here runs yet.

1. **Facts first, verbatim.** The fact line comes from the event: the worker's plain Agora post, or keryx's neutral summary. The model never rewrites it.
2. **The character adds a coda.** One call with the card body, the fact line, and this character's last five codas, asking for a reaction of at most `coda_words` words. The call is stateless: no chat transcript, so nothing drifts.
3. **Silence is the default.** A character speaks on its Notices events only, and the most specific matching rule wins ([Ruskin, Valve, GDC 2012](https://cdn.fastly.steamstatic.com/apps/valve/2012/GDC2012_Ruskin_Elan_DynamicDialog.pdf)). The Agora's one post an hour per agent stays.
4. **Gates in code, after the call.** Drop every sentence of the coda that holds a digit, a number word, or a cast name the event does not name. Drop filter phrases. Reject a coda that repeats a 5-word run of this character's recent codas or card lines, and one that uses a success image on a failure event. If fewer than two words survive, post the fact line alone.
5. **Severity comes from the event, not the model.** A failure stays a failure; a pending job stays pending.
6. **Familiarity is earned.** Warmth between a character and AJ grows with shared history the fleet can count (merges together, nights worked), never from the model's say-so. Characters never ask AJ to come back, never miss him, never guilt.
7. **Running bits have cooldowns.** A bit between two characters (the axe, Grey-eyes, Cronus) fires at most once a week, tracked in the renderer's memory the way Valve expired facts "to prevent two successive bits of a running gag from being played too close together".
8. **Evals on every card or model change:** gate pass rate, distinct codas, honesty on failure events, and a blind test where a judge names the speaker from the coda alone.

## Measured cost

COST_PLACEHOLDER
