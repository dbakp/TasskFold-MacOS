# Unsent editor recovery storage and review

This stage provides the shared recovery mechanism for the next live-editor access
work. It does **not** yet capture ordinary iOS editor changes or Mac inspector
changes automatically. Live invalidation, pending-save handoff, quit protection,
child-editor integration and failure acceptance remain in progress.

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

Full rank 6 and the full Px objective remain active. Ordinary editor/inspector
admission and durable handoff are next, followed by remaining draft cohorts,
adapters and premium organization UI/acceptance. Existing release, provider and
hardware deferrals stay unchanged.

Verification: 111 relevant core tests pass in this repository, with a successful
Debug app/extension build. Mac runtime and VoiceOver acceptance remain open.
Live editor capture/invalidation and inspector autosave handoff remain unfinished.
