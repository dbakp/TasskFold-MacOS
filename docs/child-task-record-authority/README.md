# Record-authoritative child storage candidate

30 October 2026. Both repositories own this opt-in server migration and their tests. No hosted schema, real root, ordinary app flag or release setting changed. This is a verified local implementation stage, not full migration/rollout acceptance.

## Implemented

- Explicit trusted promotion compares the root's generation, project, projection revision and complete reviewed tree under the root lock. It reconstructs actual stored rows before enrollment; a stale snapshot cannot promote newer work. No root is enrolled automatically and no client role can promote roots.
- A separate materializer builds the compatibility tree only from stored child rows and the explicit null/array root kind. It validates paths, parent/sibling order, connectivity, child-container shape and decoder equality. Original notes, unknown fields, comments, file references and raw identity strings are retained. The old tree is never a content fallback.
- Existing typed field, completion and structure engines keep their account/session/role, nonce, history, receipt and certified Undo checks. For promoted roots they write child rows first, preserve unchanged row identities/revisions, then reconstruct the compatibility mirror from the stored rows. Personal prepared fields use the same-transaction preparation proof; team fields retain their dedicated ledger operation.
- Legacy full-tree replacements are refused on promoted roots. Ordinary root-title edits continue. A deferred transaction check refuses staged child rows without the exact matching root mirror, including a direct preparation that omits its patch. Root, rows, projection, history and receipts roll back together on refusal.
- New private tables have RLS and no client table grants. Materialization, arbitrary staging and promotion helpers are closed to anon/authenticated/service roles. The authenticated prepared-staging helper requires the live actor and the exact same-transaction preparation fingerprint; it cannot accept an arbitrary tree. Trigger definers have empty search paths and derive their root from the actual trigger row. Existing authorization does not use editable user metadata. No views or Storage grants are added.

## Verified scope

Each independently owned candidate passes **96 actual PostgreSQL checks**, covering personal and native team field/completion/structure paths; exact retry; deletion/Undo and fresh incarnation/completion epochs; null/empty roots through insertion/Undo; malformed older-data refusal; denied grants, role revocation and archived writes; corrupt records; root and receipt-failure rollback; completion-history creation and rollback; and a real competing root-lock promotion race. Failed staging cannot commit without its mirror.

Each repository also runs **220 existing structure-command checks plus one no-automatic-enrollment guard** with this candidate installed and roots left in legacy mode. That regression phase verifies unchanged default behavior; it does not count all those cases as promoted-root acceptance. Official advisors add no findings to the deliberately minimal fixture's seven existing notices. Fixtures use PostgreSQL 17.6, synthetic data, storage preflights and sequential owned containers, removed in finally.

Reports, compressed original logs, exact canonical/source hashes and failed attempts are retained here. Initial harness failures involved a composite result, a text boolean and an incorrect assumption that title-only edits create planning/completion history. The final history cases assert the actual event contract, including real receipt-failure rollback; none of the failed attempts is counted as acceptance.

The CLI created each canonical migration filename. The canonical SQL was applied directly in the owned PostgreSQL fixture and independently verified. The full local Supabase stack is unavailable, so `supabase migration list --local` cannot establish local history parity; the diagnostic is retained. No hosted apply-migration command ran. No Swift/UI code changed, and database passes imply no new native/spoken/build acceptance.

## Remaining implementation

- [ ] Reviewed project/generation transfers and cross-root moves. Promoted roots currently refuse scope changes rather than silently downgrading to legacy JSON; do not enable ordinary adoption until these adapters are finished.
- [ ] Incremental older-data adoption, malformed-data review tools and large-workload performance, while preserving the current premium app surfaces.
- [ ] Complete-current-schema custody, team deletion/account removal, native/secure-storage/window/background/spoken acceptance, and remaining receipt/disposal coexistence.
- [ ] Hosted deployment/backfill, older-client transition and distribution remain deferred by the user. Existing remote-reminder/OAuth/email/real-audio/location deferrals also remain.

The compatibility mirror still serves existing filters, exports and widgets. This stage does not remove whole-tree serialization or prove production latency, Storage file custody, bulk backfill or rollout readiness. The full Px goal remains open.

## Reproduce

Run `node Scripts/Database/test-child-task-record-authority.mjs /tmp/authority.json` in this repository. For the default-behavior regression, set TASKFOLD_RECORD_AUTHORITY_SQL to this repository's child_task_record_authority migration and TASKFOLD_FIELD_NATIVE_SQL to its native_team_child_field_adapter migration, then run `node Scripts/Database/test-child-task-structure-commands.mjs /tmp/authority-regression.json`. Each loader resolves only files owned by its repository.

Reviewed [Supabase triggers](https://supabase.com/docs/guides/database/postgres/triggers), [database functions](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) and [PostgreSQL locking](https://www.postgresql.org/docs/17/explicit-locking.html). The current Supabase changelog and linked PostgreSQL minor-version notice were reviewed; this candidate does not change TLS, gateways, extension pinning or indexes covered by those notices.
