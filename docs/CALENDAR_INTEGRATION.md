# Real device-calendar integration

The iOS acceptance cases use the actual EventKit provider in an isolated Simulator app, rather than the empty UI-test calendar provider. The app requests access through the real system prompt. Only the dedicated test runner receives Calendar access in advance so it can create and remove its own local calendar and event.

## Verified behavior

- Denying the real access prompt leaves the planner disconnected and displays permission guidance.
- Allowing access exposes the runner-created calendar for explicit selection.
- A selected 45-minute event appears as Busy by default. Its original title is absent from the planner accessibility tree.
- Enabling event titles displays the fixture title, including after app termination and relaunch.
- Disconnecting removes the event from the planner.

Both native apps now expose a Settings shortcut alongside visible instructions for enabling calendar access and reconnecting. iOS uses UIApplication.openSettingsURLString; Mac opens the system settings application using its bundle identity. Neither app writes calendar events.

## Direct-link limitation

The iOS Simulator opens the supported Settings URL at the Settings home screen, rather than Taskfold’s page. An attempted Settings.bundle did not change this and was removed. Both failed route assertions are retained in the local results. The final test verifies the visible manual path and that Settings opens; it does **not** claim that denied permission was successfully re-enabled. End-to-end recovery through system settings remains open, as do physical-device, external-provider and Mac runtime acceptance. No installed Mac app was launched or modified.

## Reproduce safely

Use the isolated app `com.dbakp.taskfold.assigneepatterntests` and runner `com.dbakp.taskfold.assigneepatterntests.uitests.xctrunner`. Reset Calendar permission for that app before each test. Before the event test only, grant Calendar permission to the runner. Run `testRealCalendarPermissionDenialExplainsRecovery()` and `testRealCalendarEventSelectionPrivacyAndDisconnect()` separately. The event test refuses other runner bundle identities and creates only “Taskfold isolated calendar” / “Taskfold fixture review”; teardown removes its calendar. Reset the two scoped Calendar grants after verification. Never run against a real account or create fixtures in a cloud calendar.

See `calendar-integration-evidence.json` for exact results and source hashes. These checks close the real EventKit read/display path on one Simulator, not the full P0 goal.
