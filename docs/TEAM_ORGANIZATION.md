# Team organization foundation

Status: disabled, local verification only (24 October 2026). Gated native
overview and reviewed organization administration now exist in each app; no
deployment or project access change is included. Each app repository owns its sources, migration and tests; neither
app builds against the other repository.

## Native overview

`TeamOrganizationView` previews active/archived teams, your organization role,
folders, incoming invitations, and ownership offers. Owner/admin detail includes
the role directory and pending invitation emails; member and guest responses
must omit that private directory, and guests must also omit folders. Names are
not invented from account identifiers. The initial read-only milestone is retained in `p2-team-overview-evidence.json`.
Reviewed organization changes are described below. All eighteen service actions
now have gated native controls, including membership and ownership management.
No email is sent by these controls; live rollout remains disabled.

`TeamOrganizationOverview` and `TeamOrganizationDetail` decode bounded collections,
UUIDs, finite integer revisions, valid states, roles, expiry dates, folder order,
unique records and the current directory role. They are ephemeral, scoped to the
captured account/backend, and never stored in the task cache or backup. The
existing hardened `taskfold_teams` read transport rejects redirects/cookies/cache,
limits response bytes, and checks session identity before and after requests.
The two-read overview also fences reauthentication between list and invitations.

The view masks existing content and its title when its workspace, session,
known access revision or foreground state changes; refresh clears prior content
before awaiting new results. Delayed or overlapping responses cannot replace a
newer screen. These guards do not claim instantaneous detection of remote role
changes before the app next refreshes access.

Release navigation remains hidden unless `TaskfoldTeamsEnabled` is explicitly
configured. The synthetic debug route requires an exact isolated bundle ID plus
`--team-overview-testing`, does not sign in and never touches task data. Neither
this UI flag nor organization roles enable native team task writes. The backend
rollout gates below remain in force. Verification is scoped in
`p2-team-overview-evidence.json` and `p2-team-overview-postgres-evidence.json`.

## Reviewed team and folder changes

Both native apps now support Create team, Rename team, Archive/Reopen team,
New folder, Rename folder and Remove folder in this gated surface. The review
captures the original account, backend, team revision and selected folder before
presentation. Confirmation shows the affected team/folder and the effect; names
are trimmed and validated. Owners/admins see ordinary naming/folder controls;
only owners see Archive/Reopen. Paused enrollment hides ordinary setup controls.
These client affordances never replace the service's current permission checks.
There are still no automatic grants to projects/tasks, and no optimistic task
queue or Undo entry is used for administration.

Before sending, `TeamOrganizationCommandVault` saves the exact action, body,
request UUID and issue time in an app-only, non-synchronizing Keychain item
(`WhenUnlockedThisDeviceOnly`). Its key is partitioned by account and a digest
of the backend origin; the contents revalidate both. A process lock serializes
windows, one pending command per account/backend prevents replacement, and the
account-removal disk fence blocks late recreation or recovery reads. Confirmed
account cleanup erases the matching item, including corrupt recovery, without
erasing another backend's item. Pending names never enter task caches, widgets,
exports or portable backups.

Relaunch and reauthentication recover a request without sending it. Retry keeps
its original ID, body, reviewed revision and timestamp. It also revalidates the
request currently displayed: if another window cleared it and prepared a new
one, the stale Retry only reloads that new review and sends nothing. Validated minimal SQL
receipts must identify the expected team, revision, state and (for creation) new
folder before local recovery is cleared. Failure to save private recovery prevents any send. Dispatch/acknowledgement
errors, unknown responses, permission changes and account transitions preserve
the original request identity for recovery. The UI offers Retry, Check latest team and an explicit Clear saved
request confirmation. Clearing is local only; it cannot cancel or undo an
already accepted change. After the service's 15-minute request window expires,
retry is refused; no new timestamp/ID or automatic revision rebase is generated.
The user must inspect current team details before deliberately clearing and
reviewing a new action.

A confirmed change refreshes organization presentation and, outside the synthetic
fixture, invokes the existing workspace sync to refresh task/access projections.
Successful compilation is not live team-rollout acceptance. Exact checks and
remaining limits are in `p2-team-commands-evidence.json` and
`p2-team-commands-postgres-evidence.json`.

## Membership, invitations and ownership

