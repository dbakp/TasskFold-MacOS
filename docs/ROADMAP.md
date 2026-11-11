# Taskfold roadmap: Todoist parity and a premium feel (macOS + iOS)

Draft, 10 November 2026. Based on `TasskFold-MacOS@a43fca03` and `TaskFold-iOS@e09b071a`.

## 1. What I found

### Both apps already cover more than I expected
- About 90k lines of Swift on Mac and 195k on iOS (iOS includes Watch, widgets and the share extension). Each repo has about 1,200 commits.
- The existing plans (`TODOIST_PORT_PLAN.md`, `P1_PLAN.md`, `P2_PLAN.md`, `PREMIUM_MAC_PLAN.md`, `px-progress.json`) list most Todoist features as already built:
  - Inbox, Today and Upcoming
  - projects, sections and subprojects, with list and board layouts
  - labels, priorities, saved filters with a query language, and favourites
  - natural-language Quick Add with chips
  - deadlines, estimates and durations
  - advanced recurrence and multiple reminders, including location and calendar reminders
  - comments, file and audio attachments, mentions and activity
  - collaboration and assignment
  - templates, Todoist import, backup and restore
  - an hourly calendar planner and read-only EventKit calendars
  - Plan Your Day and Review This Week
  - goals and insights
  - 12 widget kinds
  - Shortcuts, the share extension, Apple Watch, voice capture and on-device AI breakdown
- Measured by feature list, Taskfold is already close to or past Todoist.

### Why it doesn't feel premium yet
1. **Work has gone into verification, not product.** The last few weeks of commits are about cold hierarchy history, opaque row reuse, custodian recovery and evidence JSON. Both repos together hold about 2,500 `docs/` entries, and `PREMIUM_MAC_PLAN.md` alone is 11.7k lines. That rigour protects data, but almost none of it is visible to someone using the app.
2. **Many features are built but not switched on.** Remote push reminders, provider calendar sign-in, older-client rollout, subtask storage migration, audio publishing and email capture are all deferred, or held behind normal-use rollout gates. To a user, a feature behind a gate doesn't exist.
3. **The UI looks functional rather than premium.** From the screenshots:
   - **Mac task inspector:** it reads like a Settings form, with toggle switches for due date, time and labels, a stepper date field showing `11/ 9/2026`, and pickers with ⌃⌄ arrows. Todoist uses inline chips and popovers here.
   - **Mac task rows:** every row always shows a flag and `…`. The metadata line is indented inconsistently (the project name is offset by a space), and the selected row in Today has low contrast (white text on light grey).
   - **iOS task rows:** each row repeats a large calendar icon with the date even inside Today. The metadata line is crowded, the top-right ⋯/+ pill and the tab bar sit heavily, and there is no visible priority or label detail.
4. **It can't be installed like a finished app.** The Mac DMG is ad hoc signed, not notarised, and ships without widgets. iPhone installation is deferred. Nothing is on TestFlight or the App Store.
5. **Process gaps for "commit and merge every update":**
   - Neither repo has CI (`.github/` is missing), so "wait for required checks" checks nothing.
   - The iOS repo is private on a free plan, so it has no branch protection.

