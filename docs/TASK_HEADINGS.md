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
Project totals now expose nearest ordinary descendants beneath headings while
retaining ordinary-parent checklist semantics; see the project-work stage below.
The remaining productive projections and child history still need acceptance
before exposure. Largest-text, spoken, Mac runtime and cross-device acceptance are also
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

See `p2-task-headings-todoist-evidence.json` and `headings-todoist/`. Taskfold
workflow CSV/clipboard is covered below; generic source mappings, older imported-copy
conversion review, remaining action/history policies and shared adapters still
need work before normal heading exposure.

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
4. Generic CSV file/text column mapping is implemented with explicit types,
   references and full definition review; see TASK_CSV_SOURCE_MAPPING.md for
   supported fields and current acceptance. Finish provider/file-handoff and
   cross-device/native recovery acceptance, flat task-row sharing and the
   reviewed Todoist adapter's wider acceptance. Scoped duplication, versioned
   template files/runs and workspace backup/restore preserve known types.
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

## Workflow CSV and explicit clipboard transfer — 26 October 2026

The template library now accepts Taskfold workflow JSON or CSV through its file
picker, or text through an explicit Paste/edit → Review → Add to templates flow.
Export previews offer JSON/CSV and Copy template text. Import saves only a private
reusable definition; task creation remains the separate reviewed Use template
operation. Cancel leaves saved definitions and tasks unchanged. Pasted text stays
in memory across a workspace change, but requires an explicit new workspace bind
and review before saving. No background clipboard inspection is performed.

The CSV is Taskfold's own versioned workflow interchange format, not a generic
Todoist/third-party CSV mapping. Its exact 26-column header begins
`format,document_version,workflow,name,capabilities,entity,id,parent_id`.
`format=taskfold-workflow-v1`; document version 2 requires `task_headings` and
explicit `type=task|heading`. Version 1 remains ordinary tasks. A title beginning
`* ` remains literal; it never creates a heading. A workflow metadata row precedes
project/section/task rows, with repeated metadata checked on every row. References
are file-local, and tasks have explicit parent references; sibling order follows
row order. Labels and recurrence use JSON cells. Text fields use a reversible
leading-apostrophe escape for formula-like prefixes and literal apostrophes.
UTF-8, optional BOM, quoted commas/newlines and doubled quotes are supported.
Export uses CRLF. Parsing is bounded to 2.1 MB and 20,000 entity rows, and refuses
unknown fields/types/capabilities, invalid values, duplicate/missing references,
cycles and excessive depth as a whole definition. Existing template validation
and portability limits apply, including intentional exclusion of assignments,
attachments, discussion and completion history. Ordinary v1 exports remain v1.

Mac retains its native save panel and pasteboard; iOS retains protected temporary
share files and an explicit system Paste button. Each repo owns its implementation.
Normal heading authoring remains gated. Generic source mapping, flat task-row
sharing, cross-device/provider handoff, older literal-copy conversion review,
remaining action/history/shared adapters and the broader headings acceptance
matrix remain open. No hosted service or shipping capability is changed here.

Verification: each repo passes 75 scoped Core cases, including all 12 new CSV
cases and 16 heading-portability cases; four optional cloud integration cases
skip without disposable accounts. Both isolated Debug builds and strict code
signatures pass. The actual clipboard review/edit/Cancel/Save/cold-return scenario
passes on iPhone and iPad Simulator with unchanged task tables; two screenshots
are inspected. Mac native launch is blocked by the locked screen, so Mac
clipboard/save-panel acceptance remains open. The initial phone offscreen-control
assertion and locked Mac launch failure are retained, not counted as passes.
See `p2-task-headings-csv-evidence.json` and `headings-csv/`.

## Project work beneath headings — 26 October 2026

Project pulse now uses an explicit current-work policy in both apps and their
published widget summaries. Headings contribute no work occurrence themselves;
their nearest ordinary descendants count in their place, recursively through
heading-only containers. Traversal stops at an ordinary task: its own checklist
remains part of that task, preserving the existing ordinary-parent policy. A
completed ordinary parent still counts once even with open checklist details.
Empty headings add no unfinished work. This changes current project progress,
not the saved hierarchy or completion behavior.

