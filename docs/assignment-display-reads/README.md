# Reuse assignment display names for large member catalogs

Reviewed 3 November 2026. Both apps now resolve the existing project-member list once per unchanged project/context for name display. Previously every assigned row rebuilt and sorted the full member list to retrieve one name. The cache retains only a user-ID/name index. Member pickers, membership resolution, sorting and permission/writer checks keep their existing fresh readers.

The index is bound to the snapshot revision, mask epoch, account and backend. Snapshot/mask/readability changes discard it synchronously. Every hit still reads the presented tables so SwiftUI retains source, access and readability dependencies. Missing names, empty names, exact text and first-match behavior are preserved. The ordinary unmasked table path does not discard an otherwise-current display-name index. No persisted contract, user interaction, release gate or hosted service changed.

## Diagnostic observations

The owning iPhone fixture has 240 assigned roots, 720 checklist children, one project and **400 accepted collaborators plus the owner**. Its task/project/collaborator tables are deterministic and byte-identical before and after, checked with a sorted-encoding SHA-256. The actual Store performs 100 task/project/name lookup combinations per sample, verifies all returned values, preserves the snapshot and opens the actual production TaskScreen.

| Warm read batch | Before | After |
|---|---:|---:|
| Sample 1 | 463.95 ms | 2.23 ms |
| Sample 2 | 467.56 ms | 2.05 ms |
| Sample 3 | 454.19 ms | 2.03 ms |
| Median | 463.95 ms | 2.05 ms |
| First observed name lookup | 4.63 ms | 4.89 ms |

The initial lookup is outside the warm batches and still resolves the current member list. These are three consecutive Debug Simulator samples per version, with other host activity uncontrolled. They measure repeated Store reads, not full-list scrolling/frame rate, save duration, Release, hardware or Mac performance. Reports bind the source and compiled code; iOS retains the actual baseline sources. This extends the earlier [filtered workspace read checkpoint](../workspace-read-reuse/README.md); the old one-collaborator native case was not repeated.

## Verification

- Each independently owned repo passes **91 workspace Core tests**, including five new catalog reuse, project/context isolation, negative/positive invalidation, exact-name and existing fallback/membership compatibility cases. Core excludes Store and does not alone prove its wiring.
- Before and after each pass one owning iPhone native case, with no failures/skips/reported runtime warnings. Sixteen actual Store checks cover source edits, warm-hit Observation, access loss/return, unreadability/recovery, unmasked fallback and original restoration. New name checks also exercise collaborator rename with Observation, project-specific member override/removal, hidden names after access loss/unreadability and restored names. The method preserves the original snapshot before opening the production list.
- The screenshot is inspected for the existing notes, project, 0/3 child count and assignee layout. Native scope is synthetic Auth/data, light appearance and standard L text.
- Both own app/test-runner builds and strict signatures pass, with own host/source bindings. Counterpart iPhone evidence is not Mac/iPad runtime or audible VoiceOver acceptance.

## Storage

The Mac storage guard stopped compilation below the 20 GiB floor. Four verified obsolete Taskfold build caches from September/early October were removed, reclaiming about 0.99 GB; current reusable products, Core caches, app and app data were preserved. The guard then allowed the Mac build. See storage-cleanup.json.

## Remaining

Richer workflow creation/persistence, production-list scrolling/rendering, multiple-project/catalog scaling, Mac/iPad runtime, wider accessibility/account/lifecycle and genuine cloud/paired delivery remain. The broader save-pause checkpoint and full Px goal stay open. All previous user deferrals remain unchanged.