Both apps now expose in-app Invite, Revoke, Join and Decline; Change role and
Remove member; Offer/Accept/Cancel ownership; Leave and Delete team. All use the
same private stable-request journal and reviewed account/backend/revision as
team/folder administration. Invite explicitly says no email is sent: a verified
recipient finds the offer in their own Taskfold invitation list. Existing members
see Already a member rather than an invalid Join action. Declining an offer does
not change an existing membership.

Role choices are visible native rows with permission descriptions and selected
state. Owners may appoint admins/members/guests; admins may manage members/guests
but cannot appoint or manage admins. Current owners cannot be removed or leave;
transfer requires an accepted non-guest recipient's separate confirmation. Guest
and member views omit the privileged directory. Account references in individual
reviews disambiguate the selected UUID without inventing display names or adding
an unscoped account lookup; richer verified member identity presentation remains
a rollout gate.

Recovery/removal/ownership controls follow the service's paused/archived rules;
ordinary setup stays hidden while paused and ordinary edits require an active
team. The server still checks current authority for every attempt and replay.
Role/member changes warn that the target's issued invitations and related
ownership offers are cancelled. Ownership acceptance warns that the former owner
becomes an admin and pending invitations are cancelled. Delete requires typing
the exact reviewed team name and explains loss of access; it is not an assertion
that every retained team-work record is physically erased.

Review metadata retains the team's original active/archived state outside the
RPC body, so recovery commands validate the correct result state. Old saved
seven-action requests without that metadata retain their original body/ID and
infer their original state. Invite and ownership-offer receipts require their
new identifiers before acknowledgement. A verified Leave/Delete finishes
navigation in its original context immediately; workspace sync runs separately
with captured account/generation/session guards, so delayed I/O cannot dismiss
a different account's screen.

The database harness now captures successful responses at the RPC boundary for
all eighteen actions and adds positive leave/revoke/retry/return checks; existing
authority, actor/session, replay and concurrency cases remain. Each repository
owns its generated response fixture and sources. See `p2-team-members-evidence.json`
and `p2-team-members-postgres-evidence.json` for exact acceptance. These controls
do not complete native team task adapters, live Auth/Keychain/account/access
acceptance, profile identity presentation, spoken testing or distribution, and
do not enable the disabled team service.

## Durable model

A team has one owner and accepted admins, members and guests. Ownership is derived
from the team row, never from editable claims or a client-supplied role. The owner
must remain an accepted member through a deferred foreign key. Teams can be
archived, reopened or deleted. Deletion removes names, ownership, membership,
invitations and folders and retains a minimal identifier tombstone to prevent
recreation by an old create request. The owner's account cannot be removed before
ownership is transferred or its teams deleted. Transfer requires an accepted
non-guest recipient's explicit acceptance; the former owner stays an admin until
removed or leaving. Transfer cancels outstanding invitations.

Folders are flat team metadata. They do not contain or grant access to projects
in this foundation. Members see folders; guests see only their team's basic
metadata. Only the owner/admin sees the member directory and pending invite
emails. There is no public account lookup. Invitations target the authenticated
user's currently verified canonical email, expire after seven days and are
removed on acceptance, decline or revocation. Demoting/removing an inviter cancels
that person's pending offers. Ownership offers expire after one day and are
invalidated when the target's role changes or membership ends.

## Server contract

`public.taskfold_teams(_action text, _body jsonb)` is an authenticated invoker
wrapper around a private permission-checked implementation. All eight private
tables have RLS and no direct client or service-role table grants. New functions
have a fixed empty search path; only the wrapper and guarded core are executable
by authenticated clients. The actor must have a current Auth user, confirmed
email, live matching Auth session, no current ban and no pending account-removal
receipt. User-editable metadata never authorizes a request. The privileged core
is necessary for access to the private records; its explicit checks determine
permission rather than bypassing an existing project policy.

Read actions: `list`, `invitations` and `get` (the latter requires `team_id`).
Every mutation carries a nonzero UUID `team_id`, unique nonzero UUID `request_id`
and UTC RFC3339 `issued_at`; all except `create` also require the reviewed integer
`revision`. Bodies reject unknown fields and exceedances of 16 KiB. Names are
trimmed, 1–100 characters, at most 400 bytes and contain no control characters.

