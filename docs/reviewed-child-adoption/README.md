# Reviewed adoption of older subtasks — 30 October 2026

The candidate now exposes a read-only review and an explicit, root-by-root adoption decision. The review returns the current original content, diagnostics and an opaque fingerprint binding the task generation, project/workspace, complete tree, projection, row identities/versions and existing authority. Adoption sends metadata only and succeeds only if that exact review remains eligible. It never guesses missing or duplicate child IDs, reconciles mismatched records, drops unsupported content or bulk-converts an account.

Successful adoption preserves the entire public task and existing record identities/revisions, creates no synthetic task-activity events, and retains prior private deletion archives and their usable Undo. Malformed/oversized data stays unchanged. Content over 2,000,000 JSON bytes is explicitly omitted from the response, with a diagnosis; the original stays stored. The review currently reports the first decoder issue, not a complete repair plan.

Requests have send/check/close operations, immutable metadata-only receipts, exact retry and reciprocal nonce fences with older field/completion/structure/transfer writers. Only a live authenticated actor may recover their own metadata after access loss, root deletion or disabled rollout. An unsent closure cannot reserve another actor's team request identity. Adoption does not provide an unsafe downgrade to legacy whole-tree writing.

Each repository owns this migration and harness. Its own 138 actual PostgreSQL/RLS checks pass; before/after advisors report no added findings, and the fixture container is removed. No real tasks, hosted schema, normal app gates, dependencies or Storage objects changed. `supabase migration list --local` could not connect because the full local Supabase stack is not running; this is isolated SQL acceptance, not hosted/full-stack rollout verification.

## Still required

- Typed client validation/transport and encrypted pending-request recovery.
- Store admission that preserves private drafts and other pending child actions.
- Native review/diagnostic/recovery controls, explicit malformed-content repair and original-content export.
- Native, VoiceOver, real secure-storage/account/window/background acceptance, full custody and larger workloads.
- Rollout and older-client transition stay deferred. This service foundation does not close the broader migration checkpoint.

## Reproduce

Run `node Scripts/Database/test-reviewed-child-adoption.mjs /tmp/adoption.json` from this repository. It uses only owned migration paths and the existing pinned, disposable PostgreSQL fixture with a free-space guard. The migration was created with the installed Supabase CLI's `migration new`; SQL was iterated in the isolated fixture, without applying hosted migration history.

Reviewed [database-function security](https://supabase.com/docs/guides/database/functions), [row locking](https://www.postgresql.org/docs/17/explicit-locking.html), the [Supabase changelog](https://supabase.com/changelog), and its linked PostgreSQL/TLS notices. This stage does not change TLS, legacy PGP decryption, ltree/GiST indexes, custom operators or provider configuration.
