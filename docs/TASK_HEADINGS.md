# Task headings — contract and implementation gates

Updated 26 October 2026. Rank 3 is in progress. This is an independently owned
source contract in each app repository, not a shipped heading feature.

## Intended experience

An explicit Heading type organizes tasks without a completion circle. It keeps
notes, files, dates and nested tasks. Its ordinary descendants can be completed
independently. Converting an ordinary completed task first requires reopening it;
converting a heading back to a task is explicit and undoable. A literal title
beginning with `* ` remains ordinary Taskfold text. Import may translate a
source-specific heading only after a complete, reviewed mapping is implemented.

## Implemented foundation

- `tasks.is_heading` is nullable: missing/NULL/false is ordinary, true is a
  heading. NULL preserves existing rows, default inserts and old full-row
  baselines. Unknown local JSON types are retained but cannot grant completion
  authority. There is no automatic title reinterpretation.
- A heading must have `completed=false` and no completion timestamp. Core
  mutation admission and an invoker database trigger reject accidental completion
  before persistence, including recognized nested checklist headings. Notes,
  dates, files and opaque metadata remain intact. Only `subtasks` arrays are
  interpreted as containment.
- Task-type changes advance the completion revision. Explicit personal type
  edits capture task generation, completion state, timestamp and revision.
  Undo uses explicit false instead of deleting the type field; Redo restores true.
  Root true-to-NULL and old checklist writers that drop a surviving heading's
  type are rejected. Explicit removal remains allowed.
- The ordinary completion engine produces no completion or recurring successor
  for headings. Mixed root/child completion selections fail as a whole. A
  heading's ordinary child remains actionable. Widget completion refuses the
  heading without success feedback; root type changes invalidate its action
  token. The Watch phone planner already refuses an empty completion plan.
- The personal patch service retains its existing ownership, generation,
  baseline merge and team-content guard. The global trigger also rejects the
  actual team completion service; an ordinary legacy team completion remains
  separately covered. RLS and default-off team configuration are unchanged.
- Heading creation and type controls remain unexposed. No migration or setting
  was applied to the hosted service; all SQL runs use disposable synthetic data.

## Ordered work before exposure

1. Native presentation and captured editing: type choice in task details,
   heading typography, accessible heading/state labels, no misleading completion
   control, explicit completed-task handling, workspace/access/source rechecks,
   durable Undo/Redo and recovery. Provide equivalent native behavior on Mac,
   iPhone and iPad, including nested headings and shared role restrictions.
2. Complete every interaction path: detail and checklist controls, keyboard and
   swipe actions, bulk actions, Focus/shortcut/notification actions, widgets and
   Watch projection. A refused action must neither report success nor discard
   authored work. Test stale ordinary-to-heading actions after relaunch.
3. Define actionable totals consistently across Today, Inbox review, project
   progress, day capacity, productivity, filters, notifications and wearables.
   Retain dated headings as readable context without treating them as work that
   can be completed. Verify ordinary descendants independently.
4. Preserve the type through duplication, templates, backup/export/import,
   clipboard capture and reviewed Todoist mapping. Reject any incompatible
   template or export instead of silently dropping the type or its content.
5. Finish team type-edit command/receipt/recovery adapters and capability
   negotiation. Resolve the user-deferred older-client rollout dependency before
   hosted deployment/exposure. Missing server capability must leave current work
   safe; this contract is not a complete legacy-writer enforcement audit.
6. Run native local/shared source-change, accessibility, large-text, relaunch,
   rollback and cross-device acceptance. Real Mac automation currently awaits
   interactive permission; builds and Core checks do not substitute for it.

## Verification

Run `swift test --filter
'TaskKind|TaskCompletion|CompletionRevision|TaskGeneration|Subtask|TeamCompletion|WidgetAction'`
and `node Scripts/Database/test-task-headings.mjs /tmp/taskfold-headings-report.json`
from the corresponding repository. The SQL harness uses its own labelled
PostgreSQL 17.6 container, runs advisors and removes the container in `finally`.
See `p2-task-headings-contract-evidence.json` for exact accepted runs, source
hashes, rejected harness attempts and remaining limits.

This stage does not close headings, rank 3, rank 6, wearable acceptance or the
full Px backlog. Release/distribution, remote reminders, old-client rollout,
provider registration and physical location delivery remain deferred.
