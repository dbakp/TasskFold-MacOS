# Reviewed history custody

26 October 2026. Prepared `20261026122805_reviewed_history_custody.sql` closes the forward-path
history-only/deleted-root retention gap identified by the preceding transfer-review
milestone. It covers parent and child metadata equally. This is locally verified
service behavior, not a hosted deployment, native UI pass or completed Px goal.

## Ownership and visibility

A private, RLS-enabled registry records `(feed, event UUID, team UUID)` and the
exact selected project references justified by an actual transfer review. The
feed is part of identity: matching UUIDs in the two independent ledgers do not
share authority. It contains UUIDs and the binding time, never task titles, notes,
file contents, credentials or event state bodies. Clients and the service role
receive no table privileges and cannot call the registration routine.

The existing adoption commit registers only the rows covered by its bounded,
fresh review and exact private transaction scope. Current roots and before/after
project references use the same selection as the reviewed counts/fingerprints.
The registry does not add root-task custody, change a task's owner/generation,
move a live task, replay an event or create a new public API.

Custodied events require a live authenticated session and permission for
**every nonempty before/after project state**. Each team state uses the current
native-read flag, project role and team lifetime; each personal project uses its
current access rules. Private Inbox states remain limited to their actual owner.
A team read also requires an active owning team and readable bound project. The
original author can retain an independently personal context, but cannot bypass
checks on a team or missing/deleted project state. A member can read a deleted root's past project events
without seeing a different personal/current project. A cross-project event stays
hidden until the caller has current permission for both contexts. Missing/deleted
project contexts keep it hidden, including from a remaining joint owner.

The existing wire rows, IDs, sequence spaces, kinds, dates, types, paths and work
bits remain unchanged. Removing the author retains reviewed history and stable
creator UUIDs; the existing Auth actor foreign key makes the actor unknown. Other
personal history is removed. Author removal here is the real Auth-table delete
and existing cleanup trigger, not an HTTP/native account-removal walkthrough.

## Shared ownership and deletion

Separate reviewed project transfers can give an old event joint custody. This is
necessary when its live root moved to another personal project before either
project was transferred. Each registration is fingerprinted, so a custody change
invalidates another pending review even when the source event bytes are unchanged.
Registry metadata has its own 100,000-link bound and participates in the existing
32 MiB contents budget; no private ownership map is returned to the client.

Deleting a team physically removes its exclusive history. If another active team
also reviewed the same event, that team retains the immutable common record.
Deleting the last owning team removes it unless the still-active author retains
an independently personal project/Inbox context. That personal counterpart stays
until its own author is removed; deleted team metadata remains inaccessible.
A surviving team cannot read the deleted
project's before/after state: current scope checks still apply to the entire row.
This intentionally preserves joint audit metadata privately instead of rewriting
it into fabricated creation/completion events. Shared retention is not a claim
that all jointly owned rows are physically erased by the first team's deletion.
UUID-only custody tombstones remain, matching existing task-custody practice.

Team deletion NOWAIT-locks the candidate parent and child rows before cleanup.
A concurrent transfer holding those rows returns a retryable PT409; cleanup does
not wait on an old snapshot that missed a newly committed ownership binding.
The actual held-transaction test confirms the collision and unchanged source
history. The existing storage-removal guard remains first, and a later failure
rolls back history bindings, project placement and event state atomically.

## Upgrade and verification

Apply transactionally through the normal migration path. A NOWAIT exclusive
lock on the private adoption-scope table first refuses an in-flight old transfer
without acquiring source locks. A versioned private scope trigger then rejects
an old controller that resumes after the upgrade. The new controller explicitly
supplies version 1. Source locks follow Auth, tasks, then parent/child ledgers to
drain old cleanup/recording writers. An actual held old adoption proves safe
refusal without a partial registry; a stale scope insert returns PT409. No hosted
lock-duration/full-chain claim is made. Existing rows are preserved, and there is
no unreviewed backfill of previously adopted orphan events. Both guaranteed
recording epochs advance conservatively because old cleanup could already have
lost unbound history. Earlier observed rows remain available; no past event is
invented and no earlier interval is certified as complete.

The inspection advertises `history_custody_protocol: 1`; the additional private
hash invalidates pre-upgrade approvals. Existing applied receipts and client
command shapes are preserved. Existing public-invoker/private-review execution
ACLs remain intact. Four replaced routine bodies are checked against their
inspected originals after stripping only intended custody/locking additions.

Each repo passes 88 real-PostgreSQL custody checks and 55 existing connection-pause
checks with the new migration loaded. Coverage includes upgrade preservation,
pre-upgrade approvals, exact-scope registration, cross-feed UUID collision, late
cutover rollback, applied receipt retry, joint-custody proof invalidation, actual
SQL RLS reads, permissions/session/rollout removal, author cleanup, private Inbox
exclusion, held-transfer/deletion concurrency, storage-guard rollback, exclusive
and final joint-team deletion, personal counterparts, prior Inbox archives and
cleanup after the last personal owner leaves, closed helper/table authority and official advisors.
Only seven existing fixture init-plan warnings remain; no new-object findings.
All owned database containers are removed. Storage coverage uses synthetic
metadata only, without uploading bytes or contacting a storage provider.

Both owned clients pass 258 focused Core checks, including a new actual-SQL
post-author-removal fixture. Parent/child records decode, preserve unknown actors,
archive without replay and cannot supply a route to a missing current task.
Production Swift, UI and ledger wire formats are unchanged in this milestone;
no new app build, installation, screen, VoiceOver or widget-host pass is claimed.
The prior prepared Mac host/build remains intact. No real work or credentials
were read, no hosted flag changed, and normal heading authoring stays disabled.

Evidence, source hashes and cleanup notes are under `reviewed-history-custody/`.
Reproduce from this independent repo:

```sh
node Scripts/Database/test-reviewed-history-custody.mjs --report /tmp/custody.json
TASKFOLD_TEST_NODE_ADOPTION=1 TASKFOLD_TEST_HISTORY_CUSTODY=1 node Scripts/Database/test-project-adoption-connection-policy.mjs /tmp/connections.json
swift test --filter 'TaskNodeActivityTests|TaskActivityTests|TaskRootActivityContextTests|TeamWorkspaceTests|TeamProjectAdoptionTests|BackupTests'
```

The [current RLS documentation](https://supabase.com/docs/guides/database/postgres/row-level-security)
and changelog were reviewed. Privileged reads stay in private, fixed-search-path
helpers; policies use actual row fields and fresh service authority.

## Next work

Combine immutable parent/child events for activity, Insights and Project pulse,
with separate sequence spaces, stable generations/keys, productive-work rules,
partial coverage and current-task routes. Then connect the UI and widgets and
verify real client/account transitions. Broader calendar periods, heading
creation/conversion/race/spoken/largest-text work, installed widgets and shared
cross-device/provider acceptance remain open. Retrospective repair of any already
adopted orphan history requires a separate reviewed flow; this forward migration
does not silently assign it. Full hosted-chain/HTTP/native acceptance remains open.
All user-deferred provider/release gates remain deferred. The Px goal stays active.