| Actions | Authority and extra fields |
| --- | --- |
| create | Verified signed-in actor; name, client-chosen fresh team ID |
| rename | Owner/admin; name |
| archive, unarchive, delete | Owner |
| invite | Owner/admin; email, role; only owner can offer admin |
| revoke_invitation | Owner/admin; invitation_id; only owner can revoke admin offers |
| accept_invitation, decline_invitation | Current verified recipient; invitation_id |
| change_role | Owner/admin; user_id, role; admin cannot manage admins/owner or appoint admins |
| remove_member | Owner/admin; user_id; same hierarchy restrictions |
| leave | Accepted member; owner must transfer first |
| transfer_offer | Owner; user_id of an accepted admin/member |
| transfer_accept | That accepted recipient; transfer_id |
| transfer_cancel | Owner |
| folder_create | Owner/admin; name |
| folder_rename | Owner/admin; folder_id, name |
| folder_remove | Owner/admin; folder_id |

Requests expire after 15 minutes, with one minute of future-clock tolerance.
Per-actor and per-team transaction locks serialize membership limits, revisions
and current permission decisions; invitation-email locks bound cross-team offers.
Sessions and request age are checked again after waiting. Same ID and exact body
retries return the original minimal result only with current permission; changed
bodies, stale revisions and removed authority cannot replay a mutation. Receipts
are pruned after a day on subsequent team writes. Deleted team IDs cannot be
recreated even after their receipt is gone. A removed/deleted account's receipts
are removed through its foreign key.

Limits: 20 live owned teams, 20 creations per UTC day, 100 memberships per account,
500 accepted members per team, 100 pending invitations per team and per recipient,
200 folders per team and 2,000 ordinary administration writes per UTC day.
Revocation, leave, deletion and ownership recovery remain possible at the write
limit or while enrollment is paused. Pausing is not a promise to reject already
in-flight operations. Archived teams permit recovery/removal and ownership transfer,
but ordinary edits/invitation acceptance require reopening.

The private configuration defaults to **disabled**. Do not enable it until the
project/task/API/email/storage authorization stage and native acceptance pass.
The private service rollout configuration and service credentials are not
embedded in either app.

## Verification and limits

From the repository root:

```
node Scripts/Database/test-team-organization.mjs docs/p2-team-foundation-evidence.json
```

Or run `npm run test:teams` inside `Scripts/Database`. This uses the existing pinned
PostgreSQL 17.6 disposable container, actual SQL grants and authenticated JWT
contexts, synthetic confirmed accounts and the actual account-removal migration.
It tests lifecycle, current roles, privacy, verified invitations, transfer,
account removal, malformed/stale/replayed requests, quota recovery and real
concurrent transactions. A waiting request loses authority after a competing role
change and rejects a session that expires while waiting. Two reviewed writes
produce exactly one mutation; two last-slot creations produce exactly one new
team. Fixture project/task definitions, existing public functions, grants and
storage policies are unchanged after loading the migration.

The official CLI advisors run read-only on the exact owned fixture over a
loopback-only ephemeral port. No new team warnings/errors are allowed. The minimal
bootstrap's existing `public.is_project_owner` mutable-search-path warning is
recorded separately; it is not a claim about the hosted schema. Containers and
ports are removed in `finally`, including on failure. Evidence is generated
independently in each repository, with the actual migration SHA-256.

The SQL was iterated directly on an owned PostgreSQL fixture without migration
history, then saved using the CLI-generated migration filename. A database pull
from this minimal fixture would incorrectly include synthetic Auth/bootstrap
objects, so it is not used to generate a managed baseline. No hosted migration,
provider, user account, app process or release setting is changed.

This is not full hosted HTTP/RLS acceptance or native team feature completion.
Before enabling: connect team projects and folder placement; define owner/admin/
member/guest task permissions across every direct and service write path; preserve
existing personal/project sharing behavior; cover account-removal export/restore,
audit and widget privacy; add the premium native team switcher, folders and
administration flows independently to both apps; run cross-client and native
acceptance. Existing release, remote-reminder, older-client rollout, OAuth,
physical-location and email-provider deferrals remain in effect.

The subsequent disabled content-custody layer is documented in
[TEAM_CONTENT_CUSTODY.md](TEAM_CONTENT_CUSTODY.md). It preserves team work after
creator removal, retains personal deletion semantics and closes legacy team-data
shortcuts. It does not enable team access or complete the next permission/UI gates.
