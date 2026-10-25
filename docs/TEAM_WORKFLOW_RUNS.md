# Shared workflow runs

The intended experience is an explicit destination and audience choice, a complete
workflow preview, then one Create action. Cancel creates nothing. A successful
run creates the full selected workflow together and leaves the reusable source
and existing runs unchanged.

## Implemented foundation

`TeamWorkflowRunPlan` freezes the source, destination, workspace/session and new
content. Personal sources must belong to the opening account; shared sources
keep their full catalog scope and revision. Task/section templates target an
existing scoped project. Project templates create a new team hierarchy with
explicit visibility. Dates, order and portable label names are retained, and
history/assignment/attachments are excluded as in personal template runs. Root
and checklist identities are fresh per run and stable for the same frozen run.
Content cannot be submitted by this value: it exposes no personal-writer mutation
or transport call. Its role checks are preview admission, not server authority.

## Implemented atomic service (source only)

`public.taskfold_team_workflow_run(_body jsonb)` is guarded by the existing team
and native-project gates plus a new default-off private workflow-run gate. It
accepts frozen reviewed rows, not executable template documents. A supported v1
source is verified as provenance and for stale-review detection; it grants no
permission in the destination. Private sources require ownership; shared sources
require current full membership and exact document/revision. All task/project
writes use existing private controllers inside the same transaction. Checked
section/hierarchy writes hold a private transaction scope; direct grants remain
closed. Auth/session locks precede sorted source/destination team locks.

The envelope contains team_id, request_id, team_revision, source, destination,
projects, sections, tasks and orders. Source includes kind, id, nullable team_id/
revision and document. Destination includes mode, nullable project_id/revision,
visibility, folder_id and parent_id/parent_revision. New project rows form one
parent-first branch; task/section templates append into an existing editable
project. Orders include project_id, nullable section_id, exact base_ids and the
new task_ids in reviewed order. Old order is compared under lock and in the
conditional upsert, including an initially missing order row.

Fresh identities are checked before nested-controller calls, so a separately
created task/project or its old receipt cannot become a new full workflow run.
The private receipt holds a HMAC and identity metadata, not workflow text. Exact
replay rechecks current rights, then acknowledges the original result without
reapplying content or order. A late failure rolls back the whole branch, nested
receipts, quota and order together. Runs have bounded source/row/envelope sizes
and count against the existing team daily operation quota (up to 2,000 changed
projects/sections/tasks in one admitted run).

The Swift plan now freezes folder/parent and complete existing actor order into
the same request shape. Shared checklist children use the established checklist
wire fields and fresh tokens. Repeating checklist definitions are preserved but
refused for shared use until that shared format supports their repeat semantics.
This is a compatibility refusal, not silent removal of the rule.

93 isolated SQL checks pass independently in each repo, including the actual
Swift-generated workflow envelope. Both Core suites pass 105 cases; both app
Debug builds compile. These are local synthetic tests, not hosted HTTP or native
save acceptance. No hosted migration/configuration or rollout changed.

## Implemented durable client layer (source)

`TeamWorkflowRunCommand` validates and freezes the complete plan/order envelope.
Its decoder rejects unsupported or partial recovery; receipts must match the
exact account, team, request, complete project/section identities and every task's
identity, generation and project. The bounded HTTP method checks backend origin
and account/session before publishing a reply, refuses redirects, disables
cookies/cache storage and caps the streamed reply at 1 MB. Server messages are
sanitized; authorization failures request sign-in instead of exposing raw text.

`TeamWorkflowRunModel` saves before sending, retains unknown outcomes, and retries
only the identical saved command. Disk clear is conditional on the original
request. Account/window invalidation cancels the lease and drops presentation
without dropping recovery. Stop retrying clears local retry intent, not cloud
work. The new encrypted file lives under the account's backup directory, is
excluded from backup, uses the existing backup key and removal/process locks,
and has a separate filename/prefix/AAD from template-curation requests. The
common file engine preserves the legacy template format byte-for-byte; tests
open ciphertext sealed with the previous literal AAD. Store factory and account
removal hooks compile in both apps.

