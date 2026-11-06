# Team projects — access and native management (gated)

24 October 2026. Local, undeployed, disabled by default. This builds on
TEAM_ORGANIZATION.md and TEAM_CONTENT_CUSTODY.md. It does not complete advanced
teams: full task/comment/file/service editing, rollout and broader native acceptance remain open.
The latest gated project-management implementation is recorded below.

## Role contract

| Team role | Project access |
| --- | --- |
| Owner/admin | Manager of all team projects, including private projects |
| Member | Editor for team-visible projects; private projects require an explicit grant |
| Guest | Only explicitly granted projects, as viewer or editor |
| Removed/nonmember | None; creator UUIDs and old grants never substitute for membership |

An explicit project grant can make a member a manager, editor or viewer. It can
lower a member's team-visible default to viewer. Creation grants its current
creator manager access. Guests cannot become project managers. A demotion to guest
removes manager grants so promotion back to member cannot silently revive them.
All explicit grants reference accepted team memberships and cascade on departure.
Admins' inherited management access cannot be falsely overridden with a viewer
setting. Private means invited people **and team admins**, not secrecy from admins.

Every task-write capability remains false in this stage, including for an editor
or manager. Those roles are the authority model for the later write adapter;
current native/direct/service writes remain closed. Access management below is a
separate, implemented permission, not a claim that task editing is enabled.

## Native reads and data boundaries

Private role lookup joins current accepted membership, project visibility/grants,
live verified Auth accounts and account-removal state. Native reads also require
the caller's actual matching live Auth session. Editable user metadata cannot grant
access. RLS protects project/task/section/activity/file rows; existing creator-only
OR policies cannot override it. History checks both the current/last project and the projects in each activity
state, including after a move or deletion. A creator shortcut cannot expose
private history, and admins with both scopes retain the full authorized timeline.
A single permissive activity policy avoids overlapping-policy overhead.
Private files gain an explicit member-read policy,
while pending-cleanup files stay hidden. Departed creators/uploader IDs do not
reopen task history or file access.

The existing project-member display API returns only current readers of a team
project. A departed creator no longer becomes a directory entry through the
legacy owner branch. The inspected legacy email-contact helper now excludes team
relationships from both sharing shortcuts. Personal sharing still provides its
existing contact lookup; a team relationship alone never grants contact email.

Native visibility does not authorize service/API/email destinations. Their old
project lock remains closed for team projects, and their personal task pages still
work without inheriting native team access. Privileged comment writers have their
own closed trigger, because task UPDATE restrictions alone would not fence them.

Workspace-link guards prevent legacy personal writes from attaching project
hierarchy, recurring tasks or section moves to a team. Same-workspace personal
hierarchy remains valid. New bindings reject existing cross-workspace hierarchy or
recurrence relationships. Clearing a link remains available for cleanup. Moving
existing personal projects/templates into a team still needs its reviewed native
workflow; the current creation endpoint creates new, empty top-level projects.

## Reviewed project management

`public.taskfold_team_projects(_action text, _body jsonb)` is an authenticated
invoker wrapper over a private guarded command. Private tables have RLS and no
client or service-role table grants. A verified live caller and team membership
are required; a target Auth row is locked before team/project rows, and current
manager authority is rechecked after waiting. An unauthorized caller cannot use
recipient errors as an account lookup.

- `list`: team_id, optional after/limit (1–100). Returns only readable projects,
  sorted UUID cursor pages, current roles, team state/revision and paused status.
- `get`: team_id/project_id. Returns current capability/settings; only a manager
  also receives explicit grant IDs and roles.
- `create`: members/admins/owner may create a new project, choose team/private
  visibility and a folder in that team. Guests cannot create projects.
- `settings`: a manager may change visibility and folder placement.
- `set_access`: a manager may set a current accepted member's project role.
- `reset_access`: remove an explicit override and use the team default. For a
  guest or private-project member this removes access; for a team-visible member
  it can restore editor access. The UI must label this as resetting team
  permissions, not always as revoking access.

Mutations require team_id, project_id, request_id, issued_at, team_revision, plus
project revision except for creation. Creation also requires name, visibility and
folder_id (explicit null is allowed); settings requires visibility/folder_id;
access commands require user_id and set_access additionally requires role.
Unknown fields, malformed IDs/revisions, oversized bodies and invalid choices fail
without partial changes. Names use the existing bounded team/folder validation.

