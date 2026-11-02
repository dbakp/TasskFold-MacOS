# Native recording retention and task Undo

Reviewed 2 November 2026. This follows the [certified generation-restoration service](../audio-generation-restore/README.md).

## Implemented

Both independently owned apps have a gated recording-recovery section in the shared-task Delete review. It reads current, permission-checked metadata without fetching captions or media; shows the exact recording count and 30-day recovery period; and requires explicit consent before deleting a task with recordings. Cancel, refresh, account/session/workspace changes, backgrounding and five-minute expiry invalidate that consent. Original task admission is checked again at confirmation.

The typed acknowledgement is persisted inside the existing immutable mutation and Undo history. Normal Undo restores the original recording through the certified new task generation without replacing its publication identity, bytes or Storage path. Explicit expired-media omission is typed and service-checked, but its user-facing recovery review is still to build. Restore-to-delete inverse history clears an omission acknowledgement.

A new authenticated metadata-only RPC validates current membership/editor access and captures no caption or object path. Multi-task operations accept only a complete set of exact member reviews; the service preserves atomic recorded/empty-member deletion and restoration. Responses, expiry, scope and policy are validated strictly with a 4096-byte transport limit. Failed metadata reads cannot invent a saved edit.

## Verification and limits

The owning verification snapshot and local service reports record exact results. Both repositories independently pass 85 actual local PostgreSQL/Storage checks, including 20 metadata-review/batch additions to the preceding 65-case restoration suite. The final current-source Core run passes 175 tests per repo (31 in the focused lifecycle suite, including 13 new cases). Thirteen new Core cases cover strict wire decoding, durable policy/Undo, zero inventory, expired omission, wrong scope, access loss and oversized replies. Both current app and test-runner builds pass strict signing verification.

The iPhone isolated native case passes 36 service/native checks: private capture, lost publication reply, cold metadata reconciliation, production Delete review consent, Cancel/reopen with fresh consent, actual deletion, normal Store Undo, original-recording playback, removal and fenced cleanup. Saved task contents are equal except for the certified generation renewal; the private original and frozen publication intent remain unchanged. The test uses a reserved debug root to keep controls alive while the task is absent. It does not establish ordinary multi-window or Mac keyboard Undo behavior.

Auth, HTTPS/PostgREST routing and media capture/playback drivers remain controlled synthetic adapters. PostgreSQL authorization, production gateway, pinned local Storage, client Store/history and production Delete review are real within that fixture. Genuine Auth/full-schema/hosted integration, Mac runtime, wider account/window/background/privacy/VoiceOver/largest-text acceptance, mixed file/recording restoration, personal/legacy migration and whole-project recording transfers remain open. No hosted deployment, scheduler or normal-use enablement occurred. Client and service restoration switches default Off.

## Attempt qualifications

The first phone attempt exposed a section accessibility identifier overriding the consent switch; the parent identifier was removed. The second attempt tapped the label center rather than the trailing switch; the harness now taps the observed switch position and asserts its value. Phone v3 passes. The first iPad attempt timed out before initial sync completed, before any audio operation. A subsequent build adds a test-only sync-stage indicator and a bounded 90-second initial sync wait; no production sync bypass or cached-data success was introduced. The diagnostic iPad v2 attempt also stops before any audio operation: workspace and profile reads complete, but the Store remains awaiting reminder scheduling. Its service report records zero audio requests, no rejected workspace reads and complete fixture cleanup. iPad native retention/Undo remains unaccepted; do not repeat this unchanged run. The older iPad file-picker/cache run is a separate unaccepted scope and was not repeated.

## Storage discipline

Heavy jobs run sequentially behind the default 20 GiB free-space floor. Two verified unused, owned compiler caches were removed (1,339,109,376 allocated bytes); current native products, active compiler caches, app data and existing Simulators were preserved. Each app's Core test helper now reuses its existing platform-specific cache and checks the floor before starting. No Docker reset or real app data removal was used.

The accepted phone v3 build predates only DEBUG sync-stage tracing and the longer bounded initial-sync test wait. The current v4 app/runner builds are signed; the iPad diagnostic uses v4. No production retention or Undo logic changed after the accepted phone flow.
