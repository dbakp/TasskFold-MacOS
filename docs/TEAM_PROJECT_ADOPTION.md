# Personal projects into a team

Status: the ownership boundary, reviewed service, private native command/recovery
and native Mac/iPhone/iPad flow are implemented in source. Core checks and isolated
Debug app builds pass. Initial iPhone/iPad installed acceptance now covers transfer,
cancellation, stale local review and exact private recovery after relaunch, expiry
and simulated destination loss. Mac installed acceptance, broader layout, keyboard,
VoiceOver, account/window and hosted acceptance remain open. Provider custody and integration pause adapters
remain open; affected transfers are explicitly rejected atomically. No rollout or
hosted configuration was enabled.

## Intended experience

The personal project owner selects one or more project branches and a team in
which they can create projects. Every descendant belongs to the transfer. The
review lists all affected projects, including archived projects and completed
work, and shows task, section, discussion and attachment totals.

The owner chooses team-visible or private access, an optional team folder and an
optional parent project they can manage. Existing child relationships and each
project's own archive flag remain intact. Selected roots detach from their old
personal parents; inherited archive state follows the reviewed destination.

Every accepted collaborator needs an explicit retain-as-editor, retain-as-viewer
or retire-personal-access decision. Retention requires eligible membership in the
destination team. Pending and declined personal invitations close; adoption sends
no invitations and creates no team memberships. Multiple accepted invitation rows
for one person/project must produce one consistent grant. The review shows the
**effective** resulting access: removing a personal grant does not remove access
that follows from team visibility or the person's owner/admin role.

Project IDs, task IDs, generations, creators, notes, dates, sections, checklist
identities, discussion/mention read history and eligible assignment provenance
remain intact. Only assignments whose resulting access is insufficient are
cleared, with their exact count in the review. Device credentials, private device
stores, preferences and private template definitions are outside this transfer.

Native attachments are currently inline data URLs; these can remain byte-exact.
External references retain their provider's access rules. Taskfold Storage-backed
references need an explicit custody review before adoption; they must not become
broken or silently remain owned by a departing personal account. Personal email/
webhook integrations need a reviewed pause or supported team destination; their
existing personal authorization must never become a team-writing shortcut.

Adoption changes custody to the team. Returning work to personal ownership is a
separate transfer, not an automatic local Undo. The confirmation must state this.

## Reviewed service protocol

Use separate inspect, review and adopt operations. Inspect captures a complete,
bounded source manifest and eligible collaborator options. Review accepts exact
identity-bound access decisions and returns the final contents/audience review.
Adopt requires its immutable proof, expiry and one durable request UUID. A lost
reply retries that identical request; it never becomes a new transfer.

Proofs must cover the exact selected roots and expanded branch, every relevant
record and monotonic row epoch, current ownership and access boundary, destination
placement/visibility/folder, participant eligibility and exact access decisions.
Mention read acknowledgements are excluded from authored-content comparisons and
are never reset. Display-name changes must not retarget a decision to another ID.

A practical initial bound is 100 explicit roots, 1,000 total projects, 10,000 tasks,
1,000 legacy collaborator rows, 100,000 total records and 32 MiB of source content. These are atomic
review limits, not permission to split a transfer into partial chunks. The Auth
participant cohort is bounded at 2,000 and the access-decision command at 256 KiB;
it does not inherit the ordinary team command's smaller 16 KiB envelope. Cross-
project repeat links must remain within the selected transfer or the destination
team. Additional personal branches require explicit selection and a fresh review;
no unrelated work is added automatically and no links are silently detached.

## Required commit sequence

1. Validate the live confirmed Auth session and source owner. Collect and lock the
   known source participants' Auth rows before team/content locks. Recheck the
   cohort later; a newly discovered participant requires a new review, not another
   late Auth lock. Use the established account-removal ordering.
2. Lock affected teams/access epochs in canonical order before changing bindings
   or grants. Avoid upgrading a workspace boundary's shared epoch locks after a
   second caller has acquired the same shared locks.
3. Expand and validate the owned personal forest. Use nonblocking `FOR NO KEY
   UPDATE NOWAIT` locks on its current projects and content rows, respecting the
   existing collaborator/task/comment ordering. Key-share foreign-key checks must
   remain compatible; a task writer must not wait on the project while adoption
   waits for that task.
4. Take `try_project_adoption_fences` for the selected project IDs. Re-read the
   complete row-ID set, content/epoch proof, hierarchy and participant cohort.
   Added or changed rows invalidate review. Do not take blocking locks on newly
   discovered rows after taking these fences.