Reviewed requests expire after 15 minutes, allow one minute of clock skew and
hash the exact action/body. Exact current-authority retries return the original
minimal receipt; changed bodies and stale reviews conflict. UUID-only project
identity records prevent recreation after deletion. Receipts are pruned after a
day on subsequent team writes. Projects are limited to 1,000 per team and normal
management shares the team's 2,000 daily-operation budget. Narrowing resets remain
available while setup is paused/archived or the normal budget is full. A reset
that would widen access must respect normal setup/availability checks.

Protocol 1 replies carry the verified account and team. Mutation receipts also
carry their request ID. No server, client, provider or release configuration is
enabled by these definitions. The private native_reads_enabled flag defaults off.
It must stay off until write, client/workspace and acceptance gates are satisfied.

## Independent native clients

Both repos own TeamProjectAccess.swift and Backend read methods for paged catalog
and single-project access. Their models retain account/origin/team context,
validate IDs/revisions/roles/visibility/capability consistency and cursor ordering,
and reject unsupported protocol or task-editing capabilities. A creator field
never supplies missing permission. The read requests use the existing account and
session-generation fence, same-origin configuration, no redirects/cookies/cache,
a 25-second timeout and a 256,000-byte response limit.

A confirmed unavailable scope is distinct from a missing/unverifiable server
contract, so later workspace integration can hide revoked data without treating a
server outage as deletion. Expired authority requests explicit sign-in. Internal
server details are not displayed. These methods are not yet installed into the
workspace/sidebar, mutation queue or widget publication. No native team screen or
new app-runtime acceptance is claimed.

## Verification and remaining work

Each repository independently passes 145 actual PostgreSQL checks with the real
migrations, SQL roles, native guarded routines, service task API and current
session records. It covers role/visibility matrices, guest scope, profile/email
privacy, former-creator history/files, strict reviews and retry behavior, folder
and workspace boundaries, paused recovery, identity tombstones and three real
transaction overlaps (authority loss, competing reviews and queued session
expiry). The official advisors report no new warnings/errors beyond known fixture
Auth-init-plan warnings. Containers and loopback ports are removed in finally.

Each independent SwiftPM core run passes 48 selected checks, including 8 new team
checks and existing automation/email regressions, with no failures or skips.
The native contract test decodes a response fixture produced by that repo's actual
PostgreSQL RPC run. Controlled HTTP tests cover oversized replies, protocol errors,
confirmed loss and a late response during an account switch. This is not hosted
HTTP, Realtime, native UI or actual Storage-provider acceptance. Xcode source
membership is validated; app launch/build is not inferred from the core suite.
See p2-team-project-access-evidence.json and p2-team-project-native-evidence.json.

Next: implement current-role native/direct/service task/comment/file writes,
assignment rules and reviewed project move/template/subproject workflows; then
native team switcher/folders/administration, project invitation/people flows,
membership-driven catalog refresh/cache/filter/widget privacy, account-removal
explanations and backup/activity acceptance. Keep all existing user deferrals and
the full ranked Px objective intact; this is neither rank-6 nor full-Px completion.


## Gated native project management (24 October 2026)

Both independently owned apps now connect Projects from a team's overview to the
permitted catalog, project visibility/folder settings and reviewed access controls.
Owners/admins and project managers see current accepted recipients; guests cannot
create projects or become managers. Team-role management remains inherited and
cannot be misleadingly overridden. Reset to team permissions explicitly explains
whether this restores Editor access or removes access. Narrowing resets remain
available while paused/archived; widening changes require normal availability.
Unchanged settings and unchanged explicit roles cannot create a new command.

Creation makes a new empty top-level team project. Private visibility includes
explicit recipients plus the team owner/admins; it never promises secrecy from
admins. Folder options come from the same reviewed team. Project moves, personal
project adoption, templates/subprojects and actual team-task editing remain other
workflows, and no such write permission is enabled by this screen. Team-project
rename/archive/delete still need dedicated guards and reviews; personal edit
paths stay closed for team projects. The preview
states when task editing is unavailable rather than opening a personal task path.

The source-only private presentation wrapper first executes the existing guarded
service. It adds bounded project names to permitted list/get rows and accepted
member IDs, roles and profile names to manager get responses. It adds no global
account search or contact-email endpoint. Nonmanagers receive no recipient/grant
directory. Banned/unconfirmed/removal-pending recipients are excluded. Names never
authorize actions; commands retain the selected exact account ID. A team admin's
confirmed email is merged only from that admin's separately authorized team read.
The Join disclosure now explains project managers' name visibility separately
from the owner/admin email directory. Profiles are self-authored, not proof of
identity. The existing project/task/storage access boundaries stay intact.

