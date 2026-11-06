# Prepared workflow Undo — 2026-10-27

Eligible fresh **local** workflows now build their bounded Undo history in the
existing detached preparation worker. Final Store admission uses the unchanged
source revision, raw account bytes, current calendar, and the retained immutable
command buffer. Both array borrows are scoped and read-only; no address escapes.
This is a conservative identity proof: even an equal copied array takes the
ordinary constructor. Commands with preexisting capture metadata also fall back.
All task-generation, heading, type, account and fresh-row validation still runs.
The disk save stays synchronous and durable; history is exposed only after it
succeeds. Cloud creation retains its ordinary path. No schema/provider/rollout or
release configuration changes.

The worker already captured completion revisions, so final admission preserves
those commands rather than rebuilding the same array. This keeps raw Unicode,
opaque fields, command IDs and run identity intact. The failed-save path does not
expose Undo or replace the previous saved history. Source changes reject the
prepared result. Cancellation never writes the prepared snapshot.

## Verification and limits

- 95 selected Core cases pass, followed by one separately run metadata-fallback
  case: **96 distinct cases**, not one 96-case run. Both independent repositories
  ran their own tests. Frozen history digest, 176 hierarchical-recording inputs
  and 1,377 body-size inputs remain unchanged.
- New coverage compares prepared history with the ordinary constructor, tests
  raw Unicode/signed-zero edits, copied/reordered commands, changed metadata,
  account/source revisions and nonstandard capture fallback.
- The same-input 5,000-root Core benchmark uses 20,001 commands and three pairs.
  Scoped identity admission takes roughly 2–25 microseconds versus 0.30–0.32 s
  rebuilding history on this Mac. These are Debug host observations, not release
  device latency promises. Assertions check correctness, not timing thresholds.
- An earlier deep-comparison approach took about 0.37 s, slower than construction.
  It was discarded; its passing functional checks are not current acceptance.
- DEBUG metrics now report prepared Undo reuse. Widget-publication failures write
  an explicit terminal result, so a missing shared-storage identity fails clearly
  rather than producing an unexplained 180-second wait. No error is swallowed.

## Earlier attempts retained locally

Original result bundles and logs remain under `/tmp/taskfold-prepared-undo-*`.
Mac v1 was interrupted before a terminal result. Mac v2 tested the discarded deep
comparison and also reported geometry warnings; these were not reproduced in v3,
but no geometry fix is claimed. Mobile v1 used signing-disabled Simulator products
and lacked the embedded Simulator/App Group identity required for widget storage.
Three scale cases timed out on each device; an idle-main-thread sample did not
show a spinning worker. Those runs are rejected. Current mobile builds preserve
Xcode Simulator entitlements and verify real team signatures independently.
A stale iPad diagnostic collector was interrupted only after all its cases ended.

Current source hashes, isolated namespace diffs, build logs, product hashes,
metrics and result summaries are retained here. The original host-preparation
receipt is historical: its initial source hashes are not current acceptance.
Use `current-source-binding.json` and `isolated-source-diff.json` for this stage.
Product hashes include the split Taskfold.debug.dylib, not only its launch wrapper.
All accepted native cases use synthetic caches and a local test peer, not a
production cloud service. No user task or credential was changed.

## Mac native scope

Six selected cases pass: actual local UI Create/Undo, cloud-peer Create/Undo/Redo
and cold return, 5,000-root local save/publication, failed save, preparation
cancellation/retry, and changed-source fallback. At 5,000 roots the measured
synchronous commit is 0.873 s; background preparation is 0.927 s; preparation plus
commit is 1.800 s; final widget publication is ready at 4.446 s. The worker records
449 main-actor pulses while preparing. Prior root/node history is preserved, one
revision is published and one Undo command is available.

The earlier sampled baseline has a 1.395 s synchronous commit, 0.729 s preparation,
2.124 s total and 5.161 s widget publication. Sampling and variable machine load
prevent a controlled percentage-speedup claim. The profile includes 266
EditHistory samples among 1,049 commit-path samples; about 238 are snapshot encode.
Much earlier decode activity belongs to fixture restore, not the commit itself.
The remaining encode/durable-save pause is still open.

The final run has **three QoS warnings**, and the strict verifier correctly
rejects clean runtime acceptance. All three archived events have UUID-matched
system frames through data-detector/Services menu accessibility inspection;
unresolved frames remain explicit in `warning-attribution.json`. This evidence
does not turn warning-bearing tests into a clean run or prove all pauses harmless.
