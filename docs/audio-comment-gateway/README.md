# Audio publication gateway candidate — 28 October 2026

This is an independently owned, default-off source candidate in each app repo.
It was not deployed; no hosted bucket, credentials or user records were changed.
Genuine microphone/dictation/TCC testing remains deferred. No native app session
was opened for these checks.

## Implemented

- A fixed-origin authenticated Edge handler verifies the bearer with Auth, binds
  its canonical user/session IDs and asks the database to verify the live session.
  User metadata cannot select the account. Requests and upstream responses have
  bounded streaming reads, deadlines and cancellation. Errors omit provider data.
- A private 8 MB, `audio/mp4` bucket candidate with restrictive client policies:
  even a broad permissive policy cannot expose its objects or bucket to anonymous
  or authenticated clients. Service-only commands mediate access. An incompatible
  existing bucket or disabled Storage RLS stops setup instead of broadening it.
- Shared per-account fixed-minute budgets: 12 publication, 30 download and 60
  combined list/removal requests. Admission happens before reading the caller's
  body. The clock-taking test helper is unavailable to service/client roles.
- Publication reserves the frozen native v1 identity, uploads without overwrite,
  re-reads the entire stored file and checks its size, SHA-256 and bounded M4A/AAC
  container/duration before finalizing. A successful upload ACK alone is insufficient.
  A dropped ACK is reconciled by readback with the same IDs. Missing published
  bytes are never silently recreated. Finalization also checks the private bucket,
  exact Storage object identity, service ownership and numeric size/type metadata.
- Download reads authorized metadata, validates all retrieved bytes, then rechecks
  current session/task/comment authority after the network await. Responses are
  private/no-store and contain bytes, never public or long-lived signed URLs.
- Listing strips internal Storage paths. Removal retires metadata through existing
  authority checks and remains available when publication is disabled. No user
  route exposes maintenance or claims physical deletion.

Container admission is **not a full AAC decoder**. Native playback still needs
complete AVFoundation decoding. Standard bounded upload is used; resumable upload,
physical cleanup and real provider behavior are not accepted by this fixture.

## Verification

Each repo independently passed:

- 18 Deno handler/media tests: stored readback, lost ACK, no-byte ACK, corruption,
  original-ID retries, no overwrite/resurrection, stale receipt/access, actor
  mismatch, gates, forbidden maintenance routes, admission before body consumption,
  malformed input, oversize input, stalled body/transport cancellation, truncated
  media, descriptor tampering and an actual 8,000,000-byte padded synthetic M4A.
- 54 PostgreSQL boundary/HTTP checks using PostgreSQL 17.6: concurrent request
  budgets, role grants, direct Storage client denial despite permissive policies,
  compatible bucket facts, finalize rejection for missing/wrong/unsafe objects,
  removal/revoked sessions, plus actual loopback publication/retry/download/list/
  removal and dropped-response/corrupt-byte/stale-session paths.
- Official Supabase CLI baseline/final advisor comparison: no introduced findings.
  Existing dependency-fixture findings remain; this is not a clean hosted audit.
- Deno type checking/lint and Git whitespace checks.

The HTTP integration runs the production handler in a Deno child process with
network access limited to loopback. PostgreSQL executes the real migrations and
service commands. **Auth identity and the Storage byte API are controlled local
adapters**, not real Supabase JWT cryptography or Storage service acceptance.
Those adapters write actual Storage metadata rows and transfer the actual small
synthetic AAC fixture over HTTP; they do not prove deployed provider behavior.

Source bindings and independent results: [manifest](source-bindings.json),
[iOS database/HTTP](database-ios.json), [Mac database/HTTP](database-mac.json),
[iOS Deno](unit-ios.txt), [Mac Deno](unit-mac.txt).
Owned PostgreSQL containers, Deno HTTP processes and loopback servers are removed
in `finally`; no large native build or simulator was started.

Reproduce from either repository root:

```sh
deno check supabase/functions/audio-comments/index.ts Scripts/Database/audio-comments-http-fixture.ts
deno lint supabase/functions/audio-comments Scripts/Database/audio-comments-http-fixture.ts
deno test --allow-read supabase/functions/audio-comments/handler_test.ts
node Scripts/Database/test-audio-comment-gateway.mjs /tmp/audio-gateway-result.json
```

The database check uses the existing owned Docker fixture and official CLI
advisors. It does not read project secrets or contact hosted Supabase.

## Still required before exposure

1. A late-upload-safe physical cleanup worker: fence/reconcile in-flight writes,
   verify object removal before marking purged, retain aggregate quotas until
   removal is proved, and accept expiry/account-removal/retry/scheduled execution.
2. Native frozen publication journal and explicit publish/retry/remove/comment UI;
   reconcile uncertain replies with original IDs and preserve local work across
   cancellation, account/workspace changes and relaunch. Existing local audio
   library/import/export acceptance does not accept server publication.
3. Real authenticated Supabase Auth/Storage acceptance with synthetic media and
   role/removal/reinstall cases, including any provider size/metadata/error quirks.
4. Remaining native playback/accessibility and deferred genuine audio acceptance
   before normal feature exposure. Release/provider deferrals remain unchanged.

Both `TASKFOLD_AUDIO_COMMENTS_ENABLED` and the private database configuration stay
off. Native audio entry points remain gated. This advances authenticated delivery
source; it does not complete audio comments or the overall Px objective.

## Primary references reviewed

- [Private Storage and ownership](https://supabase.com/docs/guides/storage/security/ownership)
- [Standard uploads and overwrite behavior](https://supabase.com/docs/guides/storage/uploads/standard-uploads)
- [Storage error codes](https://supabase.com/docs/guides/storage/debugging/error-codes)
- [Official Storage client HTTP routes](https://github.com/supabase/storage-js/blob/master/src/packages/StorageFileApi.ts)
- [Row-level security](https://supabase.com/docs/guides/database/postgres/row-level-security)

The new migration was created with `supabase migration new` and exercised on the
owned dependency fixture. No hosted migration history or deployment was performed.

Follow-up: [upload fencing and cleanup](../audio-comment-cleanup/README.md)
supersedes the current handler/source acceptance. This artifact and its source
bindings describe the preceding iOS `2744a8f` / Mac `d46b4fa` checkpoint.
Unknown-upload recovery, scheduled/real provider acceptance and native publication
remain open; the cleanup candidate does not complete the feature.