5. Establish exact private adoption scopes for every project and planned parent.
   Keep eligible assignment history unchanged. Clear only reviewed ineligible
   assignments through the task guard while rows are still personal and original
   memberships still exist. Retire personal invitations under the exact scope so
   ordinary departure cleanup does not erase retained assignment history. Detach
   selected roots from external personal parents, admit immutable team custody,
   install reviewed effective grants and apply destination placement through the
   existing team hierarchy scopes.
6. Commit a durable identity-only receipt. Erase temporary authority rows. Deferred
   placement checks still verify the final project/binding state after those rows
   are erased. A failure anywhere rolls the entire transfer back.
7. The client confirms its private request receipt before refreshing the normal
   workspace/access boundary. Preserve queued or unsent drafts through existing
   recovery rather than projecting an old server reply over them. Require a clean
   originating editor/outbox for new adoption authoring. Keep retry/clear available
   through a discoverable account-bound recovery entry after relaunch.

## Implemented transaction boundary

`20261025011154_team_project_ownership_fences.sql` adds identity-only row epochs,
transaction-local realm tickets and exact private adoption-placement scopes.
Tickets use an unlogged private table because no ticket survives a committed
transaction. Authored epochs are durable and survive record deletion/recreation;
there is no project-wide counter that serializes unrelated task edits.

Before commit, a writer collects all of its affected project IDs and tries shared
ownership fences. It checks fresh immutable custody against the realm under which
it wrote. An adoption controller takes exclusive fences after locking the known
rows and before the final proof. Both sides use try-locks: the transition cannot
wait in a cycle while one side holds a row the other needs. An old insert/edit,
subproject or invitation cannot appear after a cutover under obsolete authority.
Unrelated projects continue writing.

Only the private binding writer can stamp this transaction's own deliberate realm
changes. A caller cannot stamp another transaction's tickets or fabricate an
adoption scope through JWT metadata or settings. Team custody remains immutable;
existing guarded team writes retain their established authorization paths.

The existing invitation cleanup trigger skips destructive assignment clearing
only for an exact private adoption scope. The controller computes and applies
every reviewed eligibility change before retiring the personal invitations.
The private scope is never a direct client capability.

Local evidence is recorded in `p2-project-adoption-fences-evidence.json`. Owned
fixtures include the inspected invitation/assignment-cleanup definitions and the
actual assignment-provenance migration. Existing task-move, batch-deletion and
project-hierarchy suites can explicitly load this layer for regression checks.

The remaining API/native/hosted, storage, integration, keyboard and accessibility
acceptance stays open. This cutover-specific guard does not complete rank 6 or
reopen the user's deferred general older-client, distribution, remote-delivery,
OAuth/provider or physical-location work.


## Implemented service and remaining acceptance

`public.taskfold_team_project_adoption(operation, body)` supports `inspect`,
`review`, and `adopt` under a current confirmed native Auth session. Inspect takes
`team_id`, `roots`, `visibility`, `folder_id` and `parent_id`. Review adds the exact
`inspection_token` and one `{project_id, user_id, role}` decision for each distinct
accepted collaborator. `role` is editor, viewer or JSON null for retiring the
personal grant. Duplicate accepted invitations share one decision; pending,
declined and accountless rows are retired without inventing membership.

The result identifies every selected descendant, including own/source inherited
archive state, counts all task/section/discussion/history/provenance records and
root/nested attachments, and reports the resulting effective access and exact
assignment clears. Display names and invitation addresses are presentation only;
all decisions bind UUIDs. Task bodies, attachment bytes, provider URLs and webhook
credentials never appear in review or receipt payloads. Complete record hashes,
monotonic row epochs, destination ancestors, access epoch and live membership
eligibility bind the inspection proof. Mention read/revision changes are excluded
from authored-content comparisons and never rewritten.

Adopt adds `review_token`, `expires_at` and a durable `request_id` to the exact
review input. A 15-minute HMAC proof is revalidated while holding Auth participants,
the team/access epoch, nonblocking source row locks and exclusive ownership
fences. Source changes require a fresh review. It checks the established 1,000
team-project limit and 2,000 daily administration-operation limit. Exact temporary
adoption/hierarchy scopes apply placement and custody; deferred placement checks
remain authoritative after those scopes are erased. Returning to personal custody
is a separate future operation, not automatic Undo.

Identity-only receipts retain a fingerprint, account/team/request and selected
project/root/placement IDs and counts. The identical request can confirm after
expiry, access loss, disabled rollout or subsequent task moves without changing
later work. Reusing the UUID for another command/account is rejected. Recovery
still requires a live confirmed session. Receipts are not returned as workspace
content and must not be used by clients to overwrite queued drafts or later edits.

