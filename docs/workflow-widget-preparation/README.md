# Reuse prepared workflow widget signatures — 28 October 2026

Fresh local workflow workers already prepare completion signatures and encode their immutable projection. Final persistence used to prepare all widget signatures again. The worker now uses an initializer that performs that preparation itself and records private provenance. Only that initializer can attest preparation; an ordinary encoded snapshot cannot. Persistence skips its repeated pass only after the existing full table-buffer/raw-key and byte-exact encoded-metadata admission succeeds. Changed rows, equal-but-rebuilt arrays, private receipts, token metadata and raw Unicode changes take the ordinary preparation path. Final receipt staging separately rechecks encoded-byte reuse as before.

Per-command validation, account/source/calendar admission, Undo construction, durable-baseline decoding, location/wearable receipt staging, atomic writes and rollback remain in place. Cancellation is checked after token preparation and before encoding; non-encodable input retains failure/fallback. This adds no retained global cache, permission or user-visible workflow.

## Measurement

One before/after diagnostic run of the existing 5,000-task synthetic workflow used the same iPhone Simulator and reserved signed test app. Temporary timers existed only in the disposable host; the instrumented Store/fixture sources, input hashes, app/test executable hashes, signing receipts, logs and exported measurement attachments are retained here. Both diagnostic results have one actual passing test and pass the strict verifier. This is a single Debug observation, not a statistical benchmark, physical-device claim or release acceptance.

| Phase | Before | After |
|---|---:|---:|
| Final widget preparation/admission | 52.43 ms | 10.97 ms |
| Per-command row validation | 217.35 ms | 210.41 ms |
| Entire synchronous commit | 463.87 ms | 409.05 ms |
| Worker preparation | 1.161 s | 1.102 s |
| Widget ready | 3.794 s | 3.727 s |

The after widget-preparation interval also includes cache-directory creation, a negligible but explicit boundary difference in the temporary timers. Remaining phases fluctuate between runs. The direct work removed is the repeated signature preparation; the roughly 55 ms total difference is an observation, not an attributed guarantee. The larger validation/save pause remains open.

## Verification scope

Both independently owned Core suites pass 114 selected tests: PreparedSnapshotEncodingTests, WidgetCompletionPreparationTests, FreshLocalActivityTests, ProjectWorkflowsTests and WorkflowHistoryGuardTests. New cases require provenance, exact unchanged snapshot admission, idempotent token preservation, changed-buffer/metadata/Unicode refusal and cancellation before encoding. The actual admitted workflow projection is also checked before its ordinary token pass and after a late receipt change.

Four final iPhone cases pass: actual TemplateRunView Create/Undo, 5,000-task save with one publication, changed-source fallback and failed-save history preservation. iPad passes the actual Create/Undo case. Both strict result verifiers report no runtime warnings. Final native build/runtime receipts are listed in final-verification.json. Diagnostic timers are removed before those builds, with source equality checked against each repository. Mac desktop runtime, existing Mac warning gates, production rendering, richer child/assignment workloads and hosted/paired bulk delivery remain open. Genuine audio, provider configuration, remote delivery, older-client rollout and release work remain explicitly deferred. Full Px completion is not claimed.
