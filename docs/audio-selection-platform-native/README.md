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

Mac runtime and iPad ordinary Settings/main-screen entry with queued follow-ups; broader queued/history/account/window/background/privacy/accessibility cases; normal sign-in/bootstrap and full-schema/hosted integration; mixed-media migration and whole-project recording transfers. Normal-use gates stay closed. The 74 curated checkpoints and 35 substeps do not change from this platform evidence.

## iPad history and already-applied confirmation follow-up

Two further owning iOS runner modes, `ipad-selection-warm` and `ipad-selection-recorded`, use the same existing Simulator, app/runner and independent local service fixture. No production Swift or migration changes were needed. Each mode passes one native UI case without skips: 73 service/native checks for warm history and 50 for already-applied confirmation.

The warm case keeps every Undo/Redo action and logical history ID unchanged when a recovery save fails after server closure. Successful recovery rebinds the existing history to the reviewed policy and new request identities. Real Store Redo deletes the entire selection again, retaining only the available recording acknowledgement, and a second Undo restores all three tasks into fresh generations. Final rows equal actual SQL and survive cold return. SQL proves two restoration groups/six member receipts; the available recording remains byte-exact and the expired object stays purged. No replacement media upload occurs.

The recorded case applies the original restore but loses its reply. Review reports that Undo already applied and offers unchanged confirmation without omission consent or a replacement command. Later keeps the original queue and complete history. An actual acknowledgement-save failure keeps both intact; retry sends the exact original whole-selection request for the third time and acknowledges the existing result. SQL proves one restoration group/three member receipts and no closure. Both original recordings remain available with exact downloaded bytes. Final cache and SQL agree after cold return.

Both cases compare private paths/bytes where present; no new private-capture positive control is inferred. Screenshots were inspected in the tested iPad dark appearance/normal text size. This does not establish spoken accessibility or largest text. All owned configuration, local service resources and app processes close, and the Simulator returns to Shutdown. Mac remains unaccepted: native computer use independently confirms the Mac is locked, in addition to the previous authentication-cancelled test launch.
