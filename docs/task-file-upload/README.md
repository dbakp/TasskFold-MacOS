# Shared-task file admission and gateway — local candidate

Reviewed 1 November 2026. This repository owns its SQL migration, service, fixtures and tests independently. The service and database publication switches default to Off. Nothing was deployed or enabled for normal use.

## Implemented

An authenticated sender reserves an immutable operation bound to the current team, project, root task and generation. The service validates the file descriptor and bytes, uploads to a fixed service-only namespace without overwriting, reads and hashes the stored bytes, then asks SQL to publish. SQL validates private Storage identity and metadata, binds the object to the task, appends its attachment reference and records the receipt in one transaction. Late failures roll everything back; retries recover the same publication without duplicate attachment rows. Concurrent unrelated task edits survive the append.

Files are limited to 5 MiB and supported document/image/plain-text types (unknown binary files use application/octet-stream). File names never become Storage paths. Existing uploader requirements stay in force outside the exact private admission scope. Objects already scheduled for cleanup cannot be admitted. The source never changes provider bytes through SQL or reconfigures the existing bucket.

Download verifies the sender's live Auth identity and session, authorizes the current task generation/project, fetches and hashes the bytes, then checks access again before returning content. No service credential, provider path or signed URL is returned to the app. Direct authenticated Storage reads/writes in the new namespace are blocked by restrictive RLS. Same-team moves and Undo use the existing reviewed custody protocol and immediately change gateway access.

Per-actor request budgets include retries and both download authorization passes. New-operation/pending limits and a serialized team byte quota bound allocations. Cancellation/expiry is durable and cannot later publish. It does **not** prove that provider bytes were removed: those allocations continue to count until a future fenced cleanup worker confirms removal. Cleanup is deliberately not inferred from a timeout, missing reply or cancelled UI.

## Verification

This repo independently passes 49 actual local PostgreSQL admission assertions and all 59 existing custody assertions with the new candidate applied. Both owned containers are removed, with no additional advisor findings over their recorded fixture baselines. The service passes 28 typechecked request/response tests and lint, including stored-byte corruption, no-overwrite collisions, lost-reply retry, late access loss, bounded upstream waits, paused publishing and a receipt captured from this repo's successful SQL finalization.

SQL fixtures seed **synthetic Storage metadata only**. Service tests use injected HTTP responses and synthetic bytes. These results do not prove real Supabase Storage/provider delivery. No Apple app source changed in this batch, so app builds/native workflows were not rerun or newly accepted. Prior app build evidence remains separate. Development caught an ambiguous SQL local variable and a test that tried to bypass the existing task-generation guard; the corrected test uses certified lifecycle deletion. Production lifecycle guards were not relaxed.

## Required before enabling

- Native upload controls, encrypted pending-operation recovery, account/window/cold-launch integration, accessible status and exact receipt reconciliation.
- Fenced provider cleanup and verified quota release for cancelled/expired reservations; attachment removal/recovery and retention rules.
- Real Storage API upload/readback, collision/timeout recovery, revoked-session/account/generation behavior and deployment configuration checks.
- Legacy provider-file migration, non-root/independent child files, shared audio and genuine shared-account acceptance.
- Full Supabase-stack migration-history parity and hosted rollout remain unclaimed. Existing rollout deferrals are unchanged.

## Reproduce locally

Run the free-space check before each fixture and serialize heavy jobs. No hosted credentials are needed.

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-task-file-upload.mjs /tmp/taskfold-upload-report.json
TASKFOLD_TASK_FILE_UPLOAD_SQL="$PWD/supabase/migrations/20261101220633_task_file_upload_admission.sql" node Scripts/Database/test-task-file-custody.mjs /tmp/taskfold-upload-regression.json
deno test supabase/functions/task-files
deno lint supabase/functions/task-files
```

## Documentation review

Reviewed current [standard-upload guidance](https://supabase.com/docs/guides/storage/uploads/standard-uploads), [private bucket/access guidance](https://supabase.com/docs/guides/storage/buckets/fundamentals) and [Storage schema guidance](https://supabase.com/docs/guides/storage/schema/design). SQL only reads Storage object metadata; uploads/downloads use the API, without upsert. The [changelog](https://supabase.com/changelog), upcoming [CBC TLS deprecation](https://supabase.com/changelog/cbc-tls-ciphers-deprecated) and [Postgres minor-release changes](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes) were reviewed. The candidate uses standard HTTPS and SHA-256, introduces no legacy pgcrypto cipher, and changes no engine/SDK version. Private tables use RLS and have no client grants; the public invoker wrapper is service-role-only. Authorization uses live users/sessions and project roles, never user-editable metadata.
