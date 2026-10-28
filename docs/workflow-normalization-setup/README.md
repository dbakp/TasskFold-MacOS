# Skip discarded workflow normalization setup — 29 October 2026

Fresh local workflow commits now reuse the already-admitted normalized commands
without first constructing command copies, destination-table lookups and label/
cache inputs that the prepared path discards. Ordinary and stale-source commits
keep the original normalization path. Retained fresh commands also reuse the
workflow shape already proved by their prepared Undo instead of scanning it again.

No new admission token or permission cache is introduced. The existing immutable
buffer, source revision, raw account, calendar and workspace-cache admission stays
in place. Current authorization, heading capability, task kind/generation,
receipt staging, exact final encoding, durable baseline read, atomic write,
failed-save rollback and Undo checks remain on their existing paths. No persisted
contract, schema, server deployment, customer control or rollout flag changes.

## Diagnostic observations

The existing native iPhone Simulator case creates 5,000 roots, 5,000 sections,
5,000 labels and 5,000 order records plus one project: 20,001 commands. The seed
has one existing task and 100 root/200 child history rows. The new roots have no
children or assignees. It runs through the actual Store, private durable cache and
background widget publication, using only synthetic data.

| Debug observation | Before | Changed |
|---|---:|---:|
| Synchronous commit, run 1 | 220.00 ms | 191.24 ms |
| Synchronous commit, run 2 | 223.32 ms | 164.44 ms |
| Synchronous commit, run 3 | 219.82 ms | 170.61 ms |
| Median | **220.00 ms** | **170.61 ms** |

All six independent runs pass the existing saved-row, prior-history, prepared
validation/encoding/Undo, widget and source-preservation checks. The changed runs
also assert that the actual Store skipped ordinary normalization setup. These
are a small set of Debug observations on one Simulator workload, with no own
build/Core-test jobs overlapping the six measurements. They are not a statistical,
Release, physical-device or full-list-rendering guarantee. The synchronous pause
is reduced, not eliminated. Raw metrics: [measurements.json](measurements.json).

No temporary phase timers were added to Store. A permanent DEBUG-only branch
flag supplements the existing native fixture report; it is absent from Release.
The same actual-Store test now verifies that stale and ordinary inputs use the
ordinary setup while admitted/rejected-projection/failed-save inputs retain the
prepared normalization they already used.

## Functional verification

- **118 existing focused Core cases per repo pass**, covering worker admission,
  encoding, workflow/history and destination/body-size invariants. The Core target
  excludes Store; these do not by themselves accept the new Store branch.
- **Six iPhone native cases pass**: actual TemplateRunView Create/Undo; ordinary
  1,000-task commit; changed-source fallback; failed-save/history preservation;
  rejected task projection; rejected project-only projection. These execute the
  actual Store and assert the new branch diagnostic in scale cases.
- **Two iPad native cases pass**: actual Create/Undo and 1,000-task prepared local
  history with Undo. Synthetic peer/workspace only; no genuine hosted acceptance.
- Both independent isolated app/test builds pass and verify strict signatures.
  Real-team Simulator signing verifies its embedded identity/App Group. Loaded
  debug-code hashes are recorded separately from the launcher stub.
- No failures, skips or runtime warnings are reported in the successful native
  summaries. This does not accept Mac desktop runtime or its existing warning gate.

[Verification](verification.json) · [Build](build.json) ·
[Source bindings](source-bindings.json) · [Baseline bindings](baseline-bindings.json) ·
[Changed measurement bindings](changed-bindings.json) · [Installed app hashes](installed-builds.json).

The six measurements and common baseline host source archives are from **iOS**;
Mac has its own source/build/Core evidence and no timing/runtime claim here.
The independent prepared hosts use their respective App Group/namespace transforms;
production sources remain separately owned by each repo.

## Setup correction and limits

The initial three repeated attempts failed before reaching the measurement because
the fixture inherited Accessibility XXXL and queried an unloaded Form row. No
timing data was produced. The functional/performance fixture now explicitly uses
standard L text, temporarily disables Simulator VoiceOver for touch tests, and
restores the observed state through XCTest teardown blocks even after assertion
abort. This is not largest-text or spoken workflow acceptance. The initial failed
runner was cancelled/terminated after its three failed setup outcomes when result
finalization did not exit; its log and bindings remain recorded. Successful runs
were then executed separately, without the repetition option.

The Mac was checked through computer use and was locked, so no Mac test app was
launched. No microphone, real task, provider credential or hosted data was used.

Still open: the remaining save pause, production rendering, richer child/assignment
workloads, cloud/paired bulk delivery, Mac runtime/geometry and previous warning
gates. The full Px objective and all user provider/audio/release deferrals remain
unchanged. Earlier admission evidence:
[worker validation](../workflow-validation-admission/README.md).

## Reproduction

Prepare this repo's reserved host using
`Scripts/prepare_team_editor_native_test.py --output <new-path> --headings`.
Build/sign for the explicit existing Simulator using the repository's signing
helper and an available development identity; on Apple Silicon use arm64 and
`ONLY_ACTIVE_ARCH=YES`. Select
`testPrivateWorkflowNativeLocalHistory5000PublishesOnce` in the repo's native UI
test target. Before/after sources, exact commands, signing receipts and summaries
are archived here. Recreate the recorded before Store from its parent commit or
baseline source archive; compare with new result paths, not overwritten evidence.
Do not enable production gates or target a real account.

[Cleanup](cleanup.json) records removed obsolete products/results/videos, no
remaining Taskfold executables, and both owned Simulators returned to Shutdown.
Reusable source and build caches remain.
