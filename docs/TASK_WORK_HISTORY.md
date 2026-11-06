# Parent and child work history in the app

26 October 2026. Both owned apps now read parent and child history together for
project activity, Insights and Project pulse publication. This is a read-only
integration over the existing wire ledgers. No schema, hosted configuration,
release input or normal heading-authoring flag changes in this milestone.

## Counts and history identity

`WorkActivity` retains each immutable source row and namespaces its display ID by
feed, so matching UUIDs or sequence numbers across ledgers cannot collide. A
combined timeline uses receipt time; sequence order is used only within its own
feed. Future-receipt rows are excluded from the combined timeline. The legacy
parent-only projection API remains available for existing callers; app views and
Store widget publication explicitly supply the optional child feed.

`ChildWorkReading` folds stable root/generation/node subjects independently of the
parent fold. Ordinary tasks within headings count as work. Ordinary checklist
details and headings remain visible history context without separate completion
credit. A completion requires productive task state both before and after the
actual transition; already-completed imports, promotions and type conversions
cannot manufacture progress. Current task trees never reinterpret old eligibility.

Reopen/Undo removes an active credit from its original day; another genuine
completion/Redo restores one current credit. Completion-time correction retains
the completing actor and project. Lower completion counters are ignored. Deletion
closes and archives genuine work, and a new generation/key lifecycle cannot inherit
another occurrence's counter. Leaving productive scope for a heading/checklist
detail preserves the work already done, without counting conversion as a reopen.
A later genuine completion in a new productive scope is its own work episode.
The parent fold now follows the same type-conversion rule, while preserving its
existing legacy untyped history and generation-reset behavior.

A valid gap retires uncertain active child credits for that root; later genuine
observed completions can recover new credit without certifying the missing past.
Conflicting row identities or sequences quarantine affected subjects. Unsupported
node identity with a known root quarantines that root, preserving other roots;
an unidentifiable root withholds the child read rather than guessing authority.
Duplicate identical rows do not add credits. Root and child feed sequence spaces
are never compared to decide which action won.

## Partial data, authors and routes

Missing child rows differ from a loaded empty ledger. Missing/invalid/future child
epochs withhold its read but keep available parent history. Child-only local
history works even before the first parent event creates its recording epoch.
Days combine both recording guarantees: complete only when both cover the day,
partial when one is absent/later or observed backdated work predates a guarantee,
and untracked when neither has recorded coverage. Known child gaps make Insights
partial; malformed parent history retains its established refresh/error state.

Project activity and widgets scope a known child gap to its referenced projects;
unscopable data stays explicitly partial. Project pulse reports completion/reopen
**events**, while Insights reports corrected completion **credits**. Current task
progress remains a separate current-tree total. The widget publishes only bounded
counts, attention excerpts and an optional per-project `historyPartial` flag, not
the raw ledgers. The two snapshots retain their existing versions and routing
contracts. Older snapshots omit the new optional flag. A partial child feed does
not erase verified parent counts or block the current progress card.

Mine uses the recorded actor. Unknown/departed actors are not replaced by their
creator and contribute only to accessible workspace totals. Store supplies its
existing presentation/access mask; Insights also checks the child project's
current accessible scopes before counting. Workspace changes continue to dismiss
old views and revalidate every action against the current binding.

Child rows say Subtask and resolve current names/routes by stable key in the same
root generation and creator, using a freshly validated accessible tree. Historical
paths are never editing authority. Missing, duplicate, transferred, recreated,
legacy-unverified or unreadable occurrences remain unavailable. Click handlers
re-resolve the task immediately before opening; the source history is never
replayed as a mutation. Actor names come from current project members.

## Verification

Each repository passes 257 selected Core checks, including 20 new work-history
cases. These cover separate sequences/UUIDs, completion/Undo/Redo, completion-time
correction, imports/promotions/details, productive-scope/type changes, deletion
and generations, missing feeds/different epochs, conflicting/unknown identity,
gap recovery, actor scope, exact current routes, actual retained SQL rows and
native/widget parity. A 5,000-independent-completion read takes about 0.25–0.27
seconds in the accepted concurrent Debug checks. It uses per-pass parsers and
project indexes, without shared mutable formatter state.

The independent arm64 Mac Debug app build passes unsigned. The isolated arm64
iOS Simulator app, share/widget targets and UI runner build and its deep strict
signature pass. The first UI-runner build caught a duplicate test variable; it was
corrected before execution, not counted as a passing build. Existing unrelated
Swift 6/test warnings are recorded separately; no release-signing claim is made.

The iPhone and iPad native case verifies the existing 1/3 to 2/3 current progress,
records exactly one productive child event, preserves the heading, returns cold
to the same saved root, opens the exact child from the combined activity row and
shows one completion in Insights. The synthetic root remains byte-exact after
viewing history and cancelling the editor. Final result summaries/source bindings
are in `work-history/`; screenshots are from the owned Simulator fixture, not
real work. Debug widget diagnostics may appear behind the test sheets on iPad.
These runs do not prove native Mac interaction, live cloud two-device delivery,
VoiceOver announcements, largest-text acceptance or an installed WidgetKit host.

The iOS-owned SwiftUI widget source is rendered in partial-history light and
dark states; its current progress and recorded-event summaries remain distinct
and readable. The Mac-owned source is rendered independently in partial-history light mode too. These are source
renders, not desktop/Home Screen WidgetKit installation/action acceptance. Owned
scratch builds/results/test apps are removed after preserving evidence. The prior
ready Mac test host/build and persistent Core caches are preserved.

## Remaining work

The local/service foundation, reviewed custody and this combined read integration
are separate milestones. Prepared server migrations remain undeployed. Historical
orphan repair still needs an explicit reviewed flow; no backfill is inferred from
a current task or project. Full migration-chain/hosted HTTP/native shared-device
acceptance remains open, as do Mac runtime and installed-widget replay, new spoken
and largest-text checks and broader heading creation/conversion/race acceptance.

Continue productive child work through broader calendar periods and remaining
shared/provider adapters, then complete the remaining Px plan. All user-deferred
remote-reminder, older-client rollout, release/distribution and external-provider
configuration gates remain deferred. The full Px goal stays active.
