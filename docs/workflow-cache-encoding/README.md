# Background workflow snapshot encoding — 27 October 2026

Fresh local workflows now encode their completed snapshot in the existing
preparation worker. Final Store validation and the atomic durable write remain
synchronous. Undo is exposed only after that write succeeds. Cloud workflows and
unsupported/changed captures keep the ordinary path.

The worker projects the same normalized commands and local activity, prepares
completion tokens, then retains its immutable tables and encoded bytes. Store
still validates every command against the current source before adopting those
tables. The existing raw-account, calendar, workspace-revision and command-buffer
admission remains required. Final persistence still prepares widget state, reads
the current disk file, and stages private reminder/import/wearable receipts with
the original rules and account-removal authority.

Prepared bytes are reused only if every table key has identical UTF-8 spelling,
every retained row array has the same scoped read-only buffer and count, and the
encoded non-table metadata matches byte for byte. Metadata uses the existing
Snapshot encoder with empty tables and sorted keys; there is no new disk format.
The full payload uses the ordinary Snapshot encoder. Changed receipt metadata,
row copies/edits/reordering, unknown fields or table spelling take ordinary
encoding. Array addresses never escape their borrow scopes. Worker encoding
failure also keeps the ordinary final-save error path. Cancellation checks surround
widget preparation and encoding; the worker never writes to disk.

## Core verification

Each independently owned repository passes 104 selected Core tests. A stronger
independent projection assertion was then added to one of those cases and rerun
successfully in each repo: this is still **104 distinct cases**, not 105. It
compares the worker's complete projected rows and private history against ordinary
projection/recording byte for byte, normalizing only random assignment transport
nonces and new widget tokens after comparing the complete signature registry.
Final widget preparation preserves the exact worker tokens.

Seven new encoding cases cover unknown fields, raw composed/decomposed Unicode,
signed zero, copied/reordered/edited arrays, table-key spelling, private-ledger
metadata changes, empty snapshots, encoder errors and 5,000-row round trips.
Late receipts refuse reuse. Source changes and existing metadata fallback retain
the preceding safety checks. The frozen history digest, 176-input hierarchy corpus
and 1,377-input body-size corpus still match.

The small same-input encoding benchmark records roughly 0.010–0.014 s admission
versus 0.026–0.065 s ordinary encoding under varying shared-host load. Its 5,000
simple rows are much smaller than the full native workflow with sections, labels,
ordering rows, activity and widget tokens. It is not a release/device performance
promise, and no timing threshold is asserted by tests.

## Native scope and measurements

All acceptance uses reserved isolated identities, synthetic local caches and a
local synthetic HTTP peer. No real user tasks, account credentials, deployment,
rollout gates or signing/distribution configuration changed. Source bindings,
product hashes (including Taskfold.debug.dylib), build logs, summaries and metrics
are retained here. Original result bundles stay under `/tmp/taskfold-encoding-*`.
Pre-driver bindings remain separate from the final runner binding.

For 5,000 roots / 20,001 commands, final native observations are:

| Platform | Worker preparation | Synchronous commit | Combined processing | Widget ready |
| --- | ---: | ---: | ---: | ---: |
| Mac | 1.256 s | 0.605 s | 1.861 s | 4.449 s |
| iPhone Simulator | 1.177 s | 0.595 s | 1.773 s | 4.513 s |
| iPad Simulator | 1.300 s | 0.627 s | 1.926 s | 4.621 s |

All three report prepared encoding reuse, one published task revision, one Undo
command, an empty local pending queue, 5,001 saved roots/lists and preserved prior
root/node history. The failed-save case preserves the prior durable state and
exposes no new Undo. Changed-source cases use ordinary history/encoding and retain
the concurrent edit. Cancellation/retry and actual local Create/Undo are covered.

The preceding synchronous commits were 0.873 / 0.851 / 0.850 s on Mac/phone/tablet.
These varying-load Debug observations show work moved off the main actor; they
are not a controlled percentage speedup or a claim that total processing is faster.
The synchronous commit still lasts about 0.6 s. Previous-file decoding, final
validation/widget preparation, durable writes, production rendering and richer
child/assignment workloads remain performance work.

## Interrupted attempts and test-driver correction

The first run was interrupted: Mac completed actual local Create/Undo and the
cloud-peer Create/Undo/Redo/cold-return case, but did not finish the scale case.
Both mobile runners stopped before reporting cases. The second mobile runs each
complete all six selected cases, with no failures/skips/reported runtime warnings.
Both strict six-case verifiers pass. The prior stage's mobile cloud-settle timeouts
do not reproduce here, but their underlying cause is still not explained.

Mac v2 passed the scale case but its following measurement action did not start.
The native event log records an unrelated foreground-window interruption; the
window still showed the original task and disabled Restore, and app sampling
showed an idle run loop. Runner sampling showed it waiting for the absent result
file, rather than a busy save. That wait timed out, then the run was interrupted
in its next case. Negative-width/height warnings are retained as unresolved.

The Mac runner now explicitly activates the app, requires a hittable measurement
button, sends one click, and waits for Restore to become enabled as proof the
action started. A missed event now fails in ten seconds rather than masquerading
as a 180-second save. There is no silent retry or relaxed save assertion. Only the
runner was rebuilt; the app's debug-dylib UUID remains
79549250-9CE8-3E9D-8FFC-53E71598C53B. All four remaining Mac cases then pass in the
final v3 result. The two first-run completed cases are retained as partial-log
evidence, not relabeled as a complete six-case result bundle.

The final Mac v3 result has four passes and **one QoS warning**. The strict
verifier correctly rejects clean runtime acceptance. Its archived event has
UUID-matched system frames through AppKit Services-menu accessibility inspection
and the data-detector scanner; unresolved frames stay explicit in the attribution.
This identifies the observed stack without suppressing Services, excusing the
warning or claiming every UI delay has that cause. Earlier geometry warnings
remain open even though v3 does not report them. No broad Px completion or release
readiness is claimed.
