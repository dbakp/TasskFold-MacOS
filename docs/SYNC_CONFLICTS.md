# Reviewed sync edits

Both native apps own their guarded task transport and review screen independently. The existing authenticated `taskfold_patch_task` RPC compares each changed field with the queued baseline under a row lock. It merges independent fields and identifiable comment/subtask items. Overlapping changes pause the durable queue instead of replacing the other edit. The deployed function is `SECURITY INVOKER`; existing row access rules apply. The original field-merge rollout needed no schema change; the later completion-cycle guard adds the server-owned revision described below.

## Review choices

On iPhone, **Review sync edit** appears above the workspace when an overlap pauses sync. Mac offers **Review** in the sync footer. Each review shows My edit and Synced version for the affected fields.

- **Keep my edit** rebases the reviewed values on the fetched server version, keeping independent collection edits where the original baseline is available.
- **Use synced version** drops this queued edit, then replays later offline edits to the task. It does not discard later queued work or changes to other tasks.
- **Later** closes the review and leaves sync paused; the edit remains saved on this device.

The resolution and rebased queue are persisted before sync resumes. Save failure retains the original snapshot and review. Undo history is cleared after a successful resolution so an earlier inverse cannot remove independent server work. A new overlapping edit during review can pause again; choosing a version is not permission to overwrite all future changes.

Reviews identify the exact queued mutation. Stale/mismatched requests cannot resolve a different task or edit. Account changes clear the review. Conflict detection captures the request that failed instead of assuming the first queued edit is still that request after an asynchronous fetch.

Older queues may lack a baseline or individual baseline fields. Those edits require explicit review before any update is sent. The review explains that Keep my edit uses the shown values in full, including comments/subtasks in the affected fields; automatic collection merging cannot reconstruct an unknown original state. An intentional clear remains a clear after that choice. New task edits capture all affected baselines normally.

## Verification

`CollaborationTests.swift` covers reference identity, nested merge behavior, reviewed versus later queued edits, stale/mismatched requests, durable encoding, old-baseline clearing, RPC confirmation and rejection of unknown-baseline transport. `NativeConflictIntegrationTests.swift` is an opt-in live test of two native Backend instances with separately authenticated URLSessions against a disposable account. It exercises independent title/deadline edits, independent comments, retry deduplication, same-field rejection, persisted resolution/rebase and a second conflict when the server changes during review. It deletes the task it creates. The operator must revoke/delete the disposable account afterward.

Provide a private JSON fixture with `url`, public `key`, `email`, `password` and `userID` through `TASKFOLD_CONFLICT_LIVE_FIXTURE`. Only `taskfold-conflict-…@example.invalid` accounts with UUID owner IDs are accepted. Sessions are retained in memory; the test supplies a no-op Keychain persistence closure. Do not commit the fixture. Without it the integration test explicitly skips. Live evidence and native user walks are recorded in each platform's validation record.

The live backend test is not proof of two simultaneously running native UI apps, physical devices, OS background replay, shared-project access revocation or deleted-task recovery. Those remain broader P0 acceptance checks. Clients predating this rollout can still send legacy direct updates; this source change does not upgrade an already distributed binary. No new app release is implied.

## Completion and reopen cycles

A task’s `completion_version` advances when its completion state or completion instant changes. The server owns this value, starting at zero at migration/creation. Native completion/reopen queues capture it in the baseline; ordinary title/notes edits do not advance it. A stale completion/reopen pauses even if the task’s visible state returned to the same values after an intervening cycle. An immediately following revision with the exact desired completion values can acknowledge a lost-response retry. Later matching cycles still conflict. Explicit completion instants are preserved, while older clients that omit a timestamp keep the server-time default.

Keep my edit rebases the completion revision and the known later offline completion chain. Use synced version cancels an unedited, unsent recurring successor if the synced root is open. Later edited successor work is retained as an independent task/series, including future metadata and pending edits. A remotely completed root retains its create-only successor request. Server acknowledgement saves the confirmed row and replays later work rather than replacing it with the earlier response. Create-only queue replay never overwrites an existing remote row.

Older native completions without revision baselines require review before making an update request. The new client does not upgrade the safety behavior of already distributed binaries that still make legacy direct writes. The live native fixture now also exercises an unseen complete/reopen cycle, reviewed retry, preserved completion time and a later cycle ending with the same visible completion time.


Task editor saves use the revision from the original form baseline when changing completion. A remote complete/reopen cycle during an open editor cannot become an implicitly approved newer baseline. The shorter Use synced action remains readable at maximum text size; the iPhone walkthrough verifies the complete comparison values are above its fixed action area after scrolling.


## Account-scoped transport and Focus

Sync captures its workspace account for each queue run. Backend sends reject a stale account before HTTP, retain account/session-generation guards across response awaits and 401 retries, and prevent joined token refreshes from restoring an older sign-in. `AccountTransportTests.swift` exercises late 401, stale shared-task/Focus transport and joined-refresh races through held responses. These deterministic regressions do not replace native paired/offline account-switch acceptance.

Focus has its own revision/action guarded slot and review: [Focus sessions](FOCUS_SESSIONS.md). Use synced removes the dependent Focus command chain; Keep this device rebases its final desired state while retaining unrelated queued task edits. Timer commands are excluded from ordinary task Undo history.
