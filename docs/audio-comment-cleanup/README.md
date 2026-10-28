# Audio upload fencing and cleanup worker — 28 October 2026

Default-off source candidate; not deployed. This extends the authenticated gateway
candidate at iOS `2744a8f` / Mac `d46b4fa`. Both repositories own their sources and
passed their tests independently. No real user data, provider configuration,
permissions, native app sessions or live audio were used.

## Implemented

- Before each Storage POST, the gateway creates a durable upload ticket under the
  publication row lock. Only one open ticket is allowed per operation. Retirement,
  expiry, wrong ownership, a missing live session, archived/inaccessible targets
  or disabled configuration prevent new upload tickets. Task locks precede the
  publication lock, matching the existing coordinator's order.
- A definite successful/conflict response settles that ticket. A timeout, dropped
  response or server error **does not expire into proof**. Successful stored-byte
  verification plus finalization reconciles the sole open ticket. Lost upload ACKs
  still finish with their original IDs when readback can prove the publication.
- An unresolved upload blocks retirement cleanup and quota release indefinitely;
  another retry cannot start a competing write. Settlement remains possible after
  the user's session is revoked because it records a service transport observation,
  not a new authorized user write. User HTTP routes cannot invoke it directly.
- The separate service-only maintenance RPC retires expired pending reservations,
  claims at most 25 due retired records with rotating two-minute tokens and excludes
  open uploads. Expired cleanup tokens can be retried; old tokens cannot confirm.
  The original unfenced cleanup/purge branches are no longer service-callable.
- The new maintenance Edge handler requires platform JWT verification plus a
  dedicated 32–256 character scheduler secret. It validates the entire manifest
  before any destructive call, then uses only the fixed private bucket and exact
  canonical object paths. Each removal goes through the Storage HTTP API. It
  verifies GET 404 before asking SQL to confirm; SQL independently rejects an
  open upload, stale token, wrong target or remaining Storage metadata row.
- The worker reports claimed/purged/unresolved counts and the number of blocked
  retired uploads. Removing an object unsuccessfully retains quota. No database
  function deletes Storage rows or pretends that SQL row removal deletes bytes.
- Worker calls, response reads and streams have bounded deadlines/cancellation;
  errors omit provider data. Maintenance remains available independently of normal
  publication when explicitly configured, but its own enable flag defaults off.

## Verified scope

Each repository independently passed **26 Deno tests** (18 publication/media and
8 maintenance) and **82 PostgreSQL/boundary/loopback HTTP checks**. The database
run loads all three audio migrations and compares official CLI advisors before /
after the boundary changes: no new findings. Existing dependency-fixture findings
are retained in the reports; this is not a hosted schema audit.

New checks cover unknown upload tickets, competing retries, elapsed time without
proof, retirement, settlement after session revocation, client/helper grants,
blocked-upload reporting, cleanup token expiry/rotation, object metadata fencing,
quota retention/release, malformed manifests, wrong scheduler credentials, failed
Storage deletion, readable bytes after an acknowledged delete, SQL refusal and
late-response cancellation. A dropped ACK with no readable bytes is verified
to retain its single upload attempt, survive expiry into a blocked retirement and
keep quota after worker execution. The real loopback worker test makes an actual HTTP
DELETE against the owned controlled byte API, checks GET absence, then confirms
through actual PostgreSQL. A failed HTTP deletion retains the ledger's quota.

The fixtures use the production Deno handlers and real PostgreSQL 17.6, with
**controlled local Auth and Storage adapters**. The adapter's SQL deletions emulate
provider metadata changes only; production cleanup exclusively uses the Storage
API. These tests do not accept real Supabase JWT cryptography, provider deletion
queues/backing-store erasure, hosted migration compatibility, scheduled execution,
full account-removal flows or native publishing/playback. A Storage API absence
check alone must never clear an unresolved upload ticket.

[Source bindings](source-bindings.json) · [iOS database/HTTP](database-ios.json) ·
[Mac database/HTTP](database-mac.json) · [iOS handlers](unit-ios.txt) ·
[Mac handlers](unit-mac.txt).

```sh
deno check supabase/functions/audio-comments/index.ts supabase/functions/audio-comment-maintenance/index.ts Scripts/Database/audio-comments-http-fixture.ts
deno lint supabase/functions/audio-comments supabase/functions/audio-comment-maintenance Scripts/Database/audio-comments-http-fixture.ts
deno test --allow-read supabase/functions/audio-comments/handler_test.ts supabase/functions/audio-comment-maintenance/handler_test.ts
node Scripts/Database/test-audio-comment-gateway.mjs /tmp/audio-cleanup-result.json
```

The test requires the existing owned Docker fixture and Supabase CLI advisors. It
reads no production credential and has no hosted endpoint. Containers, Deno child
processes and loopback servers are closed in `finally`.

## Remaining work — feature stays gated

1. Recover uncertain uploads after process loss/retirement using provider evidence;
   a missing object is insufficient to prove that an earlier upload stopped. The
   conservative open-ticket fence is deliberate, but indefinite blocked quota is
   not accepted as the final user experience. Recovery/operations must be finished.
2. Add and accept scheduled maintenance, lease recovery/backoff/observability,
   overlapping cold workers and full removal/expiry/custody cases. The callable
   worker is implemented; no cron job or deployment has been installed.
3. Accept the real provider's upload/deletion behavior and backing-store cleanup
   semantics with synthetic data. Current Supabase implementation can queue backend
   cleanup after metadata commits; do not equate this local API proof with direct
   verification of every provider object/version or an indefinite-late upload.
4. Native frozen publication journal, explicit publish/retry/remove/comment UI and
   remaining genuine/native audio acceptance. Normal audio and both server feature
   flags remain off. The user's microphone/release/provider deferrals stand.

## References reviewed

- [Delete objects through Storage, not SQL](https://supabase.com/docs/guides/storage/management/delete-objects)
- [Current upload completion/error handling](https://github.com/supabase/storage/blob/master/src/storage/uploader.ts)
- [Backend deletion and queued fallback](https://github.com/supabase/storage/blob/master/src/storage/object-cleanup.ts)
- [Supabase changelog](https://supabase.com/changelog)

The CLI generated the migration filename. It was applied only to owned dependency
fixtures; no hosted migration history was changed. The changelog index was reviewed
for relevant breaking changes. No Supabase client library/TLS stack was introduced.
