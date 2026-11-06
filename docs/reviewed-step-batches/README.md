# Reviewed on-device steps — 6 November 2026

**Current follow-up:** editable Add/Undo/Redo and lost-response Check/Retry/Stop now pass four genuine local iPhone journeys with zero runtime warnings. The earlier warning-producing results below retain their historical scope. See [current header repair and limits](../step-recovery-layout/README.md).


## Implemented

The saved-subtask organizer offers root/nested on-device review, explicit selected Add, availability checks, encrypted saved requests and Check/Retry/Stop. Existing unsaved iPhone drafts and Mac autosave remain separate. The model receives only the editable goal; selected titles save literally without date/label/person parsing. Normal rollout gates remain Off and installed apps are unchanged.

Confirmed additions now join ordinary Undo/Redo history through the existing bridge. Explicit screen inverses advance that same frame without submitting twice. Redo retains reviewed titles, destination and original insertion slot while using fresh request/node identities. The private journal reads the prior format and adds version 2 only when Redo lineage exists. Missing/cyclic lineage, identity reuse and premature history removal are refused; competing windows recover one saved inverse. Whole settled families can be forgotten together.

The service accepts a fresh current structure revision for an earlier batch’s Undo, preserving normal consecutive Undo/Redo. Exact inserted-record digests still refuse changed fields or placement. A former null/absent container is restored only if the batch’s removal leaves it empty; later unrelated children are kept. Source goal, parent incarnation, account/session/workspace/access and fresh permissions still guard additions. Existing API shapes and default-Off gates remain compatible.

The review now shows recent additions first, lets users inspect confirmed titles, explains invalid goals/offline saving, shows progress, and disables invalid destinations. After a confirmed change it reads the already-refreshed Store rather than repeating a full workspace sync. The saved organizer also refreshes when global step history runs while it is visible. The iPhone review controls now have the scoped acceptance below; Mac controls and accessibility remain separate.

## Verification

- [Owning client/history checks](client-verification.json): **106 passes, 0 failures**. These cover typed wire data, encrypted cold recovery, version/lineage validation, competing inverses, literal titles/original-slot Redo, cancellation, paused recovery and existing native-history/child-action regressions. This round does not repeat the unchanged generation probe; its last explicit result was Apple Intelligence disabled.
- [Owning complete schema](full-schema.json): **123 genuine local Auth/REST checks**. Added cases cover sequential batch reversals, preserving later work in root/nested containers that began null, and original-slot reinsertion. Changed-step Undo refusal, exact paused retry, session/access/legacy behavior and late rollback remain green. All isolated database fixtures are removed; advisors retain only the known pg_net placement warning.
- [Native production code](native-store-verification.json): The production Store/Backend and native UndoManager bridge pass 25 checks in nine cold-launch phases. The test supplies synthetic reviewed titles and uses real local Auth/REST with transport-only interception. It exercises a lost committed reply, cold exact retry, two consecutive Undos/two Redos, preserved action names, fresh Redo identities, cold lineage and stopping a nested addition before write. Real model generation, keyboard focus and production Keychain/TLS acceptance are **not** inferred from this proof. The separate iPhone screen journeys below provide bounded control acceptance.
- [Current signed build](signed-build.json) and [cleanup/cache budgets](cleanup.json) are retained. The Mac test adapter now isolates both legacy session service names before launch; normal session names and real credentials are untouched.

## Actual iPhone review controls — 6 November

Two owning XCTest journeys use the signed reserved Simulator app against genuine disposable local Auth/PostgREST. Synthetic proposals enter only through a DEBUG fixture guarded by its reserved bundle, explicit arguments and loopback configuration; actual generation and the engine's availability checks are unchanged. No real accounts, normal gates, installed apps or system settings change.

- [Review/Add/Undo/Redo/cold reopening](ios-screen-review.json): edit a proposal to literal `Tomorrow #work @Pat`, finish keyboard editing, exclude the third proposal, explicitly add the two selected steps, Undo, Redo and reopen without seeded proposals. The actual controls and cold saved-cache checks pass; original children, opaque fields and notes survive. Xcode relocated the test container, so the completed journey’s report was recovered by reserved bundle identity and matching fixture nonce. Final external row/receipt assertions were not reached; they are explicitly unaccepted in this screen receipt. The earlier production Store/service evidence remains separate.
- [Cancel](ios-screen-cancel.json): close the seeded review without adding; the exact server row and original two children remain, with zero batch receipts.
- The [recorded screen regression](screen-crash-regression.json) exposed an array-index binding crash when Add clears the reviewed rows. Both assistance forms now resolve editable/toggle bindings by stable identity and ignore late writes after removal; retiring controls retain a safe snapshot. History-row buttons now use separate borderless actions, so Undo cannot also activate the neighboring history-removal control. The saved-record Add is verified by the final journey; separate draft removal/generation lifecycle checks remain. The journey also exposed a keyboard-obscured action. The form now dismisses its keyboard while scrolling and provides an explicit iPhone/iPad Done control. Both owning app sources build/sign; actual Mac screen behavior is not inferred from iPhone tests. The test's first edit-menu attempt was unreliable, so the final journey uses ordinary typing and verifies the resulting literal value.

