# Cache request identity in existing database policies

Reviewed 3 November 2026. The owning complete schema now passes 48 focused genuine local Auth/REST and catalog/query-plan checks after replaying all 203 owning migrations. No hosted database or normal-use feature gate was changed.

## Change and evidence

The additive migration alters 14 existing policies on sections, labels, profiles, project collaborators, projects and tasks. It wraps only request-constant auth.uid() calls in scalar SELECTs. Row-dependent project access/ownership helpers stay outside those subqueries. Policy names, commands, roles, permissiveness, ownership/membership predicates and implicit/explicit update checks are preserved. It adds no grant, SECURITY DEFINER helper or metadata-based authorization.

The driver captures every database policy immediately before the owning migration, then compares the completed schema. Exactly 14 policies differ; removing only the scalar identity wrapper produces exactly the previous predicates. Every other policy, table RLS/ACL setting, function definition and function ACL remains identical. Real locally issued Auth sessions exercise private labels/profiles, cross-owner create/update refusal, owner-only project deletion, section/task creation, pending invitation privacy, accepted membership and revocation. A bounded 1,001-label EXPLAIN ANALYZE confirms identity InitPlans each execute once and RLS still returns all owned rows. This proves a query-plan improvement, not whole-app latency or a measured speedup.

The official complete-schema advisor falls from 15 warnings to one: the known nonrelocatable pg_net extension in public. No auth_rls_initplan finding remains. Extension placement still requires a supported installation/hosting decision; this migration does not move, drop or reset it. Scheduler launch remains Off, no outbound job is queued and all owned test services are removed.

## Reproduce and limits

Run `node Scripts/Database/test-rls-initplans.mjs /tmp/taskfold-rls-initplans-<unique>.json` from this repo with the pinned full-schema runtime prerequisites. The runtime enforces the 20 GiB free-space floor and uses isolated disposable data. Its optional beforeMigration observer permits baseline catalog capture; ordinary runtime callers retain their existing behavior. No app rebuild is needed because app sources are unchanged. Existing native Store proofs predate this additive migration and are not relabeled as native acceptance of the new schema. Hosted rollout, protected session/TLS acceptance, independent child journals and broader migration/media checks remain separate.

References: [official request-function SELECT guidance](https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select) and [Supabase linter explanation](https://supabase.com/docs/guides/database/database-linter?lint=0003_auth_rls_initplan).
