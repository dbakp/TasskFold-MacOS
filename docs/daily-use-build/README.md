# Daily-use development builds

The immediate delivery is an ordinary personal-workflow app on the existing storage path. Independent-child migration, teams, advanced shared files/audio and their acceptance remain later work.

## Installed daily-use apps — 5 November 2026

- Mac **1.2.0 (14)**: installed at `/Applications/Taskfold.app`; later source builds are separate candidates and do not replace the running app.
- iPhone **1.4.0 (31)**: installed and launch verified after saved-draft approval. All 205 previous task identities, titles, descriptions, attachments and children were preserved. This update fixes skipped day-review decisions and reduces repeated large-attachment parsing and redundant drop writes. Wider physical rendering/FPS remains unmeasured.
- Current and rollback archives are retained privately; later candidates are documented in their individual receipts and remain uninstalled until an appropriate update window.

Ordinary candidates use no test launch arguments and keep the recorded advanced feature gates. Acceptance fixtures run only in the reserved namespace. The initial build/package work made no hosted changes, new simulators, real-task edits, installation or publication. The later focused assignment service deployment is recorded below. Build receipts bind the app input fingerprint.

## What the ordinary client exposes

| Experience | Client/configuration inventory | Service inventory |
| --- | --- | --- |
| Capture, task edits/completion/deletion, planning and recurring dates | Existing personal path available | Guarded task edit/delete functions present |
| Archive/subprojects, manual ordering and filters | Existing personal path available | Project archive/parent columns and ordering function present |
| Templates and multiline capture | Ordinary personal screens available | Template table and guarded edit function present; template and capture Undo services are live; checked capture order restoration requires Mac build 7/iOS build 22; actual Store acceptance passes on Mac and iPhone Simulator |
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

Prior build-6 startup/sync is verified; build 7 is installed but its startup/sync await app-data approval. Finish physical iPhone signing when the user confirms setup. Scoped assignment and independent personal-template Undo are deployed; native capture/template Store acceptance is now complete on Mac and iPhone Simulator. Continue daily organization/templates/planning improvements; verify installed build 7 startup/sync after app-data approval and finish phone signing/installation when confirmed. Keep the full advanced Px backlog; do not restart broad unchanged acceptance matrices as the immediate focus.

The delivery check originally assumed exactly three versioned targets and rejected the iOS Watch companion. It now requires both configurations for each core bundle identity and consistent versions across optional companions. Each repo passes 12 focused checks, including matching companions, missing required configurations and mismatched companion versions; the ordinary projects and actual built app/widget/share metadata pass. This does not establish distribution or Watch runtime acceptance.

## Assignment service preflight — 3 November

At the initial preflight, read-only inspection confirmed exactly one merge anchor in the live guarded task editor, with task-generation protection, invoker security and authenticated-only execution. The scoped endpoint/guard were absent at that preflight; the later deployment below supersedes that availability status. See `hosted-assignment-preflight.json`. No real tasks or hosted definitions were changed. This is readiness evidence for a narrow update, not a deployment or acceptance result. Unrelated personal workflows can proceed.

## Template search update — 3 November

The ordinary library now searches template names, shows native no-results feedback and clears its query when the workspace changes. Import/save/edit/run controls and persisted template definitions are retained. Mac 1.2.0 (4) is development signed and separately packaged; the extracted ZIP payload passes signature/extension checks. iOS Simulator compilation passes. Native visual acceptance and actual installation remain pending, with the existing Xcode account/profile blocker for iPhone. See `template-search.json`. The earlier build-3 and build-4 ZIPs remain older candidates; build 5 supersedes them. No backend or real-task changes were made.

## Multiline capture update — 3 November

Mac **1.2.0 (5)** and iOS Simulator **1.4.0 (20)** include inherited quick-capture context, explicit section selection and fuller review captions. Capture from label views includes its label. Per-line recognition overrides defaults; project changes clear incompatible section/assignment. Fresh task identities do not copy existing content or completion. Each owning repo passes six focused Core checks, including four new regressions; both ordinary app builds pass. The actual Mac ZIP payload passes signature/widget/share checks. See `capture-context.json` for receipts, source hashes and the roughly 1 GiB of reclaimed completed test products. Native visual acceptance and actual installation remain pending; physical iPhone signing still needs Xcode account/profiles. No backend or real-task data changed. This refines existing capture scope; curated progress bars are unchanged.

