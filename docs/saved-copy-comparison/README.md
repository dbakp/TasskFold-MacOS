# Compare saved subtask copies before reconciliation

The repair screen can now inspect the task list, saved snapshot and separate subtask records without choosing a winner. It displays each readable list separately, including notes, completion state, due date and priority. An exact JSON export preserves readable saved content, including unknown fields and values shortened in the review.

This is a **comparison/export prerequisite**, not completed reconciliation. There is no replacement, promotion, adoption, history rebinding or automatic merge in this operation. Normal migration/repair feature gates remain disabled in repository app configuration; no hosted deployment was performed.

## Access and preservation

- The current account, live session, task generation, project, workspace, access context and review fingerprint must still match. The public invoker checks current task SELECT policies before and after the private operation. Shared viewers can inspect readable work without receiving write access.
- A trusted record-authority row must match the current generation and project before differing indexed content is exposed. Without that anchor, indexed content can be shown only when it equals the task content already readable by the caller. Different unproven copies remain private and unchanged; their content, sizes and counts are withheld.
- The comparison makes no database writes. It neither refreshes a stale snapshot nor manufactures records. The independent database checks compare full roots, projections, records, authority, history, repair receipts and original counts before/after reads.
- The complete current root and all readable indexed copies are retained in an export bundle. The bundle names omitted private components. It is **not a workspace backup or an import/restore format** and does not include history. History custody remains part of the unfinished write-reconciliation work.
- Export requests fetch the comparison again. If its fingerprint changed, the user must review the updated lists before exporting. The fingerprint binds the full root, including title, and saved components. Backgrounding, account/session/access changes or a pending task edit invalidate visible content and pending export. A snapshot refresh discards the previous result and, when comparison was requested, fetches a fresh authorized result while retaining only the open-group identifiers.
- Opaque JSON stays as raw bytes through reading and export. Typed labels are bounded independently. Exact integers above 2^53, huge numeric values and distinct composed/decomposed Unicode keys survive actual SQL replies. There is no generic floating-point conversion of the originals.
- Queries and responses are bounded (1,000 records, depth 24, 2 MB trees, 4 MB records, 8 MB export, 14.3 MB full response). HTTP reads bypass caches/cookies and reject redirects; stale and late session replies are discarded. Logs/descriptions do not print private comparison content.

## Verification

Each repository owns the canonical migration, fixture loader, app implementation, tests and contract fixtures. No sibling repository is a build input.

- `database-verification.json`: 58 assertions on the repository's own historical schema chain in an owned disposable PostgreSQL fixture. Includes current/future task RLS, viewer/revoked access, expired sessions, stale generation, limited unproven shadows, exact exports, full-root digest changes, unchanged persisted state and no additional advisor findings. Fixture removed afterward.
- `build-verification.json`: current app and UI-test products compile and pass strict signature checks in each owned isolated host, with exact source matching after namespace isolation. Release distribution is not verified. The Mac availability check reports a locked screen, so native Mac runtime remains open.
- `client-verification.json`: 70 focused comparison/adoption/repair tests, including eight new comparison tests. Fixtures contain actual SQL replies; raw opaque-value fixture envelopes are separated without re-encoding their content. The SQL-session test uses PostgreSQL's `28000` error response; HTTP 401's existing token-refresh behavior is separate.
- `native-verification.json`: one native iPhone Simulator test passes at accessibility XXXL in dark appearance. Both differing instruction lists open separately, the export action stays readable/enabled, and independent saved-state inspection after cold return finds all original/nested/unknown fields unchanged with no writes or new receipts. The first two runs are explicitly unaccepted; the final run fixes oversized list rows, truncated headings and losing the comparison on a routine snapshot refresh. Open groups now survive a fresh authorized comparison read. Native Mac/iPad comparison, new file-picker delivery and human speech are not claimed. Compilation alone does not establish those acceptances. The synthetic native peer tests controls only; it is not evidence of database authorization or record consistency.

Reproduce the database checks from this repository with `node Scripts/Database/test-child-copy-review.mjs` after the storage check. The test defaults to its own `20261101091417_reviewed_child_copy_comparison.sql`; `TASKFOLD_COPY_REVIEW_SQL` can explicitly select a candidate during development. The loader executes its own prior migrations directly, not hosted migration history. Full local-stack/hosted history parity is not claimed.

## Still required

1. Bind an explicit user choice to all reviewed copies, save full originals and relevant history with correct personal/shared custody, and apply once under fresh access and concurrency checks.
2. Map historical identities and completion lifecycles without giving new tasks credit for old work; preserve uncertainty instead of manufacturing activity.
3. Support exact opaque values in normal editable caches; finish older-data and shared-file/discussion custody migration.
4. Finish native Mac acceptance and the wider account/window/privacy/speech/large-library matrix, then hosted and genuine shared-account acceptance before normal use.