137 focused Core cases pass independently in each repo, including lost reply,
relaunch, another window's request, invalid receipts, failed cleanup, access
checks before/after save, removal fences, unreadable recovery, legacy ciphertext,
actual intercepted HTTP and a real Backend sign-out during its reply. Both app
builds compile. No native recovery/save UI or physical Keychain acceptance is
claimed yet; no hosted request, schema/configuration or rollout changed.



## Implemented native review and recovery

Both apps independently own the destination/content/recovery screen. Shared and
private templates enter the same explicit review: team and editable project, or
new project audience/folder/parent, optional start date, complete generated
projects/sections/tasks/checklists, notes, labels, dates and recurrence. Creation
requires acknowledgement of the contents and audience. A fresh source, coherent
paginated destination catalog and current actor order are checked again before
the immutable request is saved and sent. A changed source/access/order refuses
that send and requires another review. No shared work enters the private writer.

Account/session/workspace and inactive-scene changes mask the review. Saved
requests have a separate entry in Account and remain recoverable without new
shared-authoring admission. Retry confirms the original request; Stop retrying
explains that already-created cloud work is retained. Successful confirmation
asks Store to sync. Actual hosted Store refresh and Mac runtime/spoken/account-
window acceptance remain open; the local native peer does not prove them.

Fresh private-source and actor-order reads use filtered REST requests with
no-store, cookies disabled, redirect refusal, bounded streaming and current
account/session checks. Destination reads publish only complete, coherent pages;
unknown archive/hierarchy/name metadata cannot become a selectable destination.
See p2-team-workflow-run-native-evidence.json for final verification scope.
Rank 6 and wider Px remain open. No hosted schema/configuration or rollout changed.

## Remaining acceptance

Retain the isolated SQL suite and finish genuine hosted Store refresh, Mac
runtime, spoken/account/window and wider hierarchy/order/date/checklist native
acceptance. Local native peer creation/retry proves screen and durable-request
behavior; it is not remote SQL/RLS acceptance. Keep rollout disabled. Release,
provider and physical-device deferrals and the wider backlog remain in P2_PLAN.md.


Verification: each independent Core suite passes 146 cases (including nine fresh
read/catalog tests); both final own arm64 Debug app builds compile. Four native
scenarios pass on each signed iPhone/iPad Simulator host. After adding the
online/sync-idle/no-pending-edit authoring guard, the complete creation/lost-reply/
termination/relaunch/Account-entry/exact-retry scenario passes again on each
device. Recovery remains available while new authoring is paused. The original
request is unchanged, with one synthetic receipt and two service calls. Source
and final installed binary/signature parity are recorded. Light-mode review,
warning, recovery and confirmation screenshots were inspected. This does not
prove genuine cloud Store sync, Mac runtime, spoken output or hosted permissions.

The first native attempt found a hidden recovery entry that never started its
disk check. Keeping it mounted fixes the workflow entry and the equivalent
template entry. Test corrections handle nested confirmation-button wrappers and
iPad lazy Form rows. Earlier failed/aborted attempts remain in the evidence.
No rollout flag, hosted data/schema/configuration or real task changed.


### 2026-10-25 — Branch locations and prepared Mac workflow acceptance

Shared-workflow reviews now show full generated project paths on task rows,
new-section rows (including empty sections), and parent captions on subprojects.
An existing selected parent is included for a newly created branch. This makes
similarly named subprojects/sections distinguishable before Create. Path walking
is cycle-bounded and reuses one project lookup per rendering pass. The request,
source, audience and creation/recovery contracts are unchanged.

The Mac repository now owns four native cases using its exact reserved sandbox
and synthetic HTTP peer: review/Back with no request, changed-source refusal,
private-template creation, and lost-reply/relaunch/Account-entry exact retry.
They compile in a consistently Apple Development-signed app. The first runner
attempt failed before Taskfold launch because macOS reported system authentication
in progress; computer use independently reported the Mac locked. No scenario
passed or actual Mac Keychain recovery is claimed by that attempt. The ready
isolated build is retained for the requested manual unlock; no test app is left
running. The iOS native results in the preceding stage remain scoped to that
stage, not this new project-path visual change.

See p2-team-workflow-branch-review-evidence.json for current compile/test scope.
Mac runtime, spoken/account/window and genuine hosted acceptance remain open;
rank 6, wider Px and all user-deferred work remain unchanged. No cloud/rollout
configuration or real task was changed.
