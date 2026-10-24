# Durable team completion cancellation

Implemented 24 October 2026. Rank 6 remains in progress. Both apps own the native
code and migration independently; team editing remains disabled. No hosted
migration, real-data mutation or native runtime/visual acceptance is claimed.

## User flow

A completion review with no recorded result can now offer **Use synced task**.
The app first checks that only the original untouched projection would be removed,
then saves the full workspace and queue in the existing encrypted Recovery vault.
It asks the server to durably cancel that exact saved action. Only a confirmed
cancellation permits removing the queue entry and installing the current synced
source/next-occurrence rows. Existing server occurrences and unrelated local work
are retained. A cancelled Undo restores the synced completed task and its existing
next occurrence instead of reopening it.

Every attempt, including recovery from a lost cancellation response, rechecks live
read access and fetches current rows. An observation without a receipt is still not
a cancellation certificate. Failed transport, encryption or persistence keeps the
queue; a persisted cancellation is recoverable through Check again or an exact
repeat. Workspace/account changes cannot commit the old review. If completion won
the race, the response is recorded and the sheet asks the user to review that result
instead of claiming cancellation.

Authored source/future-task deltas, related later edits, nested batch/history
commands, task references in pinned-note intents, and separate comment/mention
outboxes block this discard path. They remain fully saved for the upcoming explicit
draft-reconciliation flow. If new work arrives during cancellation, the cancellation
remains durable but the new local work stays queued for review. An unavailable or
replacement generation cannot be silently rebound. The ordinary conflict buttons
still cannot discard these structured commands.

## Server contract

`taskfold_cancel_team_completion` accepts the original operation and full closed
body. The current read helper checks verified live Auth/session, team/config/project
access, exact actor/body HMAC and shared nonce namespace, then obtains the same nonce
lock used by completion. Read-only members may cancel their own pending intention;
this does not edit shared task content. Read pauses and revoked access remain closed.

Cancellation reserves the original nonce in `team_task_edits` and adds a private
`team_task_completion_cancellations` marker. It never creates a completion receipt,
changes a task, increments completion/write counters, or creates/deletes an
occurrence. Existing completion/lifecycle/edit/batch RPCs reject the occupied nonce
before writing. If an action already committed, cancellation returns its recorded
result without undoing it. If cancellation wins, an old request cannot later apply.
A fresh explicit user action needs a fresh nonce and still passes ordinary guards.

The marker stores only UUIDs/action metadata; actor and fingerprint come from the
existing header. RLS is enabled with all direct client/service grants revoked.
Actor removal cascades markers through the header, and team deletion purges the
cancelled headers/markers. No receipt expires into a fresh action. Both RPC layers
use empty search paths and authenticated-only execute grants. Transport is bounded,
account/backend-bound, avoids cookies/cache and refuses redirects.

## Projection correction

Review no longer replays unrelated already-optimistic task rows after replacing its
own source/successor. A complete/Undo cycle on another task therefore retains its
original counter, row and queued baselines. A recorded result with a later atomic
batch touching those identities stays queued as a cohort for dedicated review;
a two-row receipt is not used to reconstruct part of that group.

## Verification and remaining scope

Each repo independently passes 259 disposable database checks: 61 cancellation,
131 completion regressions and 67 outcome-review regressions against the new
migration. Actual lock waits cover each race winner and access loss. Tests cover
lost-response retries, interruption rollback, namespace collisions, cancelled Undo,
permission/config changes, live sessions and actor/team cleanup. Advisors have no
new warnings/errors against fixture baseline.

Each app passes 328 selected Swift tests, including 13 new cancellation/projection
cases and 44 existing backup tests, plus unsigned Debug app/extension builds. The
Recovery round trip preserves the original typed command and snapshot in encrypted
storage. Each SQL fixture is generated independently in its own repo. Owned
containers, temporary build products and the temporary Mac registration are removed.

Still required: explicit rebasing and preserving/reconciling edited provisional
work, current-role workspace/cache privacy, remaining collaboration adapters and
premium organization UI, followed by full native runtime/visual/accessibility
acceptance before team editing is enabled. Wider Px scope and user deferrals remain
unchanged; this stage does not claim the full team feature is complete.
