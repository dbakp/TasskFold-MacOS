# Explicit team completion rebase

Implemented 24 October 2026, rank 6 still in progress. Both independent apps now
support an explicit new completion/reopen from the currently reviewed task. Native
team editing remains disabled. This stage does not claim hosted deployment or
native runtime/visual/accessibility/distribution acceptance.

## User choice and native transaction

The review can offer **Complete current task** when its current version is open,
or **Reopen current task** when reviewing a rejected Undo against a now-completed
version. It shows the current title, notes, status, completion time and planned
date alongside the original saved action. Completion previews the new planned date
from the current repeat rule, retains the original completion clock/zone, and keeps
existing shared occurrences. Reopening explicitly keeps the existing next task.

A preview never removes the old request. Before replacing it, the app saves the
full snapshot/queue to encrypted Recovery, then obtains durable cancellation of the
original nonce. It refreshes live capabilities and task/series/successor rows even
when an earlier observation already said cancelled. Changed visible content is
shown for another review; it is not silently adopted under the previous click.
A recorded race winner is reviewed as recorded instead of being cancelled/rebased.

After confirmation, one persisted snapshot removes the old header, installs the
current authorized rows and queues a fresh action in the same queue position.
Completion uses the atomic TeamCompletion command with a fresh request/successor
generation, current full source and current series references. An old Redo receipt
is not reused. Reopening is a guarded scoped patch of completed/completed_at against
the current generation and completion revision, with no successor deletion. Both
operations retain the existing server baselines and live-authority checks. Another
remote edit still causes a safe conflict and leaves the new action saved locally.

Unrelated queued rows/intents retain their exact projection/order. Authored or
related provisional work still blocks this path for explicit reconciliation; it
is not copied over somebody else's shared occurrence. Missing/replaced tasks,
unsupported repeat rules, inaccessible series parents, exhausted revisions and
stale queue heads cannot be rebound. Persistence failure restores the old snapshot;
the durable cancellation is recoverable. Account/workspace changes cannot commit
the prior workspace's result. Fresh history belongs only to the reviewed new action
and supports its own Undo rather than reviving the cancelled request.

## Read capabilities

The existing read RPC now returns `can_edit_current` and `can_edit_series`.
Current-task capability requires an existing authorized source, current editor/
manager role, enabled native task edits, and an active source project including
ancestor archive state. Series capability requires the exact readable parent and
current editing access to its project. Actual writes recheck all authority and
baselines. The new migration changes only the private read helper; it adds no write
endpoint, policy or enabled configuration.

Older responses without these fields remain readable/cancellable but default to
no rebase capability. Malformed flags are rejected. Native construction also checks
roles and the exact parent generation, so a positive flag cannot rebind a different
parent. A parent with only view access cannot authorize recurring completion.

## Verification and remaining work

Each repo independently passes 319 disposable database checks: 60 rebase/capability,
131 completion, 67 review and 61 cancellation checks against the new migration.
They exercise current notes/rules/files/opaque data, fresh identities, retained
clock, lost-response retries, a second stale edit, current-role/archive/config
capabilities, parent access/generation, and an explicit reopen after a completion
cycle that preserves its existing future task. Advisors show no new warnings/errors
against fixture baseline. No real user data or hosted state changes.

Each app passes 338 selected Swift tests (10 new rebase cases; includes 44 backup
tests), plus unsigned Debug app/extension builds. Native request fields/recurrence
plans are compared with independently generated SQL fixtures; the caller-owned
fresh successor UUID is normalized for that comparison. Tests cover persisted
retries, fresh Undo, default-closed/malformed capabilities, observation mismatch,
related-draft protection and independent queue preservation. Owned containers,
temporary builds and the temporary Mac registration are removed.

Still required: edited-provisional-draft and related-cohort reconciliation,
current-role workspace/cache refresh and privacy, remaining collaboration adapters,
premium organization UI and consolidated native acceptance before enabling teams.
Full Px scope and the user's release/provider/hardware deferrals remain unchanged.

Follow-up: TEAM_PROVISIONAL_DRAFTS.md adds safe parking of direct edits/comments
on an unused provisional generation after a recorded completion. Compound and
unrecorded cases remain in progress. Counts above describe the rebase stage.


## Workspace availability follow-up — 24 October

The preview and final application now use the same cached-project requirement.
A server review with current edit capability cannot offer Complete current task
or Reopen current task when its project is missing locally. The review explains
that the project must be reopened; keeping the synced task remains available.
Project removal after preview still refuses a new action without altering the
queue, while restoring the correct project enables the existing reviewed flow.

Both repositories independently pass unsigned Debug app/extension builds and
65 completion tests, including three new
regressions covering completion/reopen, unrecorded/cancelled reviews, missing or
wrong projects, preserved unrelated work and project removal during review. This
is a native preflight consistency fix; server authority checks are unchanged.
Full saved-detail reapplication, the other draft cohorts, current-role workspace
refresh/privacy and the rest of rank 6 remain in progress. Team editing stays
disabled, with no hosted deployment or runtime/visual acceptance claimed.
