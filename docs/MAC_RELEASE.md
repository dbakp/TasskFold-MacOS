# Mac release packaging

The public widget release must contain the app and its widget extension, share the same signing team and App Group, use Developer ID hardened-runtime signatures, and pass notarization. An Apple Development certificate alone does not establish those requirements.

`Scripts/make_dmg.sh --developer-id` now owns the archive → manual Developer ID export → app notarization/stapling → DMG signing/notarization/stapling path. It requires existing signing inputs; it does not create certificates, register identifiers or acquire profiles. Set `TASKFOLD_EXPORT_OPTIONS` to a reviewed local ExportOptions.plist containing method `developer-id`, signingStyle `manual`, the teamID, and provisioningProfiles entries for **both** `com.dbakp.taskfold.mac` and `com.dbakp.taskfold.mac.widgets`. Use the team's installed Developer ID Application identity and correct profiles. Set `TASKFOLD_NOTARY_PROFILE` to an existing `notarytool` Keychain credential profile. Keep credentials out of this repository. The command uploads only when explicitly run with these inputs.

The build cache can be selected with `TASKFOLD_DMG_BUILD`. Packaging generates the current owned project and restores the previous project and scheme on exit. Heavy builds use two jobs. The exported app's signatures, widget identity/version, metadata catalog, team, sandbox, shared App Group and hardened runtime are checked before notarization submission. Existing output DMGs are not overwritten.

Outputs are distinct:

- Public widget release: `dist/Taskfold-<version>-developer-id.dmg`.
- Registered-device development build: `dist/Taskfold-<version>-development.dmg`; profile expiry still applies.
- Legacy default build: `dist/Taskfold-<version>.dmg`; ad hoc and **without widgets**. This cannot establish full P0 distribution.

Each artifact gets a `.dmg.json` receipt binding mode, exact DMG SHA-256, source-input fingerprint and packaged version/build. Recording and verification mount the DMG read-only without opening the app. The payload inside the image is verified; an unrelated app in a build directory is never used to approve publication. Public verification also validates app/DMG stapled tickets and assesses the app with Gatekeeper. Development images cannot be published through this script.

After committing the verified inputs, explicitly publish the exact candidate using `Scripts/publish_release.sh <notes-file> <dmg-path>`. It requires public widget verification by default. The existing widget-free channel requires the explicit `--legacy-without-widgets` flag. Existing version tags/releases cannot be replaced. Publishing remains a separate action; packaging does not publish a GitHub release.

## Current evidence and limitation — 9 October 2026

Four integration tests in `Scripts/test_release_artifact.py` pass with actual disposable Mach-O signatures and DMG creation/mounting. They prove that later changes to an external app do not alter the verified packaged version; changed DMG bytes, sources or modes are rejected; and a valid DMG containing the wrong app identity is rejected. A forced build-command failure also proves the original project and scheme are restored. No fixture executable is launched. Shell syntax checks pass. A real preflight using the current keychain rejects Developer ID packaging before any build or project mutation: only an Apple Development identity is installed. Unknown-mode rejection is also verified.

The public archive/export/notarization path remains **unexecuted** without a Developer ID identity, suitable profiles and notarization credentials. These checks do not prove real Taskfold installation, App Group access, widget hosting or public distribution. No installed Mac app was launched or modified, no certificate was created, no notarization upload occurred and no release was published. The iOS repository needs no code change for this Mac-only packaging work.

Apple references: [Developer ID distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html), [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [distribution signing and hardened runtime](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/). Export option keys were also checked against the installed Xcode's `xcodebuild -help`.


## Separate local UI-test preparation

`python3 Scripts/prepare_isolated_mac_ui.py --output /tmp/taskfold-isolated-mac-ui-workspace` copies only this repository into a fresh temporary workspace and generates a test-only project. It refuses existing destinations. Build that copied project with Debug `build-for-testing`, a temporary DerivedData path, and ad-hoc signing. Use the receipt's `--uitesting --widget-action-testing` arguments for local fixtures. Preparation/building does not launch an app.

The app identity is `com.dbakp.taskfold.mac.p0uitests`; authentication/recovery services and widget namespace are separate from the installed app. Production URL/file associations and the widget extension are omitted. The receipt lists every namespace substitution and source hash. This workspace is for native UI acceptance only; it cannot establish Desktop-widget, release-signing, notarization or physical/provider acceptance. Do not ship it or replace `/Applications/Taskfold.app` with it. Native launch still requires the existing outstanding permission.
