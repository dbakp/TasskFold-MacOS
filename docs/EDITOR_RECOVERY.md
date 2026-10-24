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
