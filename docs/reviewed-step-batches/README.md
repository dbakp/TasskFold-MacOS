# Reviewed step batches — service foundation, 6 November 2026

The independently owned service can append 1–12 reviewed literal step titles to an unfinished task or child task in one transaction and one hierarchy revision. One Undo removes the entire unchanged batch; an edit to an added step prevents Undo from discarding that work. Existing children, notes and opaque fields are retained. This service does not generate suggestions or send text to an AI provider. Assistance remains on-device only.

`taskfold_child_steps` has separate apply, read-only resolve and close operations. The exact original body and request identity recover a lost reply without adding duplicates; a closed original cannot write later. Receipts contain identities/counts rather than titles. Root/project/generation, current hierarchy revision, destination incarnation/revision/title, current authenticated session and editing permissions are checked. The new gate defaults Off. Existing single-child request and receipt shapes remain unchanged.

## Verified local scope

[Owning full-schema result](full-schema.json) records 92 genuine local Auth/PostgREST checks. The owning migrations replay on an isolated pinned stack. Checks cover twelve-step and nested/null-container insertion, literal titles and ordering, one revision and one Undo, paused exact retries and resolution, closure before write, changed requests/sources, anonymous/foreign/revoked sessions, shared-project manager/editor/viewer permissions and access loss. An injected late receipt failure rolls back the root, projection, records and activity together. Existing single insert/Undo and request-identity collisions are checked. The fixture is removed on completion. Official local advisors report only the pre-existing `pg_net` placement warning; no new advisor result is introduced.

No hosted migration, provider configuration, normal feature gate, installed app or real task data changed. No native app was built or launched for this service milestone.

## Still to implement and accept

- Typed client batch requests/receipts and availability before generation/application.
- Saved exact-request recovery, cancellation and one Undo in each owning Store/history implementation.
- Review-screen integration for independently stored child tasks. iOS must retain its explicit parent-draft Save behavior; Mac must retain autosave semantics.
- Native review/apply/Undo/cold recovery, account/access changes, accessibility and generated quality/latency. Apple Intelligence is disabled on this Mac, so genuine generation is not accepted.
- Wider legacy payload, conflict and lifecycle coverage, separate from the agreed older-client rollout deferral.

This completes a service foundation, **not** the user-facing independent-subtask assistance feature. Further physical iPhone installation remains deferred.