Only project/section/account containment comes from the root. A child keeps its
own dates, priority, estimate, assignment and completion; a dated heading cannot
make an undated child overdue. Needs attention uses the same work scope and date
policy as the widget. Modern child references open the existing subtask editor,
with fresh hierarchy/workspace admission; legacy text or unavailable references
open their containing root for review instead. No derived work item is saved as
a new task row. Widget summaries retain only bounded names and opaque scoped
identities, not complete notes or mutable child commands.

Unrecognized branches, malformed containers, conflicting root duplicates and
read limits mark totals incomplete. The native overview labels known counts and
omits its progress bar; the widget says Review tasks instead of claiming a
complete ratio. The new optional countsIncomplete summary field is absent on
ordinary complete snapshots, preserving legacy decoding. Heading authoring and
all shipping/service rollout switches remain unchanged.

Recorded parent-task events remain separate from these current totals. Child
completion changes current progress but has no separate activity event yet;
Project pulse now explains that limitation even before any history exists.
Separate child history, broader Today/Inbox/capacity/Focus/Watch descendant work
projections, shared/service acceptance and the remaining exposure matrix stay
open. This is project progress and attention consistency, not completion of the
full heading/count/history objective.

Verification: 80 scoped Core cases pass per repo, including 12 new project-work
cases, with zero skips/failures. Both current Debug app/test builds, strict app
signatures and owned WidgetKit target builds pass. The final iPhone/iPad scenario
passes exact child navigation, unchanged Cancel, child completion, matching
published widget totals (1/3 → 2/3), explicit history coverage and cold return;
four native screenshots are inspected. Owned source-rendered normal/incomplete
widget layouts are inspected on both repos. Native Mac execution and installed
widget interaction remain open because the Mac is locked. See
`p2-task-headings-project-work-evidence.json` and `headings-project-work/`.

## Mac native clipboard, CSV files and project work — 26 October 2026

After the user unlocked the Mac, three distinct native scenarios pass against the
committed isolated app code: CSV clipboard review/edit/Cancel/Save/cold return;
actual native CSV file export/open/review/Cancel; and exact child navigation,
completion, Command-Z Undo, Shift-Command-Z Redo and cold project return. The
heading stays open and other saved heading/notes content remains intact. Project
totals move from 1/3 to 2/3. Clipboard Save adds only a private version-2 template;
Cancel retains work. File-panel Cancel preserves the entire saved tables set.
The real exported CSV is retained as a synthetic fixture. Four native screenshots
are inspected and scoped to the isolated app; surrounding desktop/file-picker
content is excluded from committed evidence.

Test corrections use the existing single-instance Finder/Dock-open pattern,
actual host-container path, native Switch/front-sheet scrolling and scoped
Export/Open panel controls. Earlier failures are documented rather than counted
as passes. The final test bundle builds and the app's strict signature passes.
Only test harness and evidence change in this closeout; shipping authoring flags,
services and release inputs are unchanged. See `mac-heading-acceptance/report.json`.

These scoped Mac checks supersede the earlier locked-screen blockers. Wider
heading creation/conversion, spoken/large-text, source-race, installed widget,
cloud-provider and cross-device acceptance remain open. Today/Inbox/capacity and
other descendant projections, separate child history and shared adapters still
need implementation/verification. The full Px objective remains active.

## Heading work in the day planner and capacity — 26 October 2026

The planner now shows nearest ordinary tasks beneath headings with their own
plans and estimates, real child routes and a heading breadcrumb. Dated headings
remain context, with no completion control or productive estimate/overlap credit.
Ordinary task checklists stay part of their parent work. Scheduling and completion
of projected children use the strict hierarchy selection contract and save only
the real root tree; native Undo keeps the existing durable queue/history path.

A cached productive reading excludes archived projects and is invalidated with
task/visibility changes. Planner and capacity-widget publication share child
estimates, unestimated work and carryover/overdue treatment. Unreadable branches
or missing child identities keep readable totals but withhold spare-capacity
claims; the widget says Review / Readable estimates only. Its optional
workIncomplete field is omitted when clear. Three actual SwiftUI source-view
renders (normal and review light/dark) are inspected; these are not installed
widget-host acceptance. No schema, normal-authoring or release gate changes.

