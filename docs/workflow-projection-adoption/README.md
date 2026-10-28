# Prepared workflow projection adoption — 28 October 2026

Eligible fresh local workflows now adopt the complete immutable row projection already prepared in the worker. Current Store validation still runs before adoption. Exact scope/encoding admission is required; rejection replays every ordinary append, including project-only workflows with no task-history entries. Durable atomic save, cancellation, receipt staging, final widget admission and Undo remain in place.

Each independent repo passes 108 selected Core cases, including four new projection/admission/fallback cases. Seven native cases pass on each iPhone and iPad, with no failures, skips or reported runtime warnings: ordinary Create/Undo, 5,000 roots, failed-save preservation, changed source, forced late rejection with 1,000 roots, project-only rejection, and cancellation/retry. JSON attachments retain actual Store measurements; manifests bind them to case names. These are synthetic isolated hosts.

Mac final clean source builds and passes strict signature verification. Native CUA verifies Create, Undo to empty, and Redo restoring the hierarchy in that clean build. Separately, the instrumented 5,000-root Mac host verifies Undo to one pre-existing task and Redo to 5,001. No Mac XCTest or warning-free Mac runtime claim is made in this stage.

| Mac Debug observation | Before | After |
|---|---:|---:|
| Worker preparation | 1.296 s | 1.339 s |
| Synchronous commit | 0.634 s | 0.490 s |
| Combined processing | 1.930 s | 1.829 s |
| Widget ready | 4.687 s | 4.666 s |

These are one paired varying-load observation, not a controlled percentage improvement or release/device guarantee. Temporary DEBUG phase markers and diagnostic readback existed only in the disposable Mac host and were removed before the clean final build. Bindings distinguish the profiled binaries from the final binaries. Mac timings were captured through native accessibility readback, not a byte copy of the private result file.

Still open: the ~0.49-second synchronous pause; richer child/assignment-heavy workloads and production rendering; hosted/paired delivery; earlier cloud-settle failures; Mac runtime/geometry warning gates. Audio and release deferrals remain unchanged. No real task or audio data was used.
