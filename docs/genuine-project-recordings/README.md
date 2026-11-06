# Genuine local recording-transfer integration

Reviewed 5 November 2026. The published-only personal-project branch transfer now has **49 passing service integration checks in each owning repository**. This closes the recorded synthetic-Auth/in-memory-byte-adapter gap for that local service path. The whole feature remains gated and unfinished; native app and hosted S3 acceptance are separate.

## What runs

The production audio HTTP handler uses its ordinary `fetch` dependency against actual disposable Supabase Auth, PostgREST, PostgreSQL and Storage. Every owning migration is replayed: 207 in iOS and 206 in Mac, preserving their independent migration histories. Three real signups issue signed JWTs and live sessions. Projects/tasks use genuine authenticated REST; team membership and invitation acceptance are trusted synthetic fixture setup, not invitation-UI acceptance.

The handler listener and its upstream bridge use a task-owned CA and a separately signed server certificate with proper localhost/IP SANs. Both Node and Deno validate certificates. A client without the CA must fail; no TLS guard, normal handler dependency, system trust setting or JWT/session check is bypassed. The bridge forwards actual service statuses/bodies and can hold one real Storage read while the real adoption RPC changes custody. Internal disposable Docker services use their normal local HTTP transport; this is loopback TLS proof, not release Internet trust acceptance.

## Accepted flow

- Publish two original synthetic recordings through the production handler and actual Storage API. Original personal readers receive exact bytes; the future team reader is refused before Storage access.
- Inspect/review the real recording inventory and require explicit published-recording consent. Paused transfer refuses review.
- Change the whole parent/child project branch into the team while an old reader's actual Storage download is crossing. The handler withholds bytes after the access change.
- New team readers obtain the original exact bytes. Publication receipts and Storage object identities/metadata remain unchanged, with two uploads total and exactly two custody rows.
- Retired readers are refused before another provider read. A previously reviewed private-audience approval cannot publish into the changed team audience. Direct authenticated Storage bypasses are refused.
- Retry the exact committed project request while fresh transfers are paused; it returns its original receipt without duplicate custody/uploads.
- Revoke the real team-reader session; its still-signed JWT cannot reach Storage. The scheduler remains off and no outbound jobs are queued.

Source hashes bind the complete driver, TLS bridge/server, runtime/gateway and production handler/wire code before and after each accepted run. Migration hashes bind the exact replay. Current advisor baselines have one unchanged `extension_in_public_pg_net` warning and no new findings; this is not a clean hosted security audit. The existing iOS-owned 72-check full-schema Auth/REST regression also passes after the test gateway gained server-key routing.

## Cleanup and limits

All five owned containers/internal network, handler process and private CA/key directory are removed. No new images, persistent data volumes, real accounts/files, Keychain items or normal app sessions are used. The pinned images declare no automatic volumes; database/provider data use bounded tmpfs. App packages remain Mac21/iPhone33, uninstalled, and this work does not require rebuilding unchanged app sources.

The first setup's invalid CA-as-leaf certificate failed with 503; a direct probe established `CaUsedAsEndEntity`. It was corrected in the fixture, and the final negative trust check prevents acceptance through disabled validation. The earlier failure remains recorded separately.

Native Store/media-handler and protected-session integration, hosted S3, mixed unfinished/private-removed/legacy policies, other realm directions and wider permission/lifecycle/accessibility cases remain open. No hosted schema, production handler, normal feature flag or release setting changed.

## Reproduce

From this owning repo, with the already-pinned full-schema images, Node, Deno, OpenSSL and the existing Supabase v2 CLI:

```sh
node Scripts/Database/test-full-schema-project-recordings.mjs /tmp/taskfold-project-recordings-unique.json
```

The runner enforces the 20 GiB preflight floor and removes only its own services. See [official self-hosting](https://supabase.com/docs/guides/self-hosting/docker) and [the distinction between Storage API/file and S3 backends](https://supabase.com/docs/guides/self-hosting/self-hosted-s3). The current CLI v3 breaking-change notice was reviewed; the installed v2.109.0 CLI was retained, and no hosted CLI command was used.
