# Selection recovery on iPad; Mac runner prepared

Reviewed 3 November 2026. Follows [main-screen retry](../audio-sync-attention-recovery/README.md).

The owning iOS runner now exposes `ipad-selection` using the existing iPad Simulator and signed app/runner. The owning Mac runner exposes `mac-selection`, verifies the exact Mac bundle and signed products, uses its existing isolated container and Mac XCTest target, and never boots a Simulator for a Mac case. Both platforms continue to use synthetic sign-in/routing/bootstrap with actual local PostgreSQL/RLS, the production gateway and pinned Storage. No production app, migration, normal-use gate or hosted deployment changes.

## Accepted iPad scope

One native UI case and 63 service/native checks pass without skips. Three saved tasks share one project: one recording expires and is actually purged, one remains available, and one task has no recording. The production selection-deletion review and Store Undo create the frozen pending command. Review explains each member and requires explicit omission consent. Later preserves the whole command; quitting and returning preserves it and resets consent.

An actual local persistence failure after terminal service closure leaves the original complete queue and every Undo/Redo action/identity unchanged. Fresh consent then saves a new whole-selection request with unchanged fields/generations and fresh header/member nonces. Its committed reply is lost; quitting and retrying sends the exact saved replacement, clears the queue and retains all three tasks. SQL proves one durable closure and one restoration group, with exactly three restoration receipts. Every final cached row equals the actual SQL row. The available recording's downloaded bytes stay exact, expired bytes stay purged, and there are no replacement uploads. Existing private file paths/bytes stay unchanged where present; this is not a new positive private-capture test.

The final screenshots are inspected at the tested dark appearance and normal text size. This does not accept largest text or spoken accessibility. Owned configuration/services are removed and the existing Simulator returns to its initial state. Existing iPhone ordinary Settings/main-screen, warm history and recorded-confirmation cases remain separately scoped; they are not inferred from this iPad case.

## Mac status

The new Mac-specific test and owning app/runner build and strict signatures pass. It uses native checkbox clicks, opens the existing isolated Mac app window, checks the saved cache and attempts the same cold journey. Runtime is **not accepted**: the test runner stopped before app launch with “Authentication cancelled. System authentication is running.” No product action ran. The owned configuration, database, gateway and Storage were cleaned up. Do not repeat this unchanged run until the system authentication condition clears.

An earlier harness-only preflight found the iOS Info.plist layout was wrong for a Mac bundle; the runner now checks Contents/Info.plist. That attempt stopped before native launch and cleaned up its services. Protected container-manager metadata was unavailable during preparation; the final runner instead verifies the exact signed app identifier, the existing exact real container path and its Documents directory, without reading protected metadata.

## Remaining

Mac runtime, iPad ordinary Settings/main-screen entry and other recovery outcomes; broader queued/history/account/window/background/privacy/accessibility cases; normal sign-in/bootstrap and full-schema/hosted integration; mixed-media migration and whole-project recording transfers. Normal-use gates stay closed. The 74 curated checkpoints and 35 substeps do not change from this platform evidence.