`native_project_adoption_enabled` defaults false. Normal team read/edit gates must
also be enabled; no source or hosted rollout was enabled. Inline attachments and
external references remain byte-exact. Provider-backed/unknown attachment metadata,
including rich checklist attachment arrays, and non-revoked personal email or
matching project/global webhook bindings explicitly require the still-unfinished
custody/pause adapters. Such commits fail with no partial transfer. Do not treat
this boundary as completion of the requested integration support. In particular,
pausing a global personal webhook would affect unrelated projects and must never
be done implicitly.

Personal service access rechecks team custody after acquiring its project lock.
Personal webhook capture excludes team projects/tasks and exact in-progress
adoption scopes, including subscriptions created after adoption. Unrelated
personal capture retains its existing behavior; no dispatcher/network/provider
is enabled. Read-committed isolation is required for transfer operations and the
personal-write commit ownership validator: a repeatable snapshot cannot see a
newer custody row and cannot serve as fresh authority.

The owned service fixture now loads the actual email/domain and webhook/outbox
migrations, not synthetic replacement provider tables. It also loads the actual
hierarchy/assignment/guarded task-move routines, plus documented minimal dependency
snapshots. This proves the tested local SQL paths, not full hosted behavior or
provider delivery. Evidence is in `p2-project-adoption-service-evidence.json`.

Next: installed native flow/keyboard/spoken/layout/account/window acceptance,
file custody and explicit personal-integration pause/retarget adapters, then
hosted acceptance. The native command and screens below are implemented in source;
build/Core evidence does not replace those runtime checks. The wider Px plan and every user-deferred external/release item
remain open.


## Native review and private recovery

Both apps own `Core/TeamProjectAdoption.swift` and
`Views/TeamProjectAdoptionView.swift`. Team project lists expose “Bring personal
projects…” only under the existing native team rollout gate. The flow defaults
to private visibility, lets the owner select project branches and a team folder/
parent, lists every affected descendant and content total, requires explicit
accepted-collaborator choices, and shows effective access and assignment/invitation
counts before confirmation. Destination and custody/Undo consequences are visible
on the final review. Files and personal integrations needing unfinished adapters
show their review requirements and disable confirmation.

New authoring rechecks a frozen local access/content stamp, owner-only personal
custody, an empty outbox, no unresolved sync conflicts and closed task editors for
the affected projects. Reviews invalidate across source/access changes and app
inactivity. The server remains the final content/access authority; client stamps
never replace its full proof. Late personal saves retain the service cutover guard.

The durable command contains account/origin, UUIDs, role choices, proof/expiry,
request ID and expected receipt IDs/counts. It stores no project names, task text,
invitation addresses, file bytes or provider credentials. A validated Keychain
journal uses account/process locks, cancellation leases and the account-removal
fence. Adoption permits a 300 KB envelope for up to 1,000 decisions; other reviewed
team commands keep their existing 20 KB default. Unreadable recovery blocks fresh
authoring and is kept intact.

Sending persists before network I/O. Retry reloads and sends the identical command,
including after expiry; it never creates a replacement UUID. Replies must match
the complete reviewed forest and all identity/placement/count fields. Account/
workspace/session changes, close/cancel, foreign replies and failed private cleanup
leave recovery available. Explicit clearing only removes the device retry; it does
not cancel or Undo server work. Account-level “Saved project transfer” remains
reachable independently of team membership and the ordinary team navigation flag.
Closing that sheet rechecks the journal rather than hiding an unresolved retry.

Backend inspect/review/adopt calls use the actual `operation`/`body` RPC arguments,
current account/session fencing, no cached responses/cookies, refused redirects,
a streamed 3 MB response cap and redacted errors. Accepted receipts certify custody
only. The app invokes ordinary workspace/access refresh and its existing draft/
Recovery path, never applies old task contents from a receipt. It reports refresh
as incomplete while queued/conflicting work remains; absent/inaccessible projects
are permitted after a fresh boundary instead of causing an endless refresh loop.
Success receives an explicit VoiceOver focus target, and the existing access
Recovery controls remain available when drafts are preserved.

`export-project-adoption-contract.mjs` independently generates each repo's synthetic
Swift fixture from the actual local inspect/review/adopt service and removes its
owned database container. Core tests parse those SQL responses and exercise lost
replies, relaunch, duplicate windows, foreign account/origin, cleanup failures,
lease/close/account-removal fences, unreadable recovery, the 1,000-decision journal
and actual mocked HTTP transport. Core checks and app compilation are recorded in
`p2-project-adoption-native-evidence.json`. No installed UI/spoken/layout or live
Keychain/provider/hosted behavior is claimed by that evidence.


