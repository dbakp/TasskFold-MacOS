# Team organization foundation

Status: disabled, local verification only (24 October 2026). A gated read-only
native overview now exists in each app; no deployment or project access change
is included. Each app repository owns its sources, migration and tests; neither
app builds against the other repository.

## Native overview

`TeamOrganizationView` previews active/archived teams, your organization role,
folders, incoming invitations, and ownership offers. Owner/admin detail includes
the role directory and pending invitation emails; member and guest responses
must omit that private directory, and guests must also omit folders. Names are
not invented from account identifiers. This is an overview: creation, invitation
responses, role changes, folder editing and ownership actions are still pending.
There are no mutation calls or new email sends in this milestone.

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
There is no client configuration or service credential embedded in either app.

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