These are two passed native journeys plus saved-state/service assertions, not added progress checkpoints. Recorded screenshots were inspected; VoiceOver, broader text sizes, real inference, account/window changes and normal keyboard/menu integration remain separate.

## Pending-request recovery controls · 6 November

Both apps now distinguish **Send saved request** for an unsent addition from **Retry original request** after an uncertain result. Pending rows explain that stopping leaves confirmed changes in place. A pending inverse says **Stop undo**, and its stopped confirmation correctly says it cannot remove steps later. These are interface/feedback changes; request, receipt, encryption and service contracts are unchanged.

Each owner passes [17 focused reviewed-step checks](recovery-core.json), including a new real-journal case that stops a saved Undo while keeping the original applied addition and cold closure. Current owning app/test builds and development signatures verify in [the build receipt](recovery-signed-build.json). The unchanged broad service/client matrices are not repeated.

Three current signed iPhone Simulator journeys use disposable genuine local Auth/PostgREST and the production Store/Backend, encrypted journal and actual review controls:

- [Check status](ios-recovery-check.json): production Store commits the original two literal steps, deliberately loses its successful reply, then the actual Check status control recovers the original confirmation. Cold UI history and the saved cache agree; exactly one original server receipt exists.
- [Retry](ios-recovery-retry.json): the same committed/lost-reply setup, with the actual Retry original request control. The result still has exactly the two original steps and one receipt; cold UI and a separate authenticated status request bind the exact original identity.
- [Stop](ios-recovery-stop.json): the actual Stop addition control closes an unsent saved request. The exact server task stays unchanged; a single matching closure and zero addition receipts exist. After cold UI return, resending that same body receives 410 and still leaves the task unchanged.

All three native journeys pass without skips; 25 external assertions check identity, original children/opaque fields/notes, saved cache and real server outcomes. These counts do not add dashboard checkpoints. The runner verifies all owning app Swift files and exact owning test source before/after, resolves Xcode's current data container, removes only its own disposable services/control credentials, closes the test app and restores the Simulator. No real account, hosted change, ordinary gate, system setting or installed-app update is involved.

Pending and cold settled screenshots were inspected. All three result summaries still report [a layout warning](recovery-layout-warning.json); the Check log locates it during pending-to-confirmed content replacement, with no source location/backtrace. Its cause is unproven and remains open. This acceptance covers the controls and saved data, not clean layout diagnostics or VoiceOver.

The Mac screen check could not proceed because computer use reported the Mac locked; no unlock request was repeated. Mac/iPad interaction, pending Undo/Redo buttons, Stop after an already committed request, offline/access/window directions and actual generation remain separate. [Run cleanup](recovery-cleanup.json) preserves only concise current proof and necessary images.

## Remaining

Accept Mac review controls, wider iPad/text-size/accessibility behavior, normal keyboard menus/focus, pending inverse controls and Stop after a committed/lost reply, and wider account/access/window contexts. Genuine on-device quality/latency needs an eligible enabled device; no cloud fallback is planned. Remaining legacy payload/lifecycle acceptance stays separate. Further physical iPhone installation and the three agreed release/remote-reminder/older-client deferrals remain.


## 6 November · Activity clarity and bounded Mac control attempt

Reading and updating now share one accessible inline activity row; saving takes precedence. The current loading-row iPhone Check journey passes its genuine local-service assertions, but still records one pending-to-settled frame warning. This is not a warning fix. A native Form-row redesign was reverted after retaining the warning; debugger attempts were inconclusive and are not an originating stack trace.

The actual Mac controls accepted an edited literal first title and excluded third proposal, then visibly showed confirmed Add and Undo. Server-side Redo titles/fresh identities/three receipts passed, but the verifier checked disk before settlement and terminated the app; final saved-cache and Redo-screen acceptance remain open. A corrected 30-second saved-cache wait was prepared; subsequent attempts could not exercise Add because computer control reported the Mac locked. No end-to-end Mac review acceptance is inferred. The owning Mac runner preserves this pending scope separately from automated Store evidence.


## 6 November · Completed Mac Add → Undo → Redo walkthrough

The existing signed isolated Mac binary now has an observed production-screen root Add/Undo/Redo journey. CUA edited the first literal title to `Tomorrow #work @Pat`, excluded the third proposal and verified a two-step selection. Add showed “2 steps added”; Undo showed “Added steps removed”; Redo showed a new confirmed two-step addition. The newest saved disclosure exposed both exact selected titles. The genuine local Auth/REST verifier confirms preserved original children/notes/generation, fresh Redo identities, exactly three receipts and a matching pending-free saved cache. The corrected cache wait completed after 145 ms. Both the isolated app and its disposable services closed afterward; normal Taskfold was untouched.

The raw data driver intentionally leaves `reviewScreenAccepted: false` because it cannot observe controls. Combine [raw data](mac-controls-data.json) with the separate [actual controller observations](mac-controls-observation.json); the binary matches [its owning signed build](mac-controls-build.json). The earlier verifier failure and locked attempts remain historical, unaccepted runs. Seeded proposals were used: generation quality/latency, cold UI return, wider root/nested/access/window/account and keyboard/speech cases remain open. No ordinary gate or installed app changes; iPhone warnings remain separate.
