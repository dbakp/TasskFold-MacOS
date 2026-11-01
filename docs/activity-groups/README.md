# Activity grouped by committed action

Project pulse shows a collapsible summary when several recorded changes belong together. Single changes and older records retain their existing rows. Every detail keeps its actor, recorded time, effective completion time and guarded current-task link. Expanded groups show 30 details initially, with **Show more changes** for larger groups; the outer activity limit counts groups so it never cuts a group in half. Counts say “recorded changes”, without claiming that a partially available history contains every member.

Shared work uses explicit metadata assigned by the existing ledger’s insert trigger from the actual epoch-extended database transaction, namespaced by database/server incarnation. It does not match clocks, names or guessed proximity. The metadata is display correlation, never permission, a credential or a request to Undo. Missing/unknown/malformed correlation leaves the underlying event and completion credit intact as a separate row. Actor and origin remain part of the grouping boundary; project/workspace filtering runs first.

On-device work uses the original first mutation identity of one Store commit. Only newly appended owned rows are annotated. Prepared workflow history includes the metadata before its encoding, and ordinary fallback safely rejects an old pre-encoding when metadata was added afterward. Existing event bytes/readers remain compatible; no old activity is rewritten or backfilled.

The existing child Complete command records its actual server event time; a parent may carry a chosen completion time. Grouping preserves each one. Undo remains its own committed action, and exact retries retain the original group without extra history.

Each app repository owns its implementation, migration and tests. No hosted deployment, normal-use migration gate, existing RPC grant or earlier user deferral changes here.

## Verification

- `core.json` / `core.log`: 135 focused cases in each repo, including the actual 18 server rows, six related root/child groups, ungrouped historical rows, actor/origin/project separation, malformed display-only metadata, local append/retry isolation and preserved pre-encoded workflow admission. Existing frozen event/date and activity/order checks pass.
- `postgres.json`: 67 actual database checks per repo: personal/team mixed completion, whole-selection Undo, replay, fresh actions, late-history failure rollback, stale/viewer/outsider refusal, caller identities, source timestamps and closed helper/table privileges. A timezone change between real root and child captures keeps the same transaction identity. Advisors add no findings; owned fixtures are removed.

- Mobile `phase`, `summary`, `proof` and `state` records bind final source to the saved/cold UI and cache. Both detail links stay inside their own group. Selected normal/light and largest-text/dark captures are retained in the iOS repo and visually inspected. `ui-retake.json` separates earlier selector failures and the text-color correction from accepted v3 phases.

- Both current apps build and development signatures verify. Mac runtime remains open: the availability check reported a locked screen, so no isolated app was launched for another manual walkthrough.

## Remaining migration work

Older-data/history mapping and shared file/discussion custody; remaining Mac keyboard/runtime and broader real-account/lifecycle/accessibility/library acceptance; hosted migration. Ordinary subtask migration use stays disabled.