### Remaining Todoist gaps (to confirm against Todoist's current help centre before Phase 2)
| Gap | Mac | iOS |
|---|---|---|
| Global Quick Add hotkey from any app | done ([TasskFold-MacOS#118](https://github.com/dbakp/TasskFold-MacOS/pull/118)) | n/a |
| Menu bar extra (quick add and Today) | done ([TasskFold-MacOS#118](https://github.com/dbakp/TasskFold-MacOS/pull/118)) | n/a |
| Server push reminders (cross-device, app closed) | deferred | deferred |
| Two-way Google/Outlook calendar sync | read-only, no provider IDs | same |
| Karma, streaks and vacation mode (on top of goals) | done (#122) | done (#123) |
| Spotlight indexing of tasks | done (#126) | done (#127) |
| Focus filters (show work or personal projects per Focus mode) | done (#126) | done (#127) |
| Live Activity for focus or next task | n/a | removed earlier |
| Real-time multi-device sync feel (instant, no manual ⌘R) | verify | verify |
| Installable signed builds (notarised, TestFlight) | missing | missing |

## 2. How each update is delivered

For every update:

1. **Branch.** Create the same branch name in both repos, `feat/<slug>`. Some updates only touch one platform, so that repo alone gets a PR.
2. **Implement.** Keep shared data contracts identical: models, filter AST, recurrence, ordering keys. Each repo keeps its own copy of the code, with no cross-repo dependency (as the repos already require).
3. **Check.**
   - Run `Scripts/test_core.sh` on Mac and the core tests on iOS.
   - Build both apps.
   - Visually check: screenshot the Mac app, and run the iOS app in the Simulator.
4. **Ship.**
   - Open a PR in each repo and link the two PRs to each other.
   - Merge into `main`, check that `main` contains the commit, then delete the branch.
5. **Clean up.** Do the storage cleanup that `AGENTS.md` asks for.

Updates stay small, one feature each, so each PR is easy to review.

### Orchestration: who does the work
The main session (Opus) orchestrates and does not do the bulk work itself. For each update it:
1. Writes a tight brief: goal, files, data-contract constraints, acceptance criteria, and what "done" looks like.
2. Spawns subagents to do the work, then reviews what they report and the diff before merging.

Model choice per task:
| Work | Model | Why |
|---|---|---|
| Read-only search, inventories, log and test-output triage | **Haiku** | Cheap and fast; returns conclusions, not file dumps |
| Builds, test runs, simulator screenshots, mechanical ports of a finished Mac change to iOS (or the reverse) | **Sonnet** | Reliable tool use at moderate cost |
| Feature implementation, UI redesign, sync or data-contract changes | **Sonnet**, briefed with the design tokens and acceptance criteria | Good quality per token |
| Architecture decisions, final review of risky diffs (sync, migrations, data safety) | **Opus** (the orchestrator itself) | Reserved for judgement calls |

Rules that keep this token-efficient without losing quality:
- **One subagent per repo per update.** Mac and iOS agents run in parallel when their changes are independent. Heavy builds are serialized, as `AGENTS.md` requires.
- **Short reports.** Subagents report a short summary: what changed, test results, screenshots taken, open risks. They don't paste whole files back.
- **Independent check.** The orchestrator checks every report against the actual diff and test output before merging. A subagent's "done" is a claim, not proof.
- **Optional second review.** Risky diffs get a separate review agent briefed with the code only, not the author's reasoning.

## 3. Phases

### Phase 0: reset and baseline (1 update)
- Build and run both apps. Record a baseline:
  - cold launch time
  - scroll smoothness with 2,000 synthetic tasks
  - Quick Add latency
- **Inventory every gated or deferred feature.** You decide for each one: ship, hide or cut.
- **Add a light CI workflow** that runs the core Swift tests on PRs, so merges are gated by something real.
  - This uses macOS runner minutes. The free private-repo allowance is about 200 macOS minutes a month.
  - Option: run CI on the Mac repo only, or skip CI.
- **Proposal: simplify the process rules in both `AGENTS.md` files.**
  - Replace the per-change evidence docs and the `px-progress` HTML ritual with this one roadmap checklist plus clear PR descriptions.
  - Keep the data-safety rules (never touch real data, use isolated fixtures, run storage cleanup).
  - **This needs your OK.**

### Phase 1: premium foundation (5 updates, both apps)
1. **Design tokens.**
   - One spacing, type, radius, colour and motion scale, mirrored in each repo.
   - Audit every screen against it.
2. **Task row redesign.**
   - Priority is shown only by the checkbox ring.
   - A single quiet metadata line: date only when it adds information, then project, labels and subtask count.
   - On Mac, the flag and `…` appear only on hover.
   - Fix selection contrast.
   - Use comfortable and compact densities.
3. **Task detail redesign.**
   - Mac inspector and iOS sheet use inline chip rows (date, priority, labels, reminders, project) that open popovers, with no toggles or steppers.
   - Description, subtasks and comments are laid out like Todoist's task view.
   - The iOS sheet uses detents.
4. **One Quick Add composer.**
   - Highlights date, project and label words inline as you type.
   - iOS gets a keyboard accessory bar.
   - The Mac panel looks the same as the iOS sheet.
5. **Delight pass.**
   - A completion animation, with haptics on iOS and an optional sound.
   - Undo toasts.
   - Empty states, skeleton loading and consistent spring motion.
   - Dark mode tuning, plus a check at Dynamic Type and largest text sizes.

6. **Project generator repair (Mac).** `Scripts/generate_project.py` no longer reproduces the committed Xcode project: about 280 lines differ, including the share-extension target. Fix it so new files can be added safely.
7. **Progress so far.**
   - Watch freshness locale bug fixed ([TaskFold-iOS#109](https://github.com/dbakp/TaskFold-iOS/pull/109)).
   - Design tokens added in both apps: `docs/DESIGN_TOKENS.md` and `Taskfold/Views/DesignTokens.swift`.
   - Project generator repaired ([TasskFold-MacOS#110](https://github.com/dbakp/TasskFold-MacOS/pull/110)).
   - Task row redesign ([TasskFold-MacOS#111](https://github.com/dbakp/TasskFold-MacOS/pull/111), [TaskFold-iOS#111](https://github.com/dbakp/TaskFold-iOS/pull/111)) and iOS list polish ([TaskFold-iOS#112](https://github.com/dbakp/TaskFold-iOS/pull/112)).
   - Task detail redesign ([TasskFold-MacOS#112](https://github.com/dbakp/TasskFold-MacOS/pull/112), [TaskFold-iOS#113](https://github.com/dbakp/TaskFold-iOS/pull/113)). Spec: `specs/TASK_DETAIL.md`.
   - Quick Add composer with inline highlighting and property chips ([TasskFold-MacOS#114](https://github.com/dbakp/TasskFold-MacOS/pull/114), [TaskFold-iOS#115](https://github.com/dbakp/TaskFold-iOS/pull/115)). Spec: `specs/QUICK_ADD.md`. The iOS UI-test row lookup is fixed.
   - Delight pass: completion linger and sound, daily goal toast, per-scope empty states, iOS skeleton, 5 s undo toasts ([TasskFold-MacOS#116](https://github.com/dbakp/TasskFold-MacOS/pull/116), [TaskFold-iOS#117](https://github.com/dbakp/TaskFold-iOS/pull/117)). Spec: `specs/DELIGHT_PASS.md`. Phase 1 is complete.
   - Empty-state polish follow-ups done ([TaskFold-iOS#119](https://github.com/dbakp/TaskFold-iOS/pull/119)).
   - Open: Mac UI tests sign with the personal team (push and time-sensitive entitlements stripped locally), but unattended runs need UI automation enabled without a password prompt. Three iOS UI tests fail on `main` in the task editor (assignee behind "+", estimate stepper height, completion undo).

### Phase 2: close the Todoist gaps (about 9 updates)
1. ~~Mac global Quick Add hotkey (user-configurable) and a menu bar extra with Today and quick add.~~ Done ([TasskFold-MacOS#118](https://github.com/dbakp/TasskFold-MacOS/pull/118), spec `specs/GLOBAL_QUICK_ADD.md`); a real hotkey press is still to be checked by hand.
2. ~~Real-time sync feel: live updates, sync-status indicator and no manual refresh in normal use.~~ Done ([TasskFold-MacOS#120](https://github.com/dbakp/TasskFold-MacOS/pull/120), [TaskFold-iOS#121](https://github.com/dbakp/TaskFold-iOS/pull/121), spec `specs/REALTIME_SYNC.md`); real two-device realtime still to be checked by hand.
3. Server push reminders. Turn on the existing APNs worker after your sign-off on hosted services.
4. ~~Karma or productivity score, streaks and vacation mode, built on the existing goals and insights.~~ Done ([TasskFold-MacOS#122](https://github.com/dbakp/TasskFold-MacOS/pull/122), [TaskFold-iOS#123](https://github.com/dbakp/TaskFold-iOS/pull/123), spec `specs/MOMENTUM.md`): streaks, a 0–100 Momentum score with levels, and vacation mode; the live Mac milestone toast is still to be checked by hand.
5. ~~Layout parity: list, board and calendar views for projects and Upcoming on both apps.~~ Done ([TasskFold-MacOS#124](https://github.com/dbakp/TasskFold-MacOS/pull/124), [TaskFold-iOS#125](https://github.com/dbakp/TaskFold-iOS/pull/125), spec `specs/LAYOUT_PARITY.md`): one Layout picker, boards for Upcoming, Today, labels and Inbox, and month calendars for projects and Upcoming. Drag and drop and the Mac ⌃⌘1–3 shortcuts are still to be checked by hand. Follow-up polish: compact board cards on Mac ([TasskFold-MacOS#125](https://github.com/dbakp/TasskFold-MacOS/pull/125)) and the View Options test identifiers restored on iOS 27 ([TaskFold-iOS#126](https://github.com/dbakp/TaskFold-iOS/pull/126)); `testTaskDensityAcrossViewsAndRelaunch` still expects equal row heights in compact Today.
6. ~~System integration: Spotlight indexing, Focus filters, App Intents and Shortcuts expansion, and an iOS Control Center control.~~ Done ([TasskFold-MacOS#126](https://github.com/dbakp/TasskFold-MacOS/pull/126), [TaskFold-iOS#127](https://github.com/dbakp/TaskFold-iOS/pull/127), spec `specs/SYSTEM_INTEGRATION.md`): Spotlight for tasks and projects, a view-only Focus filter, 9 App Shortcuts, and Open Today and Focus timer controls. A real Focus mode, Siri and the controls with the app closed are still to be checked on a device.
7. iOS Live Activity for a running focus session or the next timed task.

### Phase 3: decide the half-finished advanced work
Finish, hide or cut each of these:
- subtask storage migration
- audio comment publishing
- team workspaces
- webhooks and API
- email capture
- physical geofence delivery

I'd finish the subtask migration, because it protects data. The rest should ship only if you actually want them.

### Phase 4: beyond Todoist (secondary)
- A Things-style "This Evening" slot and a "Someday" list.
- A Structured or Sunsama-style daily time-blocking flow, built on the existing hourly planner.
- A TickTick-style habit tracker and a Pomodoro timer that reuses Focus sessions.
- On-device Apple Intelligence: capture a voice note as several tasks, or get a smart reschedule of overdue work.

## Phase 0 outcome (10 November 2026)
- **Baseline.**
  - Mac: Core tests 4,376 run, 0 failed, 46 skipped; Debug build succeeds in about 2 minutes.
  - iOS: Core tests 4,354 run with **2 failures** in `WatchFreshnessTests`. They look date or time-zone dependent, so the fix goes in Phase 1. The Debug simulator build succeeds in about 3 minutes.
- **Visual checks are blocked on this Mac.**
  - No iOS Simulator runtime is installed.
  - Screen Recording permission hasn't been granted to the terminal, so Mac screenshots fail.
- **CI deferred.** GitHub's newest macOS runner has Xcode 26.6 (Swift 6.3). The code needs the Swift 6.4 SDK used locally. Merges are gated on local checks until runners catch up.
- **Gated features found.** All are off by default; Info.plist keys are absent.
  - Teams/organization, plus native team moves and edits
  - Audio comment drafts, publishing and restoration
  - Subtask record reads, writes and completion batches, including mixed completion
  - Email capture
  - Webhooks and automation keys (Mac)
  - Server reminders
  - Geofence delivery
  - Distribution
  - Provider OAuth
  - Safe upgrades for older app versions
  - These feed the Phase 3 ship, hide or cut decision.

### Phase 5: deferred to the end (your decision, 10 November 2026)
- **Distribution.** A notarised Mac build with widgets, and TestFlight for iOS. Your Apple Developer account is the free tier, so only local development builds are possible until then.
- **Two-way Google and Outlook calendar sync.** Waiting on OAuth client IDs.

## 4. Decisions needed from you
1. **Process reset:** may I slim the `AGENTS.md` rules and stop the evidence and `px-progress` ritual?
2. **Apple Developer Program:** free account; distribution deferred to Phase 5 (decided 10 November 2026).
3. **CI:** add GitHub Actions (uses macOS runner minutes), or merge after local checks only?
4. **Start point:** Phase 0, then Phase 1 in order?
