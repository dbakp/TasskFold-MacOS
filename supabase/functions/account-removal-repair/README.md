# Reviewed residual-file repair — disabled candidate

This is administrator tooling for Storage objects left after an Auth account is
already absent, including after its ordinary seven-day removal receipt expires.
It never deletes Auth, authorizes normal native deletion, accepts a client's
status proof as authority, or guesses that an expired pre-proof legacy command
completed. Native screens and their existing proof/receipt contract are
unchanged.

The candidate is **not deployed**. Each app repository independently owns these
sources and the matching CLI-generated migration
`20261103105727_account_removal_residual_repair.sql`; apply/deploy once to the
shared backend after separate hosted acceptance. There is no scheduler or
automatic sweep.

## Operator boundary

`index.ts` requires all of:

- Platform-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
- A separate random operator secret in `TASKFOLD_REMOVAL_REPAIR_KEY` (32–256
  characters). Keep it out of native apps, source control, manifests, chat and
  request logs.
- `TASKFOLD_REMOVAL_REPAIR_ENABLED=true`. Default is disabled.

An eventual Edge deployment needs gateway JWT handling configured for this
separate operator contract (custom-header authentication is enforced by the
handler). Do not change the existing delete-account gateway/authentication
settings to enable this endpoint. No public or authenticated-client role may
execute either the public read-only manifest wrapper or its private
implementation. The privileged implementation has an empty search path and reads
authoritative `auth.users`/Storage metadata; user-editable JWT metadata is
irrelevant.

The operator sends `X-Taskfold-Removal-Repair` with the separate secret. A
normal bearer token or account-removal status proof cannot substitute for it.
HTTPS configuration, no redirects, strict request/manifest shapes, bounded
reads, a 20-second overall deadline and sanitized errors limit each request.
Responses use no-store caching.

## Review then repair

1. Identify the removed account through the administrator's support/incident
   process. Quiesce other service-role/admin writers for its objects during
   repair. Ordinary authenticated uploads are already fenced by the existing
   account-removal policy; trusted privileged writers remain outside that
   policy.
2. POST a body containing only `action: "preview"` and the lowercase account
   UUID. Auth must already be absent. The response contains the account, up to
   100 exact object identities/paths/fingerprints, `more`, and a signed `review`
   token. Preview performs no deletion. Keep this sensitive response private.
3. Inspect every returned path/bucket. POST only `action: "repair"`, the same
   account UUID, that `review`, and `confirmation` equal to the account UUID.
   The review is bound to origin, account, complete batch and a 15-minute
   expiry. Changed/new/replaced objects, foreign plans, expired/tampered tokens
   and a recreated Auth account refuse the operation.
4. The handler rechecks Auth absence and each bucket's approved
   identities/fingerprints before removing those exact paths through the
   **Storage API**. It never deletes or changes Storage metadata through SQL. It
   then calls the existing absence RPC; only a true result returns
   `complete: true`.

Explicit ownership wins over a conflicting path prefix. Ownerless prefix
fallback is limited to avatars and task-attachments, matching the existing
deletion/status contract. Canonically owned files in other buckets are included;
unrelated ownerless files in other buckets are preserved.

A 202 response means unreviewed/residual files remain and another
preview/confirmation is required. A 409 requires renewed review (or refuses an
existing Auth account). A 503 never confirms repair; an earlier API batch may
already have removed files, so preview the remainder. A lost success reply can
likewise require a fresh preview; old reviews cannot silently remove a later
batch. The normal native status-only proof can confirm absence after repair
without gaining deletion authority.

The fingerprints detect changes at the checks. Storage's delete-by-path API does
not make these checks an atomic conditional delete. Do not claim protection
against a concurrent privileged replacement after the final check: operator
quiescence is required. Versioned S3/hosted recovery and genuine Auth Admin
behavior remain separate acceptance work.

## Checks and evidence

From this owning repository:

```
deno fmt --check supabase/functions/account-removal-repair Scripts/Database/account-removal-repair-http.ts Scripts/Database/test-account-removal-repair.mjs
deno lint supabase/functions/account-removal-repair Scripts/Database/account-removal-repair-http.ts
deno test supabase/functions/account-removal-repair/handler_test.ts supabase/functions/delete-account/handler_test.ts supabase/functions/delete-account/proof_test.ts
node Scripts/Database/test-account-removal-repair.mjs
```

The Node fixture requires the existing Node 22+ runtime and pinned Docker
images. It uses actual PostgreSQL, real pgcrypto, the production repair/status
handlers and an actual isolated Storage API/file backend. Auth absence is
modeled in the disposable SQL fixture; this is not an Auth Admin HTTP or
hosted/S3 acceptance claim. Only reserved loopback processes, labeled
containers/networks and synthetic data are used, with no persistent volumes or
user-file mounts. The observer compares actual preserved/read/deleted bytes, not
metadata alone. Official read-only advisors run before and after the migration.

Tests cover operator/client isolation, SQL privileges and actual denied
invocations, still-existing Auth, stale/new/replaced objects, explicit
confirmation, wrong target/signature/expiry, partial API failure, unconfirmed
results, request/response limits, deadlines, fresh bucket checks, actual 100+1
batching and the unchanged status proof before/after repair. Current evidence
and remaining work are in `docs/account-removal-residual-repair`.

Design references:
[Storage deletion must use its API](https://supabase.com/docs/guides/storage/management/delete-objects),
[Storage metadata is read-only](https://supabase.com/docs/guides/storage/schema/design),
and
[Auth deletion/session behavior](https://supabase.com/docs/guides/auth/managing-user-data).
The 30 October 2026 changelog and relevant 12 October TLS deprecation were
checked; no weakened TLS setting is introduced.
