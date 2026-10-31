# Atomic mixed completion: server candidate

This disabled candidate completes or reopens selected parent tasks and subtasks in one database transaction. It is a server milestone in the wider independent-child migration, which remains **To build**. It does not enable mixed selection in either app.

The request retains observations for every selected row, including rows already in the requested state. Only changed rows become write members. Current identity, completion state, editing authority, active project, source size and required hierarchy state are checked before any write. Recurring parent sources bind their complete content and separate series-parent identity; ordinary parents allow unrelated edits.

Parent changes run before child changes so a new recurring occurrence is copied from the captured source. Successors retain exact opaque content, use fresh child identities/completion cohorts and filter unavailable assignees only in the new copy. Existing occurrences are preserved; retired occurrences are not recreated. The entire group rolls back on stale state, lost access, busy resources, a later component failure or a size/quota refusal.

Immutable confirmations preserve caller order. Retrying the identical request recovers its original result without applying it again. A metadata-only close reserves every unused member identity and permanently prevents that original group from applying. Existing single/child-group APIs cannot adopt a mixed member or individually undo one certified member. New unrelated actions remain possible. Recovery requires a live account/session but can resolve known outcomes with write flags paused or source tasks gone.

The separate `mixed_completion_writes_enabled` flag defaults to false. Enabling the previously introduced parent-read flag cannot enable writing. Private ledgers have RLS and no direct client/service-role table grants. Public entry points are invoker wrappers around an authenticated, explicitly checked private executor. No hosted migration or configuration is applied here.

## Verification

Each repository owns its migration, dependency loader and tests. `verification.json` records exact source hashes, accepted checks, advisor comparisons, fixture cleanup and earlier findings. Existing suites can opt into the complete upgraded schema using `TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE=1`; normal suite setup remains available. Upgrade reads do not replace the earlier client wire fixture.

Run the storage guard first, then run database suites sequentially:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-mixed-task-completion.mjs /tmp/taskfold-mixed-result.json
TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE=1 node Scripts/Database/test-child-task-completion.mjs /tmp/taskfold-mixed-single-regression.json
TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE=1 node Scripts/Database/test-child-completion-batches.mjs /tmp/taskfold-mixed-batch-regression.json
TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE=1 node Scripts/Database/test-completion-selection-roots.mjs /tmp/taskfold-mixed-read-regression.json
```

The runtime uses labeled, disposable PostgreSQL containers with memory-backed data and no real tasks. Tests compare exact large numbers and Unicode keys inside PostgreSQL rather than relying on JavaScript numeric round trips. A separate 1,000-child stress fixture returned no parseable outcome around the runner’s query window and remains unaccepted. The final budget case uses 100 children per root and larger source text to exercise the same aggregate copy limit. These checks are not native UI, performance, release or full-product acceptance.

## Still required

Typed mixed write/confirmation transport, encrypted saved group recovery, cross-journal admission and account cleanup, whole-selection certified Undo, native list/review/feedback integration and Mac/iPhone/iPad lifecycle acceptance. Full Redo/history, indexed mapping, shared file/discussion custody and broader migration acceptance remain separate open work. Existing user deferrals remain unchanged.
