# Account removal service

This directory is independently owned by this app repository. No sibling
repository, npm dependency or embedded admin key is needed. `index.ts` reads the
platform-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`; no secret
belongs in either native app.

Deployed 22 October 2026 as function version 1, with migration
`20261022193804_account_removal_service.sql`. Each repository owns identical
server inputs; apply/deploy once to the shared backend. Future deployments must
retain gateway JWT verification disabled (`verify_jwt: false`): a completed or
pending receipt must be reachable using the original token after Auth
removal/expiry. This does not permit an unauthenticated new deletion: the
handler validates the caller through Auth, compares the verified subject/session
and checks the active session in the service-only begin RPC. Caller-supplied
targets, metadata, paths and options are rejected.

An accepted receipt is an irreversible command valid for seven days, including
after the original session is revoked. Only its SHA-256 token hash/account
ID/timestamps are retained. Receipts contain no raw token, profile, task, file
name or content; completed requests return only `{ "deleted": true }`. Hourly
cron expiry (where available) and opportunistic begin pruning enforce retention.
Clients must send `X-Taskfold-Account-Removal: 1`. Missing/unknown versions
receive HTTP 428 before any privileged call, including receipt lookups. This is
a compatibility requirement for the durable cleanup client, not caller
authorization or the deferred general older-client editing policy.

A native client must securely retain the same authorization for uncertain-result
retries; automatic refresh can otherwise lose access after successful Auth
removal. Both native Store paths now persist the original authorization in a
device-private Keychain vault, conditionally renew only after explicit
authorization refusal, and retain confirmed cleanup progress. Genuine Mac
profile/Keychain acceptance remains outstanding. Live HTTP/file-byte and normal
iOS UI acceptance are tracked separately in `docs/ACCOUNT_REMOVAL.md`.

Files are removed through Storage's API before Auth hard deletion. Ownership
comes from the service-only manifest, with owner-null UUID-prefix compatibility
limited to the existing avatars/task-attachments buckets. Explicit ownership
wins over an unrelated prefix. Responses, request bodies, batches and transport
time are bounded. Auth deletion is followed by a database completion check.
Partial failure returns a retryable error and never reports finished removal.
Deletion of up to eight 100-file batches may require another request.

The matching migration also blocks authenticated Storage writes after
authorization, including stale access tokens after deletion. User-row
key-share/exclusive locking serializes starting authorization against uploads
already in flight; the volatile predicate checks receipts after acquiring the
lock. Bucket access still needs its original permissive policy. Trusted
administrator/service-role writes are outside this restriction. Current hosted
buckets have versioning disabled; versioned object removal is not accepted by
this candidate.

Other accounts' tasks survive project-owner removal; their project/assignment
may be cleared by existing FK/guard behavior. Foreign recurrence children are
detached before deleting owned roots. Other memberships in legacy transferred
projects retain access with an unknown inviter. Shared comments on surviving
tasks remain with a NULL author. Owned reminder-device records are explicitly
removed instead of leaving unowned push tokens.

Checks from the repository root:

- `deno fmt --check supabase/functions/delete-account`
- `deno lint supabase/functions/delete-account`
- `deno test supabase/functions/delete-account/handler_test.ts`
- `node Scripts/Database/test-account-removal.mjs`

`supabase/tests/account_removal.sql` uses only a minimal local schema; its
direct storage metadata deletion simulates successful API cleanup and must not
be run on the hosted schema. `account_removal_hosted.sql` instead uses
rollback-only synthetic storage metadata and real hosted guards; prepend the
migration in the same transaction only before deployment; after deployment, run
the rollback-only fixture without recreating existing policies. Neither SQL
fixture proves Auth Admin HTTP or file-byte cleanup. Never disable hosted
triggers to adapt a test fixture.

See `docs/ACCOUNT_REMOVAL.md` for passed checks, failed fixture iterations and
the remaining native/deployment/HTTP acceptance work. No real account is a test
fixture.

Scoped live acceptance tooling is independently owned in
`Scripts/test_account_removal_live.py`. It requires an owner-private temporary
credential file with the exact project URL and server/public keys; never put
that file in the repository or native bundle. `seed` creates random, marked
`example.invalid` Auth users, real project invitations and a comment through its
public RPC, then uploads/reads synthetic bytes. `remove` checks legacy and
caller-target refusal, invokes the real endpoint and verifies original-token
success replay, outsider preservation and actual file-byte removal. `cleanup`
validates the generated identity/email/admin-only marker before removing any
remaining disposable users/files. Cleanup is operator tooling, not native
acceptance. No real account may be supplied as a fixture.

`upload-probe` is orchestrator-only: start its delayed background process before
holding the exact account's service-only begin transaction open. Preserve both
server lock and HTTP timestamps. It verifies a pending-account lock/refusal, not
every first-authorization visibility or full endpoint/upload interleaving. Never
accept a delay without matching overlap timestamps. Temporary fixture
credentials must be removed after the final independent cleanup verification.
