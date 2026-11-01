# Reviewed history mapping: transactions and reading

The existing saved-copy API now supports an explicit identity/lifecycle mapping when choosing a complete saved copy. This is a server and core-history milestone. **Native mapping controls, durable mapped reviews and original decoding are still unfinished.** The current app flow continues to support only copies whose identities and lifecycle agree. No hosted deployment or normal-use enablement occurred.

## Saving a reviewed mapping

The server derives current records, historical references and eligible recipients from the readable task/project/workspace; the client sends choices, not a replacement task tree or a trusted recipient directory. Review binds the complete choices, exact saved copies and history to a fingerprint. Stale incarnations, duplicate/reused historical references, incomplete retirement decisions and unsupported recurrence lineage are refused. Recipient Auth, membership and grant rows are locked without waiting after the root lock, preventing eligibility races without reversing deletion lock order.

Every original task, projection, record, authority and both history ledgers is archived before staging. Bound records retain their incarnations; explicitly new identities receive fresh incarnations. Retirement removes only current records, preserving their original records in the archive and all prior events in their original ledgers. Exact unknown metadata, large numbers, numeric scale, dates and child-container shapes remain in PostgreSQL JSONB.

The actual mirror update still runs through the caller's SELECT/UPDATE policies. A private transaction proof binds task generation, actor, request, archive and exact original/proposed bytes. The activity trigger consumes that proof exactly once; confirmation removes it. Record, revision, audit, policy, original-delivery or confirmation failures roll back the entire operation. The existing actor/session, nonce, replay/check/close, workspace custody and storage budgets remain. Only a strictly mapped choice gets the larger bounded metadata allowance; ordinary repair limits remain unchanged.

## Honest completion history

Mapping emits one version-4 `reconciled` audit event, with no created/completed/reopened work flags or redated work. Its context lists the affected completion boundaries and retired subjects and binds the archived request. The existing versioned `order_context` column carries this new version's context: adding a column would have changed the exact JSON representation of already archived historical rows. Versions 1–3 keep their previous contracts and cannot claim the new kind.

Lifecycle reset compares the selected result against **both** stored records and the last observable root, including completion identity/epoch, counter, date, type and productive scope. Equal counters/dates with different epochs still reset. Earlier events stay byte-for-byte intact. The core reader archives observed genuine credit at its original date, actor and project, then starts a new boundary without earning credit for restored completed state. Subsequent real completion can earn new credit; its later reopen cannot erase the archived older work. Unchanged lifecycle keeps normal completion correction behavior. Retired subjects keep their genuine historical credit.

The normal history caption is “Saved copies reconciled,” with a guarded route to the current root. A backup check also exposed a compatibility bug: backup validation rejected the supported child-history field/order recording-start dates. It now uses the same strict child-epoch contract as the reader, while retaining rejection of unknown fields and invalid dates. Root-history epoch validation is unchanged.

## Evidence and reproduction

This repository owns and runs all inputs independently:

```sh
python3 Scripts/check_test_storage.py --path /tmp
TASKFOLD_MAPPING_CLIENT_FIXTURE=TaskfoldTests/Fixtures/child-copy-reconciliation-v1.json \
  node Scripts/Database/test-child-copy-mapping-apply.mjs
Scripts/test_core.sh --filter 'ChildCopyReconciliationHistoryTests|TaskNodeActivityTests|TaskOrderActivityTests|ChildTaskTransferHistoryTests|BackupTests'
node Scripts/Database/test-child-copy-mapping-regressions.mjs
```

- `verification.json`: 77 new real PostgreSQL assertions: default gate, current eligibility, exact originals and incarnations, neutral events, lifecycle/epoch boundaries, retry/close/recovery, caller UPDATE/history SELECT policies, staged/audit failure rollback, team editor/viewer custody, same-root updates, exact numeric metadata and a valid request exceeding the old 70 KB bound with 402 records. All owned fixtures are removed; advisors show no new findings over the recorded minimal-fixture baseline.
- `regressions.json`: 133 established saved-copy assertions and 332 ordinary/duplicate-repair assertions with the current migration installed, in separate sequential owned fixtures. Their source digests bind the tested migration. The runner assembles each chain from this repository's files; it never reads a sibling repo.
- `client-verification.json`: 144 passing core tests, including ten new cases consuming this repository's actual SQL histories. They check restored versus earned credit, retirement, later completion/reopen, earlier-credit preservation, generation fencing, malformed/future metadata, captions/current-root routing, exact backup round-trip and strict epoch rejection.

These are database and core-model tests, not native app, HTTP delivery, genuine-account or hosted acceptance. App binaries were not rebuilt or installed for this milestone. Existing native evidence remains in its original scope.

## Still required

- Typed native identity/lifecycle choices, explicit recipient/recurrence decisions, durable drafts, preview/save confirmation and exact complete mapped-original decoding/export.
- Native Undo/reset, lost-reply recovery, cold return and account/window/privacy/accessibility acceptance in both apps. More complex ambiguous recurrence/recipient histories remain to resolve.
- Exact editable caches, shared files/discussions and archive discovery/custody, plus genuine shared-account and hosted migration acceptance. Remaining Mac workflows and wider library tests are separate.

`mapping_reconciliation_enabled` defaults false in addition to the existing copy/adoption/repair gates. The normal client flags remain absent/effectively false. All user-deferred rollout, distribution, provider and device work remains deferred.
