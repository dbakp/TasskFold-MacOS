# Durable sender cancellation — local candidate

Reviewed 2 November 2026. Both app repositories own their migration, service, client and independently captured SQL fixture. New publishing stays disabled; nothing was deployed or enabled for normal use.

## Result

An attempted upload could not be stopped when its first reservation never reached the server, or when its task/access disappeared. A missing reply/404 cannot prove cancellation. The new coordinator records a durable sender/operation stop when that sender has no reservation. Its minimal versioned receipt certifies only that the sender's operation cannot publish later. Reservation and finalization pass the same operation lock and consult this fence before creating provider work. A real concurrent cancellation/first-reservation test confirms the waiting reservation observes cancellation and creates no upload allocation.

For an existing operation, the authenticated original sender can recover its immutable saved status and cancel pending publication after task deletion, project-access loss or publication pause. A committed publication returns its original publication receipt; Stop never removes it. History returns only original sender-owned metadata, with no current task/discussion data or provider path. Download still performs its separate current task/generation/project checks. A genuine project editor can publish, lose their grant, recover only their own result and close their own pending attempt, while download remains denied.

Unknown stops are scoped by **actor plus operation**. Another actor's colliding UUID cannot fence, alter or disclose the legitimate sender's publication. Every command still checks a live confirmed user/session and the existing per-actor request budget exactly once. A 1,024-record lifetime limit bounds unknown-stop storage; existing proofs still replay at capacity. Private helpers/tables have no client grants, and the old coordinator's service grant is revoked so it cannot bypass the new wrapper.

The gateway and native journal validate the new exact version/account/operation/cancelled-state receipt. Unknown versions, foreign actors/operations, publishing claims and extra fields are rejected. An original file remains encrypted until the user explicitly clears confirmed recovery. The proof does not fabricate a target, rebase the intent, grant file reads or claim provider bytes were removed.

## Verified scope

Each repo independently passes 83 actual local PostgreSQL assertions, including existing admission checks, real lock/wait concurrency, revoked-editor access, deleted tasks, exact replay, lifetime/request limits, rollback and private ACLs. Containers are removed and advisor output introduces no extra findings over the recorded fixture baseline. Service tests pass 35 cases with type checking and lint; the native Core suite passes 61 cases, including three new stop-receipt/recovery cases using this repo's actual SQL result. Current isolated apps/runners build and pass strict signatures; source and binary hashes are retained. The reused test hosts had missing registered inputs; missing inputs were restored from each owning repo with isolated identifiers, preserving existing host files. The Mac debug entitlements were recovered from its previous signed debug artifact; no release signing was changed. Initial fixture testing reused an actor's newly created private stop while expecting its old unavailable status; separate actors now test both private replay and non-owner disclosure correctly.

SQL fixtures contain synthetic Storage metadata; service HTTP uses injected responses. Native picker/export/accessibility/cold/window/account interaction and real provider delivery remain unaccepted. The normal-use switch stays absent/false. Full Supabase-stack migration-history parity and hosted deployment are not claimed by these isolated fixtures.

## Cleanup invariant and remaining work

**A bare sender-stop marker is not an object-ownership or byte-deletion ticket. Never derive a Storage deletion from it:** a different sender can legitimately own the colliding global operation UUID. Future cleanup must use verified, actor-bound upload ledgers, provider identity and quiescent/fenced write attempts. Unknown markers allocate no provider location. Cancellation of a known reservation does not prove its in-flight upload finished; its allocated bytes remain charged until safe cleanup is confirmed.

Fenced provider cleanup/quota release, read-only/viewer entrypoints, full native recovery interaction, actual provider delivery, attachment removal/legacy/child/audio custody and broader Px work remain. Rollout must coordinate the private wrapper, gateway and native decoder while publishing is off; older native decoders preserve the original on an unsupported minimal receipt. Existing user deferrals are unchanged.

## Reproduce

Use only an owned local disposable fixture, and serialize heavy jobs after checking the 20 GiB floor:

```sh
python3 Scripts/check_test_storage.py --path /tmp
TASKFOLD_TASK_FILE_STOP_SQL="$PWD/supabase/migrations/20261101225002_task_file_sender_stop.sql" node Scripts/Database/test-task-file-upload.mjs /tmp/taskfold-sender-stop.json
deno test supabase/functions/task-files
deno lint supabase/functions/task-files
```

Run this repo's Core package with the `TaskFileUploadTests|TeamTemplateCommandTests|TeamOrganizationCommandTests` filter and an external build cache. No hosted credentials are required. The fixture pairs the actual SQL receipt with the locally known original intent for validation; that intent is not returned by the unknown-stop API.

Reviewed the current [Supabase changelog](https://supabase.com/changelog) and [function security guidance](https://supabase.com/docs/guides/database/functions). Relevant TLS/pgcrypto changes were reviewed in the preceding upload-admission work; this candidate changes no engine/SDK, cipher, Storage object/bucket or provider byte. The new privileged coordinator is private with an empty search path and explicit live-actor checks; its public invoker wrapper is service-role-only. No user-editable metadata participates in authority.
