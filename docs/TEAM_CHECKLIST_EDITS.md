# Team checklist editing — disabled candidate, 24 October 2026

The guarded team task editor now supports full nested checklist edits, ordering,
completion, deletion and receipt-bound Undo. This stage does not enable native
team editing. The existing live-role/task-generation/feature gates remain closed
by default, and direct team table and service writes remain closed.

## Shared editing contract

The existing `taskfold_edit_team_task` endpoint accepts `subtasks`, with its
original tree in the frozen baseline. Trees contain at most 1,000 unique item IDs,
at most 24 levels and must fit the existing 128 KB request bound. Native code
validates the same bounds before queueing. Edits to independent existing items
merge. A concurrent structure change requires review; an old layout never silently
removes another person's new work. Existing unknown fields, inline discussions,
attachments and reminder extensions survive supported edits. They cannot be forged
or rewritten through checklist editing. This does not introduce audio comments or
independent child-task records.

Every item has `taskfold_completion_v1: {epoch, version}`. The version changes on a
completion toggle; restoring a deleted item chooses a fresh epoch. A stale toggle
cannot complete an item that was completed/reopened in the meantime. Old text,
layout and deletion intents cannot target a restored incarnation. Unrelated
current completion changes remain compatible with text edits. Completion dates
are stamped by the server, and a later offline toggle can follow the optimistic
client timestamp of an earlier accepted action without a false conflict.

The native model prepares stable identities before persistence. A transport retry
keeps its nonce and payload. Preparation, account/server/generation guards and
Undo/Redo context are independently owned by each app. Malformed or conflicting
changes remain saved locally; there is no personal-write fallback.

## Deletion and recovery

The private `team_checklist_deleted_nodes` table records the latest deletion of an
item in a specific task generation. It stores UUIDs, an HMAC, the prior completion
date/epoch and consumption state, without discussion text, attachment URLs or task
content. Tables have RLS and no client/service grants. No public recovery reader
or write privilege is introduced.

An inverse carries `checklist_restore_from`, the exact original task-edit request.
The server verifies the same actor, team, task and generation, the latest deletion,
the keyed digest of protected fields, completion state and original reminder choices,
and a fresh request-bound
epoch. A later deletion supersedes earlier recovery authority. Another actor, a
forged history payload, an old epoch or a reused nonce cannot restore it. Node
IDs cannot be reused to bypass a tombstone. Successful recovery consumes that
individual deletion and preserves the original server completion date, even when
the device retained an optimistic timestamp. Role loss or expiry of the Auth
session still denies the action. Actor removal erases its existing request receipts;
team deletion purges checklist recovery metadata.

Private/unsupported reminder choices and portable extension fields also recover
through that original-content certificate. An Undo cannot invent or alter those
choices. Normal edits keep the existing portable-reminder validation. No reminder
delivery or device permission is enabled by recovery.

Epochs for recovered items use the existing stable SHA-256 UUID formatter over
`com.taskfold.recurrence.v1|team-checklist:<request UUID>|<item ID>`. Native and SQL
calculations are checked against the actual SQL-produced recovery request/reply.
The nonce is part of the existing durable team request namespace, so an old
recovery identity cannot be applied again after another deletion.

Whole-task Undo remains separate: its new root generation fences old child
callbacks, and the entire certified checklist must survive unchanged. Native
preparation explicitly preserves that recovery payload rather than resetting its
nested metadata. Successor-task children discard the preceding occurrence's
completion tag before obtaining their own identity. Atomic root completion plus
successor generation remains the next adapter; this stage does not claim it.

## Verification and remaining work

Each independent repo passes **452 real PostgreSQL checks**: 221 checklist/planning/
edit checks, 89 lifecycle, 72 linked-batch and 70 discussion regressions against the
new migration. Checks cover rich nested recovery, lost responses, actor removal,
team deletion, completion cycles, stale text/delete callbacks, optimistic timestamps,
concurrent independent edits/layout conflicts, invalid assignments and bounds,
private access and rollback of task/ledger/receipt after a forced write failure.
Whole-task deletion/restoration with versioned nested history is also exercised.
Official advisors show no new warnings/errors; known dependency-fixture init-plan
warnings remain recorded. Owned database containers are removed.

Each repo passes **196 selected Swift tests** (14 new checklist cases) using its
independently generated server fixture. These cover persistence, identity/version
prediction, Undo, actual SQL recovery identity equality, whole-task recovery,
malformed bounds, personal regression and successor child reset. Both unsigned
Debug app and embedded-extension builds pass; each Xcode main target and SwiftPM
package owns the new source. Owned derived output and the temporary Mac registration
are removed after verification. Reports are `p2-team-checklist-*-evidence.json` and
`p2-team-checklist-{lifecycle,batch,conversation}-regression.json`; the main database
report is `p2-team-checklist-evidence.json`.

The task-edit script runs the new checks with all preceding regression switches
and `TASKFOLD_TEAM_CHECKLIST_REGRESSION=1`. The lifecycle/batch/discussion scripts
also accept the checklist switch after their preceding schema layers are selected.
No hosted mutation, enabled team UI, native runtime acceptance, remote delivery or
distribution verification is claimed.

Next: atomic recurring completion/Undo, comment/mention/file/service boundaries,
current-role workspace refresh and premium native team organization/review UI,
then full privacy/recovery acceptance. Full Px, Watch/Wear OS and every existing
user deferral retain scope.
