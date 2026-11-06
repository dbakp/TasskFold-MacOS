# Reviewed on-device steps for saved subtasks — 6 November 2026

## Built in each owning app

The saved-subtask organizer now opens an editable, on-device step review for the root task or a nested task. It reads current saved records, checks service availability before generation and again before saving, and binds the current account/session/workspace/access and exact source. Apple Intelligence receives only the editable goal text. Selected titles remain literal: dates, labels, people and metadata are never inferred into saved fields. Up to twelve reviewed steps append together, preserving existing children and notes. This separate saved-record flow does not silently save an iPhone editor draft or change Mac autosave behavior. Legacy draft suggestions remain available through their existing flow.

Private encrypted request history is saved before sending. Check status is read-only; Retry uses the exact original request; Stop can close an unapplied original even while new writes are paused. Uncertain requests cannot be forgotten. Saved additions remain reachable after the task becomes unavailable or the rollout gate is disabled, without adding an empty recovery control to ordinary paused accounts. One dedicated Undo removes all unchanged steps. Competing windows recover the same saved Undo identity. Removing settled history requires confirmation and leaves tasks unchanged. Account removal includes this new private journal; pending steps also block conflicting child-action families.

The separate service appends 1–12 steps in one transaction and one hierarchy revision, retaining the existing single-child API and receipt shapes. A new read-only availability endpoint reports current gate/editing access. Apply still repeats full admission. Its gate defaults Off; no hosted database or installed app changed.

## Current evidence and limits

- [Owning complete schema/API result](full-schema.json): **104** genuine local Auth/PostgREST checks, including paused/foreign/shared manager/viewer availability, insertion, one Undo, exact retry/closure, access loss, revoked sessions, legacy single insert/Undo and late-failure rollback. All owned fixtures are removed. Advisors retain only the pre-existing pg_net placement warning.
- [Owning client checks](client-verification.json): **102 passes, 1 explicit real-model skip, 0 failures** across 103 selected cases. Genuine service-produced wire fixtures exercise strict counts/identities/revisions, nested destinations and literal fields. Real encrypted file round trips, cold recovery, competing Undo requests, cancelled leases, paused-write Check/Stop and cross-family admission are covered. The initial root/null-parent recovery-reader failure is fixed; nullable root revision is accepted while malformed/lossy counters remain refused.
- [Current native app build](signed-build.json) compiles and passes strict signatures. This is build acceptance, not a walkthrough of the new screens or genuine Swift Backend HTTP acceptance. The ordinary test selection previously skipped inference by opt-in; the latest explicit synthetic probe confirms Apple Intelligence is disabled on this Mac. Genuine generated quality/latency remains unaccepted. [Cleanup](cleanup.json) and cache budgets are recorded separately.

## Next work

1. Accept actual native root/nested review, selected Add, one Undo, interrupted/cold Check/Retry/Stop, account/access privacy and accessible feedback. Test the new Swift Backend paths with the native Store, rather than treating separate SQL and typed-wire checks as end-to-end evidence.
2. Connect these dedicated saved actions to normal global Undo/Redo and keyboard history. The current screen’s explicit Undo is implemented; global integration is not.
3. Accept real on-device generation/quality/latency on an eligible enabled device, plus remaining legacy payload and broader lifecycle acceptance. No cloud fallback is planned.

Further physical iPhone installation remains deferred. Remote reminders, older-client rollout safety and release/distribution verification retain their agreed deferrals. No real task/account data, system permission or normal rollout gate changed.
