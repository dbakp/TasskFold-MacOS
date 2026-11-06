# Certified recording restoration after task deletion

Reviewed 2 November 2026. This is an undeployed service candidate, separately disabled by `audio_comment_config.restoration_enabled = false`. The app's existing shared-recording switch also remains Off. Native retention/recovery controls are not implemented or accepted by this milestone.

## Behavior implemented

A certified team-task deletion, with recording restoration enabled, requires an exact acknowledgement of the policy, current published-recording count and 30-day retention. It locks the current bound publication/Storage inventory, stores a private snapshot under the actor's existing deletion certificate, retires the public metadata, and keeps physical cleanup ineligible until that exact deadline. Quota remains charged during retention. Pending, unbound, busy or changed recordings refuse deletion rather than silently losing custody. The existing root snapshot, current role/session, project state and task lifecycle safeguards remain in force. This acknowledgement confirms the retention policy/count; it is not a separately signed media-transfer preview.

Certified Undo validates the original deletion actor, root restoration hash, current role, new task generation, stored inventory and retention deadline. Any unresolved upload, cleanup claim, missing/changed object, changed author or custody refuses the whole restoration. Root, companion-file preparation and recording renewal share the same SQL transaction. A synthetic late failure proves audio/root rollback; mixed recording-plus-file restoration remains separately unaccepted. Successful Undo restores the original caption/descriptor and changes only current recording custody to the new task generation. It consumes the private caption snapshot.

The immutable publication operation, original sender intent, original task generation and Storage path do not change. Recipient list/download metadata uses the restored generation; the gateway privately validates the original storage generation and strips that field before returning public receipts. Publication cannot supply or borrow that internal address. Playback still verifies bytes and rechecks access after reading; the old generation cannot read the restored recording. Subsequent deletion/Undo cycles and current-author removal use current custody.

At expiry, the existing fenced maintenance path prunes the private caption snapshot, deletes Storage bytes and releases quota only on confirmed cleanup. Expiry is not proof of deletion. A distinct acknowledgement, `expired_recordings_omitted_v1`, can recover the task without recordings only after all of that deletion's recording identities are actually purged. Ordinary Undo refuses silent omission. Missing ledger rows or an unconfirmed cleanup are not sufficient. This makes the task recoverable without resurrecting expired media.

Whole-project realm changes, personal-task restoration, legacy/unbound recording adoption, new client controls and wider lifecycle/migration acceptance are outside this candidate. No existing recording is automatically backfilled, and older clients cannot perform an acknowledged recording deletion while this new service switch is enabled.

## Evidence

Each repository independently passes 65 real local PostgreSQL/production-gateway/Storage assertions, including two Delete/Undo cycles, exact original bytes and identities, Unicode caption preservation, revoked-editor refusal, changed provider object refusal, late rollback, scope retirement, sender-history compatibility, current-generation playback/removal, physical cleanup/quota, expiry/task-only recovery, private ACLs and no added advisor findings. Storage schema/API and audio bytes are real local provider operations; Auth is a controlled adapter around real SQL session/role checks. The base schema is the selected owning fixture, not complete production-schema parity.

The existing 63 same-generation project-move/Undo, legacy, old-hash and Storage-custody regression checks also pass per repo with this candidate applied at its disabled default.

Each repo also passes 56 typechecked service tests (four new cases): original-path delivery under a new live generation, stripped internal addressing, invalid/borrowed-address refusal, and access-loss refusal after readback. Reports, exact source hashes, earlier-attempt qualifications and progress QA are retained alongside this document. No native app or Simulator is launched. Owned services are removed and the default 20 GiB storage floor is enforced before heavy tests.

Reproduce from the owning repository:

```sh
node Scripts/Database/test-audio-generation-restore.mjs /tmp/taskfold-generation-fresh.json
TASKFOLD_AUDIO_GENERATION_SQL=supabase/migrations/20261102175200_reviewed_audio_generation_restore.sql node Scripts/Database/test-audio-project-custody.mjs /tmp/taskfold-generation-moves-fresh.json
deno test --allow-read=TaskfoldTests/Fixtures supabase/functions/audio-comments/handler_test.ts supabase/functions/audio-comment-maintenance/handler_test.ts
```

## Remaining

Post-restoration moves and mixed media still need dedicated integration proof. Build typed client acknowledgements and premium Delete/Undo/expired-media review, including how the current inventory is presented. Accept both native apps, mixed files/recordings, account/access/window/background changes, keyboard/speech/privacy and larger inventories. Finish whole-project recording transfers, genuine Auth/full-schema/hosted integration and broader legacy migration. Actual capture/playback hardware and all previous provider/device/distribution deferrals remain unchanged. Normal-use activation requires the retention worker and complete client workflow; this milestone does not activate either.
