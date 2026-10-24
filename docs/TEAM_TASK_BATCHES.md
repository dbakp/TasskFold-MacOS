# Atomic team selections — disabled candidate, 24 October 2026

A linked task selection now has one persisted command, one RPC and one database
transaction. This replaces the earlier temporary hold on deleting a parent and
its selected occurrences together. It does not enable team editing or complete
the remaining team interface and permissions work.

## Server behavior

`taskfold_team_task_batch` accepts delete or restore selections of up to 100 tasks,
within one team, with frozen per-task project/generation/content and operation
identities. Projects may differ. Current verified session, every project role,
team/setup switches and archive states are checked under locks. Every selected
task must match its baseline; an initial missing task is a conflict rather than a
partial/no-op deletion. Invalid selections are rejected as a whole.

Deletion runs selected children before their parents. Unselected occurrences
survive and are detached through the existing narrow relationship scope. Undo
runs parents first, gives each restored task a fresh generation and validates the
old-to-new parent generation mapping against the original deletion cohort. Only
the exact original selection can consume its batch Undo. A single-task call
cannot split that permission. Cyclic selections are rejected before effects.

All existing task-generation, whole-baseline, creator-custody, discussion-recovery
and role protections remain in force. A failure on the second task rolls back the
first task, discussion keys/content, member receipts and group receipt. Each
operation and group nonce shares the same guarded namespace. Retries acknowledge
the original selection without deleting restored work or duplicating discussion.
Authority is checked before replay. Journals contain UUIDs/digests, not task text.
Private group/item/scope tables have RLS and no client/service grants.

Auth participants are held before the team lock; project, action and task locks
are taken in deterministic order. Locks and original baselines are rechecked by
the guarded single-task lifecycle. Contention/timeouts leave the saved command
available for retry. Account deletion cleans up cohort/member receipts and their
private recovery keys. Direct legacy/native/service writes remain closed.

## Native behavior

Both independent apps own `TeamTaskBatch`. `Mutation` has an optional batch value,
so existing ordinary queues decode as before. A batch is one queue entry with
all immutable member requests. The sender verifies account/server/session, uses
the dedicated bounded uncached endpoint and validates every acknowledgement
identity before removing the group. There is no single-task fallback or client
chunking that could partially apply the selection. Minimal acknowledgements avoid
returning entire task discussions; the normal sync refresh loads current rows.

The app commit boundary captures all selected records before applying any parent
removal and groups compatible scoped deletions. Mixed workspace/actions require
review. Local projection uses a copy and installs the whole result together; a
recreated task or unavailable project prevents a partial local projection. No
fake task is created for the queue header. Undo uses original frozen records,
retains the actual deletion/member nonces and renews action identities before
constructing the next Undo/Redo history entry. New generations preserve stale
widget/reminder/callback protections.

A selection too large for the bounded request is held before local application.
Conflict, access-change, expiry and transport failures retain the complete saved
selection. The remaining team workspace and review interface must be integrated
before enabling the feature. The catalog still reports task editing unavailable.

## Evidence and remaining work

Each repository independently passes 72 real PostgreSQL batch checks, including
three-level links across two projects, unselected occurrences, discussion Undo,
forced mid-delete/mid-restore failures, changed/missing/cyclic tasks, archive and
role changes, global nonce collisions, private table isolation, removed actors
and two real transaction overlaps. Another 70 discussion, 89 lifecycle and 70 edit
checks run against this migration: 301 database checks per repo. No new advisor
errors/warnings occur; existing dependency-fixture init-plan warnings are recorded.

Each repo passes 177 selected SwiftPM tests: 10 new batch cases plus 167 existing
checks. Tests consume that repo's SQL-produced fixture and verify persistence,
whole-selection projection, Undo/Redo nonce lineage, response completeness,
malformed/old queues, session replacement and the dedicated request path.
Unsigned Debug app and embedded extension builds pass for generic macOS and iOS
Simulator, compiling the real Store integration and each app's new model source.
This is compilation evidence, not interactive UI or distribution acceptance.

Owned database fixtures and temporary app build folders/registrations are cleaned
up. Source/resource hashes identify the exact inputs. No hosted schema change,
real task write, app launch or enabled team UI is claimed. Remaining task/comment/
mention/file/API/email adapters, current-role workspace refresh, premium team
organization/review UI and full privacy/recovery acceptance remain required.
Watch/Wear OS, wider Px and all user deferrals retain scope.
