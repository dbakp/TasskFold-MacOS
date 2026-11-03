# Rich workflow construction and durable Undo

Reviewed 3 November 2026. Workflow instantiation now owns one ISO8601 formatter for the synchronous run, rather than allocating one for every root and nested task. Each node still samples its own current time using the same whole-second UTC format. No timestamp is shared between rows by fiat, and no formatter is shared across invocations, accounts or threads. The original three-argument Record.task signature remains available; an internal overload accepts the formatted timestamp while retaining the same defaults and identity generation. Quotas, IDs, dates, hierarchy, write/Undo and service protocols are unchanged.

## Native scope

The owning iPhone accepts two cases with no failures/skips/reported runtime warnings, in light appearance at standard L text:

- An actual Store diagnostic creates 1,000 roots and 6,000 nested checklist items, preserving descriptions, estimates, planned/deadline dates, unique identities and root-generation/history relationships. All prepared-history/normalization/Undo/encoding/projection/validation branches are used. It retains 100 existing root and 200 child history rows; adds 1,000 root and 6,000 child events; saves once, publishes widgets, performs warm Undo and reopens the saved local workspace after quitting. Task/organization/history tables match the saved undone state.
- The actual TemplateRunView sheet creates the same-sized nested structure through Create workflow, then performs Undo and cold local return. The reusable source template is unchanged. This follows the production preparation/context/commit flow, with synthetic local data and a guarded native fixture; it is not genuine cloud delivery.

The diagnostic instantiates and prepares in separate background jobs. The production sheet combines them in its existing worker. Its timings below do not time the sheet, preview rendering, scrolling or frame rates. Global Undo affordances after cold launch are not claimed; the saved result of a warm Undo is reloaded.

## Observed timings

| Diagnostic phase | Before | After |
|---|---:|---:|
| Template validation/instantiation | 1.236 s | 0.306 s |
| History/preparation worker | 1.416 s | 1.514 s |
| Synchronous commit | 0.113 s | 0.115 s |
| Widgets ready from preparation start | 3.270 s | 3.445 s |

This is one Debug iPhone Simulator observation per version, with generated identities/timestamps and uncontrolled other host activity. It is not a statistical, Release, physical-device or Mac benchmark. The before native case passed creation, data/history and warm Undo assertions but failed to reveal the cold saved-count label below the lazy viewport. Its timing is retained only as a qualified partial diagnostic. The label now has a stable identifier and the test scrolls it into view. The first changed build passed the complete Store diagnostic, but its template-sheet test waited for a lazy Create row before scrolling the preview. That navigation was corrected; the final changed build passes both complete cases. The before failed result is not counted as acceptance.

## Independent verification

Each repo passes 109 focused workflow/history/encoding tests, including new factory-default/signature compatibility and twelve concurrent nested workflow runs. Defaults, valid fresh identities and separately sampled current timestamp format are checked. Existing frozen history, hierarchy and prepared-encoding controls pass. Both independent app/runner builds and strict signatures pass. iPhone evidence does not establish Mac/iPad runtime or audible accessibility acceptance. Fresh Core compilation with the existing no-index CLI option did not recreate either discarded test index store.

## Remaining

Large-template definition parsing and preview/opening latency on the main actor need separate profiling; the sheet body still constructs validated definitions during rendering. Production-list scrolling/rendering, richer assignment/multiple-project creation, wider source/cancel/failure/account/lifecycle/keyboard/speech/display cases, Mac/iPad runtime and paired/hosted delivery remain. All previous user deferrals and the full Px objective remain active. Ordinary service gates and hosted configuration are unchanged.
