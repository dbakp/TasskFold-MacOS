# Project file review — first transfer step

The project transfer review now includes attachments on tasks, subtasks and older inline comments. The previous inspection counted task/subtask attachment arrays but could offer a transfer when a provider file existed only in an inline comment. The candidate now includes those references in provider-custody requirements and refuses that move until file access has its own approved transfer path.

Both clients read an optional versioned summary: stored references, older unmapped references and references needing attention. Unsupported versions, malformed or contradictory counts and an already-enabled transfer claim are refused. Older server payloads remain readable. The summary is read-only; it cannot create a transfer command or substitute for consent. The existing transfer request/receipt format is unchanged.

Private provider identity, owner, bucket configuration, material metadata and object version contribute to the signed inspection. A change invalidates a prior review. Read bookkeeping timestamps do not. Only the current actor’s unbound legacy objects in the private attachment namespace are inspected; inaccessible, foreign and already-bound references stay opaque. Their existence, metadata changes and deletion cannot be monitored through review-token changes. File names, object IDs and provider paths are not returned to the client.

The scanner retains the existing 32 MiB source budget and 32-level checklist boundary. In particular, a normal 5 MiB inline attachment remains supported. References are bounded, and provider/custody summaries retain their own 10,000-item limit. Storage metadata is read only; the candidate never writes, moves or deletes Storage objects through SQL. Existing task/project lookup and object-identity indexes are reused.

## Verification scope

The focused database suite uses the production review/commit functions with synthetic sessions and Storage metadata. It reproduces the old comments-only omission and checks ownership/version/bucket changes, private helper privileges, unavailable-reference noninterference, malformed/deep/large references, inline/external-only commit and paused exact receipt recovery. Advisors introduce no new keys over that fixture’s seven existing warnings.

The full-schema service suite independently replays each owning migration history and uses genuine disposable Supabase Auth, PostgREST and Storage APIs. It uploads one original synthetic file through Storage, reads exact bytes with the original owner, refuses an outside reader, saves the comment reference through authenticated REST, reviews it and verifies that unapproved custody change is refused without replacing bytes or changing the task/project. All owned containers and their bounded tmpfs data are removed. This is local internal-HTTP service proof, with a file-backed Storage provider; it is not hosted S3, release TLS, native app or physical-device acceptance. The complete-schema advisor still reports the previously recorded pg_net placement warning.

The five new client tests decode actual captured local SQL responses and verify bounded/versioned counts, older payloads, cold encoding and refusal to turn the inventory into approval. App builds/signatures are tracked separately. Native layout, VoiceOver and actual move controls remain unaccepted. No hosted schema or service deployment, normal gate change, installed app update or real task/file modification occurred.

## Still required for complete file transfers

Implement explicit owner/audience consent and a signed file-transfer policy, verify original provider bytes, lock and recheck the provider inventory before transactional custody changes, and preserve exact retry/receipt recovery. Add native controls and encrypted pending recovery, legacy reference resolution and the other ownership/realm directions. Downloads, access retirement, existing links/copies, history, retained/private files and discussions need their own complete integration checks. This inventory closes a review gap; it does not complete whole-project file transfer or the Px goal.

## User decisions

On 5 November the user chose on-device-only task breakdown and filter suggestions; no cloud assistance provider or fallback is planned. Further iPhone installation is deferred. Installed phone34 and Mac14 and their running sessions are unchanged by this work.

## Reproduce

Run the free-space preflight first; serialize heavy platforms and retain cleanup evidence.

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-project-file-inventory.mjs /tmp/taskfold-file-review-sql.json --export-fixture
node Scripts/Database/test-full-schema-project-files.mjs /tmp/taskfold-file-review-api.json
swift test --scratch-path ~/Library/Caches/TaskfoldBuild/core-ios --filter 'TeamProjectAdoptionTests|TeamProjectFileInventoryTests'
```

The Mac repository uses its own core-mac scratch cache and independently generated migration. Each repo owns its code, fixtures, runners and deployment inputs.

Current [Storage schema guidance](https://supabase.com/docs/guides/storage/schema/design), [access controls](https://supabase.com/docs/guides/storage/security/access-control) and the [changelog](https://supabase.com/changelog) were reviewed. The installed CLI remains pinned at v2.109.0 after reviewing the v3 breaking change. No engine/SDK update, TLS override or credential/public grant change was introduced.