## Scoped assignment service update — 3 November

The current clients' endpoint is live after a focused update. Both owning repositories pass 32 actual PostgreSQL compatibility checks, with the original deployed task-editor body and synthetic task rows. Exact guarded deployment/rollback bundles are tested. Live metadata verifies the reviewed function hashes, authenticated-only invoker execution and unchanged existing patch permissions, table policies and task triggers. The live REST route rejects anonymous calls with permission denied. Current security-advisor findings are unchanged, not universally clear; existing findings/remediation links are retained in `scoped-assignment-advisors-before.json` and `scoped-assignment-advisors-after.json`.

`scoped-assignment-deployed.json` and `scoped-assignment-api-probe.json` record the live scope. No user task records were read or modified. This is not a signed-in real-account/native assignment acceptance or a solution to the separately deferred older-client rollout gate. This assignment-only milestone did not enable workflow Undo; the later independent Undo update below supersedes that availability status. Mac installation now passes; physical iPhone signing remains separate.

Each repo owns the canonical applied-history version `20261103201254_taskfold_daily_scoped_assignment_guard.sql`. It is the idempotent existing candidate, matching its source hash; the actual single-use deployment also included the reviewed live baseline check retained under `Scripts/Database/fixtures`. Do not push the whole unfinished advanced migration chain merely to reproduce this selected update. The guarded rollback refuses definitions changed after this update.

## Personal-template Undo update — 3 November

Personal-template workflow Undo now discovers service support independently of teams. New Mac build 6/iOS Simulator build 21 bind cached support to the account and HTTPS service origin. Missing support holds only the saved Undo rather than blocking unrelated legacy sync. Snapshot corruption in optional capability metadata preserves task/queue data. Requests use bounded, cookie-free transport with redirects refused.

The focused service migration is live as `20261103212921_taskfold_personal_workflow_undo_service`. Both repos own the identical replayable canonical SQL; the single-use live preflight and exact-definition rollback are retained separately. Each repo passes **21 Core checks**, **53 actual PostgreSQL checks** including deployment/rollback/reinstall, and **19 real local Auth/REST checks**. These cover atomic fresh-record removal, later-edit/access-loss refusal, session revocation and retry preservation. Live hashes, grants, unchanged public table ACL/RLS/policies/task triggers and anonymous REST refusal verify; no real task rows were modified by deployment/probes. Existing security WARN findings are unchanged. The new private receipt table has RLS, no client SELECT grants and intentionally no client policies; its advisor INFO is recorded.

This earlier update was scoped to fresh insert-only personal template runs. At this historical milestone, native template Undo and atomic multiline capture Undo remained pending; the 4 November update below supersedes that status. Atomic capture order restoration was not part of this earlier change: it needs safe handling of existing order deltas and Redo. No team/boundary rollout, ordinary advanced gates or deferred release features were enabled. See `personal-workflow-service-*.json` for exact evidence.

`--products-directory` selects output placement but cannot prevent Xcode from retiring earlier managed products. The helper now refuses a build while an app is running from the same cache. Run daily apps from Applications, preserving build receipts/packages and a private safety copy before replacement. Build 5's removed managed files were restored byte-for-byte from its verified package before the old process was closed; build 6 was subsequently closed for the installed build-7 update.

## Atomic multiline capture Undo — 4 November

Fresh multiline captures now retain one workflow history entry, including checked restoration of an existing manual order. A separate capture command/capability/API route avoids treating it as the older insert-only template protocol. The service checks the whole batch and order before writing, preserves later task edits/reorders and returns the same successful receipt on retry without touching re-created work. Rollback retains those receipts.

Native testing exposed the ordinary order normalizer converting a workflow PATCH into a POST, plus replay needing its inverse even without a new UI history entry. The fixes preserve legacy order upserts. Exact UTC/time formatting comparison handles PostgREST spellings, preserves SQL microseconds and avoids a date formatter per row. Each repo passes **39 Core checks**, **60 actual PostgreSQL/deployment/rollback checks**, and **36 genuine local Auth/API checks**. Scoped Mac Store capture → Undo → Redo → Undo and fresh template run/Undo now pass, with the real local server preserving the original task/order and recording three receipts. This uses reserved-namespace test transport; it does not establish real TLS/Keychain or every UI/accessibility direction. The same actual Store lifecycle now passes on the reserved iPhone Simulator, whose initial Shutdown state was restored. Physical device, real TLS/Keychain and wider UI/accessibility directions remain separate.

