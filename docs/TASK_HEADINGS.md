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

## Typed portability and checklist progress

Checklist progress now counts ordinary descendants and excludes heading and
unsupported-type nodes. Expansion and the full tree remain intact; a heading
container does not hide its ordinary descendants from the checklist count. Empty
work progress is omitted rather than presenting 0/0. Version-2 workflow review
summaries count ordinary tasks/subtasks separately from headings.

Heading workflow definitions use version 2 with the exact capability declaration
`["task_headings"]`. The matching `taskfold-template` file envelope also uses
version 2. Ordinary captures remove nullable/false type metadata from the fresh
definition and keep version 1, preserving ordinary file compatibility. A newer
version without the declared capability, an unknown capability, malformed type or
mismatched file/document version is refused. Capturing an unsupported live task
type refuses rather than dropping it. Relative plans, notes, labels, hierarchy
and header flags survive file roundtrip and fresh runs. Existing intentional
template exclusions—completion, discussion, attachments and assignments—remain
visible in the review; workspace backup is the full work-transfer format.

Workspace exports containing a root or recognized nested `is_heading` field use
version 2 and the same capability. Version 1 and original unversioned exports
remain readable for ordinary work. Typed work cannot be smuggled into a version-1
or unversioned file; root/nested boolean and open-heading invariants validate
before restore planning. Restore mapping preserves the flag while giving copied
work its proper account and identities. Unsupported future template definitions
remain preservable as opaque saved definitions under the existing backup rules.

Root/branch duplication keeps known types and content while replacing identities
and refusing unknown types for the whole selection. A saved editor draft's
independent Inbox copy also retains known heading flags instead of turning the
reference into completable work. The full encrypted original remains preserved.

Final Store admission checks authoring availability for introduced headings and
explicit conversions, including nested writes, restore and duplication. Existing
metadata/deletion remain available. Private workflow creation checks the captured
workspace and heading capability before preparing mutations. Heading previews
show the nested contents and type status; a capability refusal leaves the saved
template intact. Shared publication/run requests explicitly refuse version 2
until their server/capability adapters support it. No cloud capability or hosted
schema was enabled by this stage.

See `p2-task-headings-portability-evidence.json` for the exact Core, coordinated
file-I/O, native and build scope. Broader action/count/history consistency,
source-specific Todoist/CSV/clipboard mapping and shared type support remain open.
In particular, project totals still use the existing root-occurrence/checklist
policy; descendant work under headings needs a deliberate broader review before
exposure. Largest-text, spoken, Mac runtime and cross-device acceptance are also
not established by these scoped checks.

## Reminder eligibility and displayed counts

A heading is reference context, not reminder work. Time-reminder generation and
reconstruction now require an ordinary task, including the legacy planned-date
fallback. Converting to a heading suppresses future task alerts and makes old
snooze callbacks obsolete after the current state is loaded. Reminder settings,
notes and dates remain saved. The native reminder screen explains that delivery
is paused and settings are kept; converting back to a task is explicit.

Focus start/resume admission and finish-alert generation require an ordinary
open task. Saved sessions are retained for review, pause/stop and history. A
captured ordinary choice no longer authorizes Focus after conversion.

Location candidates, editor reviews, outbound private drafts, imported receipt
admission and recovery candidates require an ordinary task. Type conversion
retires the old delivery ticket without deleting saved task settings or private
pins. Cancellation-only ticket reconstruction intentionally remains available:
a retired or unsupported task must still be able to cancel an old OS request.
No physical location delivery or remote reminder rollout is enabled here.

List, board and saved-filter group badges count the displayed records. Ordinary
only groups keep their compact numeric badge; mixed/context groups label task,
heading and unsupported-item counts separately. This does not expand checklist
descendants into a second count. Typed template-library summaries now use the
full task/subtask and heading totals used in their review. Project pulse retains
its documented root-occurrence policy (checklist items excluded); a hierarchy
view counts the independently displayed nodes in that view.

See `p2-task-headings-actions-evidence.json` for current verification and exact
limits. Historical activity semantics, broader productive/descendant policies,
provider/source mapping, shared capability work and native Mac/spoken acceptance
are still open; these changes do not expose heading authoring in normal builds.

## Reviewed Todoist source mapping

Both app repos now own the import-todoist service source, handler and tests,
starting from the observed deployed version 41. This removes the release input
dependency on the web-reference checkout. No hosted source/configuration changed.

Only the documented Todoist leading `* ` prefix maps to an explicit heading;
Taskfold capture, literal titles and unrelated clipboard text do not gain this
interpretation. The first marker is removed from the displayed imported title;
source metadata retains the complete original content. Root/nested flags, notes,
dates, HTTPS file links, comments and ordinary descendants are preserved. A
source heading carrying a completed state becomes an open heading with a preview
warning and original state kept. Empty heading titles refuse the entire import.
A heading hierarchy outside the current reader's 32 nested levels also refuses.

Typed bundles require version 2 plus exactly `["task_headings"]`. The invoker RPC
persists the root flag and retains the global nested-heading invariant. Its
source-account lock, owner checks, RLS, source-ID mapping and atomic transaction
remain intact. Malformed/unsupported capabilities, invalid types and completed
heading states refuse without partial work. Legacy ordinary bundles remain
compatible. Source metadata is not interpreted as nested task containment.

The service switch `TASKFOLD_TODOIST_HEADINGS_ENABLED` defaults off. Both this
switch and an explicit client capability are required to save a heading bundle.
Preview exposes separate included heading counts and availability; unavailable
native previews retain their source token/workspace approval and disable Import.
The client uses its existing local test heading opt-in, so normal/cloud heading
imports remain unavailable. Saving rechecks the approved heading counts against
the fresh source snapshot; a changed count requires a new preview. Typed receipts
must confirm the capability before the client clears its token/approval. A lost
or unconfirmed receipt keeps the same source for safe retry.

Retries deliberately preserve existing imported Taskfold types/edits, including
older literal-prefix copies. They do not auto-convert those copies or resurrect
deleted destinations. The preview explains this limitation. No Todoist mutation
is performed: the provider client retains GET-only behavior. Service mapping and
real local PostgreSQL persistence are tested separately from native response/UI
fixtures; these do not establish genuine-provider, hosted, broad Mac/spoken or
cross-device heading acceptance.

See `p2-task-headings-todoist-evidence.json` and `headings-todoist/`. Clipboard/CSV
formats, older imported-copy conversion review, remaining action/history policies
and shared adapters still need work before normal heading exposure.

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
   can be completed. Checklist progress now excludes heading nodes and retains
   ordinary descendants; verify the remaining root/descendant totals and history
   independently before exposure.
4. Finish clipboard/CSV formats and provider/native acceptance of the implemented
   reviewed Todoist mapping. Scoped
   duplication, versioned template files/runs and workspace backup/restore now
   preserve known types; wider provider/file-handoff/cross-device and native
   recovery acceptance remain open.
5. Finish team type-edit command/receipt/recovery adapters and capability
   negotiation. Resolve the user-deferred older-client rollout dependency before
   hosted deployment/exposure. Missing server capability must leave current work
   safe; this contract is not a complete legacy-writer enforcement audit.
6. Run native local/shared source-change, accessibility, large-text, relaunch,
   rollback and cross-device acceptance. Mac UI automation now works and the
   focused Todoist heading review passes; broader Mac heading scenarios still
   require execution. Builds and Core checks do not substitute for that work.

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
