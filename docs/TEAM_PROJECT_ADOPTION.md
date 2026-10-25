# Personal projects into a team

Status: ownership-cutover primitives are implemented and tested locally. The
reviewed adoption API, client command and native screens are still required.
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

## Reviewed service protocol still to implement

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
1,000 legacy collaborator rows and a bounded total contents size. These are atomic
review limits, not permission to split a transfer into partial chunks. Cross-
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
   Retire personal collaboration rows under those scopes, create immutable team
   custody/bindings and effective grants, and apply reviewed placement through the
   existing team hierarchy scopes. Keep eligible assignment history unchanged;
   scope the necessary ineligible assignment clears through the native task guard.
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
only for an exact private adoption scope. The future controller must still compute
and apply every reviewed eligibility change. This exemption is not an exposed
transfer API and is not a reason to omit collaborator retirement.

Local evidence is recorded in `p2-project-adoption-fences-evidence.json`. Owned
fixtures include the inspected invitation/assignment-cleanup definitions and the
actual assignment-provenance migration. Existing task-move, batch-deletion and
project-hierarchy suites can explicitly load this layer for regression checks.

The remaining API/native/hosted, storage, integration, keyboard and accessibility
acceptance stays open. This cutover-specific guard does not complete rank 6 or
reopen the user's deferred general older-client, distribution, remote-delivery,
OAuth/provider or physical-location work.
