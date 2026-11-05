# Reviewed project file transfer — 5 November 2026

The service can now move an eligible personal project into a team and publish its prepared file copies in one reviewed transaction. The owner explicitly chooses `share_copies_keep_originals`. The originals retain their provider identities, bytes, metadata and private owner access. The new team receives access to immutable copies through the existing authenticated file gateway. This completes the scoped service path beyond private preparation; native controls and encrypted pending recovery for this new file policy remain to implement. Nothing is deployed or enabled for normal use.

## Consent and atomic behavior

The file policy is optional on the existing project review and commit commands. Without it, the existing provider-custody refusal remains. The new private transfer gate defaults to Off in addition to the preparation and existing team/adoption gates. The policy names an actor-owned, unexpired, fully prepared plan for the exact current destination scope and inspection. Files with unresolved references, unsettled writers, expired reservations, changed source/copy metadata, lost access or mismatched task identities cannot be approved.

A review locks its plan, upload ledgers, private bucket and original/copy object metadata, then refreshes the original project inspection. Its signed proof extends the existing access/connection/recording review proof with the explicit file action and exact private prepared inventory. No provider path or original/copy object identity is returned in the consent summary. Existing collaborator decisions, team access, source fences, integration policies, recording policies, child/history custody and review expiry checks remain in the coordinator. An old client receives its original read-only inspection behavior and cannot infer approval from an inventory or preparation alone.

Commit registers the exact file admission scope, rewrites only the known task/subtask/inline-comment attachment references, updates independent child records through their existing authority/mirror path, publishes task-bound file custody and completes the project transfer together. Attachment UI identities, per-reference display names, opaque fields, child order/identity and discussion text survive. Old provider URL fields on replaced typed references are removed. The existing file-to-team-project foreign key is retained and deferred to transaction commit so the private graph can be installed atomically; parentless custody still cannot commit. No triggers, grants or row security are disabled. See [PostgreSQL's constraint documentation](https://www.postgresql.org/docs/current/sql-altertable.html).

A late failure rolls back root references, independent child records, custody bindings, ledger publication and the preparation's committed state. Verified private copies remain available for a retry. A successful receipt records the policy, preparation ID, file count and bytes, without provider identities. Exact retries recover that receipt after transfer gates are paused and never overwrite later work or upload another copy. A committed preparation reports that the transfer happened and cannot be cancelled.

## Ordinary file compatibility

A normal 5 MiB inline file remains supported when a stored copy shares its task. The older whole-document 4 MiB reference check is raised to the existing project-review 32 MiB document budget; node/reference/unique-object limits remain unchanged. Preparation now preflights those task limits before creating a plan or uploading copies and returns a review requirement for an oversized reference set. It does not spend provider bytes on a transfer that cannot pass the task reference guard. SQL reads Storage metadata only; bytes remain owned by the [Storage API](https://supabase.com/docs/guides/storage/schema/design).

## Verification scope

`full-schema.json` records 81 passing checks and contains the complete owning migration hashes and genuine disposable Auth, PostgREST and pinned file-backed Storage results. It uses production preparation and download handlers, real actor JWTs, synthetic files, independent child records and an intentionally retired personal collaborator. It verifies explicit consent, wrong action/scope/actor refusal, unprepared and forged-request refusal, a forced late rollback, atomic project/custody publication, all known attachment locations, preserved aliases/opaque fields and the 5 MiB inline file. It checks exact new-audience download bytes, original privacy, direct Storage bypass refusal, retired/outside audience refusal before provider access, access loss crossing an actual download, committed-plan state, bounded reference preflight and exact paused receipt replay.

The 24 passing handler tests separately verify strict committed preparation facts: an unfinished plan cannot report a completed transfer. The complete-schema advisor introduces no finding beyond the previously recorded pg_net placement warning. All owned fixture containers and bounded tmpfs data are removed. The test's fixed virtual HTTPS file-gateway origin is mapped to its owned loopback API transport; this is not TLS acceptance. There are no synthetic Auth/SQL/Storage replies in these service flows, but this is not a deployed Edge runtime, hosted S3 or release installation test.

No Apple app code changed in this milestone, and unchanged builds/UI matrices were not repeated. Installed phone34 and Mac14, their drafts and frozen packages are unchanged. Assistance remains on-device only; further iPhone installation remains deferred.

## Remaining work before this is an everyday feature

Implement native preparation/progress/consent controls, exact file-policy command and receipt decoding, encrypted preparation/pending recovery, saved-draft/session/access cancellation and appropriate native/large-text/speech/keyboard acceptance. Verify combined recording/integration policies with files, wider concurrency/lifecycle/history/account-removal cases, legacy/unavailable references, other ownership/realm directions and hosted providers. Existing unresolved producer-terminal recovery and maintenance acceptance remain open. Do not enable a hosted/normal-use transfer gate on the strength of this scoped local service milestone alone.

## Reproduce

From this owning repository, serialize the heavy fixture:

```sh
python3 Scripts/check_test_storage.py --path /tmp
deno test supabase/functions/project-files/handler_test.ts
deno run --allow-run --allow-env --allow-read --allow-write --allow-net=127.0.0.1 Scripts/Database/test-full-schema-project-file-transfer.ts /tmp/taskfold-reviewed-file-transfer-own.json
```

Each app repository owns its migration, service source, tests and release inputs independently. No sibling checkout or dependency is required.
