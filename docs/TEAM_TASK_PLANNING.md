# Team task planning edits — candidate, 24 October 2026

This stage extends the guarded team task editor with assignment, labels,
same-project section moves and portable reminder choices. It does not yet expose
team editing in the app: workspace authority refresh, remaining commands and
native review flows must be completed before enabling the existing flags.

## Behavior and authority

The existing `taskfold_edit_team_task` request carries the frozen account/server,
team/project, task generation, action identity, baseline and desired fields.
No new public endpoint or direct table grant is introduced. Existing live-session,
current editor/manager, active-team and unarchived-project checks remain under
locks. Native queued intents retain all four fields through persistence, conflict
review and Undo/Redo. Failed changes stay on the device without a personal-write
fallback.

Assignments accept only current project editors/managers. Explicit recipients'
Auth rows are locked before the team, matching account-removal lock order. The
recipient's live state and role are checked before a new write. A recorded retry
can still acknowledge an applied assignment after its recipient becomes unavailable;
it returns current authorized state and cannot reassign that recipient. Changing
the payload or actor with the same request identity remains a conflict.

Sections must still exist within the original project and are held against deletion
through commit. Cross-project/task-ownership/recurrence moves remain separate
commands. A changed section baseline requires review rather than replacing another
person's move. Labels use bounded text lists; concurrent replacements require review.

Reminder choices use the reviewed portable-reminder validator. Unknown/private
choices and future extension fields already in the task are preserved. New private
choices cannot be inserted through this adapter. Validation runs both on the
submitted values and on the final merge against the current row. Two individually
valid reminder lists cannot merge beyond the twenty-choice limit: the entire edit
rolls back and leaves the remote task/receipt state unchanged. This does not enable
push delivery, request device permissions or fetch holiday calendars.

## Verification

Each independent repo passed 132 planning/edit database checks, 72 linked-batch,
89 lifecycle and 70 discussion regressions: **363 checks** with owned synthetic
PostgreSQL data. These include recipient demotion while waiting, removal of a
section while waiting, stale/replayed requests, rejected fields, reminder extension
and opaque-row preservation, and concurrent merged-list limits. Official advisors
show no new warnings/errors; known dependency-fixture init-plan warnings remain
recorded. All owned database containers are removed.

Each repo passed **182 selected Swift tests** (five new native planning cases),
using its independently generated SQL fixture. These verify the real server reply,
all four persisted fields, atomic local application/Undo, rejected local shapes,
mandatory baselines and dedicated transport. The existing session/reply/batch/
lifecycle/conversation/automation/email regressions remain included. Unsigned Debug
app and embedded-extension builds pass on macOS and iOS Simulator. Evidence hashes
identify the tested source, migration and fixture. Temporary derived builds and
Mac registration are removed after verification.

Reports: `p2-team-planning-evidence.json`, `p2-team-planning-batch-regression.json`,
`p2-team-planning-lifecycle-regression.json`,
`p2-team-planning-conversation-regression.json`, and
`p2-team-planning-native-evidence.json`.

Reproduce the planning checks with all four regression switches set to `1`:
`TASKFOLD_TEAM_LIFECYCLE_REGRESSION`, `TASKFOLD_TEAM_CONVERSATION_REGRESSION`,
`TASKFOLD_TEAM_BATCH_REGRESSION`, `TASKFOLD_TEAM_PLANNING_REGRESSION`, then run
`node Scripts/Database/test-team-task-edits.mjs <report> <native-fixture>`.
The batch/lifecycle/discussion scripts accept the planning switch after their
respective preceding layers have been selected.

No hosted deployment, real-data mutation, native team UI/runtime acceptance,
remote delivery or distribution pass is claimed. Checklist/recurrence completion,
comments/mentions/files/service integrations, current-role workspace refresh,
premium team organization/admin/review UI and full privacy/recovery acceptance
remain open. Wider Px, Watch/Wear OS and all user deferrals retain scope.
