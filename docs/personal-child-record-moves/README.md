# Personal task moves with separate subtasks

Reviewed 2026-10-30. Routine personal project/Inbox moves now integrate with the separate-subtask candidate through the existing mutation queue, picker, conflict review and Undo history. This phase does not deploy migrations, promote real roots or enable ordinary-use feature flags.

## What changed

- A persisted optional queue marker selects the new move endpoint. Newly authored cloud moves capture it only under the existing separate-child read/write gates; a saved request retains its route and UUID across retry, restart and subsequent gate changes. Older unmarked queues and local-only work keep their previous route.
- Routine moves no longer upload a stale whole checklist just to clear assignments. Local projection clears assignments and the old section immediately, preserving null/empty/sparse child containers and opaque fields. The server clears the **current** child assignments, writes promoted records first and rebuilds the compatibility tree. Mixed authored root edits keep the existing baseline merge; a newer disjoint child note survives.
- The request binds account, mutation UUID, root, task generation, original project and the exact baseline/changes. A private transaction scope binds the old full row and admitted new row. Only that proof relaxes the promoted-record project fence; the actual public task write remains an invoker operation with RLS. Caller-set flags and direct ordinary project replacement cannot manufacture it.
- Project and Inbox access are checked independently; team/shared-workspace custody remains on its reviewed path. Inherited archive state blocks an invalid destination. An old source section clears automatically; an explicitly chosen destination section must belong to that project and is held through commit.
- Saved deleted-subtask copies stay actor-private and bound to their original project/generation. They cannot publish into the destination; a valid explicit return permits the original certified restore. Disposal/quota and root/account deletion behavior remain on their existing paths.
- All confirmations are metadata-only, including the first success. Current workspace reads supply task data. A successful old request can be retried after later moves, deletion, access loss or disabled rollout without reapplying the move, returning old task contents or overwriting later local work.
- A confirmation-only mode can check a blocked original request without starting it. An unknown result preserves the pending request. The existing automatic unavailable-project cleanup does not discard this durable move before its result can be checked.
- Explicit Keep mine creates a fresh request identity; an already-achieved destination removes only the redundant move while retaining other authored root edits. Undo/Redo also get fresh request identities. Valid original section/root assignment are restored through the existing membership-guarded assignment step; child assignments continue to clear on a project move.
- Preparation cannot be committed alone. A deferred check prevents durable orphan scopes/private request bodies. Late receipt failure rolls back the root, child records and authority binding together. UTC proof hashing also works when the caller's session uses another time zone.

## Verification

[verification.json](verification.json) binds current owned sources, canonical SQL, actual database/client logs, compiled wire fixture and signed build products. Each repo executes its own canonical migration and independently compiles its own client and resource fixture. The final synthetic wire fixture is an actual successful SQL command and its contentless first/retry/confirmation-only responses.

The new database cases cover nullable and legacy-null generations, sparse/empty/null children, actual row-derived mirrors, source-bound private Undo, source/destination permissions, metadata recovery, later-move preservation, newer disjoint child notes, section validation, blocked preparation and late rollback. Existing authority, structure, team-move and whole-project-adoption assertions also run with this migration applied. See the owned reports for exact totals and zero added advisor findings.

Failed development phases remain separately named. They include an SQL variable qualification error and null/SQL-null comparison correction, a test HTTP-body stream assumption and a stale-generation test fixture that correctly refused local application. The production generation check was retained. Earlier pre-section build successes are not accepted as the final source phase.

Reproduce the new synthetic database cases:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-personal-child-moves.mjs /tmp/taskfold-personal-moves.json
```

Combined regression runners take this repo's `TASKFOLD_PERSONAL_MOVE_SQL`, together with its existing `TASKFOLD_CHILD_ADOPTION_SQL`, `TASKFOLD_CHILD_TRANSFER_SQL` and (for structure) `TASKFOLD_RECORD_AUTHORITY_SQL`. No runner imports runtime/build inputs from the sibling repo.

## Remaining scope

This accepts the recorded local database/client/build scope, not a fresh complete app/Keychain/account/window/background or spoken walkthrough. Whole-schema discussion/provider/Storage custody, cross-root child moves, cross-team/team-to-personal transfers, older-data review/adoption tools and large-workload acceptance remain. Ordinary personal baseline semantics are retained; this is not the deferred older-client rollout-safeguard upgrade. Source-only direct fixtures do not establish hosted deployment or full local Supabase migration-history parity. All existing user deferrals remain.
