# Unsent editor recovery storage and review

Live sessions now connect the recovery vault to the iOS task editor, the Mac
inspector, note-formatting sheets and checklist organizers. A Store-owned session
retains full drafts beyond a view's disappearance. The iOS background transition
flushes retained checkpoints; Mac quit first tries ordinary inspector saves and
then verifies every retained checkpoint. An unwritten recovery failure refuses
termination. These are implementation statements; platform acceptance is scoped
below and does not close the full rank-6 work.

TaskEditorRecovery preserves the complete original record, draft record, labels
and extra editor state with account/backend binding, editor-session UUID and a
monotonic revision. The encrypted vault is separate from daily backup retention.
It exposes only dates/UUIDs until a user opens an entry. Older writers cannot
replace newer checkpoints; equal-revision conflicts and source identity changes
refuse replacement. The implementation verifies a staging ciphertext round trip
before atomically renaming it into place. Removal locks cover readers/writers and
key acquisition so deleted accounts cannot recreate files or keys through this
API. Malformed or unsupported originals are retained rather than overwritten.

Backups & restore lists saved task edits. Review Inbox copy opens a native preview
with title, notes, planning, checklist/file counts and explicit limits. It creates
one independent Inbox task with fresh root/child identities, clear assignments,
no shared history/project links/pins and explicit disabled reminders. Supported
planning, recurrence, checklist details and attachments are copied; remote files
can still require their original access. Unknown fields and unapplied editor
extras remain in the full encrypted original, available through Export original
edit. Original-edit JSON is not a portable workspace backup.

A stable copy ID prevents repeated recovery. Existing task collisions refuse
review, and both preview and Store.restore enforce a single insert-only Inbox
mutation, including after preview refresh. The original shared task cannot become
an update target through this path. Workspace generation/snapshot checks surround
asynchronous reading, copy planning and the final reviewed restore. Copy planning
and encryption run off the UI thread. No source edit, assignment, mention,
notification delivery, team permission or hosted service is replayed.

Per-repository evidence is p2-editor-recovery-evidence.json. Core cases cover
complete encrypted round trips, wrong account/origin/key, tampering, revision and
source fences, retention/removal, safe independent copy plans and unsupported
content. Native fixture acceptance is explicitly separate from live editor
capture: synthetic saved edits are seeded into an independently named app, then
reviewed/recovered/refused on repeat and inspected after relaunch. Mac runtime,
VoiceOver and live editor capture are not implied by builds or Simulator proofs.

Live admission checks require the captured account/workspace, source root
incarnation and project identity, current visible task/project access and an
editable destination. Team-native task writing stays disabled until its scoped
adapters/UI are accepted. Loss of access or source identity swaps the root
editing controls for a neutral recovery status without showing stale shared
content. Mac autosave and quick-entry side effects stop. Checkpoints include
unsubmitted comment/subtask text, note pin choices and parsing/reference choices.
Nested formatting/checklist sheets register their own private drafts so parent
teardown cannot silently discard their changes.

Checkpoint writes coalesce behind one background worker per session. Increasing
revisions prevent an older write replacing a later one. Successful saves and
explicit discards close their session; an in-process closure fence under the
vault lock prevents an already queued writer recreating the archive afterward.
Reverting and editing again uses a fresh session. Account removal fences still
precede key/file access; retained sessions retire after explicit account removal.

Acceptance is recorded in p2-live-editor-evidence.json. Core coverage includes
rapid edits plus synchronous quit flush, closing ahead of an asynchronous writer,
unavailable encryption keys retaining the draft, and account removal before key
acquisition. Full rank 6 and the full Px objective remain active: the wider live
role/account/child-editor acceptance matrix, remaining adapters and premium
organization UI still require work. Builds and core tests do not establish Mac
runtime, human VoiceOver or real service role-change acceptance. Existing release,
provider and hardware deferrals stay unchanged.

Verification: 115 relevant core tests pass in this repository; the independent
Debug app/extension build passes. Mac runtime and spoken acceptance remain open.


## Nested editor source custody — 24 October

TaskEditorSourceContext separates the persisted access root from the record being
edited. Nested note formatting and checklist organizers now receive the complete
edited record plus its actual root ID. A recovered child retains its own title,
notes and checklist, rather than the root title/notes or unrelated siblings.
Only root/path/generation/project identifiers enter the recovery source identity.

Admission rechecks the captured root generation, owner and project, and resolves
the exact captured child path. Ordinary text updates and sibling reordering are
allowed. Missing/moved paths, ambiguous child UUIDs and changed child creation or
generation stamps refuse continuation. A new child cannot retarget a newly
persisted matching UUID. Root access checks remain separate from these identity
checks; no new team write adapter or organization permission is enabled.

Core and native scope are recorded in p2-editor-context-evidence.json. The broader
account/role transition matrix, additional draft cohorts, native Mac/VoiceOver
acceptance, remaining adapters and premium organization UI remain in progress.
Existing user deferrals remain unchanged; the full Px goal is still active.

Nested organizers capture their workspace at the opening action, pass it into
child details, and refuse stale admission before creating a recovery session.
Formatting likewise requires its captured workspace before session creation.
Mac Complete and confirmed Delete recheck editor admission at action dispatch.

Verification: 119 relevant core tests pass independently in each repository,
with successful Debug app/extension builds. Mac runtime/VoiceOver and the broader
role/account matrix remain open; Simulator acceptance is not Mac runtime proof.


## Editor opening admission and queued capture — 24 October, rank 6 in progress

Editor requests now capture their workspace incarnation and source root at the
opening action. Existing tasks require a matching stored source; deleted or
replaced records cannot silently become new tasks. New tasks require their
creating account and an unused identity. Nested opening values retain the
parent's workspace/root rather than resolving them again in another account.
Calendar, list, widget/notification, Inbox-review, pinned-note and nested editor
routes use the captured admission. Current Store write permissions are checked
separately before controls or mutation paths are admitted.

Quick Add → More checkpoints the authored task before deferred presentation. Its
Store-owned session and device vault remain bound to the original account while
the sheet is queued. A blocked presentation can preserve/close that original
checkpoint without writing in the current account. An unchanged, unsaved new
task is still an authored draft; it no longer disappears merely because it was
unchanged since More. Successful Save or explicit discard retires its session.
Private preservation is allowed while ordinary editing is paused (including an
unreadable cache or sign-out in progress); removal fences still prevent account
recreation. Recovery status directs the user to the original workspace.

See p2-editor-admission-evidence.json for core/build and synthetic native scope.
The test identities are local-only, not evidence of live cloud Auth, service role
transitions or Mac runtime/VoiceOver. Those checks, remaining draft cohorts,
scoped adapters and premium organization UI remain in progress. The ranked
backlog and every explicit user deferral remain intact; full Px is not complete.

Inbox-review and pinned-note edit sheets carry the record and admission in one
TaskEditorOpening item, so deferred presentation cannot combine independently
updated state values. Root iOS requests also carry their handoff session in the
same item. This is separate from current service authorization.

Verification: 124 relevant core tests pass independently in each repository;
Debug app/extension builds pass. Mac native runtime, real cloud transitions
and VoiceOver remain open. Simulator proofs do not establish those gates.
