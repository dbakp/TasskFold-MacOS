# Structural command proofs — 30 October 2026

Both clients now have typed insertion, move/reorder, reviewed deletion and receipt-certified Undo intents. This is the contract layer for native structural editing; transport, encrypted offline recovery and native controls remain to be integrated. Each repository owns its code, Xcode membership, package inputs, fixtures and tests.

## Behavior

Commands bind account/server, task generation, project and exact independent structure revision. Ordinary commands carry only their intent: moves carry no task fields; deletion carries every descendant's incarnation/revision rather than a copied subtree. Current review detects structural ABA, identity replacement, changed deleted descendants, unavailable destinations, cycles, no-op moves and invalid post-removal sibling slots. Disjoint field changes remain compatible with moves and unrelated fields remain compatible with deletion review. Server admission remains authoritative for current permissions, recipients, insertion digest and archived contents.

New-node validation preserves authored raw identities and sparse/null/empty containers, rejects duplicate normalized IDs, excessive depth/count/bytes, unsupported fields and forged history/files/completion identities. Known planning, assignment, label and reminder fields reuse the field validator; that validator's access scope is the only change to existing field command code. Existing opaque data is moved/restored by the server instead of being copied into a client command.

Receipts require the exact actor/request/root/generation/project/action, consecutive structural revisions, correct node and operation-specific incarnation semantics. Moves keep the incarnation; deletion and Undo of insertion return null; restoration uses a fresh incarnation. Undo retains its validated original request/receipt lineage and cannot Undo an Undo. Replayed proof agreement ignores only the replay marker.

Cold deletion-Undo discovery also works without the original local command: a protocol-validated actor-owned deletion metadata receipt can prepare a restore at the exact current revision, with no downloaded/reconstructed archived subtree. Missing original bodies are accepted only for discovered deletion receipts. Server-owned archive availability, original applied status and restoration authority remain server checks. Discovery is limited to 64 unique deletion entries and 64 KiB, and excludes task content. Disposal validates an exact actor/request `forgotten` response; an eventual native control must separately confirm permanent disposal before sending.

The bounded command-storage entry point validates raw counter syntax before Codable decoding, including nested original proofs and descendant version maps. Receipt, terminal-decision, discovery and disposal wire parsers similarly reject duplicate keys, fractional/exponent/rounded counter tokens, unknown keys and cross-account/request metadata. Saved commands are schema-validated and descriptions hide authored content. No task cache, durable journal or user-facing feature is changed by constructing or checking these values.

## Evidence

Each repository independently passes **146 selected Core checks**, including **29 new structural-command tests**, 13 structural-reader/adapter-contract cases, 21 existing record-reader cases and 83 existing field-command cases. Tests cover actual PostgreSQL insertion/move/deletion/restoration/closed/archive/disposal outputs from that repository's independent fixture run. The lost-journal restoration case combines real server proofs with a clearly synthetic survivor-only current read; it does not claim a real cold client/server journey.

Each repository also reruns the **220 structural database checks** with the native team field adapter applied. The test harness only adds bounded fixture export fields; no SQL or acceptance assertion changed. All owned fixtures were removed and advisors added no findings. This is a rerun of the structural portion of the preceding 630-check database stage, not 220 additional distinct checks. `database.json`, compressed official test/build logs and source-bound `verification.json` record the exact evidence.

Both complete app/test products build with the new source in their own Xcode projects. Strict app/runner signatures pass; iOS extensions, test bundle, team and app-group checks pass. No apps/devices were launched for runtime acceptance in this stage. Ordinary flags stay absent/off, no hosted migration is applied, full local migration-history parity remains unverified and prior native/spoken/large-text/lifecycle/Storage findings remain open.

The first Mac test run mixed a receipt fixture and read fixture from two independently generated accounts: two tests failed on the intended account guard. Pairing fixtures from the same report passed all 140 cases then present. A later added synthetic survivor-only read kept its old sibling index after removing siblings; the strict reader refused it. Correcting that fixture to index zero passed all 146 final cases. Neither failed run is counted as a pass, and neither required weakening a product guard. `attempts.json` retains these phases.

## Next implementation

1. Bounded scoped transport for edit/close/discovery/disposal and encrypted structural journals, including attempted/confirmed/closed states, exact retry, terminal-before-replacement and failed-proof-write recovery.
2. Current live sender leases, account/session/workspace/removal fences, archive-capacity recovery and explicit permanent-disposal confirmation.
3. Premium native insertion/move/reorder/deletion review/Undo/recovery controls, with private draft preservation, keyboard/spoken/large-text and actual Mac/iPhone/iPad lifecycle acceptance.
4. Cross-root/project adapters, legacy/adoption/authoritative migration, full-schema/Storage custody and the remaining Px scope.

User deferrals for release/distribution, remote notifications, generic older-client rollout, OAuth registrations, email-provider setup, genuine dictation and physical geofence delivery remain unchanged.

## Reproduction

```sh
python3 Scripts/check_test_storage.py --path /tmp
swift test -j 2 -Xswiftc -driver-batch-count -Xswiftc 2 --filter '(ChildTaskStructureCommandTests|ChildTaskStructureReadTests|ChildTaskRecordReadTests|ChildTaskFieldCommandTests)'
```

For database fixtures, set `TASKFOLD_FIELD_NATIVE_SQL` to this repository's native team child-field adapter migration, then run `node Scripts/Database/test-child-task-structure-commands.mjs /tmp/structure-proofs.json`. The fixture exports independent real proofs alongside its unchanged checks. Use only synthetic fixtures and preserve the storage floor.
