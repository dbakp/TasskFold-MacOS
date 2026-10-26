# Task headings — contract and implementation gates

Updated 26 October 2026. Rank 3 is in progress. This is an independently owned
source contract with gated local native authoring in each app repository, not a
shipped heading feature.

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
- Normal app configuration still omits the authoring switch. The native editor
  now offers explicit Task/Heading choices only in an opted-in local test copy;
  cloud and team authoring remain unavailable. No migration or setting was applied
  to the hosted service; all SQL runs use disposable synthetic data.


## Native editing and productive projections

The local editor uses the existing Save/Cancel flow on iPhone/iPad and the Mac's
existing autosave/Undo flow. Root and nested headings retain notes, dates, files,
children and identity. Rows use a text symbol and stronger title weight instead
of a completion ring; normal descendants keep their own completion controls.
Selections, navigation and metadata editing remain available. Heading titles have
an accessible heading trait where native text supports it, and their status is
labelled “Heading, stays open”. Unsupported future types have a separate cue.
Actual spoken, largest-text and broader Mac acceptance remain open.

Type editing checks the opening workspace/source through existing editor
admission, plus task type, completion state/timestamp, generation and revision.
Unrelated current notes/dates can merge. A changed completion/type or unsupported
revision refuses Save and preserves the draft. Final Store admission also covers
compound type-and-note-pin saves. Embedded nodes retain their captured path and
parent-owned write; they never become new root records. Legacy child nodes do not
acquire a historical completion counter from this change.

Heading completion controls are removed from rows and organizers; completion
swipes and accessible completion actions are unavailable. Native completion
entry points refuse headings and mixed selections without success feedback.
Productive widgets publish actionable task rows only. Pinned note can still show
a heading's selected notes. Inbox review, Focus choices, current project progress,
project-attention widgets and capacity estimates exclude headings and unsupported
future types. The app's date queries retain headings as context. Apple Watch's
Today projection independently excludes headings and refuses stale ordinary
completion commands after conversion; this is Core verification, not new paired
Watch runtime acceptance. Historical activity and the remaining broad count/
action/portability integrations are still acceptance gates below.

Prepare a disposable copy with
`python3 Scripts/prepare_task_heading_native_test.py --output /tmp/taskfold-heading-test`.
This writes the local test switch only into the copy; it enables no hosted
capability and changes no production settings. Use the existing signing and
isolated-build scripts before runtime testing. See
`p2-task-headings-native-evidence.json` for exact accepted build/test scope.

## Ordered work before exposure

1. Finish native acceptance of the implemented local presentation/type editors:
   completed/new task handling, durable Undo/Redo/recovery, source/access races,
   Mac keyboard/window behavior, largest text and spoken feedback. Shared type
   authoring and role-restricted command adapters remain unimplemented.
2. Complete every interaction path: detail and checklist controls, keyboard and
   swipe actions, bulk actions, Focus/shortcut/notification actions, widgets and
   Watch projection. A refused action must neither report success nor discard
   authored work. Test stale ordinary-to-heading actions after relaunch.
3. Define actionable totals consistently across Today, Inbox review, project
   progress, day capacity, productivity, filters, notifications and wearables.
   Retain dated headings as readable context without treating them as work that
   can be completed. Checklist progress still counts heading nodes (visible in
   the recorded organizer screenshot); exclude those while retaining ordinary
   descendants. Verify the remaining counters/history independently.
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
