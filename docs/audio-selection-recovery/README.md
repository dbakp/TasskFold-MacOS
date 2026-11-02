# Complete-selection recording recovery: service and Core boundary

Reviewed 2 November 2026. Follows [selection admission](../audio-recorded-native/README.md).

## Implemented

The local service can inspect or permanently close the exact original retained-recording Undo for an entire 2–100-task selection. A private keyed fingerprint binds the complete original body, actor and operation. Recorded outcomes are confirmed without closure; an unrecorded observation never authorizes replacement. Closure requires the complete original deletion group, current session/editing access to every project, unchanged original content hashes and recording counts/policies, at least one expired member, and confirmed physical cleanup for each expired member. Unexpired recordings stay retained. A member cannot be detached through the single-task recovery endpoint.

The closure stores only team/actor/request/source identities, member nonces, a keyed fingerprint and creation time. It stores no task contents, captions, media paths or sessions. RLS is enabled; direct access is revoked from public, anon, authenticated and service_role. Only the explicitly granted authenticated wrapper can invoke the private, empty-search-path coordinator. Auth/session rows and team/project state are checked before results are returned. Header and member identities remain fenced in both the batch and single lifecycle writers after closure; member lookups have a GIN index.

Serialization follows Auth, team/project bindings, sorted header/member request mutexes, original group row, then sorted task mutexes. The original group row precedes task locks to match a fresh batch restore. Controlled tests cover an applied Undo winning against closure, a delayed original waiting behind closure, and a fresh request waiting on the original group without reversing the task lock order.

Both independent Core implementations strictly validate the actual owning SQL receipts against every member and header identity, state and exact metadata keys. The bounded, uncached, cookie-free transport refuses redirects, oversized replies, private error detail and a reply from a replaced session, including a new session for the same account. A 100-member metadata receipt fits the 32 KiB bound in a unit test; this is not a 100-task service load test.

Only a closed receipt plus a complete fresh review with explicit omission can construct a replacement. It preserves each task's fields, chosen generation and original deletion certificate, keeps unexpired/empty member policies, and creates fresh header and member request identities. The pure Snapshot operation checks the exact queue head and all pending nonce collisions before one assignment; later queued edits and task tables are unchanged on success or refusal. These models are not yet connected to Store persistence or native selection controls.

## Default-valued source fields

The sparse-record case found an existing batch expression associating concatenation and extraction to the left: defaults were merged into the envelope before its record was extracted. The migration explicitly parenthesizes record extraction at the two existing batch sites and uses the same normalization in recovery. The actual service test restores a mixed three-task selection with default-valued fields omitted and compares every full saved row to its original intended values; retry uses the same sparse request and records one restore.

## Evidence and limits

Each repo owns its CLI-created migration, service runner, generated SQL wire fixture, Core tests and reports. The final local service run has 186 passing checks, no added advisor findings and all owned containers/services removed. Its mixed flow uses three tasks across two projects: one expired recording, one unexpired recording and one task without audio. It checks all-or-nothing refusal, current access/session/pause, malformed and altered groups, actual expiry/purge, terminal closure and competing requests, exact task fields, retained recording identity and absence of expired audio. Real local PostgreSQL/RLS, pinned Storage and the production gateway are used; Auth, HTTPS routing and the minimal schema bootstrap remain synthetic. No hosted or full-schema/genuine sign-in acceptance is inferred.

The initial service suites passed 182/185 checks before the indexed fence and default-normalization case. iOS service v3 stopped at that new sparse case; its diagnostic exposed the precedence issue and its owned fixtures were cleaned up. The initial iOS Core attempt stopped because a new test assumed URLProtocol retained httpBody instead of presenting httpBodyStream. The harness now materializes that stream and reports a missing/malformed body as an assertion rather than crashing. These attempts do not establish final acceptance; final reports are recorded separately.

Remaining: Store context/save/readback/rollback and cold retry, explicit native whole-selection consent and recorded confirmation, accessibility/largest text, wider lifecycle/account/background/privacy, Mac/iPad runtime, mixed file/audio and discussion expiry, whole-project transfers and genuine Auth/full-schema/hosted integration. Prior single-task iPhone evidence keeps its separate scope. No app runtime or app-signing acceptance is added in this milestone. All normal-use switches remain Off and nothing is deployed.

References reviewed: [Supabase functions](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [current changelog](https://supabase.com/changelog), and the linked October TLS/PostgreSQL notices. The local changes use existing PostgreSQL locks/HMAC and explicit role checks; they do not depend on a new SDK or remote service configuration.

Final Core acceptance: 200 focused tests pass independently in each repository, including nine new receipt/replacement/transport cases. Each suite consumes its own generated SQL wire fixture. The 100-member metadata test, late same-account session replacement, exact streamed request body, refusal privacy, size bound and atomic head/tail preservation all pass. No extra app build or native runtime is claimed.

## Reproduce independently from either repository

```sh
TASKFOLD_AUDIO_LIFECYCLE_REVIEW_SQL=supabase/migrations/20261102181442_audio_lifecycle_native_review.sql \
TASKFOLD_AUDIO_RESTORE_FENCE_SQL=supabase/migrations/20261102194929_recording_restore_recovery_fence.sql \
TASKFOLD_AUDIO_SELECTION_RECOVERY_SQL=supabase/migrations/20261102212850_recording_selection_recovery_fence.sql \
node Scripts/Database/test-audio-generation-restore.mjs /tmp/taskfold-selection-recovery-check.json

bash Scripts/test_core.sh --jobs 2 --filter 'TeamTaskLifecycleTests|TeamTaskTypeLifecycleTests|TeamTaskBatchTests|TeamTaskEditorTests|TeamCompletionTests'
```

To regenerate that repository's wire fixture during the service run, additionally set `TASKFOLD_AUDIO_SELECTION_RECOVERY_WIRE_OUT=TaskfoldTests/Fixtures/audio-selection-recovery-v1.json`. Heavy runs are sequential and enforce the default 20 GiB floor; no Simulator, native app instance, new device, Docker reset or real task is involved.

Final Mac port audit removed a duplicate sanitized error handler and repeated route-list entries introduced while transferring the shared implementation. The independently owned transport now has one handler and one route membership at each dispatch site. All 200 focused Mac Core tests pass again against this final source; the service migration and its 186-check proof are unchanged.
