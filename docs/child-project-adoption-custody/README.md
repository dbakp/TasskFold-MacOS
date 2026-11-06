# Reviewed project adoption with separate subtasks

Reviewed 2026-10-30. This phase extends the existing signed transfer of a personal project branch into a team. It does not enable ordinary-use feature gates, apply hosted migrations or promote real roots.

## Behavior

- The inspection and final review bind actual subtask records, projections, authority bindings and private deletion copies into the bounded signed content digest. Archived subtree text and other actors' archive identities/counts are never returned in the review.
- Existing role decisions, hierarchy, archived-project placement, provider-file refusal, personal-connection pause consent, discussion/history custody, receipt identity and exact retry behavior remain in the real commit path.
- Reviewed assignment changes write promoted records first and reconstruct the compatibility tree. Sparse, absent and null containers and opaque fields survive. Personal root/task/project identities and task generations stay intact.
- Current child incarnations renew at the ownership boundary; the topology revision advances even when its shape and project UUID do not change. Unconfirmed personal field/completion/structure requests must refresh. Confirmed metadata-only deletion receipts remain recoverable without applying work again.
- Deleted-subtask copies remain private and actor-disposable. They cannot be restored into the team's hierarchy. Previous insert/move/delete Undo also cannot cross the boundary. Neither the team nor its administrators receive archived subtree text through this transfer.
- The review locks source roots before private child state and uses nonblocking custody locks, so an in-flight archive disposal requests a fresh review instead of reversing lock order. A late failure rolls back child identities, private-copy state, assignments, sharing, history, team bindings and receipt creation together.
- Unreviewed realm changes remain fenced for promoted roots, private archives **and unpromoted child projections**. Only the current transaction's reviewed, completed custody scope admits adoption.
- Both clients validate a paired custody protocol, retention policy and actor-owned count (0–64), reject unknown/unpaired values, and explain the consequence in the existing transfer review. The immutable saved command and confirmation/retry contract do not gain client-supplied custody assertions.

## Verification

See [verification.json](verification.json) and the owned compressed logs for exact source hashes, database/client checks, build results and scope limits. The new Swift wire fixture is captured from the real synthetic SQL inspection, review, sorted command and successful receipt on this canonical migration, then independently compiled/tested by each repo.

The initial failing database run exposed the existing topology trigger overwriting the attempted ownership-boundary revision bump. The final implementation recognizes only the exact private adoption scope when advancing the unchanged topology. A separate malformed completion baseline and a fixture-path setup error were harness failures, not accepted checks; their diagnostics are retained separately. No failure is counted as a pass.

Reproduce the new custody cases with:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-child-project-adoption.mjs /tmp/taskfold-child-adoption.json
```

For the existing project adoption/connection policy, authority and structure suites, set `TASKFOLD_CHILD_ADOPTION_SQL` to this repo's `20261030102036_child_record_project_adoption_custody.sql`; the authority/structure stack also takes this repo's `TASKFOLD_CHILD_TRANSFER_SQL`, and structure takes `TASKFOLD_RECORD_AUTHORITY_SQL`. All inputs are owned by this repo. The default suites retain their previous setup and assertions.

## Still open

This is the personal-branch-to-team adapter, not a general cross-team/return-to-personal or individual personal-task transfer. Cross-root child moves, older-data review/adoption tools, full-schema/provider/Storage custody, large workloads and broader native/account/window/background/spoken acceptance remain. The new review text is built but not claimed as a fresh VoiceOver or largest-text acceptance. Local direct fixtures do not establish Supabase migration-history parity or deployment readiness; the full local Supabase stack is unavailable. User-deferred remote push, older-client rollout safeguards, OAuth/email configuration, genuine audio/location delivery and distribution remain deferred.
