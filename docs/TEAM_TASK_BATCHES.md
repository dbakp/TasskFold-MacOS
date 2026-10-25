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
selection. The native selection review is now connected, as described below.
Team rollout remains disabled pending the remaining native/live and rollout gates.

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


## Reviewed native selections — 25 October 2026

Both apps capture a non-serializable opening admission for 2–100 distinct root
tasks from one shared team; projects and retained task creators may differ. The
review lists every selected task and project. It explains shared deletion,
linked-occurrence preservation and the device's existing Undo. Personal/shared,
nested/root, cross-team, duplicate and oversized selections are refused as a whole.
A selected task that disappears cannot be silently dropped from the action.

All source rows and member/group nonces are frozen before presentation. Preview,
confirmation and local retry require the same account/server/workspace/session,
access token and current editor permissions. Every selected row must still match
its opening contents, and selected parent cycles are refused. The complete bounded
command is checked before local application; it is never chunked or truncated.
The existing single RPC, atomic projection, durable queue and receipt-scoped
Undo/Redo remain responsible for delivery. Later access/transport conflicts retain
the complete queued group. A failed local save keeps the review and tasks intact.

The native list actions enter this review before the personal/hierarchy writers.
The single-task review remains separate, and its failed-save handling now consumes
the error inside the review instead of leaving a competing workspace alert. No
stored/wire contract or migration was added. `test-team-task-batches.mjs` can now
run its existing real PostgreSQL checks against the current workspace loader via
`TASKFOLD_TEAM_CURRENT_BATCH_REGRESSION=1`; its original fixture mode is preserved.
Exact current verification and remaining gates are in
`p2-team-selection-deletion-evidence.json`.


## Reviewed shared planning selections — 25 October 2026

Both repos now own a source-only `edit` variant of the existing atomic team-task
batch endpoint. It accepts 1–100 distinct tasks from one team, with complete frozen
source records, each task’s project/generation, one group nonce and immutable
member nonces. Native date/remove-date and priority selection actions enter an
explicit review in both apps, listing every task, project and requested change.
Cancel leaves tasks untouched. Save persists one queue entry and one linked Undo
intent; personal/shared, nested/root, cross-team and missing-member mixtures cannot
silently become a partial selection. Already-correct date choices remain members.

The service accepts priority, date/time/zone, deadline and estimate fields only.
Completion/recurrence, assignment, labels, moves, checklists and other content keep
their separate command contracts. The new batch validates the entire source under
canonical nonblocking task locks before applying any member through the existing
guarded task editor. A later member validation failure, trigger fault or busy row
rolls back every task and receipt. Live actor/session, team/setup switches, current
roles and all project archive states are checked before new writes and replay.
Replay confirms the original bounded identity-only receipt without rewinding a
later edit. No whole task body is stored in server receipt tables.

The private local command retains complete baselines and effects through restart.
Projection uses a copy and installs only the complete result. Undo/Redo keeps the
same task generations and renews group/member action identities; it refuses changed
source contents instead of overwriting another person’s work. Raw multi-PATCH
arrays cannot bypass the reviewed batch path. Existing delete/restore batches use
their original implementation and permissions.

This is source and scoped verification, not completed native acceptance. Database,
Core, build and cleanup evidence is in `p2-team-planning-batches-evidence.json`.
Installed iPhone/iPad/Mac review/Cancel/save/retry/Undo, keyboard/spoken/large-text
and live multi-actor acceptance remain required. Deadline and estimate bulk UI
entry, other shared bulk commands and the wider rank-6/Px backlog remain open.
No hosted schema, real task, provider, rollout or deferred release setting changed.
