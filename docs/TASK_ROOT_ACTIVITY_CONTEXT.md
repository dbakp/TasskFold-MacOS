# Historical task type and generation

26 October 2026. New parent events now carry an optional `root_context` annotation
with the observed before/after task type and generation. Local recording uses the
same contract. This prepares mixed parent/child history without inferring an old
event's type from today's task. The SQL migration is prepared, not deployed.

## Behavior

New heading creations/completions remain readable timeline events but do not add
work or completion credit. Ordinary task events keep their work credit. Missing
metadata remains legacy parent history and keeps its previous counting behavior;
no old row is backfilled, deleted or reclassified from a current task tree.

Known generation transitions start a distinct occurrence. Genuine prior completion
credit is retained once; an old completion counter cannot suppress a later new
occurrence's completion. A generation-changing update does not manufacture a
completion/reopen for the new copy. Work movement can still be counted from its
observed types. Type-only changes do not invent an event kind in the legacy feed.
Separate root type-only timeline events are not introduced by this migration.

Typed history routes require the current generation and original recorded owner,
a unique current root, and existing project/private-task access. A deleted event
cannot open a recreated root at the same ID. A known transition can open its
current after-occurrence. Explicit legacy/unverified generations cannot certify a
typed route. Untyped older history retains its existing current-task-reference
behavior; this does not add historical-incarnation proof to old rows.

Unsupported source identities or task types retain an explicitly unclassifiable
actual event without repairing the source, granting a route or inventing work
credit. For malformed local generation values, the annotation uses the reserved
unverified generation marker and unknown classification; the original task data
remains intact. Unsupported annotation versions/fields fail decoding and make
history incomplete rather than silently becoming ordinary work. Portable archives
retain supported annotations losslessly and never replay them as edits or actor
proof in another workspace.

## Schema and custody

`20261026104450_task_activity_root_context.sql` adds one nullable, bounded JSON
column. It adds no new public API, event kind or DML permission. Existing IDs,
sequences, state document keys and authorization remain unchanged. The constraint
is introduced NOT VALID then validated separately; old rows remain null.

The private writer preserves the later team-custody rule from
`20261024022352_team_content_custody.sql`. A test removes only the explicit
annotation delta and compares the complete writer body against that existing
implementation. This guards the original actor/DML/cascade behavior, including
recording retained team work after its original Auth account disappears. The
annotation contains only version, type and generation, never titles or notes.

The current Supabase changelog and trigger documentation were reviewed. This
change uses ordinary nullable columns, JSON and the existing private trigger; it
does not modify restricted Auth/Storage/Realtime schemas or extensions. Official
advisors run on each disposable fixture. Only known fixture init-plan warnings
remain. See [trigger documentation](https://supabase.com/docs/guides/database/postgres/triggers)
and the [changelog](https://supabase.com/changelog).

## Verification

Both independently owned repositories pass 239 focused Core checks, including 13
new root-context cases. Coverage includes legacy compatibility, observed type,
current-tree independence, unsupported/future data, archive preservation,
incarnation counter reset, stale route prevention and bounded widget summaries.
Each repository independently passes 36 real-PostgreSQL upgrade/context checks
and 94 broader custody checks. The latter installs the new annotation writer over
the actual custody schema and verifies typed history continues after Auth removal.
All owned containers are removed.

The small upgrade fixture uses minimal non-team bindings with actual inspected
custody helper definitions. The broader suite loads its existing inspected
organization, identity, cleanup, storage and automation dependencies. These are
owned synthetic fixtures, not a full hosted migration-chain, native team-role,
HTTP or cross-device acceptance claim. No credentials, real work or hosted flags
are changed. Normal heading authoring remains disabled.

Independent app/test builds pass; iOS also builds its widget/share extension.
Development signatures and prepared-source hashes are recorded under
`root-activity-context/`. No new native UI, installed-widget or spoken acceptance
is claimed for this model/schema stage. The Mac is still reported locked; its
prepared build is retained. Previous iPhone/iPad native evidence remains the
previous milestone's evidence, not a new runtime pass for this change.

Reproduce the owned checks from either repository:

```sh
swift test --filter 'TaskRootActivityContextTests|TaskActivityTests|TaskNodeActivityTests|ProjectActivityContextTests|ProjectPulseWidgetTests|BackupTests|TeamWorkspaceTests'
node Scripts/Database/test-task-root-activity.mjs --report /tmp/taskfold-root-context.json
TASKFOLD_TEST_ROOT_CONTEXT=1 node Scripts/Database/test-team-content-custody.mjs /tmp/taskfold-root-custody.json
```

## Next, before mixed child history is enabled

1. Align the separate child ledger with team custody and role gates. Its original
   foundation still references Auth users and skips writes after creator removal;
   it needs stable content-identity custody, matching native-team read restrictions,
   personal-account cleanup and explicit team deletion. This is an undeployed
   service prerequisite, not proof of completed child retention. Do not deploy the
   child ledger into retained-team usage before this work and its tests.
2. Combine both feeds using stable child occurrences and separate sequence spaces,
   preserve legacy root credits, and expose the child recording/coverage boundary.
   Known root context is now available for that fold; child events must not credit
   headings, ordinary checklist detail or already-completed imports as new work.
3. Connect project activity, Insights and Project pulse/widget summaries, then
   verify native routing, Undo/Redo, unavailable/partial data, actor removal and
   account changes. Continue broader calendar periods and the remaining native
   heading creation/conversion, legacy/race/accessibility, installed-widget,
   shared/service/cross-device and provider-adapter acceptance.

The Px goal remains active. User-deferred release/distribution, remote reminders,
old-client rollout safeguards and external-provider configuration remain deferred.
