# Legacy migration refusal boundaries through genuine local APIs

Reviewed 3 November 2026. The owning complete schema passes 59 checks using actual local Auth and PostgREST after replaying all 203 owning migrations. All task fixtures and source changes are created through the authenticated REST interface; only the disposable local feature switches are enabled through trusted fixture SQL. No hosted database, ordinary app switch or app source changed.

## Accepted cases

Four legacy sources require review and cannot be adopted: duplicate node identity, canonically equivalent composed/decomposed Unicode identities, missing identity, and a non-array legacy checklist object. Each review exposes the original JSON value without normalizing away its distinctions. An attempted direct migration is refused; the complete original task record and generation stay identical, and no record authority is created.

A valid source is reviewed, then changed through another authenticated API request. Sending the original digest is refused while the newer task remains exact and authority stays absent. Explicit Close returns a real proof bound to that original request/digest. A late Send of the closed request returns its closed replay proof and cannot promote or overwrite the newer source. A freshly requested review has a new digest and request identity; only that explicitly fresh request migrates the current tree. Both the closed old and applied new receipts remain, and the current task stays exact.

A genuinely issued outsider session cannot read the private task, review its original source or reuse the owner's request. User-editable role metadata does not make those attempts succeed. The owner's current task is unchanged afterward. Cron launching stays Off, no outbound job is queued, and all owned containers/network are removed.

## Limits and reproduction

These are genuine local API/database boundaries, not native editor/Store, keyboard or VoiceOver acceptance. They verify original JSON values and whole persisted rows, not raw file-export formatting. They do not establish full migration of invalid sources: duplicates/missing/unsupported originals remain for explicit repair and mapping. Broader history/identity/custody/shared-account/window/access-loss and hosted directions remain separate. The recorded valid-tree native migration proof is retained in [genuine-native-adoption](../genuine-native-adoption/README.md).

Run `node Scripts/Database/test-legacy-adoption-boundaries.mjs /tmp/taskfold-legacy-boundaries-<unique>.json` from this repo with the existing pinned full-schema runtime prerequisites. The 20 GiB floor and resource ownership guards apply. Current app products and devices are reused untouched; this suite needs no app rebuild, Simulator or new device. Reports contain synthetic data only.
