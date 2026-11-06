# Team completion outcome review

Implemented 24 October 2026, rank 6 still in progress. Both independent native apps
now have a dedicated completion review route. Native team editing remains disabled;
this stage is not hosted deployment or native runtime acceptance.

## What the review can do

A failed completion or a receipt that cannot be acknowledged triggers a bounded,
account-bound read of its outcome. The review compares the saved action with the
current original task and next occurrence. It can acknowledge a confirmed server
result without executing another completion, provided the existing native queue
can safely install it. Later unrelated edits and supported queued task changes are
replayed. No earlier mutation is bypassed.

An observation without a receipt is explicitly **unrecorded**, not cancelled. A
concurrent request might still be in flight. The review allows checking again or
retrying the exact original action, clock, generation and nonce. It cannot discard
a command based on an absent receipt. If another server generation would displace
an edited provisional task, Continue is unavailable and all authored work remains
saved for the remaining dedicated draft-reconciliation flow. Read-only members may
acknowledge their own recorded outcome but cannot retry a write.

The grouped native sheet follows the existing review style, with selectable task
text, clear status, date and note summaries, a persistent action area, named
controls and Later. Refresh failure removes the stale review content; account or
workspace changes dismiss it. Review state is ephemeral and bound to the exact
queued command, current workspace and displayed observation.

## Read contract and privacy

`taskfold_review_team_completion` accepts the original closed command body and
operation. It never writes tasks, reserves a nonce, creates an occurrence or
cancels an action. It serializes with the original command's nonce lock and checks
live verified identity/session, team state, read configuration and current project
access before inspecting receipts. It remains readable when task editing is
paused or the project is archived; all read access still applies.

A recorded outcome must match the original actor, full HMAC payload, operation,
source generation and shared nonce namespace. Other actors and altered payloads
cannot inspect that receipt. The current source, series and successor rows are
read in one statement snapshot. Source and series replacements are not returned
under their old generation. An accepted successor is restricted to its recorded
generation. The series parent has a separate current-role/project-custody check,
so an inaccessible parent is omitted while an authorized child remains readable.

Private and public RPC functions have an empty search path and authenticated-only
grants; anonymous/service-role access is revoked. No new table or public write
policy is added. Responses are capped at 1 MB, requests at 128 KB. Native requests
avoid cookies/cache and reject redirects; native parsing checks all frozen
identities, row generations and consistency with the established replay receipt.

## Verification and remaining work

Each repo passes 67 disposable review database checks and 131 completion regression
checks against the new migration, including actual lock waits, concurrent command
commit, permission loss during a wait, revoked sessions, read/edit pauses,
archiving, private parents, replacement generations, changed payloads and existing
nonce collisions. Advisors report no new warnings/errors against fixture baseline.
Each app passes 271 selected Swift tests, including nine new outcome-review tests,
and unsigned Debug app/extension builds. Golden review fixtures come from each
repo's own SQL run. Owned containers and temporary builds are removed.

Still required: cancellation/rebase certificates for rejected actions, explicit
preservation/reconciliation of conflicting provisional drafts, team workspace
refresh/cache privacy, remaining collaboration adapters, and enabled team UI with
full native runtime/visual/accessibility acceptance. No generic overwrite/discard
is offered as a substitute. Wider Px work and the user's release/provider/hardware
deferrals retain their original scope.

Follow-up: TEAM_COMPLETION_CANCELLATION.md adds durable cancellation for untouched
projections. Explicit rebasing and reconciliation of authored dependent drafts
remain in progress. The verification counts above describe the outcome-read stage.
