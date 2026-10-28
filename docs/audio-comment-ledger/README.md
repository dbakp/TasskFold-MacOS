# Inactive audio publication ledger — 28 October 2026

This checkpoint adds the database coordinator needed for private audio comments.
It is **metadata only, disabled by default and undeployed**. It creates no bucket,
transfers no audio, writes no ordinary conversation row and enables no app entry.
A ledger state named `published` records a privileged service attestation; it is
not independent proof that Storage received any bytes. The HTTP/Storage gateway
must supply that proof before the native app can consume this acknowledgement.

Each repository owns the same migration identity and its own runnable check code.
Apply a shared backend migration once per backend, not once per platform. There
is no sibling checkout dependency. Existing native audio entry points stay gated;
the user's genuine microphone/dictation/speaker/TCC test stays deferred.

## Implemented boundary

- Only `service_role` can execute the public invoker wrapper. Privileged logic is
  in the private schema with an empty search path; both private tables use RLS
  and have no client/table-write grants. Client roles cannot call the wrapper or
  read captions. HTTP must bind actor/session from verified Auth, not user JSON.
- Every user operation checks the live user, ban, session ownership/expiry and
  removal receipt. The current task generation, project and ownership/membership
  are checked under row locks. Known managed-team task identities and the existing
  centralized managed-project exclusion fail closed; native team authority is
  not inferred from a creator UUID. Missing/disabled configuration rejects new
  publication, finalization and reads.
- Version-1 requests use the existing native publication shape. IDs, caption,
  descriptor and destination form one immutable fingerprint. A repeated operation
  returns its original state/IDs; changed content conflicts. Asset and comment IDs
  cannot be reused by another operation. Literal UTF-8 captions are preserved,
  including a maximally escaped four-KB caption within the 32-KB metadata bound.
- A reservation expires after 24 hours. Only matching service-observed digest and
  byte-count assertions can finalize it. Those assertions must come from actual
  bounded Storage readback in the forthcoming gateway, never from the app body.
- Provisional candidate budgets are 100 non-purged assets / 250 MB per active
  author, and 20 / 50 MB per task. Clip descriptors retain the native two-minute /
  8-MB limits. Retired bytes consume quota until trusted physical deletion is
  acknowledged. Account and task transaction locks serialize concurrent limits.
  Project/team aggregate budgets and final provider/cost policy remain open.
- `read` and `list` return published metadata only, with current access. Archived
  projects retain readable acknowledgements but reject fresh reservations.
  The service receives a generated object name, never a user-supplied path/URL.
- Pending/published media blocks task identity/generation changes, project moves,
  personal Inbox ownership transfers and heading conversion. A reviewed custody
  operation must precede those changes. Explicit task/project deletion retires
  the ledger entry instead of retargeting it to Inbox. Retirement clears caption
  and descriptor. Published shared metadata survives uploader deletion with its
  author identity cleared; unfinished/personal retirement and normal membership
  denial stay separate from shared custody.
- Maintenance requires a service invocation with **both actor and session null**;
  an authenticated-user command cannot nominate cleanup or attest physical removal.
  Each cleanup request expires at most 25 old reservations and lists at most 25 due
  retirements. Exact operation/asset/path confirmation can mark a retired item
  purged while retaining its replay tombstone. The five-minute queue delay is not
  an upload lease or a guarantee against late object writes. No cleanup worker or
  Storage deletion runs here; physical reconciliation is still required.

## Verification

Run independently from either repo:

```sh
npm run --prefix Scripts/Database test:audio-comment-ledger -- /tmp/taskfold-ledger-report.json
```

The runner uses the existing digest-pinned PostgreSQL 17.6 image, an owned labeled
container, bounded tmpfs, synthetic identities and a loopback-only advisor port.
It reads no credentials or app/user containers. Existing team/project, task and
account-removal routines load unchanged into the deliberately minimal dependency
schema. It is not a complete hosted Supabase/Auth/Storage stack.

Both final runs pass **102 actual PostgreSQL checks**. Official CLI advisors run
before and after; neither run introduces a finding. Existing dependency-fixture
findings remain in the full reports and are not a clean hosted-advisor claim.
Both owned containers are verified removed. No Swift source changed, so app/UI
builds and genuine capture tests were not repeated for this database checkpoint.

The two opt-in development probes run only inside a new owned fixture:

```sh
TASKFOLD_AUDIO_LEDGER_TEST_PROBE=missing-task-quota-lock npm run --prefix Scripts/Database test:audio-comment-ledger -- /tmp/no-task-lock.json
TASKFOLD_AUDIO_LEDGER_TEST_PROBE=personal-custody npm run --prefix Scripts/Database test:audio-comment-ledger -- /tmp/no-personal-custody.json
```

These commands are expected to fail. Removing the single task-quota lock fails
at the real cross-account contention assertion; removing the personal ownership
condition fails the custody assertion. Probe inputs do not alter the migration
file. Reports bind both the on-disk and fixture-applied SQL hashes.

One controlled replica-mode fixture transaction simulates a managed task's legacy
project drift; normal authority checks run after trigger behavior is restored.
A proposed null-owner fixture was rejected by the existing NOT NULL constraint
and was removed; it is not accepted legacy-data coverage. Explicit null-safe
checks remain defensive. Earlier harness invitation/removal setup refusals are
not counted as acceptance. Final reports and probes are the authoritative scope.

## Next required implementation

1. Implement the authenticated Edge gateway and provision a strictly private,
   constrained bucket with no client bypass. Verify JWT with Auth, bind its live
   session, use these service-only commands and keep maintenance off user routes.
2. Persist the native frozen publication journal before networking. Upload only
   immutable reserved bytes; reconcile uncertain replies with the same IDs,
   verify actual stored bytes/hash/duration bounds, then finalize. An echoed
   native intent or this metadata attestation alone must never mean success.
3. Implement authenticated, bounded media download with another access/state check
   after the Storage read; no public or long-lived signed playback URLs.
4. Implement physical cleanup with explicit late-upload fencing/reconciliation,
   removed-account custody, quotas/rate budgets and scheduled worker acceptance.
   A metadata `purged` marker must follow verified object removal. App/server
   cleanup/recovery and aggregate budgets must be accepted before exposure.
5. Integrate real comment presentation and explicit Publish/retry/removal in the
   native apps; verify synthetic media through genuine HTTP/Storage and current
   role/deletion/reinstall cases. Do not reopen the deferred genuine audio test.

No remaining audio/Px requirement is closed merely by this coordinator.

## References reviewed

The migration was created using `supabase migration new`; development SQL was
executed against the owned fixture and checked with official CLI advisors. No
hosted migration history was written. The changelog index and relevant TLS entry
were reviewed; this checkpoint adds no TLS/client transport implementation.

- [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [PostgreSQL explicit locking](https://www.postgresql.org/docs/17/explicit-locking.html)
- [Private Storage buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals)
- [Supabase changelog](https://supabase.com/changelog)
