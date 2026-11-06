# Durable structural recovery — 30 October 2026

Both clients now save structural requests before sending, retain exact uncertain identities and recover terminal decisions without overwriting task data. This stage adds transport, encrypted journals, senders and Store ownership/cleanup factories. Native recovery/review/authoring controls and actual Store/app lifecycle acceptance remain open. Each repository owns its code, build membership and tests.

## Request and disposal lifecycle

- **Queued → attempted → confirmed.** Attempted state is durably written before the RPC. A lost reply or failed confirmation write retains the exact original UUID/body. Retry does not manufacture another insertion or deletion. Previously confirmed results are read locally without another task write.
- **Check and stop.** Resolution saves attempted state before asking the server to settle the original fingerprint. Applied results retain their receipt; closed results permanently stop that request. Only a durable closed decision permits a fresh save-only replacement, preserving the original intent/root and certified Undo lineage. Resolution works independently of current write admission.
- **Root ordering.** Earlier unsettled structural actions block later writes to the same root/generation/project, even for another child. Different roots remain independent. Terminal checks can settle later saved identities without sending task changes.
- **Durable private-Undo disposal.** Explicitly saved disposal records have queued/attempted/confirmed states and exact acknowledgements. An uncertain disposal cannot be discarded or raced with Undo. Retry only repeats the idempotent disposal RPC. Discovery can supply a deletion's metadata after local journal loss. Native UI must still confirm permanent disposal before enqueueing it; no automatic disposal is implemented.
- **Scope and removal.** Account/server/workspace/session/access leases surround asynchronous work, including failed replies, metadata discovery and disposal. Store reuses current root/project/pending-write/team admission for sends, adds absent-by-default structure write gating, supplies separately scoped encrypted files and connects real account-removal and synthetic-reset cleanup. Native runtime acceptance of those Store hooks remains pending.

## Bounded private storage and retention

One AES-GCM file per account/server uses a distinct encryption context, scoped path and authenticated associated data. The existing device-key provider, atomic writes, restrictive file permissions, backup exclusion, no-follow final-file checks and process/removal locks are reused. Account cleanup can unlink the owned file without retrieving its key. Task cache, widgets and portable task exports receive no journal data. Construction/confirmation never patches the task from a historical receipt.

The journal permits at most 64 structural entries and 64 disposal entries within 8.4 MB. Requests and Undo records form retention families. Only entirely confirmed, unprotected families may age out; a recent Undo keeps its whole family recent. Queued, attempted and stopped work remains until reviewed. A confirmed deletion remains protected while its server-held Undo content may exist: it only becomes eligible after confirmed Undo or explicit confirmed disposal. Settled history removal keeps complete Undo families together. Exhausted protected capacity refuses the new save instead of losing work.

Bounded wire validation runs before typed journal decoding. Duplicate keys, unknown record schemas, fractional/exponent/rounded structural counters, inconsistent phases, invalid receipts, cross-scope records, conflicting active Undos and concurrent Undo/disposal are refused. Validation includes nested original command/receipt proofs, deletion descendant versions, terminal outcomes and disposal acknowledgements.

## Transport

The four existing RPCs—edit, close, archive discovery and forget—use exact original request bodies, 25-second timeouts, no cache/cookies and redirect refusal. Streaming limits are 16 KiB for command/terminal/disposal transport and 64 KiB for archive discovery; proof decoders have their own tighter limits. Metadata listing therefore works above the ordinary command response limit. Service errors become bounded plain-language reasons; private diagnostics are not displayed. Live session/account/server and cancellation checks surround request success, failure and decoding.

## Verification

Each repository independently passes **271 selected Core tests**: **44 new recovery tests**, 29 structural-command proofs, 13 structural-reader/adapter-contract cases, 21 record reads, 83 field-command cases, 68 completion-command/recovery/retention cases and 13 completion-draft cases. Final compressed official XCTest logs and exact source hashes are recorded here.

The new tests cover lost send/close/disposal replies; failed attempted/proof writes; exact cold retries; same-root ordering; immutable stopped originals and save-only replacements; all live scope components; account removal during a reply; mutually exclusive Undo/disposal; protected deletion and byte/count capacity; recent Undo retention; encrypted path/AAD isolation, permissions, symlink refusal and keyless cleanup; and two journal instances sharing a coordination lock. Seventy successive actions reopen the encrypted file before each iteration and retain the outstanding deletion plus recent Undo. These are cold-file/peer journeys, not actual native-process or hosted-cloud acceptance.

Actual Backend methods run against an intercepted HTTP transport using independently captured PostgreSQL proof fixtures. Tests verify all four paths, exact bodies, no-cache/cookie policy, timeout, large metadata lists, declared/streamed limits, malformed counters/duplicate proofs, redirect refusal, sanitized reasons and held successful/error replies across account switching. No new SQL or hosted mutation is introduced, and no database suite was rerun or counted as new evidence in this client-only stage; the independently owned previous 220-check server reports supply the proof fixtures.

Both complete app/test products build, with strict app/runner signatures and iOS extension/team/app-group checks. The manifest binds production sources to the namespace-adjusted isolated build hosts. No native app or Simulator was launched for runtime acceptance in this stage, and no new test device was created. Ordinary feature flags remain absent/off. Full local migration-history parity, genuine Keychain/Store cleanup, native/spoken/large-text/lifecycle and hosted Storage/team custody acceptance remain open.

Initial client phases passed 56 and then 185 selected tests. Review before final verification corrected retention ordering to use a family's most recent acknowledgement, added atomic removal of fully settled Undo families and added cancellation checks around response decoding. The final 271-case runs include those changes. No failed product/test run is counted as a pass.

## Remaining implementation order

1. Native saved-action recovery, current-value review, explicit stop/fresh replacement and archive/disposal confirmation controls, integrated with actual Store refresh and presentation lifecycle.
2. Premium native subtree insertion, move/reorder, deletion and certified Undo controls; preserve private drafts and validate keyboard, speech, large text and real Mac/iPhone/iPad runtime/lifecycle behavior.
3. Cross-root/project adapters, legacy/adoption/authoritative migration, complete-schema/Storage custody and the remaining Px backlog.

The user's release/distribution, remote-notification delivery, generic older-client rollout, OAuth registrations, email-provider setup, genuine dictation and physical geofence-delivery deferrals remain unchanged. The broader goal remains active.

## Reproduction

```sh
python3 Scripts/check_test_storage.py --path /tmp
swift test -j 2 -Xswiftc -driver-batch-count -Xswiftc 2 --filter '(ChildTaskStructureRecoveryTests|ChildTaskStructureCommandTests|ChildTaskStructureReadTests|ChildTaskRecordReadTests|ChildTaskFieldCommandTests|ChildTaskCompletionCommandTests|ChildTaskCompletionDraftTests)'
```

Reuse the current isolated hosts/products for builds, run heavy platforms sequentially and preserve the storage floor. No real tasks or Docker volumes are part of these tests.
