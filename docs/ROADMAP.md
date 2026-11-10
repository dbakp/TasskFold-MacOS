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
| Global Quick Add hotkey from any app | missing | n/a |
| Menu bar extra (quick add and Today) | missing | n/a |
| Server push reminders (cross-device, app closed) | deferred | deferred |
| Two-way Google/Outlook calendar sync | read-only, no provider IDs | same |
| Karma, streaks and vacation mode (on top of goals) | missing | missing |
| Spotlight indexing of tasks | missing | missing |
| Focus filters (show work or personal projects per Focus mode) | missing | missing |
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

### Phase 2: close the Todoist gaps (about 9 updates)
1. Mac global Quick Add hotkey (user-configurable) and a menu bar extra with Today and quick add.
2. Real-time sync feel: live updates, sync-status indicator and no manual refresh in normal use.
3. Server push reminders. Turn on the existing APNs worker after your sign-off on hosted services.
4. Karma or productivity score, streaks and vacation mode, built on the existing goals and insights.
5. Layout parity: list, board and calendar views for projects and Upcoming on both apps.
6. System integration: Spotlight indexing, Focus filters, App Intents and Shortcuts expansion, and an iOS Control Center control.
7. iOS Live Activity for a running focus session or the next timed task.
8. Two-way Google and Outlook calendar sync. Needs your OAuth client IDs, already deferred.
9. Distribution: a notarised Mac build with widgets, and TestFlight for iOS. Needs a paid Apple Developer account.

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

## 4. Decisions needed from you
1. **Process reset:** may I slim the `AGENTS.md` rules and stop the evidence and `px-progress` ritual?
2. **Apple Developer Program:** do you have a paid account, for notarisation, TestFlight and widgets in distributed builds?
3. **CI:** add GitHub Actions (uses macOS runner minutes), or merge after local checks only?
4. **Start point:** Phase 0, then Phase 1 in order?
