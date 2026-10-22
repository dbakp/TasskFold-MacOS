# Account removal service candidate

This directory is independently owned by this app repository. No sibling
repository, npm dependency or embedded admin key is needed. `index.ts` reads the
platform-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`; no secret
belongs in either native app.

The candidate is **not deployed**. Apply the reviewed matching migration before
any controlled deployment. Deploy with gateway JWT verification disabled
(`verify_jwt: false`): a completed or pending receipt must be reachable using
the original token after Auth removal/expiry. This does not permit an
unauthenticated new deletion: the handler validates the caller through Auth,
compares the verified subject/session and checks the active session in the
service-only begin RPC. Caller-supplied targets, metadata, paths and options are
rejected.

An accepted receipt is an irreversible command valid for seven days, including
after the original session is revoked. Only its SHA-256 token hash/account
ID/timestamps are retained. Receipts contain no raw token, profile, task, file
name or content; completed requests return only `{ "deleted": true }`. Hourly
cron expiry (where available) and opportunistic begin pruning enforce retention.
A native client must securely retain the same authorization for uncertain-result
retries; automatic refresh can otherwise lose access after successful Auth
removal. Both native Store paths now persist the original authorization in a
device-private Keychain vault, conditionally renew only after explicit
authorization refusal, and retain confirmed cleanup progress. Genuine Mac
profile/Keychain and live HTTP/UI acceptance remain outstanding.

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
candidate migration in the same transaction. Neither SQL fixture proves Auth
Admin HTTP or file-byte cleanup. Never disable hosted triggers to adapt a test
fixture.

See `docs/ACCOUNT_REMOVAL.md` for passed checks, failed fixture iterations and
the remaining native/deployment/HTTP acceptance work. No real account is a test
fixture.
