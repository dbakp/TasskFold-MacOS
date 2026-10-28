# Skip redundant workflow Undo identity scans — 28 October 2026

Workflow commits previously built identity sets for every saved table before checking whether a complete Undo inverse was already available. They now return from that guard without reading the baseline when the inverse is nonempty. When the inverse is missing, they build indexes lazily for only the destination tables actually checked. The Store still refuses a single-run, all-POST workflow containing any new record if no inverse is available. Existing-row replays, mixed/non-workflow changes, case sensitivity and Swift's existing Unicode identity semantics keep their prior decisions.

This removes main-thread work from the ordinary workflow commit. The helper has no retained cache or asynchronous state. Normalization, complete mutation validation, scope/admission checks, actual Undo construction, receipt staging, atomic persistence, presentation rollback and widget publication keep their existing paths. This is a guard-cost improvement, not completion of the broader save-latency work.

## Core verification

Both independent repositories pass 102 selected Core tests: ProjectWorkflowsTests, FreshLocalActivityTests, WorkflowBodySizeTests, WorkflowDestinationIndexTests and five new WorkflowHistoryGuardTests. The new cases include 3,240 comparisons with the frozen original Store predicate across table/ID spellings, missing/existing rows, nil/empty/nonempty inverses, mixed methods/runs and untagged/empty commands. They also exercise actual valid and failed EditHistory construction, require zero baseline evaluations when an inverse is available, and preserve a 90,000-row unrelated-history/future-table fixture.

Before optimization, the extracted original guard fails the zero-baseline-read assertion in each repo (one failure among the same 102 cases); its decision-parity cases pass. The retained helper text and parent-commit reconstruction reproduce the exact before source hashes. No complete prior binary manifest is claimed. The final unchanged test corpus passes in both repos.

The following Debug component observations are five guard evaluations in each final Core process on this Mac. The frozen original and new guard are timed in the same run, without timing thresholds. The fixture has 90,000 minimal ID/text records, not a fully validated application history workload.

| Core run | Frozen original guard | Current guard |
|---|---:|---:|
| Mac-owned repo | 0.192755 s | 0.00001296 s |
| iOS-owned repo | 0.190547 s | 0.00002063 s |

The data demonstrates removal of the unrelated-table scan. It is not a release, physical-device, renderer or end-to-end workflow speedup measurement.

## Native verification and limits

Both current native app/test builds and strict signatures pass. iPhone Simulator passes three selected cases: the actual local TemplateRunView Create/Undo flow, a 5,000-task local workflow with one widget publication, and a failed 1,000-task save preserving its original history. iPad Simulator passes the actual local TemplateRunView Create/Undo flow. Strict result verifiers report four actual passing tests overall with no failures/skips/reported runtime warnings. These are existing functional checks of the ordinary Store call path in reserved synthetic hosts; no new layout or screenshot acceptance is claimed.

The native 5,000-task receipt records 20,001 commands, 5,001 saved tasks, one Undo command, one task-revision change and preserved prior root/node history. Its current synchronous commit is 0.46654 seconds, preparation 1.13192 seconds and widget-ready time 3.81154 seconds. These are a single iPhone Simulator observation. They cannot be compared as a controlled improvement against the earlier approximately 0.49-second Mac observation. The half-second-scale synchronous pause remains open.

The failed-save case keeps the one original task, prior 100 root-history/200 node-history records and zero pending changes, with the existing readable save error. No source/destination/body/Undo guard has been relaxed to obtain a faster success. The Mac desktop remains locked: native Mac interaction, its existing runtime/geometry warning gates, production rendering, richer child/assignment workloads and hosted/paired delivery remain open. User audio, provider, older-client rollout, remote-reminder and release deferrals are unchanged. Full Px completion is not claimed.