A typed project command retains exact action/body/account/backend/team/project
and both revisions. Creation/settings/set_access/reset_access all use a separate
private recovery namespace. The shared journal implementation preserves existing
team-command bytes/keys while keeping the two families independent. It checks the
account-removal fence, coordinates across app windows, saves before sending and
clears only the reviewed request after a verified minimal receipt. Lost replies
retry the same nonce/body; stale, expired or unauthorized results stay saved for
explicit review/clear. Saved-request recovery shows the authored name, requested
visibility/folder or selected account/role so an expired request remains useful
to review without recovering private files manually. Project access never enters the optimistic task queue or
Undo. Account removal also clears this new private command family.

Catalog/detail reads clear prior names before loading, bind the caller/session
and compare the existing verified workspace-boundary token before/after the full
read. Pages are bounded at 1,000 total projects and must keep team revision/state/
pause context and strict ordering. Access drift or an account switch publishes no
partial directory. Project replies now have a bounded 1 MB transport allowance
for up to 500 recipients; redirects, cache/cookies and existing session fences
remain closed. No directory or grant projection is saved into tasks/widgets or
portable backups. Confirmed management refreshes the scoped view and requests the
existing workspace sync; wider live workspace/cache/editor/widget transition
acceptance remains required before enabling teams.

See `p2-team-project-management-evidence.json` and the separately generated real
SQL response fixtures for exact verification. This is a gated implementation,
not hosted Auth/Keychain, Mac runtime/spoken, Realtime or release acceptance.
Team rollout and task-write flags remain disabled. Existing user deferrals and
all other ranked Px work remain intact.


The new shared-service migration versions are canonical in both independently
owned copies: directory identity `20261024161155` and project presentation
`20261024163752`. The Mac directory file was renamed from `20261024161156` with
identical SQL; its earlier evidence remains the historical snapshot at commit
`aff6323`. Both services stay undeployed. Current Mac directory/project harnesses
are rerun against these owned canonical files; no cross-repo runtime dependency
is introduced. Older foundation-history reconciliation remains a rollout check.


## Reviewed project rename, archive and reopen — 24 October 2026

The gated project surface now offers Rename, Archive and Reopen, with explicit
active/own-archive/inherited-archive status. Older services without the versioned
state fields remain unknown and do not receive these new controls. A structural
review shows the complete affected project count and explains preservation before
confirmation. Cancel creates no command. The server rejects a branch if the
actor cannot manage every child, or if a reviewed branch changed. No child names
are disclosed by that review. Reopening a parent preserves individually archived
children; reopening under an archived parent requires reopening the parent first.

All seven project commands use the existing separate private project journal.
The archive review token/count, account, backend, IDs, revisions and request ID
survive uncertain results and relaunch. Exact retries return the original minimal
receipt without applying the operation again, including an old archive retry
after a later reopen. Fresh archive is available as a narrowing/recovery action
while setup is paused or the team is archived/at its budget; rename/reopen retain
the normal setup/team/budget restrictions. Requests expire after 15 minutes.

The canonical source-only migration is 20261024172109_team_project_archiving.sql
in each repo. A private, transaction/actor/team/root/project/operation scope lets
only the reviewed project metadata fields change. Existing task/comment/file
write guards stay untouched. The real legacy hierarchy cascade derives inherited
archive state while retaining child own flags. Team and hierarchy locks serialize
reviews against branch changes; affected project locks serialize against task
writers. Every affected binding revision and access boundary changes on apply.
The existing trusted whole-team cleanup scope remains separate. No hosted schema
or native rollout/task-write flag was changed.

Verification: 114 focused Swift tests, 93 owned PostgreSQL metadata checks and the
152-check project access regression pass independently in each repo. Actual SQL
review/command fixtures are decoded by each native core test suite. The database
suite covers lost responses/replay, stale branch/revisions, explicit manager and
lower roles, private/foreign/personal children, corrupt cycles/depth, paused/team
archive/quota recovery, unchanged task/discussion/file/custody/grant rows, epochs,
concurrent writes and project locks, direct-write rejection, exact scope rejection
and existing empty whole-team cleanup. Both Debug app/extension builds succeed.
See p2-team-project-archiving-evidence.json for native results and limitations.

This advances rank 6; it does not complete team collaboration or the full Px
objective. Live Auth/RLS/Keychain acceptance, Mac runtime/spoken checks, broader
workspace/editor/widget transitions, scoped team task/comment/file adapters,
project deletion with retained custody/Storage API cleanup, project adoption/
templates/subprojects and remaining ranked work remain open. All user-deferred
provider/device/release work stays deferred.

