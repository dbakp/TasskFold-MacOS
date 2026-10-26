# Child history custody and native-team reads

26 October 2026. `20261026113556_task_node_activity_custody.sql` aligns child
history with the existing parent feed's identity, cleanup and team-read rules.
It is prepared and locally verified, not deployed. No rollout flag or task-write
permission changes. No production Swift/UI change is needed for the same wire
rows; the client compatibility tests now include actual retained-author SQL rows.

## Retention and permissions

The child ledger's creator foreign key now references stable content identities,
with deletion restricted, like parent history. Removing an Auth account retains
its team-work history and creator UUID. Its personal/non-team history is physically
removed by the existing private account-cleanup function. Other people's history
is retained when the departing person was only its actor; that actor becomes
unknown through the existing Auth foreign key. Creator identity never replaces
an unknown actor.

The source writer still records retained team children after their original
Auth account disappears. It also handles a successor carrying a retained creator
UUID before its task-custody trigger has registered the new root: the current team
project binding supplies the same custody evidence as the parent writer. Source
DML authorization and actor validation remain authoritative. The child source
writer is not a callable client API.

Both the permissive and restrictive read expressions exactly match the current
parent-history policies. Team reads require the existing native-read flag, a
live session and current project role. Private prior/next scope is not exposed
by moving a root into a readable project. Grant removal, member removal, session
expiry, bans and departed-author tokens do not bypass those checks. Owner and
creator shortcuts cannot bypass the team boundary. Direct team writes remain
closed; clients cannot forge the private transaction authority.

Explicit team deletion removes child history through the existing cleanup
routine, including history of roots already deleted. Its original file-removal
guard remains intact: a blocked deletion retains every child event. UUID custody
tombstones remain, as before, to prevent replay.

## Upgrade and coverage

The migration preserves every existing child event, ID and sequence. It changes
no row fields, wire version or archived actor/owner data. No lost event is
backfilled. An earlier deployment of the foundation could have lost events
through its old Auth cascade, so the guaranteed recording epoch advances to the
custody upgrade; earlier observed events remain available with partial coverage.
Personal history may therefore have an earlier observed interval than this
workspace-wide guarantee.

Apply transactionally through the normal migration path. The upgrade takes Auth
then task source-table locks, in the same order as account cleanup, to drain old
writers before switching the private routines and publishing the coverage epoch.
Normal reads remain available; Auth/task writes wait for this schema switch. The
foreign key is added NOT VALID and then validated. Hosted lock duration and full
migration-chain acceptance are not claimed by the owned fixtures.

The three private routine bodies are compared against their inspected originals
after removing only the intended child-custody additions. Existing storage,
identity, task and account rules are preserved. There are no new public routines,
client DML grants, Auth-schema triggers or mutable search paths.

## Verification

Each independent repository passes 64 real-PostgreSQL checks using the existing
inspected team-project schema, real role helpers, Auth/session rows, parent and
child migrations, and synthetic work. These cover upgrade preservation, coverage,
parent-policy equivalence, the role matrix including explicit guest grants,
private scope movement, current-session enforcement, author removal, continued
recording, unknown actors, deleted roots, direct-write denial, rollback on file
cleanup failure and physical team deletion. Official advisors ran independently;
only seven existing fixture/init-plan warnings remain, with no new-object finding.
Every owned database container was removed.

The recording harness uses trusted private transaction scopes to exercise
actor-tagged writes. This verifies recording behavior, not delivery through a
native editor, hosted HTTP or a specific team mutation RPC. Team deletion uses
the actual permission-checked team RPC. Storage tests use synthetic database
metadata only, without upload, object bytes or provider-delivery claims.

Both clients pass 228 focused checks, including two new cases using actual
post-author-removal ledger rows: decode/archive preservation without replay or
actor rewriting, and current-member routing through a fresh accessible project
catalog. No new native app build, installation, widget or UI runtime acceptance
is claimed for this SQL/client-contract stage. Existing prepared Mac build remains
available. No real user work, credentials or hosted configuration was read/written.

Evidence and hashes are under `node-activity-custody/`. Reproduce from either repo:

```sh
node Scripts/Database/test-task-node-custody.mjs --report /tmp/taskfold-node-custody.json
swift test --filter 'TaskNodeActivityTests|TaskActivityTests|TaskRootActivityContextTests|TeamWorkspaceTests|BackupTests'
```

The current [RLS guide](https://supabase.com/docs/guides/database/postgres/row-level-security)
and changelog were reviewed. Existing helper policies remain the source of team
authority; neither stored history nor a client claim grants access.

## Remaining work before service/UI completion

1. Extend project-adoption inspection, counts, fingerprints and custody locks to
   include `task_node_activity`. The current adoption snapshot lists parent
   `task_activity` but not the new child ledger. Update the bounded client review
   contract too, so transfer cannot omit unreviewed history. This is a remaining
   service-rollout gate; this milestone does not close all service adapters.
2. Combine the two feeds with independent sequence spaces, stable occurrences,
   work eligibility, known root type and explicit coverage/unknown states. Do not
   credit headings, ordinary checklist detail or already-completed imports as new
   work. Preserve earlier root credits and partial child coverage.
3. Connect project activity, Insights and Project pulse/widget output, then verify
   native routing, actor removal, Undo/Redo, unavailable data and account changes.
   Continue broader calendar periods and remaining headings authoring/conversion,
   race/legacy/accessibility, installed-widget and cross-device/provider work.

The full Px goal stays active. Remote reminders, older-client rollout safeguards,
release/distribution and external-provider configuration remain user-deferred.


26 October follow-up: bounded adoption inspection/counts/fingerprints/locks and
the client review contract are implemented locally. Historical-only event custody
is still open; see [TASK_NODE_PROJECT_ADOPTION.md](TASK_NODE_PROJECT_ADOPTION.md)
for exact scope and remaining service/UI work.


26 October retention follow-up: reviewed per-event custody is now implemented
and locally verified for new transfers, including deleted roots, joint ownership,
author removal and final-team cleanup. It does not grant live-task authority or
backfill already adopted orphan history. See
[TASK_REVIEWED_HISTORY_CUSTODY.md](TASK_REVIEWED_HISTORY_CUSTODY.md) for exact
semantics, coverage epochs, evidence and remaining UI/hosted acceptance.
