# Mixed task/subtask completion: selection preflight

This milestone implements shared, immutable selection preparation in both independently owned clients. It does **not** enable mixed completion in the task list. Root rows and independent child rows still need one atomic server executor, typed confirmation, saved recovery and whole-selection Undo before the UI can send them together.

## Implemented

- Capture 1–32 unique selected rows in user order, including roots and children from the same or different branches. Keep full account/backend/workspace/session/access scope.
- Resolve each selected row against exactly one accessible root and one current, unarchived project where applicable. Refuse headings, malformed references, stale identity/completion cohorts and duplicate/missing source rows.
- Recheck the entire selection before returning any prepared result, including selected rows already in the desired state. A later failure returns no partial result. The prepared value retains an ordered observation of every selected row, including no-ops, for the future atomic server guards.
- Ordinary roots retain fresh unrelated title/note/unknown-field edits. Recurring roots compare the full authored source because completion may copy it into a successor. Completion version changes catch complete/reopen cycles even when the visible state returns to its original value.
- Root/child reads must agree on the same root content and client scope. Existing independent-child requests retain their bounded field-only bodies; no parent tree is added to those requests.
- The existing child-only batch intent uses this preflight and now reads selected no-op rows. It emits commands only for rows that need changing, after all selected rows validate.

## Verification boundary

Core tests verify preparation and the existing child-only command path. This milestone does not claim mixed SQL, transport, journal, Undo or native runtime acceptance. Existing normal-use child gates remain absent/off. No hosted data/schema or release configuration changes.

## Next implementation

1. Define root and child members inside one atomic completion envelope with one reserved selection identity. Cover ordinary and recurring roots, shared/private roots, reopen and same-branch root/child ordering. Do not split a mixed selection into legacy root writes and a child batch.
2. Carry every selected observation, including no-ops, as a server guard. Make all admission, current permission/cohort checks, root locks, recurrence creation, activity, projections and receipts one transaction. Any stale/busy/denied/exhausted member must leave all members unchanged. Preserve existing individual request namespaces and exact retry behavior.
3. Add strict mixed confirmations, encrypted scope-bound journal/recovery, metadata-only terminal resolution, cross-journal admission and proof-based whole-selection Undo. A partial or reordered proof cannot certify a group; lost replies retain the original request.
4. Connect the premium native selection/review/feedback controls only after those contracts pass. Verify Mac/iPhone/iPad completion, cold return, uncertainty and Undo. Keep full Redo/history, indexed mapping, custody and the wider migration acceptance open.

The parent observation/read and private guard server contract is now recorded in `../completion-selection-roots/verification.json`. It supplies the baseline/fingerprint needed by the future atomic executor; mixed writes, typed client integration, recovery and Undo are still pending.