82 focused Core checks pass independently in each repository, including ten new
productive-planner cases. The signed iPhone and iPad native flows pass scheduling,
Cancel, Undo, completion and cold saved-state equality. The independent Mac app,
widget and corrected test harness build; its native planner case remains pending
an unlocked run. Initial selector/navigation failures are documented as failures.
See `p2-task-headings-planner-evidence.json` and `headings-planner-work/`.

Next: Today/Upcoming and Inbox review, matching badges/primary widget rows,
reviewed containing-heading moves, wider calendar projections and child history.
These remain implementation work; this stage does not close headings or Px.

## Heading work in Today and Upcoming — 26 October 2026

Today and Upcoming now query ordinary work beneath headings using each child’s
own date, priority, search text and completion. Heading dates remain context,
including earlier dates; totals count work. The Mac Today badge uses the same
query. Heading estimate badges are hidden while their stored values are kept.
Unreadable groups show a parent-review notice. Parent captions and independent-row
membership use cached lookups.

Mac projected rows use the established hierarchy selection/edit/Undo path for
completion, details, planning, duplication and deletion; moving a child keeps its
parent’s containment rule. Printing and row gestures receive hierarchy context.
Ordinary task checklists remain expandable, while a heading does not repeat the
work already listed independently. iPhone date placement commits its real root
and view order together; a captured lift intent refuses changed workspaces, rows
or work that disappeared after a heading conversion.

190 iOS and 189 Mac focused Core checks pass (six/five new cases). Current app,
widget and UI-test builds/signatures pass. iPhone and iPad native flows pass exact
child details, Cancel, title editing, completion, Undo, cold data equality and
Upcoming membership. Final synthetic screenshots are inspected. The independent
Mac planner/Today cases remain prepared for an unlocked run; one unlock request
is already pending. Core checks do not establish real drag or spoken acceptance.
See `p2-task-headings-dated-evidence.json` and `headings-dated-work/`.

Next priorities are Inbox review/default Inbox membership with reviewed heading
moves, then matching primary widget rows/token/link authority. Wider badges,
calendar/project/label projections, child history and native/shared/cross-device
acceptance remain open. No normal-authoring, hosted or release gate changes;
this milestone does not close headings or Px.


## Heading work in Inbox and primary widgets — 26 October 2026

Default Inbox and its review cards now use the cached productive work reading.
Independent tasks beneath headings show their own details, plans and parent
context. Child completion/editing uses the strict real-root transaction path.
The Mac Inbox badge counts the same eligible work.

Moving one of these cards presents a review of the entire containing root
heading, including completed work. The review names the destination, lists the
affected tasks and warns when assignments will be cleared. Confirmation checks
the captured root, destination and workspace again; Cancel makes no change,
and one Undo restores the group. Direct synthetic-child project PATCHes are
rejected. This stage intentionally offers a whole-group move, not detachment.

Primary Today, Inbox reset, Focus, Week and planning-widget task data now
publishes independent work with exact child routes and completion authority.
Ordinary checklist children require an explicit child filter. Removing that
filter or converting a heading rejects stale completion authority. Ambiguous or
unreadable groups produce a review state rather than an empty-Inbox claim.
Five light/dark/review SwiftUI source renders use the synthetic app's saved
widget projection; these are not installed WidgetKit host acceptance.

164 iOS and 163 Mac focused Core checks pass, including seven new cases per
repo. App/widget/test builds and signatures pass. Native runtime results and
source bindings are recorded in `p2-task-headings-inbox-evidence.json` and
`headings-inbox-work/`; do not infer Mac app-flow acceptance from its build.

Next: project/label/default saved-filter projections and remaining badges,
wider calendar projections, separate child history, then broader native,
installed-widget, shared/service and cross-device acceptance. Normal heading
authoring remains disabled. This milestone does not close headings or Px,
and all user-deferred release/provider/device gates remain unchanged.

The final iPhone and iPad native scenarios both pass, with Cancel preserving the
root exactly, edited child title retained, completion/Undo, confirmed whole-group
move/Undo, published Inbox counts 2→0→2→1, and exact cold-return root equality.
Four native screenshots were inspected. The debug-only publication panel can
overlap the iPad toolbar; it is absent from normal app runs. The independent Mac
Inbox/planner/Today attempts all stop at foreground activation while the Mac
reports locked, before app-flow checks. Those remain unverified, with the prepared
Mac host preserved for a later unlocked run.


## Heading work in project, label and filter lists — 26 October 2026

