# Team project access — native read and management foundation

24 October 2026. Local, undeployed, disabled by default. This builds on
TEAM_ORGANIZATION.md and TEAM_CONTENT_CUSTODY.md. It does not complete advanced
teams: task/comment/file/service editing and native workspace screens remain open.

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
