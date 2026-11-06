# Bounded repair originals

Ordinary use remains **disabled**. This closes the unbounded history-aggregation gap in the existing atomic repair candidate; the broader older-work migration checkpoint remains **To build**.

## Change

The original builder opens one explicit forward-only cursor over historical rows ordered by sequence. It rechecks one row’s historical visibility, serializes it and admits its exact UTF-8 byte count before retaining it. The original root, metadata, array punctuation and separators share the existing 8,000,000-byte budget. Accepted rows are assembled once from their captured text; there is no second all-history aggregation or second-query snapshot race. The final canonical size is checked again before the original can be saved.

A task/sequence index supports selective ordered reads. The planner may prefer the existing global sequence index for a task containing most of the fixture's history; representative cursor plans verify ordered index scans without a Sort, without forcing planner settings.

The inner repair implementation calls this builder. Existing root/realm/session locks, archive quotas, immutable receipts, caller RLS and current historical-permission checks remain. The helper and retired inner implementation have no client execution grants. No flags, app sources, hosted configuration or hosted schema were changed.

This bounds the retained serialized archive, **not total PostgreSQL memory**: the existing root, one historical row, JSON conversion overhead and database execution working memory still exist. Extremely large individual values, production latency and broader library-scale acceptance need separate checks. The new index is a regular migration index; production deployment must plan for its build lock before enabling this candidate.

## Evidence

Each repo independently passes **313 actual PostgreSQL checks**, including the prior 283-check repair/history suite and 30 additional assertions. The owned fixture is removed after each run; advisor findings remain seven before and seven after, with no additions.

- Exact 8,000,000-byte originals pass; one-byte overflows fail, with and without historical rows. UTF-8 values and array separators are accounted for.
- Canonical originals equal the old reference construction; historical order, unknown root values and all historical generations are preserved.
- A later sentinel proves that the builder stops before inspecting further entries after overflow.
- An actual repair with 3,000 historical entries preserves every original entry, root, archive byte count and digest.
- An actual oversized 9 MB history refuses without a root change, archive, receipt or projection, and preserves all 18 input entries. Its unknown request remains checkable and can be explicitly stopped.
- Both representative broad and selective cursor plans are recorded. Private helper privileges, public caller-RLS and historical access regressions pass.

Run `node Scripts/Database/test-child-repair-bounded-originals.mjs` from this repository after its storage guard. The script uses an isolated synthetic PostgreSQL fixture and never contacts a hosted project. The full default local Supabase database is unavailable, so `supabase migration list --local` could not connect; only the relevant dependency/migration chain was executed here. App source hashes still match the preceding guided-native acceptance; no app rebuild or native retest was warranted for this SQL-only change.

Development trials corrected two fixture issues: an oversized command argument was replaced by SQL-generated payloads; the plan assertions were changed from a full SELECT/one required index to the actual cursor workload, allowing the planner's valid broad-index choice. The final migration did not require weakening its size or custody protections.

PostgreSQL documents [cursor-based row retrieval](https://www.postgresql.org/docs/17/plpgsql-cursors.html) and [EXPLAIN for DECLARE](https://www.postgresql.org/docs/17/sql-explain.html). Current Supabase function/security guidance and relevant changelog entries were reviewed before implementation.

## Still open

Normal opaque editing/cache support, indexed/history identity reconciliation, attachment/discussion custody, partial repair-review drafts, broader native action/account/window/background/concurrency/spoken/export-provider acceptance, original cleanup/restoration/Undo and genuine PostgREST serialization remain. This change does not enable everyday migration or finish the entire large-work workflow.