Default Project, All Tasks, Completed, label and ordinary saved-filter queries now
read independent work beneath headings. Each child keeps its own labels, plans,
priority and completion. Explicit root/subtask/parent predicates retain their
existing checklist semantics, including mixed independent query sections. A
mixed filter cannot reintroduce roots from unavailable projects.

Manual project queries preserve the source outline. Existing sparse saved orders
containing only heading roots expand their anchors to retain the grouped work;
explicitly saved child positions remain respected. Project sections and widget
ordering use the same rule. Native project/label badges count productive work,
and affected badges show a lower bound when grouped data needs review. Unknown
future task types remain reachable review context without work-count credit.

Configured project, label and ordinary-filter widgets resolve primary published
children without requiring an unrelated child filter. Missing child catalog
members cannot appear as an empty ready list. Unreadable project/group data
produces an unavailable/review state; ordinary missing-root deletion tolerance
and duplicate suppression remain intact. Five actual SwiftUI source renders from
the app-published synthetic snapshot were inspected, including populated project,
label/filter and missing-child states. Installed WidgetKit action/route replay is
still a separate runtime gate.

Print capture validates the exact projected sources, retains an ordinary task's
checklist once, and avoids recursively duplicating heading work already listed.
Headings and unknown types receive no printed task total or completion box.
Default-list print keeps the existing Include checklists option; explicit
hierarchy-filter output retains its matching-only setting. The final print-review
classification and search-hidden heading-anchor corrections are Core/build
verified. Native list scenarios ran just before those two corrections; no new
native print-dialog, exported-PDF or hidden-heading search-order acceptance is
claimed by this milestone.

191 iOS and 190 Mac focused Core checks pass, including 13 new cases per repo.
App/widget/test builds and signatures pass. Both iPhone and iPad native scenarios
pass project membership, exact child details/Cancel, own-label filtering, child
editing, ordinary saved-filter membership, completion/Undo, and exact saved-root
cold return into label/Completed views. Eight native screenshots were inspected.
The Mac still reports locked; its independent project/label/filter case is built
and prepared alongside the prior Inbox/planner/Today cases, with no new native
Mac acceptance claim. See `p2-task-headings-list-evidence.json` and
`headings-list-work/` for source variants, signatures, results and exact limits.

Next: separate child activity history and broader calendar periods, then remaining
native creation/conversion/race/legacy/largest-text/spoken acceptance, installed
widgets, shared/service and cross-device adapters and generic provider mapping.
Normal heading authoring remains disabled. This does not close headings or Px;
all user-deferred release/provider/device gates remain unchanged.


### Child history recording foundation (26 October 2026)

Separate child-ledger schema, strict reader and standalone local recorder now
exist in both owned repos. 53 Core checks per app (22 new) and 49 real-PostgreSQL
checks per independent fixture pass, including actual SQL-to-Swift rows, retry,
privacy/account boundaries and 10,000-child samples. Official advisors report no
new-object findings. This stage is inactive: Store/sync/team masking/backups and
activity/Insights/Project pulse integration remain next. Hosted deployment and
normal heading authoring remain unchanged. Mac native replay was retried after
unlock, but the Mac locked before interaction; no new runtime pass is claimed.
See [the child history contract and ordered next work](TASK_NODE_ACTIVITY.md) and
`child-activity-history/evidence.json`. Px remains open.


### Child history in local edits, sync and backups (26 October 2026)

Both apps now record committed local child transitions, read the optional cloud
feed with sequence/session/epoch checks, apply team visibility masks, discard
unavailable cached history on a fresh task read, and preserve history as a
validated backup archive without replaying it. Ordinary task Undo/Redo now uses
fresh action identities; retries keep their prepared identity. Per-pass parsers
reduce a 5,000-event append validation from 2.915 seconds to about 0.14 seconds
without weakening decoding; a 5,000-distinct-root/timestamp sample takes about
0.36–0.37 seconds. 252 focused checks pass per repo, including 12 new
cases. App/test builds pass; exact native and signing scope is recorded in
`child-activity-integration/evidence.json`. Mac runtime remains unverified while
locked. No service migration or rollout flag changed.