## Installed acceptance still required

The following are open runtime gates, not completed by the Core/build evidence:

1. Use a reserved, network-isolated host backed by the synthetic SQL contract.
   Open the team project list and choose an archived personal root as well as an
   active branch. Confirm all descendants/completed work appear; an inherited
   archive clears at an active destination while explicit child archive remains.
2. Require every accepted collaborator decision, including duplicate invitation
   rows sharing one person/project decision. Verify guest/viewer/editor/retired
   choices and effective admin/team-visible access; show exact assignment and
   closed-invitation counts and the final team/folder/parent/visibility.
3. Change source content/access or open an affected editor during review. Confirm
   authoring stops without losing drafts; missing/corrupt private recovery must
   block a fresh request, and unsupported files/integrations must stay blocked.
4. Drop an already-applied reply, quit and relaunch, then retry the exact UUID.
   Repeat after review expiry and destination-access loss. The account recovery
   entry must remain reachable with ordinary team navigation disabled. Closing
   it must not hide the unresolved retry. Reviewed clearing sends no Undo/cancel.
5. Change account/session/workspace or close a window while storage/network I/O is
   paused. Resume and verify no callback clears another context's journal or
   changes its navigation. Competing windows must preserve the existing request.
6. Refresh after confirmation while a late local edit/conflict exists. Verify
   ordinary access masking, widget publication, encrypted Recovery and queued
   draft preservation; no receipt task projection or false fresh-workspace claim.
   An absent/inaccessible project after a fresh read must not cause endless retry.
7. Check iPhone and iPad sizes, Mac resizing, large Dynamic Type, dark mode and
   increased contrast. All destination/count/access/expiry/blocker text must be
   readable. Exercise keyboard selection, Cancel/Back/confirmation and VoiceOver
   success focus, plus the existing draft Recovery controls.
8. Verify genuine private Keychain persistence/cleanup, including a large bounded
   decision command. Core memory-I/O capacity checks do not prove this OS path.
   Leave signing/distribution and physical-device/provider dependencies deferred.

Prefer automated Simulator/native controls and authoritative saved-state checks.
Only request a human observation for a system/spoken behavior that automation
cannot inspect, after preparing a short concrete test. Broader hosted/provider
acceptance and the wider Px plan remain open.


## 2026-10-25 installed acceptance follow-up

The reserved DEBUG host now bundles the actual independently exported SQL contract,
including an archived owned root, an explicitly archived descendant, completed work,
an outside assignment and a transferring owner who is an ordinary destination team
member. Its ephemeral HTTP session intercepts every request; no real endpoint,
account, provider or task is used. Normal Store sync and real OS private storage
are exercised; receipt task projection is not used. The peer honors activity
sequence ordering and ordinary row pagination, and records only synthetic state.

The initial iPhone and iPad checks cover contents/access review and commit; preserved task
text/completion, assignment clearing and an empty queue after ordinary refresh;
cancel without custody/cache changes; source-edit invalidation before sending; and
an already-applied lost reply followed by quit/relaunch, Close/reopen and exact
request replay. A further check lets the real review expiry pass and simulates
removed destination access before relaunch/retry. The same request confirms once,
while ordinary refresh removes inaccessible cached projects/tasks. This is a
SQL-contract-derived simulated peer, not live hosted adoption or an Auth membership
change. Local SQL protocol checks remain separate evidence.

The relaunch check found that an empty SwiftUI Group could prevent the recovery
entry's loading task from running. Both apps now keep a stable Account entry named
Project transfers, changing to Saved project transfer when private recovery exists.
It remains reachable when normal team navigation is unavailable. Empty recovery
still has a safe explanatory screen; closing an unresolved request keeps it saved.

Simulator Keychain access requires Xcode's local Simulator signing and generated
simulated entitlements. Unsigned and manually invented-entitlement diagnostic
launches were not accepted as OS storage evidence. This does not configure or
verify release signing. The isolated Mac Debug build passes, but no new installed
Mac, physical-Keychain-capacity, multi-window/account, keyboard/spoken, large-text,
dark/contrast or provider/hosted acceptance is claimed in this follow-up.

See `p2-project-adoption-installed-evidence.json` for exact runs and limitations.
The normal rollout switches remain disabled. File custody and personal integration
pause/retarget adapters, the remaining adoption acceptance and wider Px work stay
open; all user-deferred release/provider/device dependencies remain deferred.
