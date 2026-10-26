# Child history: app sync and backup integration

26 October 2026. Both apps now record child history during committed local task
edits and read the optional service feed during workspace sync and access
recovery. The source schema remains the additive migration from the recording
foundation; this milestone does not deploy it or enable normal heading authoring.

## User behavior

Completing, reopening, moving or rescheduling a child creates a separate event.
Editing its title or notes does not invent a history transition. A local change,
its events and the existing task/assignment metadata share Store's snapshot and
persistence rollback. Failed saves restore that whole snapshot. Networked edits
continue to use server-confirmed events; optimistic edits do not manufacture
cloud history.

Undo and Redo are new actions. Ordinary task history requests now receive fresh
mutation IDs, like scoped team requests already did. A transport retry keeps the
prepared mutation ID, so retry deduplication cannot swallow a real Redo. Existing
team completion/batch renewal and task-incarnation guards remain in their path.

Portable backup files retain child events and the coverage epoch as an archive.
They validate event identity, format, sequence uniqueness, paths and epoch
metadata. Restore never sends those archived rows as edits, remaps their actors,
or presents them as newly recorded work. Restored task copies keep their existing
new-incarnation behavior. Invalid/future archives are preserved at their source
and require a supported reader before portable restore; encrypted Recovery's
original snapshot is not silently rewritten.

## Read and privacy contract

The child feed is optional so an undeployed service cannot stop core task sync.
A successful empty feed has a valid epoch; missing, denied, malformed, partial or
future data is unavailable. The client reads the epoch before and after all
sequence pages and rejects a changed epoch. Each page is bounded, strictly
ordered, fully decoded and globally unique by event ID; a later-page failure
cannot return an earlier partial page. The read is capped at 100,000 rows rather
than silently truncated. Both account identity and session incarnation fence the
entire optional read, including a same-account sign-out/sign-in cycle.

Workspace reads keep their existing before/after project-access boundary checks.
Team presentation applies the same prior/current scope mask to parent and child
history and prunes profiles that are no longer needed by visible events. A fresh
task refresh with unavailable child history removes both cached history and its
epoch, including access recovery and team merges. It does not reuse the old feed
or erase unsent task changes. Offline/non-task refreshes retain existing history.
The optional read itself does not grant task-editing authority.

Store and Backend reject client mutations to both child-history tables. The
private database trigger remains the only cloud writer. The existing service's
team adoption inspection counts/protocol are unchanged: expanding those service
adapters is still separate work and is not claimed by these client checks.

## Performance

The first 5,000-event local append probe took 2.915 seconds. Per-pass date parsers
and caches reduce the same strict validation to approximately 0.137 seconds for
iOS Core and 0.139 seconds for Mac Core with repeated timestamps. A final expanded
fixture with 5,000 distinct roots and timestamps takes 0.362 seconds for iOS Core
and 0.370 seconds for Mac Core. Fixture construction is outside the measured
append. No mutable parser survives the validation pass or crosses accounts/threads. SQL-produced rows, offsets, fractional instants,
invalid dates and unsupported formats retain exactly the default decoder's
results. These are local Debug samples, not a production latency guarantee.

## Verification and limits

Both independently owned repositories pass 252 focused checks, including 12 new
cases in this stage (10 child-history cases and two workspace cases). The selected
suites cover old activity, backups, child history, workspace access, team task
lifecycle and team batch history. HTTP uses synthetic URLProtocol peers and tests
empty/unavailable, sequence paging, duplicates, future rows, later failures,
epoch changes and same-account session replacement. This is not a hosted REST or
cross-device delivery claim. The earlier independent PostgreSQL/advisor evidence
remains in `child-activity-history/`; no SQL changed during this integration.

Independent isolated app/test builds pass. iOS also builds its widget and share
extension. Signing, native results, source bindings and screenshots are recorded
in `child-activity-integration/` in each corresponding repository. The iOS
repository retains phone/tablet runtime evidence; this Mac repository's evidence
covers its own Core/build results. Native phone/tablet coverage exercises the
actual Store, persisted child completion/reopen/Redo events and cold relaunch.
The Mac screen remains locked: its signed build and augmented native case are
prepared, but no new Mac runtime acceptance is claimed.

The metadata is now integrated; activity UI, Insights and Project pulse still use
the original parent feed. They must not claim child-history coverage yet.

## Current follow-up status

The parent type/generation prerequisite below is now implemented and verified;
see [historical task type and generation](TASK_ROOT_ACTIVITY_CONTEXT.md). The
[child identity, role and cleanup custody](TASK_NODE_ACTIVITY_CUSTODY.md) is now
implemented. Project-adoption inspection/review parity and mixed-feed integration
remain before service/UI rollout. Activity screens still await that
integration. The original sequence below records this milestone's starting plan.

## Original next-work sequence

1. Capture trustworthy root type/work context for future root events before
   combining aggregates. Today's root type cannot classify a historical root
   event. Preserve legacy parent credits, make unknown historical context explicit,
   and avoid counting headings or both a heading and its independent children.
2. Combine parent and child activity using root incarnation plus stable child key,
   separate feed sequence spaces, work-before/after eligibility and explicit
   recording/coverage gaps. Support exact current-child navigation through a fresh
   tree, with no editing authority from the archived path.
3. Connect project activity, Insights and Project pulse (including widget output)
   and verify complete/reopen/Redo, type changes, imported completions, deleted or
   recreated roots, account changes, unavailable feeds and partial coverage.
4. Complete shared/service adoption, notification/webhook/email adapters,
   cross-device acceptance and installed-widget replay; continue broader calendar
   periods and the remaining headings authoring/conversion/accessibility checks.

The full Px goal stays active. User-deferred release/distribution, remote
reminders, old-client rollout safeguards and external-provider setup stay deferred.


26 October follow-up: bounded adoption inspection/counts/fingerprints/locks and
the client review contract are implemented locally. Historical-only event custody
is still open; see [TASK_NODE_PROJECT_ADOPTION.md](TASK_NODE_PROJECT_ADOPTION.md)
for exact scope and remaining service/UI work.