Reproduce the owned service checks with `node Scripts/Database/test-team-project-archiving.mjs <report.json> <native-fixtures.json>` and run the existing project access suite under `TASKFOLD_TEST_PROJECT_ARCHIVING=1`. These commands create and remove owned local PostgreSQL containers; they do not deploy a migration. Native recovery uses a separately namespaced debug app and synthetic file peer. Production Keychain/cloud acceptance is not implied.

Native verification: iPhone and iPad each pass the two final normal/Accessibility
XXXL workflows. The saved peer contains one project at revision 4, exactly three
unique accepted changes (rename/archive/reopen), and no pending request. Sixteen
screenshots are visually inspected. Accessibility-size review titles shorten to
fit; long body copy remains in the scrollable form. The test waits for a control’s
center to be visible before tapping. Intermediate failed UI trials are described
in the evidence and are not counted as acceptance. Native tests use a one-project
synthetic file peer; task/content and descendant preservation are real owned-SQL
checks. Mac runtime/spoken and genuine hosted Auth/Keychain acceptance remain open.

Owned isolated test apps/runners and temporary host/build/result/attachment folders
were removed after preserving evidence; approximately 1.22 GiB of allocated artifacts removed. No Mac test app launched. Persistent core caches and unrelated apps, containers and runtimes remain intact.


## Team subprojects and branch moves: service and command foundation — 24 October 2026

The next rank-6 stage adds source-only `review_hierarchy`, `move` and
`create_subproject` service operations, with independent native command/read
implementations in both repositories. It does **not** expose the new app controls
yet. The destination picker, branch confirmation, synthetic UI peer and native
phone/tablet/Mac acceptance are the next stage. Teams and task writes stay gated;
no migration is deployed and no real workspace or rollout setting is changed.

A hierarchy review binds the exact source branch, its per-project revisions and
archive settings, and the destination ancestry/revision to a digest. The caller
must manage every affected project and the destination. Cross-creator branches
and branches whose creator has left are valid; private parent identity is hidden
when unreadable. New subprojects are attributed to their actual creator, with an
explicit manager grant and separately chosen visibility/folder. Destination
permissions and folder settings do not propagate into the moved branch.

The separate transaction/actor/team/root/project/destination scope permits only
reviewed parent and derived archive changes. Source creators, own archive flags,
tasks, discussions, sections, Storage rows, file custody and grants stay intact.
Moving into an archived destination is explicit in the review and retains each
project's own archive flag. The legacy personal ownership guard remains intact;
only bound team rows use the new team-aware organization guard. Live Auth/session
and role checks, team serialization, bounded branches/depth, request fingerprints,
15-minute request expiry, operation budget and exact replay apply. A failure after
the root write rolls the entire operation back, including scope and receipt rows.

The optional versioned hierarchy projection distinguishes team-level placement
from an inaccessible parent, and rejects partial/contradictory values. Native
reviews/commands/receipts bind account, backend, team, action, source, destination,
revisions, count and archive states. An HTTP review must return the requested
destination. Both new commands reuse the private project journal, keeping their
exact reviewed intent across a lost response and relaunch. Existing controls
explicitly decline hierarchy actions until the reviewed native flow is ready.

Verification in each repo: 121 focused Swift tests; 95 real owned-PostgreSQL
hierarchy checks; the existing 93 archive and 152 access checks with the new
migration loaded. Native core tests decode each repository's independently
produced SQL reviews/receipts, including archived-root moves. Checks include
concurrent requests, destination revocation while waiting on a lock, stale branch
and destination ancestry, full rollback, exact scope misuse, hidden parents,
departed creators, 20-level depth and 1,000-project limits, direct-write rejection,
unchanged content/custody/grants and unchanged personal creator isolation.
Security/performance advisors report no new warnings (the existing fixture's
`auth_rls_initplan` baseline remains). Debug app/extension compilation is recorded
in `p2-team-project-hierarchy-foundation-evidence.json`; build success is not
native interaction, spoken, hosted Auth/Keychain or rollout acceptance.

Reproduce with `node Scripts/Database/test-team-project-hierarchy.mjs <report.json> <native-fixtures.json>`.
Run the two existing service suites under `TASKFOLD_TEST_PROJECT_HIERARCHY=1` to
load this migration as well. Their deliberate corruption fixtures conditionally
bypass both organization triggers; production guards are not weakened to seed
those fixtures. All service runtimes are owned local containers removed in finally
blocks. No cross-repository build input is introduced.

This completes the hierarchy service/typed-command foundation only. The ranked
Px objective, team hierarchy UI/acceptance, scoped task/comment/file integration,
project adoption/templates/deletion, Watch acceptance and the other remaining
ranked work stay open. Existing user deferrals stay deferred.

