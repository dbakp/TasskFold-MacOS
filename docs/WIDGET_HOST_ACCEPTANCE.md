# Installed My list widget acceptance — 9 October 2026

One small My list widget now passes actual iPhone Simulator host configuration, scoped contents and native task routing. This supersedes the earlier unresolved-entity result for this specific host path; it does not close every widget acceptance gate.

The final native test selects Widget Studio in the system configuration card, waits for Sketch widget concept on the Home Screen, excludes an unrelated Inbox task, then taps the widget and verifies the correct native task editor title. It executed once with zero failures/skips and no reported test-result runtime warnings. SpringBoard still logged accessibility hierarchy and animation-idle diagnostics; the completed run took about 151 seconds. The pre-layout version also passed once and revealed the visual truncation described below.

## Signing prerequisite

The earlier ad-hoc binaries had no signing team. A valid local Apple Development identity matching the configured team is now available. Passing its fingerprint as Xcode's Simulator CODE_SIGN_IDENTITY did not replace the cached ad-hoc signatures. Explicitly signing the owned app, extension, UI-test bundle and runner produced real matching team identities. Strict signatures were verified in the build products and again in the installed app/extension. The existing catalog check with `--require-team` passes all eight configuration intents, three entities, six enums and the completion metadata contract.

The iOS repository now owns `Scripts/sign_simulator_test_products.py`. It accepts only the dedicated `com.dbakp.taskfold.assigneepatterntests` Debug Simulator bundle family, verifies IOSSIMULATOR binaries before signing, uses an already-installed identity, preserves entitlements, and verifies the expected team afterward. It does not acquire certificates, alter provisioning, sign the installed Mac app or publish a release. Always stop the test sequence on a failed prerequisite.

An initial Project pulse attempt was interrupted during SpringBoard's unrelated Maps drag-menu animation; it is not a host pass. An early My list attempt was stopped when its signature check showed the Xcode override had not taken effect. The passing My list walk uses its existing checked-wallpaper entry to Home Screen editing. No XCTest-source change remains in this checkpoint.

## Readability fix

The first actual host screenshot truncated both Widget Studio and Sketch widget concept despite available space. Both owned widget implementations now use a compact, wrapping list heading on small widgets and allow three task-title lines. The 44-point completion target remains intact. Medium/large task-title limits and all task/configuration data contracts are unchanged.

The final installed screenshot shows both ordinary names in full. Final iOS Debug app/widget/test builds and the Mac Debug app/widget build pass. The matching Mac layout compiles; no Mac GUI or widget host was launched. This presentation-only change did not require repeating unrelated Core suites. Actual before/after/configuration PNGs are retained in the iOS repository under `docs/widget-host-previews`; `widget-host-evidence.json` records their hashes and the scoped result.

## Remaining acceptance and retained state

Cloud/physical cold-launch and recurring completion, privacy on other families/hosts, independent instances, other sizes/configured families, rename/delete/account refresh, iPad/physical devices, Mac hosts and distribution remain open. One passing project selection does not prove saved-filter/label configuration or complete P0 acceptance.

The isolated iPhone retains its configured fixture widget for follow-up. Seven obsolete test apps and their seven runners were uninstalled from that test device; only the current test app/runner pair was kept. This cleared duplicate Taskfold gallery entries and left about 96 GiB free. No real account data or installed Mac app was changed.

## Actual completion — 9 October follow-up

`testInstalledMyListCompletionPersistsAndKeepsOtherTasks()` now passes against the real Home Screen button on the isolated iPhone. With Taskfold backgrounded, tapping Complete updates the widget to All clear without foregrounding the app. The app then shows the selected task as completed and retains an unrelated open Inbox task; completion survives termination and relaunch. One actual test passes with zero failures/skips or reported result runtime warnings. The actual empty-state screenshot was inspected and is retained in the iOS repository. This proves the warm/background local fixture path; killed-app execution, cloud sync, recurring completion, account switching and Mac/physical hosts remain separate.

