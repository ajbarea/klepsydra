# IMPL: #513 doctor reports agy and Copilot model-list changes (PR #520)

Branch feat/model-watch-513 (agy's, reviewed and fixed by Opus agy-review-k 11-23).
Push: `git push origin feat/model-watch-513:feat/model-watch-513`. Never push to main.

## Done
- agy: eng_models (agy models; Copilot via its OAuth token to api.githubcopilot.com with a
  spoofed VS Code Editor-Version, else data.db); doctor snapshot + one-run warning.
- Opus r1 fixes:
  - Security: no token read, no private API call. Copilot's list comes from its CLI's own
    cache (data.db opened read-only). Live: 7 ids, 36 ms.
  - Performance: doctor runs every 5 min; the list is asked at most every 6 h
    (FLEET_MODELS_EVERY_S). Live doctor 5.9 s first run, 4.7 s the next (agy call skipped).
  - UX: the warning held only one run, so the timer cleared it before anyone saw it; it now
    holds 3 days (FLEET_MODELS_WARN_S, a models-<e>.changed file).
  - One sort/comm collation (LC_ALL=C); the parsers tested on real `agy models` output and a
    real-schema data.db.
- Opus r2 (fresh reader) fixes: SC2004/SC2016 (CI lint); agy's failing or partial listing now
  fails whole (awk was last in the pipe, so an error read as models gone); one .asked stamp sets
  the interval for every attempt, so a lister that never succeeded is not asked every run; a list
  unread for two intervals is a warning; COPILOT_HOME (Copilot's own variable); atomic snapshot.
- Opus r3 (verify + fresh pass): a lister that never succeeded read ok forever: now a warning;
  a second change within the 3 days is appended (the first was lost; .prev dropped, nothing read it);
  the Copilot login line honours COPILOT_HOME.
- 16 cases pass in isolation; doctor.sh and engines.sh shellcheck clean; live doctor agy 6, Copilot 7.

## Next
- CI green, fresh-reader verify, merge (restore main's IMPL.md first).

## Verify
- `FLEET_MODELS_DIR=$(mktemp -d) bash fleet/doctor.sh | grep models` (live).
- `make test-fleet` (takes the heavy lock itself).
