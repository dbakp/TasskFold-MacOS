# Team task lifecycle — disabled candidate, 24 October 2026

## Behavior and authority

Both apps independently own `taskfold_team_task_lifecycle` and the matching native
queue adapter. Fresh creation supports task planning, labels, nested checklists,
portable reminders, section selection, current editor assignments and recurrence
parent references with an explicit parent generation. New content cannot forge
another author, conversation history, attachments or completion revisions.
Existing deleted/personal/team UUIDs require reviewed restoration, not creation.

Delete requires the original whole typed task and generation. It checks current
live session/membership, editor/manager access, active team, setup switches and
project archive state under locks. Another person's new edit makes the deletion
conflict rather than disappear. Later recurrence occurrences are retained and
detached; foreign workspace links make the action fail atomically.

Undo references the actor's actual successful deletion request, proves the
original task content with a keyed server digest, and uses a fresh generation.
The receipt is consumed once. Old create/delete/restore retries cannot resurrect
or remove the replacement. Author UUIDs survive account removal. Recipients who
have lost access become unassigned, matching what Auth cleanup would have done
had the row remained live. Unchanged, still-editable recurrence children can be
reattached; changed or inaccessible children keep their current state.

Operation identities share the existing task-edit receipt namespace. UUIDs,
request digests, restoration digests and detached-child digests are retained;
receipts contain no task text. Authenticated roles cannot access scope/receipt
or link tables. They have RLS and no client grants. Narrow operation scopes admit
only the exact insert/delete or exact parent-link update; unrelated direct table,
project, section and comment writes remain closed. Personal assignment rules
retain their behavior. The existing disabled edit switch also gates lifecycle.

Older unscoped guarded patch/delete RPCs now return a team review error instead
of silently acknowledging an RLS-hidden task. Current clients recognize that
error and retain the queue instead of treating it as unavailable-project cleanup.
This narrow team boundary does not complete the deferred general upgrade rollout.

## Native behavior

The persisted optional scope now includes restoration request and repeat-parent
generation metadata. It remains compatible with older queues. Only explicit
scoped intents use the lifecycle endpoint; there is no service/personal fallback.
The sender binds account, server and request identity, refuses redirects/cache/
cookies, caps responses and validates all acknowledgement identities. A retry of
a creation already removed later can acknowledge its original effect without
inserting the task again. History actions choose a new nonce before constructing
Undo, so the restoration references the nonce actually persisted and sent.

Local root deletion retains/detaches occurrences. A combined root-and-occurrence
delete selection is held for review pending the atomic batch adapter, preventing
partial recurrence Undo. The editor/role catalog remains read-only and native
team UI is not enabled by this stage.

## Evidence and remaining acceptance

Each repository independently passes 89 real PostgreSQL lifecycle checks and 70
existing edit checks against the new lifecycle migration. Cases cover rich
creation, assignment and nested permissions, private/cross-workspace denial,
retained authors, exact deletion, consumed Undo, child preservation/reattachment,
non-resurrection, conversation cascade protection, legacy queue review and two
transaction overlaps (role revocation and newer task content while waiting).
Official advisors report no errors or additional warnings; dependency-fixture
init-plan warnings are recorded. Every owned container was removed.

Each repository passes 137 selected SwiftPM tests: 10 new lifecycle tests and
127 existing role/edit/automation/email/completion/generation/deletion/sharing/
recovery checks, with no failures/skips. SQL-produced fixtures are independent.
Evidence identifies the exact source and resource hashes. Both Debug app schemes
also build unsigned for generic macOS/iOS Simulator, including Store and embedded
extensions. This proves compilation, not interactive runtime or distribution.

Shared conversations are deliberately protected from physical deletion until
conversation recovery is implemented. Atomic linked-delete batches, broader
structural/assignment/reminder editing, role/workspace refresh, premium native
team/folder/admin/invitation UI, service/email/file boundaries and backup/activity/
widget acceptance remain open. No hosted deployment, real account write or team
UI acceptance is claimed. Watch/Wear OS and wider Px remain in scope; remote push,
old-client rollout, signing/distribution, calendar registrations, physical location
delivery and inbound email provider/domain configuration remain deferred by the user.
