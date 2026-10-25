# Personal projects into a team

Status: ownership-cutover primitives and the source-only inspect/review/adopt
service are implemented and tested locally. The private client command/recovery
and native screens are still required. Provider custody and integration pause
adapters remain open; affected transfers are explicitly rejected atomically.
Nothing in this milestone enables rollout or changes a hosted database.

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

Next: private native command persistence, exact retry/clear after relaunch,
normal workspace refresh with unsent-draft recovery, premium review screens,
file custody and explicit personal-integration pause/retarget adapters. Native
Mac/iPhone/iPad, keyboard/spoken/layout/account/window and hosted acceptance are
still required. The wider Px plan and every user-deferred external/release item
remain open.