Both Debug app/extension builds passed. No native app was installed or launched in this foundation stage; no Taskfold processes remained at cleanup. The owned copies/native caches were removed after preserving evidence (approximately 1.01 GiB allocated across both platforms). Existing core caches, booted phone/tablet states, user data and unrelated runtimes remain intact.


## Team subprojects and move review — 24 October 2026

The gated project surface now offers New subproject and Move project when the
service supplies versioned hierarchy metadata and the actor can manage the
project in an active, unpaused team. Older services keep their existing controls.
Each repository owns its implementation; no cross-repository build dependency
was introduced. No hosted migration or team/task-write rollout flag changed.

New subproject reviews a fresh project identity under the chosen parent before
opening the draft. Its own visibility defaults to Private and its folder to No
folder; the parent is not treated as permission or folder inheritance. Move
loads a separate, fully paginated, access-fenced catalog. It offers managed
projects and, where applicable, Team level. It removes the source, known
subprojects, current parent and known cycles from presentation; the service
still verifies the entire private branch and destination independently.

The review names the destination and affected project count, explains retained
tasks/discussions/files and per-project settings, and warns when a destination
is archived. Change destination returns to the picker without creating a command.
Cancel creates no pending request. Confirm uses the typed source/destination
review from the preceding service foundation; no private child names are added
to the review. Late account/workspace or stale source/team/destination results
are declined. Enter/Done in the name editor dismisses its keyboard without
submitting the draft. Large review titles shorten; body copy wraps and scrolls.

A saved uncertain command shows its branch and retained destination intent and
reuses the exact private request after relaunch. Destination display names remain
presentation only. Successful creation offers Open subproject. Catalog rows show
known parent context or an unavailable-parent status, and a permitted subproject
can open its parent. Task editing remains disabled in this gated preview.

The synthetic native peer now models real parent links, mixed creators, derived
archive state, per-project revisions and separate lost replies for both new
commands. It runs only in the existing exact isolated DEBUG namespace with
explicit test arguments. Its file-backed journal replaces Keychain only for
synthetic acceptance; no real Auth, task, mail or storage service is involved.
Real SQL authorization/custody preservation remains separately proved by the
95-check service foundation and its archive/access regressions, not by this peer.

Two additional native-core cases cover destination filtering, including source,
current parent, descendants, lower roles, paused/old services, archived targets,
known cycles and cross-origin catalog rows. The focused 123-test Swift suite
passes independently in each repo, and each Debug app/extension build passes.
Native acceptance results are recorded separately below; these builds do not
imply Mac runtime, spoken, hosted Auth/Keychain or rollout acceptance.


Native iPhone and iPad acceptance now passes all six project workflows per
device: the new largest-text hierarchy cancellation/change-destination checks,
subproject creation and interrupted-reply recovery, branch move and interrupted
recovery, correct parent navigation, return to team level, saved child navigation,
and existing creation/settings/access/rename/archive/reopen regressions. Final
saved peer state has four projects and exactly three distinct accepted hierarchy
requests (create/move/move), with no pending journal. Creators, grants/folders,
per-project own archive flags and final inherited projections are verified.
Cancelled hierarchy reviews leave no peer or command files. Twenty-six new
screenshots are visually inspected and preserved in the iOS repo; standard
single-line name-field horizontal editing/truncation remains native behavior.

The passing retake uses the observed native BackButton identifier and targets
the active sheet collection viewport for visual checks. Superseded runs are not
counted as final acceptance. See `p2-team-project-hierarchy-ui-evidence.json` and
the iOS-owned native result/state/screenshot records for precise scope. Mac core
checks and Debug build pass independently; no native Mac runtime/spoken, hosted
Auth/Keychain or full team-rollout acceptance is claimed. Rank 6 and the full Px
objective remain active, including remaining task/adoption/template/deletion and
broader access/role/account integration. Existing deferrals remain unchanged.

The isolated apps and runners are closed and uninstalled from both Simulators. Owned native caches, prepared copies, result bundles and scratch files are removed after preserving evidence (approximately 1.34 GiB allocated). No Taskfold process remains. Baseline phone/tablet boot states and unrelated caches, runtimes and user data are preserved.

The [iOS-owned hierarchy UI acceptance record](https://github.com/dbakp/TaskFold-iOS/blob/53fefac03030df75bc7ff1ea714763faf14dbb0f/docs/p2-team-project-hierarchy-ui-evidence.json) is committed at `53fefac`. This is a reference to iPhone/iPad Simulator acceptance, not a Mac runtime claim.
