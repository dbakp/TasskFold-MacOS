# Reviewed repair saving and original custody

30 October 2026. **Disabled server candidate. Native repair controls and client recovery are still to build.** This follow-up makes the five-operation preview actionable through an explicit gated service; it does not complete the older-work migration checkpoint.

## Implemented and verified

- [x] Archive the complete original root and its original child history **before** updating the task. Preserve the SQL-null marker and exact JSONB values, including unknown fields, large numbers and distinct Unicode keys. A test-only BEFORE UPDATE trigger independently requires the exact original to exist first.
- [x] Recheck the current full-root repair digest and original review under the task/project/workspace locks. Reject stale children, title-only edits, generation/context changes, archived projects, invalid proposals, existing indexed copies and unsupported history identity rewrites.
- [x] Apply only the reviewed operations, then atomically create and promote the separate child records. Ordinary personal and team field commands can edit the repaired children afterward while the archived original stays unchanged.
- [x] Retain immutable, contentless applied/closed receipts. Exact original retry/check/close never applies twice or overwrites later work. Metadata recovery survives disabled rollout, revoked access, task deletion and logical workspace deletion; expired sessions and changed bodies cannot recover a different request.
- [x] Require current read access to the same root, generation, project and realm to retrieve original content. Verify the original against the immutable receipt hash/size before delivery. Damaged content is refused while metadata confirmation remains available.
- [x] Preserve team originals when the editor's Auth account is deleted. Match actual team lifecycle: the public Delete team action logically deletes the workspace and purges its original content while retaining contentless repair decisions. Personal originals follow their owner account's lifetime.
- [x] Enforce 8,000,000 bytes per original, 64,000,000 bytes per actor and 256,000,000 bytes per team. Serialize quota admission; refuse before changing work and never silently expire originals. Test all three limits with synthetic data only.
- [x] Add reciprocal actor/team nonce fences to the 13 existing/new task-command ledgers. Use indexed actor/request and team/request predicates, rather than converting every stored receipt to JSON. Real field/adoption calls and a different actor's real team send exercise both directions. Untrusted Close claims never reserve another actor's team nonce.
- [x] Use the existing protected team-edit transaction scope and remove it after the exact source update. No caller-set setting or weakened legacy guard grants access.
- [x] Prove rollback after an injected final receipt failure: source, original, history-derived writes, projection and authority roll back; the same original request can then succeed. Concurrent root writers are refused rather than overwritten.

Each independent repository passes **256 checks total, including the 133 preview regression checks**. This is not a sum of repeated development runs. Advisors have the same seven fixture findings before and after; no new findings are introduced. Every owned container is removed.

## Still required

- [ ] Strict native command/preview/receipt/original decoders and bounded, session-scoped transport. Preserve both preview trees and the complete archived original as raw JSON; do not pass them through a floating-point JSON model or dictionaries that merge Unicode keys.
- [ ] Encrypted durable commands, ambiguous-outcome retry/check/close, private editor/draft admission, unreadable-workspace write refusal, Store integration and scoped account/window handling.
- [ ] Premium native before/after operation controls, original export and saved-result recovery. No app entry point or native behavior changes in this phase, and no native runtime/build claim is made.
- [ ] Explicit indexed-copy reconciliation and history/attachment/discussion identity mapping. These remain refusal paths; neither dropping copies nor silently assigning history is a repair.
- [ ] Larger-work repair, normal editable-cache support for opaque values, reviewed original-storage cleanup and a safe restoration/Undo workflow. Archived originals are not automatically restored or silently deleted to make room.
- [ ] Wider client shared-workspace gates, genuine accounts, secure storage, windows/background/concurrency, larger libraries and spoken acceptance. All agreed rollout, provider and real-device deferrals remain paused.

The full migration checkpoint remains **To build**. Flags, hosted schema and real data are unchanged.

## Service contract

`public.taskfold_repair_children(_operation text, _body jsonb)` accepts `send`, `check`, `close` and `original`. The exact body contains the eight preview fields plus `request_id` and the server-issued `repair_digest`. Its size is bounded to 70,000 UTF-8 bytes; changes retain the preview's 65,536-byte, 1–64-operation limits. Requests contain explicit operations, not uploaded replacement trees. Receipts retain fingerprints, context, archive identity/hash/size and node count, never the original content or operation titles. Check on an unknown request returns Unknown without reserving it. Close records only its actor's decision; it cannot reverse Applied.

`repair_writes_enabled` defaults false and additionally requires every existing child read/edit/completion/structure/adoption gate plus `repair_reviews_enabled`. Preview `mutation_available` now reflects those dependencies, current team/project write permission and custody blockers. A valid graph alone does not authorize saving. Quota and concurrent changes can still refuse an otherwise eligible preview.

Saving refuses any existing projection, child record or record authority, keeping both copies untouched. Before a reference assignment/wrapper, a canonical reference must not bind to prior child history in the same root generation; an old reference with history cannot be renamed without an explicit mapping. Moves and list-shape changes preserve their existing identities. History capture remains the normal server trigger; the repair never fabricates completion events or reattributes old history.

The original bundle contains the exact full pre-write root, SQL-null marker, honest empty pre-existing projection/records/authority, original child history and review/repair digests. The original's hash is over PostgreSQL's canonical JSONB text; it is not a promise that a file's whitespace-dependent byte hash matches that digest. There is no automatic full-workspace restore, repair Undo or generic backup-import compatibility claim.

Private original rows have separate personal-owner/team custody. Team content follows the workspace deletion trigger and survives a departed/deleted editor. Original retrieval is actor/request-bound and rechecks the current root realm and read access; after deletion or access loss only contentless receipt recovery is exposed. The normal API has no direct original-table permissions.

## Evidence and development findings

`sql.json` records all named checks and the exact migration hash. `original-reply.json` is an actual synthetic original-delivery response preserving the large integer, huge number and distinct Unicode keys. Its byte hash is separately recorded. `verification.json` binds production source, fixture/test and evidence hashes.

During development, real shared writes exposed the missing protected team-edit scope; it was added rather than relaxing the guard. Deletion testing was corrected to use the actual public logical-delete API, revealing that a foreign-key cascade alone did not clear archives; the lifecycle trigger now does so. An advisor check caught a remaining test-only function, which is now dropped before final advisor comparison. SQL-null fixture decoding and nondeterministic advisor ordering were corrected without ignoring findings. Final evidence supersedes earlier partial runs.

The full local Supabase stack cannot connect, so migration-history verification remains unavailable. The owned pinned PostgreSQL fixture executes this repo's actual ordered dependency chain and candidate directly. No hosted changes, real accounts, app windows or Simulators are used. Run `node Scripts/Database/test-child-task-repair-commits.mjs` from this repository; it enforces the existing storage floor and removes its own runtime.
