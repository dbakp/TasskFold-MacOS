# Daily-use development builds

The immediate delivery is an ordinary personal-workflow app on the existing storage path. Independent-child migration, teams, advanced shared files/audio and their acceptance remain later work.

## Current candidates — 3 November 2026

- Mac **1.2.0 (5)**: ordinary app identity, Apple Development signed app, widgets and share extension. The actual ZIP payload passes the existing development-artifact verifier. The current profile expires **10 November 2026**. Startup/installation is awaiting the Mac unlock; the installed 1.1.0 app remains intact. A private local app-file safety copy was made before the attempted launch, without exporting Keychain items.
- iOS **1.4.0 (20)**: ordinary Simulator app builds with widgets and sharing. This unsigned Simulator product cannot be installed on an iPhone. The physical build stops at Xcode account/profile setup. The daily command now applies the configured team to all extensions as well. Physical signing/installation remains unverified.

No test launch arguments or candidate feature gates were enabled. The initial build/package work made no hosted changes, new simulators, real-task edits, installation or publication. The later focused assignment service deployment is recorded below. Build receipts bind the app input fingerprint.

## What the ordinary client exposes

| Experience | Client/configuration inventory | Service inventory |
| --- | --- | --- |
| Capture, task edits/completion/deletion, planning and recurring dates | Existing personal path available | Guarded task edit/delete functions present |
| Archive/subprojects, manual ordering and filters | Existing personal path available | Project archive/parent columns and ordering function present |
| Templates and multiline capture | Ordinary personal screens available | Template table and guarded edit function present; newer cloud workflow Undo is missing |
| Notes, widgets and Focus | Ordinary personal screens available; packaged extensions verified | Focus session function present |
| Insights and goals | Ordinary screens available; historical coverage stays explicit | Root activity/epoch and goals function present; new child-activity tables absent |
| Scoped assignments | Client support exists | Deployed 3 November; exact-definition/permission checks and anonymous refusal pass. Signed-in native acceptance remains separate |
| Google/Microsoft calendars and inbound email | Configuration remains pending | User-provided registrations/provider remain deferred |
| New storage, team authoring and shared audio/files | Ordinary client gates remain off | Advanced service activation is not implied by isolated acceptance |

This is source/configuration plus read-only live-catalog evidence, **not** a new real-account end-to-end acceptance. Catalog presence does not establish every authorization path. `hosted-*.json` contains metadata only; no user records were inspected or changed. The ordinary client's existing legacy-sync fallback checks that both team endpoints are absent before using legacy sync.

## Rebuild and update

Each owning repo has its own `Scripts/build_daily.py` and `Taskfold/Taskfold-Daily.entitlements`. The command copies only project metadata into the selected build cache and uses this checkout's sources/resources. Absolute scheme references keep the cached scheme bound to that project. It never edits the ordinary project, Info.plist or release entitlements.

The daily profile omits remote push and Time Sensitive notification entitlements unsupported by the current Personal Team. Ordinary local reminder code, widget App Group, share extension and existing sandbox/file/calendar permissions stay included. Normal release entitlements are unchanged.

Mac: `python3 Scripts/build_daily.py --allow-provisioning`

iOS Simulator: `python3 Scripts/build_daily.py --simulator`

iPhone, after configuring Xcode Accounts and the registered device: `python3 Scripts/build_daily.py --device DEVICE_ID --allow-provisioning`

Use `--build-number N` for a new daily update, applying the number to app/extensions together. The built app and extensions must still pass the continuity metadata floor. Use `--derived-data PATH` to reuse a current cache and `--team TEAM_ID` to select an existing team explicitly. Otherwise the sole configured project team is applied to app/extensions. Device/Simulator receipts are separate, so a failed physical build cannot erase a successful Simulator receipt. The commands enforce the storage floor, build one platform/job at a time and only the host Simulator architecture. They do not install, launch, create accounts, publish or submit an App Store release.

