# Child activity history foundation — 26 October 2026

The recording foundation has now been connected to committed local edits,
optional workspace reads, access masks and backup archives in both apps. Activity
screens and aggregate widgets still use parent history; their child integration
is next. See [the integration milestone](TASK_NODE_ACTIVITY_INTEGRATION.md) for
current behavior and verification. Normal heading authoring stays disabled; no
hosted schema, feature flag or real data changed. The notes below retain the
original foundation milestone's evidence and remaining-work sequence.

## Contract

Each child occurrence is identified by root ID, root generation and stable node
key. Paths are context, so a move within the same tree preserves identity; a
recreated root creates a distinct occurrence. Current routing requires a fresh,
validated tree and the same root owner/generation. Legacy generations remain
readable but cannot route into current data. This resolver is not write authority.

The separate `task_node_activity` feed preserves the existing parent ledger and
its older readers. It records actual creation, completion, reopening, completion
time correction, movement, planning, deletion, type and work-scope changes. Heading
context and ordinary checklist detail remain distinguishable from independent
work. Importing an already completed child, changing its type or promoting a
checklist does not invent a historical completion. Effective completion time and
server receipt time remain separate.

Rows contain bounded identity, containment, planning and completion metadata, not
titles, notes, comments, labels or attachments. Duplicate identities, legacy text,
unsupported types and unreadable trees produce an explicit coverage gap without
repairing source data or fabricating backfill. Later known transitions can resume
recording. Local retries use stable mutation/node event IDs; cursor exhaustion
cannot write half a multi-node change. Future/unreadable existing feeds are retained.

Authenticated clients have read access through the existing parent-history access
predicate. They cannot write the ledger or invoke its private trigger writer.
Collaborators cannot see private prior/next scope metadata, and lose access on
revocation. Owner deletion removes their rows; actor deletion retains events with
an unknown actor. This reuses the existing history ownership contract; it does
not relax task editing authorization or replace existing ownership-transfer rules.

## Verification

Both independently owned repositories pass 53 focused Core tests (22 new),
including real PostgreSQL-produced rows decoded by Swift. Each independently
created PostgreSQL 17.6 fixture passes 49 database checks: actual transitions,
retries, shared/private/revoked access, permissions, incarnation/owner changes,
deletions, unsupported sources and a 10,000-child tree. Creation takes about
1.7–1.9 seconds and changing one child about 0.9–1.0 seconds on the owned,
CPU-limited fixture; these are local samples, not production latency guarantees.

The official Supabase advisor ran against each disposable fixture. It reported
no findings on the new objects; its only warning concerns the synthetic bootstrap
policy `fixture_task_access`. Containers were removed. The final runner also
asserts absence of new-object findings; this assertion was separately evaluated
against both saved reports after the 49-check runs.

Migration was created with the CLI and verified as raw SQL on isolated fixtures.
Those fixtures include the relevant parent-ledger migrations and minimal synthetic
dependencies, not the complete hosted schema or HTTP deployment. No deployment,
full-schema upgrade or REST exposure acceptance is claimed. Private definer code
is limited to the non-callable ledger trigger; ordinary source DML retains its
existing authorization.

The prepared Mac native list test was retried after the unlock reply, but computer
use again reported the Mac locked before app interaction. The owned test was
stopped (exit 75); no runtime pass is claimed. Its host/build remain available.
No new app binary, installed widget, accessibility or cross-device acceptance is
claimed for this inactive model-only stage.

See `child-activity-history/database.json`, `core.log` and `evidence.json` for
results, source hashes and exact scope. Reproduce from this repository with:

```sh
swift test --filter 'TaskNodeActivityTests|TaskActivityTests'
node Scripts/Database/test-task-node-activity.mjs --report /tmp/taskfold-child-history-report.json
```

The database command creates only an owned disposable container. Advisor access
uses an ephemeral loopback port. It does not read a hosted project URL or token.

## Original integration sequence (current status linked above)

1. Add optional, account-bound feed/epoch reads with complete paging and explicit
   unavailable/coverage states. Apply current team visibility masks, account-switch
   fences, adoption/recovery rules and read-only write guards in both apps.
2. Wire local recording into committed local mutations, and preserve the new
   metadata as an archive in backup/export. Never replay historical rows as edits.
   Verify Undo, retries, restored snapshots and unavailable/future ledgers.
3. Combine parent and child history for activity, Insights and Project pulse using
   independent occurrence identities and work-before/after semantics. Preserve
   original parent credits and expose the child coverage start; distinct feeds
   have distinct sequence spaces. Never infer past root type from today's type.
4. Verify real app lists, routing, widget refresh and cross-device/account changes;
   then continue wider calendar periods and remaining headings authoring/adapters.

The broader Px goal stays open. Release signing/distribution, remote reminders,
older-client rollout gates and deferred external-provider configuration remain
separate user-deferred work.