Activity screens, Insights and Project pulse still use parent history. Next is
trustworthy historical root type/work context and a combined child activity fold,
then their UI/widget integration and broader calendar/adapters acceptance. See
[TASK_NODE_ACTIVITY_INTEGRATION.md](TASK_NODE_ACTIVITY_INTEGRATION.md) for the
contract, verification limits and ordered remaining work. Px stays active.


### Observed parent type and generation (26 October 2026)

New parent events carry optional observed type/generation metadata. Heading
events do not earn work credit, old untyped totals are preserved, and a known new
occurrence resets its counter without erasing genuine earlier credit. Typed
routes cannot open a recreated/foreign root at the same ID. The additive SQL
writer preserves the later team-custody rule and continues recording retained
parent work after Auth removal. No hosted schema or authoring flag changed.

239 Core checks, 36 PostgreSQL upgrade checks and 94 broader custody checks pass
per independent repository. App/test builds and exact native limits are recorded
in `root-activity-context/`. This is not mixed child UI/runtime acceptance.
The separate child ledger still needs team identity/role/cleanup custody alignment
before service rollout; that is now the first prerequisite for combining feeds
and wiring activity/Insights/Project pulse. See
[TASK_ROOT_ACTIVITY_CONTEXT.md](TASK_ROOT_ACTIVITY_CONTEXT.md). The full Px scope
and all user-deferred release/provider/device gates remain unchanged.


### Child custody and team read parity (26 October 2026)

Prepared child-history custody now uses stable content identities, survives Auth
author removal, keeps actual/unknown actors distinct, and follows parent-history
role/session/scope gates. Personal/account and explicit team cleanup physically
remove the appropriate child history, with file-guard rollback preserved. Existing
events and sequence IDs remain intact; guaranteed coverage advances at upgrade.
64 real-PostgreSQL and 228 focused client checks pass per repository. No hosted
change, production Swift change or new native runtime pass is claimed.

Next: adoption inspection/count/fingerprint/lock and client-review parity for the
child ledger, followed by combined history and activity/Insights/widget UI. See
[TASK_NODE_ACTIVITY_CUSTODY.md](TASK_NODE_ACTIVITY_CUSTODY.md) for the exact scope,
evidence and remaining rollout gates. Px remains open; user-deferred gates stay
deferred.


### Child history in project-transfer review — 26 October 2026

Both owned clients and prepared SQL now count/fingerprint/lock child history in
bounded transfer reviews, fence late/ABA writes and require a versioned count
contract. Native review shows task/subtask history entries. Each repo passes 35
new SQL-review checks, 55 connection-policy regression checks with the new schema,
and 64 focused Core checks. Actual old approvals become stale; existing child
rows and applied receipt/retry shapes remain intact. No hosted flag changed.

This closes bounded review coverage only. The current registry binds live task
roots, so historical-only/deleted roots and earlier project intervals still need
event-level custody, removal/read rules and acceptance before rollout. Mixed
activity/Insights/Project pulse and wider heading acceptance remain next. Mac
native replay failed to activate after the unlock reply; no UI pass is counted.
See [TASK_NODE_PROJECT_ADOPTION.md](TASK_NODE_PROJECT_ADOPTION.md) and
`node-project-adoption/`. The full Px goal remains active.


### Reviewed history survives author and task removal — 26 October 2026

Forward project transfers now assign private, per-feed/event custody to the exact
reviewed history, including deleted roots and old project intervals. This grants
no current-task authority. Every referenced state still needs current project
access; expired sessions, removed members/authors, disabled native reads and
missing/deleted projects remain closed. Separate transfers may share an immutable
event: exclusive history is removed with its team, joint history with its last
owning team. Earlier observed rows survive; guaranteed epochs conservatively
advance and no unreviewed historical repair/backfill is inferred.

Each repo passes 88 PostgreSQL custody checks plus 55 connection-policy regression
checks and 258 focused Core checks. A held real transfer proves team deletion
returns PT409 instead of acting on a stale ownership snapshot. Existing file
guards/rollback and applied receipt retry remain intact. Client wire/UI code is
unchanged; no new native build/runtime acceptance is claimed. All owned containers
are removed; hosted rollout and normal heading authoring remain unchanged.
See [TASK_REVIEWED_HISTORY_CUSTODY.md](TASK_REVIEWED_HISTORY_CUSTODY.md) and
`reviewed-history-custody/` for joint-retention semantics and exact limits.

