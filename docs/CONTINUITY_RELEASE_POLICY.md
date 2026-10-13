# P0 continuity release boundary

The supported P0 candidate pair is **Taskfold for macOS 1.2.0 (build 3) or later** and **Taskfold for iPhone/iPad 1.4.0 (build 19) or later**. App and widget versions must match within each release. These numbers reserve the first candidates containing the guarded task edits, task-generation/completion revisions, atomic organization ordering, strict filter-document preservation and label-membership conflict fix. They do not announce a shipped release or establish acceptance of the remaining P0 gates.

Each repository owns `Config/continuity-release.json`, its project, validator and tests. The paired version numbers describe a compatible service/data contract; neither build reads or imports the other repository. Mac's project generator also retains the new version rather than resetting it during packaging.

## Older active clients

Clients below these minimums are not supported as concurrent writers in a P0 workspace. Existing server access rules still permit legacy direct task updates; a current client's guarded RPC cannot prevent an old binary from subsequently replacing those values. The server does not automatically enforce these app version minimums. The release metadata validator prevents an obsolete candidate from being approved through the checked release path; it is not a server access-control mechanism.

Before enabling a P0 pilot or release for an existing workspace:

1. Inventory every Mac, iPhone/iPad and collaborator installation that can write to that workspace. Upgrade or retire every older active writer. If that cannot be established, keep the workspace out of the supported P0 rollout.
2. Preserve unsent work on each device before retiring it. Do not delete a cache or pending queue to complete the upgrade. Retain an encrypted backup/export where available; review older queued edits whose original baseline or task generation is unknown. The new client pauses those edits for explicit review rather than inventing their original state.
3. Use the supported pair for the bounded cross-device acceptance cases recorded in `P0_PROGRESS.md`, including ordinary relaunch and pending offline work. The bounded live label-conflict journey now has actual paired acceptance in `live-label-pair-evidence.json`; other named gates retain their separate evidence and prerequisites.
4. Complete the outstanding widget, accessibility, external-provider and runtime gates. Distribution signing remains user-deferred. Leave remote reminder delivery disabled until its separate provider/device and single-authority acceptance is complete.

No schema, row-access policy, account, production workspace or server rollout was changed to establish this boundary. A future requirement to block legacy direct writes needs its own compatible service migration and failure/recovery verification before deployment; do not implement it by silently discarding queued work.

## Release checks

Run `python3 Scripts/verify_continuity_release.py --project` in this repository before preparing a candidate. This checks all app/widget Debug/Release version declarations and, where present, the project generator. Run `python3 Scripts/test_continuity_release.py` for the local release-boundary regressions.

Run `python3 Scripts/verify_continuity_release.py --app /absolute/path/to/Taskfold.app` against the **actual exported app**. For an Xcode archive, the app is under `Products/Applications/Taskfold.app`. This command checks the local platform's production identity, minimum version/build, and matching widget metadata. It rejects isolated test identities, older candidates, and missing/mismatched widgets. It checks metadata only; signing, provisioning, notarization, runtime behavior and device acceptance are separate required checks.

Mac publication additionally validates the owned project, then its existing DMG verifier mounts the exact image read-only, checks the packaged app's minimum version/build, verifies signatures/widgets/notarization for the chosen distribution mode, and binds publication to the source fingerprint and DMG bytes. The explicitly named legacy widget-free packaging mode remains a separate historical channel and cannot establish full P0 widget distribution. iOS release operators must run the local project and exported-app checks before distribution; this repository does not publish or upload an archive automatically.

If a candidate needs rollback, retain the current data and queued work, stop the pilot's writers and fix forward with a new candidate. Do not reintroduce an unsupported older active writer or strip fields from a newer export to make it load. Existing additive backend migrations remain in place.
