# Structural client reads and native team field adapter — 30 October 2026

This stage fixes independently addressed team child-field edits and adds the strict client reader needed for structural commands. Each app owns its implementation, fixtures and tests. The full structural/offline/native feature remains unfinished.

## Implemented behavior

The team field route now applies the existing validated same-transaction preparation directly under the existing team write scope. It preserves null, absent and empty child lists and supports a small edit in a large root without passing the entire root through the older 128 KB team envelope. Current account/session, role, recipient, project, generation, projection, field-version and caller SELECT checks remain enforced. A dedicated private `child_field` ledger and reciprocal nonblocking final nonce guards prevent cross-protocol reuse and roll back late competing writers. Existing protocol-1 requests/receipts and personal edits retain their contracts. No normalization of saved task content is introduced.

`ChildTaskStructureRead` accepts only protocol 2, exact header keys and the complete existing record/tree reconstruction contract. It verifies account, root generation, project, projection, raw paths, unique identities, child-container shapes and authored order against the captured root. Version 1 remains independent. The bounded wire parser rejects duplicate keys and checks counter token syntax before floating-point decoding: fractional or exponent tokens cannot round into an accepted integer proof. This applies to headers and record revisions/order, not opaque authored metadata. Reusing the decoded dictionary avoids expanding slash-rich near-limit packets through re-encoding.

Backend uses the separate uncached, cookie-free, redirect-refusing bounded read route with the existing 25-second timeout and sanitized errors. Session/account/origin checks surround asynchronous decoding. Store rechecks current workspace/session/access/root state and returns verified data without writing tasks or private drafts. Its additional `TaskfoldChildStructureReadsEnabled` flag is absent/off in ordinary app configuration.

## Verification and limits

Each repository independently passes **630 database checks**: 58 new adapter checks plus 61 foundation, 95 field, 98 completion, 63 completion-recovery, 220 structural-command and 35 field-recovery regressions. Exact reports are alongside this document. The new tests first reproduce both old adapter refusals, then verify exact metadata/container preservation, large roots, role/session/recipient checks, rollback, exact retries, terminal decisions and actual legacy-writer race winners. All owned fixtures were removed; advisors add no findings to the minimal fixture baseline.

Each repository independently passes **142 selected Core tests**, including 13 new structure-reader/real-receipt cases, 21 existing record-read cases and selected field/completion/draft/transport regressions. Both app and test products build successfully; strict app/runner signatures pass, and iOS extension/team/app-group checks pass. `verification.json` binds these results to source hashes. Compressed final logs retain the official test/build output. The extra real adapter receipt compatibility test was added after app builds; production sources were unchanged, and the final Core run includes it.

The initial draft adapter suite stopped after 31 checks because its test helper tried to assign a PostgreSQL void result to JSONB. Correcting that probe to wrap the result in `to_jsonb` allowed all 58 checks to pass before canonical independent runs. No failed run is counted as a pass.

This is source-only verification. No hosted schema or normal feature exposure changed. Full local Supabase migration-history parity remains unverified. No current native runtime, spoken/large-text, real Storage custody or production performance acceptance is inferred from these checks.

## Next work

1. Strict structural request, receipt, Undo, archive-discovery and disposal proofs in both clients.
2. Encrypted offline structural journal, sender, terminal recovery, lifecycle/removal fences and current-value review.
3. Premium native insert/move/reorder/delete/Undo/disposal controls with draft preservation and actual Mac/iPhone/iPad accessibility/lifecycle acceptance.
4. Cross-root/project adapters, legacy/adoption/authoritative migration, full-schema/Storage custody and the remaining Px backlog.

The user's deferred release/distribution, remote notifications, generic older-client rollout, OAuth registrations, email provider, genuine dictation and physical geofence delivery remain deferred.

## Reproduction

Run `node Scripts/Database/test-child-field-team-native.mjs /tmp/native-team-fields.json` from this repository. The default loads this repository's own canonical migration. Existing database suites accept `TASKFOLD_FIELD_NATIVE_SQL` pointing to that migration, alongside their existing structural dependencies. Run the selected Swift suites with:

```sh
swift test -j 2 -Xswiftc -driver-batch-count -Xswiftc 2 --filter '(ChildTaskStructureReadTests|ChildTaskRecordReadTests|ChildTaskFieldCommandTests|ChildTaskCompletionDraftTests|ChildTaskCompletionCommandTests.test.*(Duplicate|Receipt|Transport|Redirect|Decode))'
```

Run the storage preflight before heavy checks. Supabase function/RLS and PostgreSQL lock-order/least-privilege guidance informed the implementation; historical reports remain point-in-time evidence.

## Subsequent command-proof stage

[Structural command proofs](../child-task-structure-client-proofs/README.md) now implement the request/receipt/Undo/discovery/disposal layer, including metadata-only restoration after local journal loss. Its verification is separate from this stage; scoped transport, encrypted journals and native controls remain open.
