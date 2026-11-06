# Retired-upload recovery and signed maintenance schedule — 28 October 2026

Independently owned, default-off candidates in both app repos. No migration,
function, Vault secret, cron job or feature flag was changed on a hosted project.
No real account/task/audio data or native app sessions were used.

## What changed

A retired recording with an unknown upload outcome can now recover automatically
when its committed file appears. The database selects at most 25 open attempts
with a two-minute probe backoff, using row locks and `SKIP LOCKED`. The worker
validates every path/identity, reads the entire bounded file and compares its
SHA-256 and byte count with the reservation's immutable values. The service-only
reconciliation command rechecks the retired row, original ticket, private bucket,
service-owned Storage metadata and size/type before settling the sole open upload.
It cannot reopen or publish a retired recording. Normal cleanup then removes that
file through the Storage API and verifies absence before releasing quota.

Missing/corrupt bytes, stale tickets and changed metadata do not settle an upload.
Two cold workers cannot claim the same due probe. A crashed worker's probe becomes
eligible after backoff; backoff expiry itself never proves upload completion.

The new private scheduler installs an **inactive** minute job. Only the database
operator can configure or invoke it. It reads a dedicated 64-character hexadecimal
key from Vault and queues a project-bound, 90-second HMAC proof with a fresh nonce;
the queue never contains the reusable key. The maintenance Edge handler verifies
the signature/time/project and consumes the exact nonce through service-only SQL
before reading or deleting data. Replays and disabled schedules fail admission.
Configuration/disable invalidate outstanding nonces. Enqueue failures are recorded
as sanitized state; response tracking stores transport health, not response bodies.

**Maintenance authentication changed:** signed schedules are not JWTs. This
function must use its own tested HMAC + one-use SQL admission with the deployment
flag described in [operator preparation](DEPLOYMENT.md). The normal user audio
gateway retains platform JWT verification and real Auth/live-session checks.
Manual operator requests still require the dedicated maintenance secret. No
verification setting was changed on a deployed function.

## Evidence and limits

Each repo independently passed:

- **33 Deno handler/media checks:** existing publication/readback/cancellation plus
  complete retired-file recovery, missing/corrupt file refusal, manifest validation,
  signed schedule validation, tampered/stale proof rejection and replay admission.
- **93 actual PostgreSQL / loopback HTTP checks:** all prior boundary/fence cases,
  concurrent probe claim/backoff, matching/wrong ticket/hash/metadata, helper grants
  and a real late-file recovery/remove/quota-release through the production worker.
- **33 real pg_cron / signed HTTP checks:** pinned pg_cron 1.6.8 launches an actual
  background job in PostgreSQL 17.6, queues the SQL-generated HMAC, and its proof is
  forwarded through the production Deno handler. That scheduled invocation recovers
  a synthetic retired tombstone, deletes its actual fixture bytes, confirms removal
  through real SQL and releases quota. The same proof is then rejected. Disabled
  setup, role grants, credential absence, cooldown, enqueue failure, nonce invalidation
  and no-secret cron/queue contents are checked.
- Official CLI advisor baseline/final comparison introduces no findings in either
  SQL suite. Existing dependency-fixture findings are preserved in the reports;
  this is not a clean hosted database audit. Type checking, lint and whitespace pass.

The cron extension and PostgreSQL are real. Vault is a controlled synthetic table;
`pg_net` is a controlled enqueue function whose committed proof the Node fixture
forwards over loopback. Auth and the Storage byte API are controlled adapters.
Thus this proves the real cron execution, SQL cryptography/admission, production
handler and real SQL state transitions, **not real Vault encryption, pg_net HTTP
transport, hosted Edge routing/JWT settings, provider Storage or backing-store
queue/version cleanup**. The tombstone fixture is synthetic and does not claim
complete account-removal or cross-role/native acceptance.

[Source bindings](source-bindings.json) · [iOS database/HTTP](database-ios.json) ·
[Mac database/HTTP](database-mac.json) · [iOS real cron](scheduler-ios.json) ·
[Mac real cron](scheduler-mac.json) · [iOS handlers](unit-ios.txt) ·
[Mac handlers](unit-mac.txt).

```sh
deno check supabase/functions/audio-comment-maintenance/index.ts Scripts/Database/audio-comments-http-fixture.ts
deno lint supabase/functions/audio-comment-maintenance Scripts/Database/audio-comments-http-fixture.ts
deno test --allow-read supabase/functions/audio-comment-maintenance/handler_test.ts supabase/functions/audio-comments/handler_test.ts
node Scripts/Database/test-audio-comment-gateway.mjs /tmp/audio-recovery.json
node Scripts/Database/test-audio-maintenance-scheduler.mjs /tmp/audio-scheduler.json
```

The scheduler check builds a hash-pinned upstream pg_cron in an owned disposable
container, mounts only its extension artifacts into the fixture, and removes the
builder/runtime/temp artifacts. It introduces no new Docker image/build cache or
native build. Each repo owns its code and proof; neither builds against its sibling.

## Still open before normal exposure

1. Unknown uploads whose bytes **never appear**, or appear corrupt, still require
   authoritative provider terminal-request evidence or an explicit recovery process.
   A missing object/time limit is insufficient. Their quota remains reserved and
   the worker reports them; this is not accepted as the final indefinite user UX.
2. Real Supabase Vault/pg_net/Edge/Storage acceptance of scheduled execution,
   deletion queues/versions, request cancellation and probe recovery, including full
   account-removal/shared custody/expiry/reinstall cases. Source is not deployment.
3. Native frozen publication journal, publish/retry/remove/comment UI and remaining
   genuine/native playback/accessibility acceptance. The user's real dictation,
   release signing and other recorded provider/device deferrals remain in force.

Normal audio, publication and maintenance environment flags remain off; the new
cron row is created inactive. This completes the bounded local recovery/signed
schedule candidate, not audio comments or the broader Px objective.

## Primary references reviewed

- [Scheduling Edge Functions with Cron/pg_net/Vault](https://supabase.com/docs/guides/functions/schedule-functions)
- [Delete through Storage API](https://supabase.com/docs/guides/storage/management/delete-objects)
- [Storage upload completion/error reconciliation](https://github.com/supabase/storage/blob/master/src/storage/uploader.ts)
- [Backend deletion queues](https://github.com/supabase/storage/blob/master/src/storage/object-cleanup.ts)
- [Supabase changelog](https://supabase.com/changelog)

The CLI generated both migration names. Changelog and current scheduling docs were
reviewed; migrations were exercised only on owned dependency fixtures. No hosted
migration history or new client/TLS dependency was introduced.

Client follow-up: [native publication foundation](../audio-native-publication/README.md).
This maintenance artifact and its source bindings describe the preceding iOS
`6e74555` / Mac `1c35b58` checkpoint. The native foundation now uses the HTTP fixture
with additional test-only counters/loopback inputs; no hosted maintenance behavior
was changed or accepted by that follow-up.