The focused service is live as `20261104190311_taskfold_capture_workflow_undo`. Live metadata matches the tested bodies, all 66 captured column contracts, authenticated-only invoker routes and unchanged public permissions/policies/task triggers. Existing security warnings are unchanged; anonymous live API calls are refused. No hosted task records were read or changed by deployment/probes, and no advanced client gates were enabled. Each repo owns the replayable canonical SQL and guarded deployment/rollback bundles. See `capture-workflow-undo-*.json`.

Mac build 7 ZIP is verified against the exact accepted native binary. The duplicate uncompressed product and completed compiler outputs were retired to respect the 20 GiB storage floor; the archive, receipts, source and concise evidence remain. Old readable test-result summaries were saved privately before pruning retired bundles; newest and unreadable bundles were kept. The disposable native host strips normal app link/document registrations and is removed after closing.

Both native proofs are under `capture-workflow-undo-native-*.json` in the owning repo. The iOS archive is explicitly Simulator-only. Native hosts strip normal link/document registrations; the iOS proof used the guarded verified-archive option to retire its duplicate source product before booting. All hosts and owned services are closed. The daily helper now requests `-j 1` inside Swift in addition to the outer Xcode job limit; Core testing uses `--jobs 1`. These scheduling-only changes apply to future builds; the accepted binaries were verified before that helper change.

### 4 November · Starter workflow candidate

Four built-in workflows now appear in template search and open the existing definition preview before an editable copy is explicitly saved. Runs remain separate and use fresh identities; dates are not imposed. Each repo passes five focused client checks covering JSON/CSV transfer, ordering/notes, scheduling defaults, Undo/Redo preservation and search. Mac **1.2.0 (8)** is signed and its actual ZIP payload passes signature/widget/share checks; it is packaged, not installed or native-UI accepted. Installed build 7 remains waiting on its macOS shared app-data prompt. Native observation stopped at the locked Mac before assertions, and the temporary host is gone. iOS **1.4.0 (23)** now compiles and its exact Simulator ZIP payload/continuity metadata verify. The initial storage refusal was resolved through the bounded test-result cleanup. Build 22 remains the earlier native Store baseline; build 23 has no new starter UI or physical-install acceptance. Physical signing/install remains unverified. See `workflow-starters-core.json` and `workflow-starters-build.json`.

Completed compiler products and duplicate host/app products were retired after retaining the verified Mac archive and concise evidence. No repeated capture-service matrices, hosted mutations, real-task edits or advanced gate changes were part of this refinement.

### 4 November · Simulator candidate and bounded storage cleanup

The owning iOS build-23 receipt binds the current committed app inputs; its archive was extracted and every payload file compared, then continuity metadata checked. No Simulator was booted for this compilation. Ten obsolete raw test results were retired only after their full summaries and individual outcomes were saved privately; about 1.9 GiB of reported disk usage was removed. The newest five readable runs and unreadable bundles remain. See `workflow-starters-storage-cleanup.json`. Current device inventory shows no connected physical iOS tunnel; no new signing or installation claim is made. The existing Mac build-7 process is still waiting at shared capture storage.

## Searchable pinned notes — 5 November

Pinned notes now search full note text, task names and project/section paths. Readable previews are prepared off the main actor and shown in bounded pages; completed and archived notes remain available, and duplicate titles have project context. Current pin/workspace/session/source identity is checked before the reader opens. Existing editing, creation and output remain on the normal task-backed path.

Both owning Core suites pass 20 checks. Two current-source signed iPhone Simulator cases pass search/paging/current-text/cold reading and dark/largest-text keyboard/Done/Close, with screenshot review and no reported runtime warnings. Saved task, pin, project and section tables remain unchanged by reading/searching. Mac20 and iPhone32 are independently built, strictly signed and ZIP-payload verified candidates; neither is installed. Current daily apps remain Mac14/iPhone31. Native Mac/iPad/speech, real-device rendering and wider account/cloud contexts remain separate. See `note-library-search.json` and the scoped native/candidate receipts.