Next: combined parent/child activity, Insights and Project pulse, then UI/widget
integration and the wider remaining heading/calendar/provider acceptance.
Retrospective orphan repair and full hosted-chain/native acceptance stay open.
The full Px goal remains active; user-deferred release/provider gates stay pending.


### Parent and child activity, Insights and Project pulse — 26 October 2026

The app now combines immutable parent/child activity with feed-specific identities
and receipt-time display order. Productive children earn corrected Insights
credit; headings, ordinary checklist details and completed imports/promotions do
not. Undo/Redo and completion-time edits keep their existing semantics, while
productive-scope conversion preserves genuine earlier work without a fake reopen.
Unknown/gap data remains partial and cannot lend current-task authority.

Project activity opens exact current children using fresh generation/owner/key
checks. Store and widgets publish the same event counts, keep current progress
separate, and show partial history without discarding verified parent counts.
Child-only local history is supported; differing recording epochs remain explicit.

Each owned repo passes 257 focused Core checks (20 new). Independent Mac Debug
app and iOS Simulator app/widget/share/UI-runner builds pass. iPhone/iPad native
flows verify child completion, 2/3 progress, one recorded event, cold saved-state
equality, exact history route and one Insights completion. Source widget renders
are inspected in partial light/dark states. Mac runtime, spoken/largest-text,
installed widgets and hosted/cross-device acceptance are not claimed. Normal
heading authoring and hosted/release configuration stay unchanged.
See [TASK_WORK_HISTORY.md](TASK_WORK_HISTORY.md) and `work-history/` for exact
source bindings/results, partial coverage rules and cleanup. Next: broader
calendar periods, remaining heading/adapters acceptance and the other Px work.
The full goal remains active; user-deferred release/provider gates stay pending.


### Calendar periods and productive work — 26 October 2026

Week, three-day, five-day, month and year calendars now project ordinary work
inside headings, using each task's own date and viewed time zone. Heading and
checklist dates do not inflate totals. Stable children use existing hierarchy
editing/completion paths; unknown identities remain non-actionable with a partial
notice. Project archive changes refresh the calendar immediately. Normal heading
authoring remains off. See [TASK_CALENDAR_WORK.md](TASK_CALENDAR_WORK.md) and
`calendar-work/` for verification, harness corrections and remaining limits.
This completes the period-projection implementation; wider native Mac,
accessibility, adapter and cross-device acceptance remains open. The full Px
goal and user-deferred release/provider gates remain active/pending respectively.


### Reviewed generic CSV workflow mapping — 26 October 2026

Both clients now accept explicitly mapped comma-separated workflows through
Templates file intake or explicit pasted text. Users choose title/notes, parent
references, exact task/heading values, dates relative to a reviewed reference
date, priority, estimate, labels, time and time zone. Unmapped columns are listed;
source account/completion/assignment/history data is not guessed or imported.
A separate full definition review precedes Add to templates; runs remain separate.
Known Taskfold files keep their strict path and normal heading authoring stays off.
Each owned repository passes 87 focused Core checks, including 12 new mapping
cases. Build/native scope, source hashes and cleanup are in
[TASK_CSV_SOURCE_MAPPING.md](TASK_CSV_SOURCE_MAPPING.md) and `source-csv-mapping/`.
This implements generic workflow mapping; provider/file handoff, flat row sharing,
shared capability adapters and wider rank-3/6/7 acceptance remain open. User-deferred
gates and the full Px goal remain unchanged.


### Reviewed flat task-row CSV — 26 October 2026

Both apps now implement Print or export → Export CSV, with row review, explicit
notes/checklist choices, native Save and guarded Share. Structured fields, status,
file-local hierarchy and complete label names survive; account/live IDs and private
non-task payloads are excluded. The explicit CSV mapper recognizes the versioned
transport without reinterpreting generic text. Source/workspace/options checks
precede handoff. Headings are counted as rows separately from productive work.
Each repo passes 64 focused Core cases; current phone/tablet cancellation and cold
preservation pass. Independent Mac build passes; native Mac, completed provider
handoff and wider source/account/accessibility acceptance stay open.
See [TASK_ROW_CSV.md](TASK_ROW_CSV.md) and task-row-csv/ for scope and evidence.
The implementation advances flat row sharing; it does not close rank 3, the wider
Px goal or user-deferred release/provider/device work.
