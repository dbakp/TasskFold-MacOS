# Reviewed on-device steps — 6 November 2026

## Implemented

The saved-subtask organizer offers root/nested on-device review, explicit selected Add, availability checks, encrypted saved requests and Check/Retry/Stop. Existing unsaved iPhone drafts and Mac autosave remain separate. The model receives only the editable goal; selected titles save literally without date/label/person parsing. Normal rollout gates remain Off and installed apps are unchanged.

Confirmed additions now join ordinary Undo/Redo history through the existing bridge. Explicit screen inverses advance that same frame without submitting twice. Redo retains reviewed titles, destination and original insertion slot while using fresh request/node identities. The private journal reads the prior format and adds version 2 only when Redo lineage exists. Missing/cyclic lineage, identity reuse and premature history removal are refused; competing windows recover one saved inverse. Whole settled families can be forgotten together.

The service accepts a fresh current structure revision for an earlier batch’s Undo, preserving normal consecutive Undo/Redo. Exact inserted-record digests still refuse changed fields or placement. A former null/absent container is restored only if the batch’s removal leaves it empty; later unrelated children are kept. Source goal, parent incarnation, account/session/workspace/access and fresh permissions still guard additions. Existing API shapes and default-Off gates remain compatible.

The review now shows recent additions first, lets users inspect confirmed titles, explains invalid goals/offline saving, shows progress, and disables invalid destinations. After a confirmed change it reads the already-refreshed Store rather than repeating a full workspace sync. The saved organizer also refreshes when global step history runs while it is visible. These screen refinements still need interaction/accessibility acceptance.

## Verification

- [Owning client/history checks](client-verification.json): **106 passes, 0 failures**. These cover typed wire data, encrypted cold recovery, version/lineage validation, competing inverses, literal titles/original-slot Redo, cancellation, paused recovery and existing native-history/child-action regressions. This round does not repeat the unchanged generation probe; its last explicit result was Apple Intelligence disabled.
- [Owning complete schema](full-schema.json): **123 genuine local Auth/REST checks**. Added cases cover sequential batch reversals, preserving later work in root/nested containers that began null, and original-slot reinsertion. Changed-step Undo refusal, exact paused retry, session/access/legacy behavior and late rollback remain green. All isolated database fixtures are removed; advisors retain only the known pg_net placement warning.
- [Native production code](native-store-verification.json): The production Store/Backend and native UndoManager bridge pass 25 checks in nine cold-launch phases. The test supplies synthetic reviewed titles and uses real local Auth/REST with transport-only interception. It exercises a lost committed reply, cold exact retry, two consecutive Undos/two Redos, preserved action names, fresh Redo identities, cold lineage and stopping a nested addition before write. Real model generation, review-screen taps, keyboard focus and production Keychain/TLS acceptance are **not** inferred from this proof.
- [Current signed build](signed-build.json) and [cleanup/cache budgets](cleanup.json) are retained. The Mac test adapter now isolates both legacy session service names before launch; normal session names and real credentials are untouched.

## Remaining

Accept the actual review form, selected Add and explicit Undo/Redo through native controls, keyboard menus/focus, accessibility and wider account/access/window behavior. Genuine on-device quality/latency needs an eligible enabled device; no cloud fallback is planned. Remaining legacy payload/lifecycle acceptance stays separate. Further physical iPhone installation and the three agreed release/remote-reminder/older-client deferrals remain.
