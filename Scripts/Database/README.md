# Assignment provenance SQL checks

From this repository, run:

```sh
npm ci --prefix Scripts/Database --ignore-scripts
npm run --prefix Scripts/Database test:assignment
```

This optional development tool uses a pinned PGlite PostgreSQL runtime in memory. It reads no app configuration, credentials, network endpoint or user container. Its dependency schema is deliberately minimal; the test checks the actual migration's PL/pgSQL, triggers, foreign keys, privileges and RLS, but does not reproduce all Taskfold Auth/project/task policies or HTTP behavior. The fixture rolls back, and the runner verifies the accounts are gone. This tooling is not an app build or release dependency.

`supabase/tests/assignment_provenance.sql` is also independently runnable as postgres against the complete Taskfold schema after the migration. It uses only its reserved synthetic UUIDs and `example.invalid` addresses inside one rolled-back transaction. Do not remove the transaction or use existing user/task IDs. Hosted acceptance must run that fixture against the actual policies; the local bootstrap alone does not prove it.

Migration `20261021122959_assignment_provenance.sql` matches the applied shared-backend migration history. Both platform repos own identical copies, with no sibling build dependency. Apply it once per backend, not once per app.

The initial model is intentionally separate from saved-filter integration. New assignment changes are server-recorded; missing legacy history, system actions without an account, removed actors and unverified recurring successors remain unknown. The client catalog has no network behavior and must receive rows from the current workspace only. Query integration still needs account-safe capability-aware synchronization, local-workspace recording, predicates/unknown Boolean semantics, native controls, widget membership and end-to-end acceptance.
