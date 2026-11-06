# Reuse access-filtered workspace reads

Reviewed 3 November 2026. Both apps now reuse the current immutable filtered tables while the source and access context are unchanged. Previously, every row lookup rebuilt the entire access-filtered workspace. Assigned task rows made several such calls. The ordinary unmasked path remains a direct table read.

The in-memory result is bound to the snapshot revision, a separate mask epoch, account and backend. Snapshot, mask and readability changes discard it synchronously, including mask changes with the same boundary. No result survives into a different context. A warm hit still reads the observable snapshot, preserving SwiftUI notifications. Copies returned to callers cannot mutate the cached value. No disk schema, authorization decision, write/Undo path, release switch or hosted service changed.

## Measurement

The owning iPhone diagnostic seeds 240 assigned roots, each with three checklist children, one project and one collaborator. It executes the actual Store lookups for 100 task/project/assignee read combinations, three consecutive times. It verifies every returned value and preserves the snapshot, then opens the actual production TaskScreen. The inspected screenshot shows task titles, notes, project badges, 0/3 subtasks and the assignee.

| Warm read batch | Before | After |
|---|---:|---:|
| Sample 1 | 551.25 ms | 3.38 ms |
| Sample 2 | 555.62 ms | 3.30 ms |
| Sample 3 | 550.87 ms | 3.30 ms |
| Median | 551.25 ms | 3.30 ms |

These are small Debug Simulator observations of repeated reads, excluding the first filtering cost. The fixture shape is unchanged, with freshly generated identities/timestamps. Other host activity was not controlled. This is not a statistical benchmark, full-list scrolling/frame-rate measurement, save timing, Mac timing, Release or physical-device guarantee. Before/after reports identify actual compiled code and owning source hashes; iOS also retains baseline source archives.

## Verification

- Each repository passes 86 focused workspace Core tests, including four new cache/immutability/context/revocation cases. Core excludes Store, so those tests alone do not accept its wiring.
- The owning iPhone after case passes with no failures/skips/reported runtime warnings. Eight actual Store checks cover warm-hit Observation notification, source edits, access loss without deleting saved rows, restored access, unreadability, readability recovery, unmasked fallback and restoring the original source. The production list is then opened and inspected. This uses synthetic Auth/workspace data and standard L text, light appearance.
- Both independently owned app/test-runner builds and strict signatures pass. Counterpart iPhone evidence does not establish Mac or iPad runtime acceptance.
- The first baseline attempt skipped because its guard compared the test bundle with the runner identifier. The exact main runner guard was corrected and the actual installed identifier checked. That skipped attempt supplies no measurement or acceptance. The successful baseline and after runs each execute one native test.

## Remaining

The broader save-pause checkpoint stays open: richer workflow creation/persistence, large production-list scrolling/rendering, assignment-heavy catalogs, Mac/iPad runtime, wider accessibility/account/lifecycle cases and paired/cloud delivery. Previously accepted flat-workflow work is not rerun here. This read-path change does not complete the full Px objective or account-deletion follow-up. All user deferrals remain unchanged.
