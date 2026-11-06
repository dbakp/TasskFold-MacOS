# Repair contracts, transport and saved-request recovery

30 October 2026. **Client components and app compilation are checked. Store admission and native repair controls are not implemented yet.** The broader migration checkpoint remains To build, with normal flags and hosted schema unchanged.

## Implemented and checked

- [x] Typed five-operation requests bound to the exact account, server, root generation, project/workspace, source review and repair digest. Only explicit operations enter the saved request; original and proposed trees never pass through the app's floating-point JSON model.
- [x] Capture both opaque siblings in one syntax pass, keeping arbitrary numeric precision and distinct Unicode keys. Refuse duplicate keys, malformed syntax, missing fields, unknown steps, invalid paths and unsigned-counter spelling such as `0.0`, `1e0` or negative zero. Fix the shared syntax checker's missing validation of scalar array elements, while preserving existing callers.
- [x] Retain the exact complete original as raw data and verify its length and SHA-256 against the confirmed receipt before exposing it for export. Refuse changed bytes, wrong request/archive/context, closed requests and damaged originals. The actual SQL fixture's original exceeds the ordinary receipt limit, proving the separate original-delivery path.
- [x] Add bounded, no-store/no-cookie, redirect-refusing HTTPS routes: 4.3 MB for previews, 16 KiB for decisions and 8.1 MB for original envelopes. Stream and decode larger bodies away from the main actor. Recheck session/account/server identity around network and decode steps, sanitize server errors, and reject Unknown as proof of Send.
- [x] Add a separate account/server-bound encrypted journal and recovery model. Save the exact request before attempting a send, retain attempted identities after lost replies, recover through Check without sending again, and keep Unknown pending until an explicit terminal decision. Prevent duplicate pending repairs for one root and conflicting confirmations.
- [x] Exercise real encrypted-file round trips, wrong-key refusal without erasing the file, account-removal tombstones, failed writes before Send, after-write recovery from the reloaded proof, account departure, private admission refusal and Check/Close when sending is unavailable. These are component proofs, not actual Store/Keychain/window acceptance.
- [x] Independently capture real PostgreSQL review/preview/applied/closed/unknown/original wire fixtures in each repository, then pass **590 selected Core checks per repo, including 25 new repair cases**. Native Mac and iOS app/test targets build and pass strict development signature checks. No native repair interface or spoken flow was exercised in this phase.

## Original-history permission correction

While connecting export, the prior service was found to archive every child-history row for a root and check only the current root's access before delivery. Historical events can belong to an older private project that the caller cannot read. The service is disabled and undeployed; this correction precedes native exposure.

- [x] Mirror the existing permissive and restrictive history policy predicates inside private admission. A preview with unreadable prior history reports `history_custody`, disables saving and leaves the source untouched.
- [x] Recheck every archived history row on original delivery against its current record and read permission. A revoked historical grant, removed event or anonymized actor cannot be exposed from the older archive. Keep the original intact rather than silently filtering or re-hashing it.
- [x] Also enforce actual caller RLS in the public wrapper. Revoke client execution of the superseded implementation so calling the granted private entry cannot bypass the check.
- [x] Compare the explicit guard with actual authenticated RLS before and after revoking only a historical project's grant, while the current task remains readable. Verify restored genuine access can deliver the same original, and actor redaction blocks export while contentless confirmation remains available.

Each repo passes **283 actual database checks, including the previous 256 repair regression checks**. No new advisor findings; all owned SQL fixtures are removed. These totals are not sums of repeated development runs.

## Still required

- [ ] Register the journal factory and account cleanup in Store; include repair intents in cross-journal/private-editor admission. Preserve unreadable-workspace write refusal, pending edits, snapshots and account/window access fences in the actual app.
- [ ] Add premium guided before/after operation controls, saved-request recovery and original-file delivery, with actual Mac, iPhone/iPad, largest-text, cancellation, cold-launch and spoken acceptance.
- [ ] Verify genuine PostgREST/HTTP original serialization and export/readback. Current transport tests use URLProtocol plus exact database JSONB responses. Original verification intentionally refuses altered serialization; it does not normalize and trust a changed file.
- [ ] Finish explicit indexed-copy reconciliation and history/attachment/discussion identity mapping. The permission fix does not authorize rewriting existing identities or dropping saved copies.
- [ ] Finish normal editable-cache support for opaque values, larger-work repair, bounded preflight before aggregating extensive historical originals, reviewed original-storage cleanup and safe restoration/Undo. The current 8 MB service admission remains a refusal path for larger originals; broader workload behavior is not accepted.
- [ ] Finish real shared-client gates, account/secure-storage/window/background/concurrent/larger-library acceptance. Keep all user-deferred rollout, release, provider and real-device work paused.

## Scope and protocol notes

`ChildTaskRepairChange`, `Preview`, `Command`, `Result` and `Original` keep opaque values separate from small validated metadata. A command can only be built from an eligible, valid matching preview; rehydration validates the complete small body again. Candidate metadata and partial discovery rows are never installed into Snapshot. The source comparison allows only whitespace outside strings; it never rounds numbers, normalizes authored strings or merges object keys.

`ChildTaskRepairState` owns its own file, encryption context and account/server key. It allows at most 64 entries, one pending repair per root, and 5 MB of validated state. It uses the existing authenticated encryption and process/account-removal locks. Terminal results are revalidated against their command on load; the model cannot turn unreadable data or Unknown into an applied decision. The model's mandatory admission and current-review callbacks still need real Store wiring before use.

Backend captures the session and server before dispatch and checks them after response/decode, including late success and error paths. Original delivery requires an already validated applied proof and remains separately authorized on the server. Original SHA-256 verification covers the canonical JSONB value bytes, separately from its outer HTTP envelope. No automatic restoration or generic backup-import compatibility is implied.

Opaque syntax is bounded to 512 levels; ordinary metadata retains its 128-level limit. This permits older raw trees to be reviewed/exported without relaxing normal editable payload validation. A valid proposed tree still requires at most 1,000 nodes and 24 task levels. Larger/unsupported work remains explicit rather than partially imported.

The new SQL history guard mirrors the current policies and the public original wrapper also queries the authoritative RLS-protected table. Future history-policy/schema changes need corresponding regression review; immutable original delivery deliberately refuses a historical row whose current representation has changed.

## Evidence

`verification.json` binds current source and evidence. `sql-history-access.json` includes every named service/privacy check. `fixture-capture.json` records independent producer results; the raw replies and manifest are owned under `TaskfoldTests/Fixtures/child-repair-*-v1.json`. `core-final.log.gz` is the final 590-test phase with those exact fixtures; `core-source.json` binds files before native compilation. Build logs/signature checks verify compilation, not native workflow acceptance.

Development testing first exposed a fixture compile issue and then the array-position validation gap. The final shared parser and counter regressions cover the fix. Earlier focused phases are superseded; their test totals are not additional coverage.

The full local Supabase stack still cannot connect, so migration-history/full-stack verification remains unavailable. Only owned synthetic SQL/runtime data is used; hosted services, real tasks, app windows and Simulators are untouched. No new dependency is introduced between repositories.

A final whitespace check removed one trailing blank line after testing. `formatting-only.json` binds the compiled/tested source to the current file and proves the only change is the end-of-file newline; test and native source manifests retain their original hashes.
