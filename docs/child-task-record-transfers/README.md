# Reviewed same-team transfers with independent child records

30 October 2026. Both repositories independently own this server/client stage. No hosted schema, real root, ordinary feature flag or release setting changed. The full migration and Px goal remain open.

## Result

The existing signed team-task move and its durable Undo now support promoted record-authoritative roots. The exact actor/transaction/task/generation/old-row/new-row proof already used by the move protocol authorizes the record binding change. The trigger writes the reviewed child rows first and updates their project binding; deferred mirror checks retain atomic rollback. Direct project writes and generation changes cannot spoof this scope or silently demote records.

Sparse/null child lists use a bounded move-specific decoder and assignment clearer. They preserve raw IDs, unknown fields, notes, ordering and absent/null/empty containers. Existing nonce, live role/session, discussion/mention, provider-file refusal, content-hash, TTL, recovery-key and receipt checks remain. The newer recursive assignment guard now honors the original authorized move-Undo scope, so it restores reviewed original assignments rather than clearing them again.

A reviewed same-team move keeps private deleted-subtask archives instead of purging them. Content and original receipt scope are not rebound or shared with the destination. Only the original actor discovers metadata/disposes it; restoring in the destination is refused. After a reviewed return to the original project, the original actor can restore the certified private subtree. Archive FK cascade definitions for root/account deletion and capacity limits are unchanged; full lifecycle acceptance remains below. The review reports only that actor's bounded archive count, with a private-retention policy; another actor sees zero for those copies.

Both clients decode the additive private-retention policy/count, preserve compatibility with older replies, and show a short native review note when the actor has retained copies. Unknown/unpaired policies or invalid counts are refused. A move-only read decoder now accepts sparse/null trees in both review and confirmation while keeping identity, depth, count and completion-token checks; ordinary checklist mutation validation stays strict. Actual SQL move and Undo replies are decoded and confirmed by both owned Core suites without copying private policy/count/task data into commands.

Whole-project adoption still lacks a custody adapter for promoted records and private child archives. A trigger now refuses that realm change for either case, including legacy-mode roots with an archive, retaining the original project and exact private contents. This is a temporary explicit implementation boundary, not completed adoption support.

## Evidence

Each repository passes **475 actual PostgreSQL checks** on the combined current candidate chain: 68 transfer/custody cases, 90 existing move cases, 96 record-authority cases and 221 structure cases (the latter include the existing 220 plus the enrollment guard). The promoted-root cases cover move/Undo, null/sparse data, assignments, stable incarnations, discussion and mentions, exact retry, stale source-project child edits, private archive retention/non-disclosure/destination refusal/return restore, direct-write refusal, late receipt rollback and both realm-fence branches. The existing suites also run with the current candidate applied; they are not all promoted-root native acceptance.

Each repo passes **168 selected Core checks**: 29 team-move and 139 hierarchy cases. Eight added team-move methods cover legacy/new policy decoding, invalid counts/policies, real SQL review+confirmation, sparse tree validation and identity/depth/node limits. Both app/test products build and verify their development signatures in reused isolated hosts. These builds establish no new native UI, VoiceOver, largest-text or real-account walkthrough.

The captured wire fixture came from the 63-check phase on the same canonical SQL, before adding the five archive-only custody-fence cases. Its replies and policy/count are actual synthetic SQL outputs; the final compiled Core resource bytes match the owned fixture. The final server phase is the expanded 68-check run. Exact phase/source hashes, reports and compressed logs are retained.

Earlier failures are preserved: an expired fixture used the wall clock rather than an explicit fixture time (production expiry checks stayed unchanged); real SQL data exposed the array-only client decoder and prompted the actual read-decoder fix; and an empty archive query needed explicit JSON null encoding. None is counted as a passing phase.

Official advisors add no findings to the minimal fixture's seven existing notices. Fixtures use inspected real authorization/history/custody migrations and PostgreSQL 17.6, not the complete hosted schema. Storage preflights and sequential owned containers were used; all fixtures were removed. CLI-generated canonical migrations were tested directly in those databases. The full local Supabase stack is unavailable, so local history parity remains unverified; the diagnostic is retained. No hosted apply-migration operation ran.

## Remaining

- [ ] Reviewed personal/cross-team transfers and whole-project adoption, including the guarded record/archive custody review.
- [ ] Cross-root moves, older/malformed-data review/adoption tools, complete-current-schema/provider/Storage/account/team deletion and large-workload acceptance.
- [ ] Native/spoken/largest-text acceptance of the updated review note and wider account/window/background/secure-storage recovery.
- [ ] Hosted rollout/backfill, older-client transition and distribution remain deferred, together with the user's other explicit deferrals.

Existing move bounds remain: 128 KiB task envelope, 16 KiB request, 500 discussion comments, 1,000 children/24 levels, and existing bounded private archive/recovery-key policies. This does not remove whole-tree compatibility serialization or prove production latency.

## Reproduce

Run `node Scripts/Database/test-child-record-transfers.mjs /tmp/transfers.json` in this repo. Set TASKFOLD_CHILD_TRANSFER_SQL to this repo's child_record_reviewed_team_transfers migration for the existing move and record-authority suites. For the structure suite also set TASKFOLD_RECORD_AUTHORITY_SQL and TASKFOLD_FIELD_NATIVE_SQL to this repo's corresponding migrations. Each loader resolves only its own repository's files. Run the team-move/hierarchy Core filter and build the owned app/test products separately.

Reviewed [Supabase triggers](https://supabase.com/docs/guides/database/postgres/triggers), [database functions](https://supabase.com/docs/guides/database/functions) and [PostgreSQL lock ordering](https://www.postgresql.org/docs/17/explicit-locking.html#LOCKING-DEADLOCKS), alongside the current Supabase changelog. Authorization uses the existing live actor/session and private transaction scope, not editable user metadata or a caller-set flag. New helpers have empty search paths and explicit closed grants. No views or Storage grants are added.
