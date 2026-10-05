# Independent app repositories

Each app owns its code, resources, test suite and release inputs. Mac development and deployment use only `TasskFold-MacOS`; iOS development and deployment use only `TaskFold-iOS`. Neither app requires a checkout, source fetch, package dependency or version pin to the other app.

The Mac Core, three planner/filter views, backend configuration, app icon and Core tests were initially copied from iOS revision `708d8936ef7ba74158b7370c530cd6ff256c6116` on 5 October 2026. That revision records provenance only. The files are now maintained in this repository. Existing Mac views, platform services and widget extension retain their Mac ownership. Historical references to pinned shared Core in earlier implementation notes describe the architecture before this change.

## Cross-platform behavior

The apps share the deployed backend and persistent data formats. Task fields, saved filter AST versions, view settings, ordering keys, recurrence rules, fixed/floating planning semantics and durable mutation formats must remain compatible. Device permissions, calendar selections and local UI behavior remain platform-owned.

For changes to a persistent contract or behavior relevant to both platforms:

1. Implement the change in each app repository, with platform-specific UI where appropriate.
2. Add or update the corresponding local contract fixtures and run each repository's tests. The suites do not import one another.
3. Verify additive backend compatibility with already released clients and record any deployment prerequisite.
4. Exercise cross-device persistence and offline replay where the change affects synchronized work.
5. Commit and push each app's changes to its own repository. Release each app from its own verified revision.

Source files do not have to remain identical. Compatible persisted behavior and independently passing tests are the requirement. Do not automatically overwrite platform changes when porting a fix.

## Mac build and release

Run `Scripts/test_core.sh` and `Scripts/test_core.sh -c release` locally. These run the local Swift package with build products outside synced Documents folders, which can add resource forks that prevent test-bundle signing. Plain `swift test` also works from a checkout outside such folders. The Xcode app and widget targets compile local `Taskfold/` and `TaskfoldWidgets/` files. `Scripts/test_mac.sh` builds/runs Mac UI tests with the established fixture/signing configuration. `Scripts/make_dmg.sh` packages the local app, and the publish script checks a fingerprint covering local Core, views, configuration, icon, widgets and release tooling.

The external backend service and Apple signing requirements still apply. Backend migration history and rollout notes are service prerequisites, not source-code dependencies between the app repositories. This separation does not change bundle IDs, account caches, Keychain service names, App Group IDs or backend data.
