# Explicit older-task identity and lifecycle planning

The private database helper `plan_child_copy_mapping` now plans an explicit match between a selected saved copy and existing child-record identities. It does not save anything, authorize access, expose an RPC, add history events or enable migration. The existing app copy-selection flow still requires matching histories.

Every selected item must either bind an existing record's exact incarnation or name an unused new reference. Every stored identity must be carried forward or explicitly retired from the proposed current tree. Retirement here is a decision in a read-only plan; it does not delete a task, event or original. No automatic identity matching or winner selection is performed.

For an existing identity, the reviewer must choose the selected or recorded lifecycle. Recorded lifecycle retains the stored completion, original date/version, task/heading type, recipient and recurrence relationship while preserving the selected copy's notes and other content. Selected lifecycle retains its chosen date and state. A new identity or changed completion/type receives a fresh completion cohort at version zero, so an old completion Undo token cannot certify that proposed state. The proposed date is never changed to the planning time. Ambiguous recurrence relationships remain explicitly refused.

The planner returns the mapped tree and an explicit summary of bound/new/retired identities and completion resets. Existing raw Unicode reference spelling is retained when binding history; new identities cannot reuse canonical aliases of existing, retired or historical references. Descendants are mapped independently, including when their choices precede their parent's. Absent/null/array child shapes, unknown metadata, exact large integers and numeric scale remain in PostgreSQL JSONB.

## Verified scope

Run from this repository, after the default storage check:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-child-copy-mapping-plan.mjs
```

`verification.json` records this repository's independent disposable PostgreSQL run: 65 assertions, all passed, fixture removed. It covers exact dates/content, recorded versus selected lifecycle, explicit retirement, reversed mapping order, Unicode identity collisions, stale incarnations, cross-root records, recipient eligibility, unsupported recurrence, malformed/oversized consent and null trusted-directory entries. Full persisted root/record/history snapshots remain unchanged. The function is stable, security invoker, uses an empty search path and grants no execution to public/anonymous/authenticated/service roles. Before/after advisors report no new findings; the seven recorded baseline performance warnings belong to the minimal test fixture.

The test uses the actual database decoder, records and activity-shape validator. It is not native UI, HTTP authorization, atomic saving, productivity-credit or hosted migration acceptance. App binaries and previous native workflows were not rebuilt or rerun for this database-only addition.

## Required integration, still unfinished

1. Derive the complete current records, historical references, eligible recipients and fresh review seed inside the caller-authorized transaction. These helper inputs are trusted internal data, **not client claims**. Bind the complete choice to account/session, task generation, project, exact readable copies and current history/access fingerprint.
2. Archive every original and the exact choices before applying anything. Retain bound incarnations; create fresh incarnations only for new identities; retire current records without deleting prior events. Preserve quotas, locking, replay/status/close recovery and full rollback through caller SELECT/UPDATE policies. Keep ordinary edit bridges closed.
3. Add neutral reconciliation audit semantics. Restored completion state must not manufacture completed/reopened/created work credit or redate earlier credit. Reset boundaries need explicit handling in future completion/Undo/history calculations; merely changing the proposed completion token does not implement that policy.
4. Add durable native mapping review, preview, explicit save, Undo/reset, original export and cold/lost-reply recovery. Accept both app workflows and wider account/accessibility/privacy cases.
5. Resolve ambiguous recurrence lineage, exact editable-cache preservation and shared file/discussion/archive custody. Finish genuine shared-account and hosted migration acceptance before normal use.

The migration is committed for later deployment only. No hosted project, normal-use flag or public app route changes in this milestone. All user-deferred release/provider/device work remains deferred.
