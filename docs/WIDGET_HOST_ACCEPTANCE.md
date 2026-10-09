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

Interactive completion, live privacy changes, independent instances, other sizes/configured families, rename/delete/account refresh, iPad/physical devices, Mac hosts and distribution remain open. One passing project selection does not prove saved-filter/label configuration or complete P0 acceptance.

The isolated iPhone retains its configured fixture widget for follow-up. Seven obsolete test apps and their seven runners were uninstalled from that test device; only the current test app/runner pair was kept. This cleared duplicate Taskfold gallery entries and left about 96 GiB free. No real account data or installed Mac app was changed.
