# Expired recording Undo review and terminal intent closure

Reviewed 2 November 2026. Follows [native recording retention and Undo](../audio-lifecycle-native/README.md).

## Behavior implemented

Both apps offer **Review recording Undo** from sync attention and Backups & restore when the queue head is a single recording-bearing task restoration. Opening inspects the exact saved request. A recorded result offers confirmation through unchanged replay; an unrecorded result never authorizes a different decision. Before expiry, the original Undo remains the only retry. During expired-media cleanup, task-only recovery stays unavailable. After confirmed cleanup, an explicit unchecked choice offers restoration without the expired recordings while preserving the saved title, notes and checklist.

Confirming task-only recovery first asks the service to permanently close the original intent. If the original Undo applied while the screen was open, the response identifies its recorded outcome and no replacement is made. Otherwise the service closes only the exact original body under the existing request/task mutexes. A delayed old retry is refused with a dedicated closed-action result. Only then can the client replace the exact queue head with a fresh request identity and explicit expired-media policy. Task contents, chosen generation, queue order and later edits are retained. Local save failure restores the old snapshot, whose immutable request and retrievable closure remain safe for retry.

Account/backend/workspace/session, current queue head, foreground, service access, metadata expiry and explicit consent are checked before changing the queue. Metadata contains identities and outcome only, never task content, captions or paths. Confirmation uses the existing current-role certified task restoration service; it cannot restore purged bytes or upload a private original again. No automatic conversion of an uncertain request occurs.

## Service boundary

The authenticated inspect/close RPC validates live session, active team/project/configuration, current editor/manager role, exact original actor/delete certificate/task hash and original recording policy. Closing additionally requires expired retention and confirmed purge of every retained recording. Recorded original requests are never marked closed. Closure receipts are stable and idempotent after a lost reply. The private RLS-enabled ledger stores only actor/scope identities and a keyed command fingerprint; account/team removal cascades it. The public wrapper is invoker-only and unavailable to anon/service_role. All normal-use restoration switches remain Off.

## Verification scope and remaining work

The owning service and Core reports record exact independently executed results. Tests cover recorded/unrecorded/closed outcomes, exact-body binding, late original retries, lost closure acknowledgement, current access/session/configuration, task/queue preservation and strict bounded client transport. Database controls exercise an original Undo held before commit and a closure held before commit, observing the competing worker actually blocked before release.

Native recovery views, Store persistence/rollback handoff and entry points are implemented, but this new screen's runtime, visual and accessibility acceptance remain open until exercised against the actual isolated service. Existing accepted iPhone retention/normal Undo evidence is not reused as proof for this new flow. Multi-task selection closure/replacement remains to implement; single-member recovery never detaches a batch. Mixed file/audio, discussion-retention limits, personal/legacy migration, whole-project transfers, genuine Auth/full-schema/hosted integration and wider account/window/background/privacy checks remain open. No hosted deployment, production configuration or real task data changed.

The iPad startup wait is separate. DEBUG-only stage tracing now distinguishes reminder registration, notification settings, location installation and reminder reconciliation without changing production scheduling or bypassing any permission/Keychain work. No unchanged broad iPad run was repeated.

## Attempt qualifications

The first service probe failed before identifying its SQL error because a test dereferenced a null result; the helper now preserves the actual code/reason. The next probe exposed a local SQL variable named state colliding with a column; renaming it to outcome fixed the function. The first Core compile caught an extra path argument introduced while updating routing; it was corrected. The next compile caught a test assigning an immutable origin; the test now captures a complete independent scope. Passing suites retain all refusal and immutable-body assertions. No native runtime pass is claimed from a build.

Both current native app and test-runner builds pass strict signature verification. Each owning final 185-test Core suite passes; the 33-case lifecycle subset is also rechecked against the latest independently generated SQL wire. Neither native compilation nor these Core checks establish new-screen runtime acceptance. Native checks must include the retention boundary while a review is open, Later/foreground/relaunch, local-save failure, changed account/window/access, speech and largest text.