The first attempt stopped before tapping because a 44-point hit target measured 43.99999999999997 points. The test now allows a 0.001-point floating-point tolerance. Production completion code did not change. Both tests compile in the final iOS Debug test build; the app, widget, test bundle and runner were explicitly re-signed and verified before execution. A stable isolated UI-build workspace now avoids changing every source path for a test-only edit.

## Live privacy — 9 October follow-up

`testInstalledMyListPrivacyHidesAndRestoresNames()` passes once with zero failures/skips or reported result runtime warnings. The actual system switch is asserted on before closing configuration; the installed widget displays My list and Private task, and neither original task nor list name appears in its accessibility descendants. Switching off restores both names. All four actual screenshots (both switch states and both widget states) were inspected and retained in the iOS repository. The test leaves privacy off.

The first attempt tapped the center of the system switch's whole accessibility row without verifying its value and left names visible. The corrected test taps the control at the row's right edge and requires the requested value before dismissal. No production privacy change was necessary. SpringBoard animation-idle waits still consume about a minute per menu operation; this passing functional run is not a performance claim. On a fresh test device, run the existing installed configuration test before these two follow-up checks.


## Terminated-app completion — 9 October

The actual small My list completion now passes after XCTest terminates Taskfold and asserts `.notRunning` before tapping the Home Screen button. The widget reaches All clear without foregrounding Taskfold. The completed task appears in Completed, survives another termination/relaunch, and an unrelated Inbox task remains open. One actual iPhone Simulator test passes with zero failures/skips/reported runtime warnings; the retained screenshot was inspected. The final saved fixture has a completion receipt and no pending mutations.

The first run exposed a fixture issue: system-launched intents have no XCTest launch arguments, so the app selected the separate local workspace instead of ui-testing. The final harness retains the disposable account only for the exact isolated bundle in Debug Simulator builds. It does not alter Release or physical-device behavior, widget action execution or persistence. Ordinary UI/live-auth test launches reset its marker, which was independently verified false after the final run. Both the failed and passing results remain recorded in `widget-host-evidence.json`. No Mac code/runtime change or real account was involved.

This closes one local terminated-app iPhone Simulator path. Recurring/cloud completion, physical devices, multiple configurations and Mac widget hosts remain open.


## Recurring completion and visible next date — 9 October

Both independently owned My list widgets now show the planned date beneath dated tasks. Previously a daily task could reappear with exactly the same title and no visible indication that completion advanced it. The small widget now displays the next date, while retaining its completion target and three-line title.

One actual iPhone Simulator test passes after terminating Taskfold: tap Complete, see tomorrow’s date without foregrounding the app, find the original in Completed, and retain tomorrow’s occurrence after another relaunch. Independent inspection of the disposable saved workspace proves exactly one next occurrence, original completed, next open, daily rule preserved, unrelated task open and no pending mutations. The temporary cold fixture marker is reset. The actual screenshot was inspected; its title and planned date are readable. Both final Debug arm64 app/widget builds pass. Mac host interaction, cloud/physical recurring completion, other recurrence rules and repeated/stale taps remain separate acceptance work. The test setup change is confined to the existing Debug UI fixture; production completion logic is unchanged.


## 9 October — installed Inbox total and batch

One actual iPhone Simulator test passes with zero failures/skips/reported result runtime warnings. The small Inbox reset widget displays six open tasks and Review 5 of 6; tapping opens a five-task review. Changing the real system configuration to All Inbox tasks displays Review all 6 and opens a six-task review. All three retained screenshots were inspected: labels are readable and the native review shows the matching count. The second visible Inbox widget retained its five-task setting when the first changed; broader multiple-instance acceptance remains open.

Independent saved-state inspection confirms six open Inbox tasks, one open project task, one completed task and no pending mutations after opening/closing both reviews. The exercised widget was removed; another fixture Inbox widget remains from earlier testing. Earlier attempts failed on fixture initialization/storage, an unavailable diagnostic panel and an incorrect system-button selector, all documented in widget-host-evidence.json. Final Debug iOS test products build and signature verification pass. No production source changed in this checkpoint; the clarified labels already exist in both repositories. No Mac GUI was run. Medium size, cloud/account changes and physical/Mac hosts remain unverified.