The Mac ZIP is in this chat's output/daily-use-mac directory, with a byte-bound build receipt. Quit the old app before replacing its application bundle; retain the local-file safety copy while validating startup. A development profile needs renewal when it expires.

## Next product work

Finish Mac startup/installation when unlocked and physical iPhone signing when the account is available. The scoped assignment service update is now deployed; next prioritize cloud workflow Undo service availability, followed by real daily-use friction in organization/templates/planning. Keep the full advanced Px backlog; do not restart broad unchanged acceptance matrices as the immediate focus.

The delivery check originally assumed exactly three versioned targets and rejected the iOS Watch companion. It now requires both configurations for each core bundle identity and consistent versions across optional companions. Each repo passes 12 focused checks, including matching companions, missing required configurations and mismatched companion versions; the ordinary projects and actual built app/widget/share metadata pass. This does not establish distribution or Watch runtime acceptance.

## Assignment service preflight — 3 November

At the initial preflight, read-only inspection confirmed exactly one merge anchor in the live guarded task editor, with task-generation protection, invoker security and authenticated-only execution. The scoped endpoint/guard were absent at that preflight; the later deployment below supersedes that availability status. See `hosted-assignment-preflight.json`. No real tasks or hosted definitions were changed. This is readiness evidence for a narrow update, not a deployment or acceptance result. Unrelated personal workflows can proceed.

## Template search update — 3 November

The ordinary library now searches template names, shows native no-results feedback and clears its query when the workspace changes. Import/save/edit/run controls and persisted template definitions are retained. Mac 1.2.0 (4) is development signed and separately packaged; the extracted ZIP payload passes signature/extension checks. iOS Simulator compilation passes. Native visual acceptance and actual installation remain pending, with the existing Xcode account/profile blocker for iPhone. See `template-search.json`. The earlier build-3 and build-4 ZIPs remain older candidates; build 5 supersedes them. No backend or real-task changes were made.

## Multiline capture update — 3 November

Mac **1.2.0 (5)** and iOS Simulator **1.4.0 (20)** include inherited quick-capture context, explicit section selection and fuller review captions. Capture from label views includes its label. Per-line recognition overrides defaults; project changes clear incompatible section/assignment. Fresh task identities do not copy existing content or completion. Each owning repo passes six focused Core checks, including four new regressions; both ordinary app builds pass. The actual Mac ZIP payload passes signature/widget/share checks. See `capture-context.json` for receipts, source hashes and the roughly 1 GiB of reclaimed completed test products. Native visual acceptance and actual installation remain pending; physical iPhone signing still needs Xcode account/profiles. No backend or real-task data changed. This refines existing capture scope; curated progress bars are unchanged.

## Scoped assignment service update — 3 November

The current clients' endpoint is live after a focused update. Both owning repositories pass 32 actual PostgreSQL compatibility checks, with the original deployed task-editor body and synthetic task rows. Exact guarded deployment/rollback bundles are tested. Live metadata verifies the reviewed function hashes, authenticated-only invoker execution and unchanged existing patch permissions, table policies and task triggers. The live REST route rejects anonymous calls with permission denied. Current security-advisor findings are unchanged, not universally clear; existing findings/remediation links are retained in `scoped-assignment-advisors-before.json` and `scoped-assignment-advisors-after.json`.

`scoped-assignment-deployed.json` and `scoped-assignment-api-probe.json` record the live scope. No user task records were read or modified. This is not a signed-in real-account/native assignment acceptance or a solution to the separately deferred older-client rollout gate. The newer cloud workflow Undo endpoint remains absent. Mac build 5 and iOS Simulator build 20 already contain the matching client; a client rebuild was unnecessary for this service-only change. Installation/signing blockers remain separate.

Each repo owns the canonical applied-history version `20261103201254_taskfold_daily_scoped_assignment_guard.sql`. It is the idempotent existing candidate, matching its source hash; the actual single-use deployment also included the reviewed live baseline check retained under `Scripts/Database/fixtures`. Do not push the whole unfinished advanced migration chain merely to reproduce this selected update. The guarded rollback refuses definitions changed after this update.
