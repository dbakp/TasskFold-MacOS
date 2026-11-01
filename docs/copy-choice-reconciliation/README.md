# Transactional saved-copy reconciliation backend

This milestone implements the **server transaction**, not the app's copy-choice controls. Existing apps still offer comparison/export only. Normal repair/migration entry points remain disabled, the new `copy_reconciliation_enabled` database flag defaults to false, and nothing was deployed to a hosted project.

A caller can explicitly select the task list, saved snapshot or stored-record copy. The request contains the source name and current comparison fingerprint, not a replacement task tree. Before any live data changes, the server saves the complete original root, SQL-null marker, projection, record rows (including incarnations/revisions/field versions), authority and root/child history. The chosen copy is then staged into the existing records and applied through the caller's real task UPDATE policies. The original, records, mirror, activity, scope and receipt commit together or roll back together.

## Supported scope and unfinished work

The initial apply path requires the same canonical/raw references, existing incarnations and matching completion, type and recipient lifecycle fields. It preserves existing event rows and original completion dates, rather than rebinding history or manufacturing completion credit. Unsupported activity shapes, ambiguous identities/completions and unproven private copies remain blocked for an explicit mapping/custody review. The ordinary three-source content workflows, legacy collaborators and native-team editor/viewer boundaries are verified; broader historical, hierarchy, scale, HTTP and genuine-account acceptance remains open.

Still required:

- Add the client change type and copy-selection controls; connect reviewed previews, durable drafts, send/check/close recovery and original export to the existing repair model. Validate the actual native flow before calling this an app feature.
- Implement explicit identity/completion/recipient mapping for blocked cases and full older-data/opaque editable-cache migration.
- Provide surviving workspace members' archive discovery/recovery, beyond retained data and the current actor's existing saved-command recovery. Retaining a team archive after editor deletion is not proof of that user flow.
- Finish shared file/discussion custody, native Mac and wider account/window/privacy/speech/library checks, then hosted/full-stack migration acceptance. All prior user deferrals remain deferred.

## Authorization, custody and replay

- Live account/session, generation, project/workspace and current access are checked under the existing locks. A copy fingerprint binds all stored versions and the full root; the repair fingerprint also binds the exact history set. That history is checked again against the original being archived and against caller-visible rows after the patch.
- The public wrappers remain invokers. Actual UPDATE USING/WITH CHECK and SELECT rules can reject the patch, rolling back the staged archive and all writes. The team bridge adds only a private transaction proof to the two inspected UPDATE policies, retaining their existing predicates. It requires the current actor, transaction, root, realm, matching applied repair/original, live editor role, unchanged top-level root fields and the exact selected mirror. Other restrictive policies remain effective. Ordinary team writes remain closed outside this proof.
- Retired public wrappers move into the private schema. They retain caller-RLS behavior for ordinary repair/duplicate-history requests without leaving a retired public route available. Their backward compatibility is tested separately.
- Personal originals belong to the actual task owner; team originals belong to the team. Team content survives deletion of the editing account and is purged by the workspace's existing deletion lifecycle. Original delivery requires the same current task context and rechecks every archived historical row against current caller permissions.
- The existing actor/team nonce fences and repair ledger preserve send/check/close/original semantics. A replay returns the original receipt without another archive or source write. Contentless receipt recovery survives task deletion; original delivery does not bypass a missing or changed context.
- Original storage stays bounded: 8 MB per original, 64 MB per actor and personal owner, 256 MB per team and the existing daily decision budget. Personal-owner quota checks share that owner's lock, so collaborators cannot consume an unguarded separate quota. History is streamed with byte and row limits before aggregation; full archive size is checked before insertion.
- JSONB value equality alone treats numeric spellings such as `1` and `1.00` as equal. Record changes, field-version changes, materialization, the final mirror and the scoped policy use canonical text with C collation where exact content is required. The selected spelling is retained while the old spelling remains in the original. Large exact integers, huge numeric values and distinct composed/decomposed Unicode keys also survive the transaction.

## Verification and reproduction

`workflow-verification.json` and `repair-regression-verification.json` record the actual results and migration hash for this repository. These use owned disposable PostgreSQL fixtures with synthetic data and no public ports. Each fixture is removed afterward. Advisor comparisons report no new findings; that does not mean the minimal prerequisite schema has no pre-existing findings.

The workflow fixture loads this repository's own prerequisite migrations, including bounded originals and field/order activity. The regression fixture keeps its earlier repair baseline and adds the new comparison/reconciliation layers, exercising ordinary repairs and explicit duplicate-history keepers through the current wrappers. Neither is a full local Supabase stack or proof of hosted migration-history parity. The fixture's existing UPDATE policy is renamed to the inspected production policy name without changing its predicates; the migration fails closed if the canonical policy shapes are absent.

From this repository:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-child-copy-choice.mjs
TASKFOLD_COPY_CHOICE_REGRESSION_SQL="$PWD/supabase/migrations/20261101101059_reviewed_saved_copy_reconciliation.sql" node Scripts/Database/test-child-duplicate-history.mjs
```

`contract.json` contains actual synthetic SQL preview/receipt/original replies for the forthcoming client integration, not a hand-written expected response. `earlier-failures.json` distinguishes the rejected wrapper/numeric-spelling versions from the final implementation. No new Swift/app build or native acceptance is claimed for this backend-only milestone.

Completed native build outputs and clean dependency caches were pruned after their prior source hashes, signed-product verification, screenshots and saved-data proofs were retained. Source hosts and dependency pins remain. A fresh build is required for the next client implementation; simulator/app data and real user data were not erased.
