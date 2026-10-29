# Saved subtask conflict review and terminal resolution

29 October 2026. This is a disabled implementation under acceptance. The generated
server migration passes 35 isolated database checks independently in each repo,
with no added advisor findings. Native acceptance is recorded below.
No hosted schema, normal read/write flag, rollout or release setting changed.

## Client implementation

- Compare a saved field intent with a fresh, strictly verified own-node read.
  Account/origin/root generation/project/incarnation mismatches refuse review.
  Current values are the default; differing saved choices require explicit selection.
  Related planning changes remain one choice to avoid mixing dates and exact instants.
- Close the original request before saving a replacement. Closing does not edit
  a task or undo an applied edit. An applied result recovers its original receipt;
  a closed result must be durable before a fresh request identity can be saved.
- Unknown close replies remain attempted. Retrying uses the original command and
  identity; disk failures and account departure cannot expose a fabricated closure.
  Recovery keeps a closed original proof and queues a separate replacement, without
  coalescing another window's saved intent. Send remains a separate review action.
- Present current/saved values without raw reminder JSON or private coordinates.
  Shared labels do not use the personal catalog. A changed workspace/read hides
  stale choices; reopening the saved-request screen rereads its journal.

Known local reminder choices remain reviewable, but changed opaque/private/other-channel rows and unknown nested extensions cannot be overwritten by a saved whole-array change. The Core backstop refuses that choice and the UI explains why; other fields remain reviewable. Unsupported current labels are likewise protected. Assignee names use the existing account/project-scoped resolver, with explicit unavailable-name text.

## Server implementation and verification

`../../supabase/migrations/20261029194600_child_task_field_resolution.sql` stores
an account/request fingerprint tombstone, serialized with the existing edit actor
lock. Closing returns a closed acknowledgement or the existing applied receipt.
It works after task deletion/access loss and with the edit gate off, without
granting task reads or writes. Preparation/finalization refuse closed identities.
Records do not expire back into executable requests; account deletion cascades
metadata. The CLI generated the migration name; both repos own the identical SQL.

`database-verified.json` records 35 passing direct PostgreSQL checks per repository:
both actual lock race orderings, identity/hash reuse refusal, wrong-account/session
refusal, lost replies, after-deletion recovery, quota/retry, explicit privileges,
RLS, fixed search path and no added advisor findings. Each owned fixture was removed.
Seven pre-existing fixture/schema advisor findings remain unchanged. No hosted
schema or flags changed. The existing child-edit regression runs the new migration
as an overlay using `--with-resolution`; all 95 checks pass per repository, including no added advisor findings and owned-container cleanup. `edit-regression-verified.json` records the results.

Earlier attempts were blocked by Docker and disk exhaustion; the first executing
permission probe needed a JSON cast in the test query. Storage recovery and the
20 GiB test preflight are documented in `../storage-recovery-20261029.json`.
Canonical final runs supersede preflight failures as database acceptance evidence.

## Verification scope

Each independent repo passes 228 focused client cases: 83 child command cases
(including thirteen new resolution/comparison cases), 21 strict child reads, 55 account
transport and 69 backup cases. Both full app/test builds pass. Existing unrelated
compiler warnings remain in the archived logs. Native results and exact source
bindings are recorded separately as they finish; synthetic HTTP acceptance cannot
establish hosted deployment or genuine credentials. Ordinary child flags remain off.

Genuine Keychain/team/account/window/hosted lifecycle, spoken acceptance, complete
conflict/lifecycle acceptance, completion/structure/legacy adapters and authoritative
child migration remain open. Existing user deferrals remain unchanged and the
full Px goal stays active.

Reproduce client checks from each owned repository with the matching scratch path:

```sh
swift test --scratch-path /tmp/taskfold-audio-recovery-core-mac --jobs 2 --filter 'ChildTaskFieldCommandTests|ChildTaskRecordReadTests|AccountTransportTests|BackupTests'
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-child-task-field-resolution.mjs /tmp/taskfold-child-resolution-database.json
node Scripts/Database/test-child-task-field-edits.mjs /tmp/taskfold-child-edit-regression.json --with-resolution
```

The database command uses only a disposable labelled local container. It does not
deploy a migration or modify a hosted project. Isolated migration acceptance
does not establish release or rollout readiness.

## Native pre-correction observations

Phone v1 passes three journeys with no reported runtime warnings. The final lost-
close case overlapped a host disk-full event; it will be repeated after cleanup.
Mac v1 selected zero tests and is rejected as runtime evidence. Mac v2 selects one
real test but fails to find the initial fixture button. Direct native computer use
with an explicit window-restoration launch argument opens the current fixture.

The direct Mac check verifies readable scrolling Plan controls and a saved notice,
then reveals a review defect: distinct requests display the first request's title,
while their comparison correctly shows their own saved value. The correction gives
each dynamic field row a request-plus-field identity and adds a two-different-title
native regression. The Mac helper also supplies the window-restoration argument
before app initialization. Final correction results are recorded separately.

Phone v2 uses the corrected runtime source. Its already-applied recovery and normal
conflict replacement pass. Distinct-value saving hits the host’s full disk; the
lost-close case is cancelled when storage cleanup stops the run. The two remaining
cases will resume on the same products after cleanup. This partial suite is not
represented as a complete pass. No runtime warnings were reported.

Mac v4/v5 expose test selectors that read only `.label` while native text is in
`.value`. Mac v6 reaches the close confirmation, which macOS exposes as a nested
sheet rather than an iOS alert. The harness now uses the observed native properties
and sheet, retaining the same content assertions. Its remaining three startup
failures came from a stray isolated process created by an interrupted native
observation; that exact process was closed. Final native phases are pending.

## Current Mac acceptance

All four targeted journeys pass on the final runtime and test source across v9
(three cases) and v10 (already-applied recovery). No runtime warnings are reported.
They verify separate request values, explicit closure/choice/new Save/Send, lost
close-reply retry with the same identity, no duplicate writes, and exact cold
readback. v9/v10 use numeric switch assertions and the frontmost native sheet.
Final screenshots capture only the isolated app window; two inspected images show
readable comparison/saved feedback and distinct request titles without clipping.
Earlier Mac screenshots containing the desktop are not repository artifacts.

The two interrupted iPhone cases and the iPad suite remain in progress. Broader
Mac spoken/genuine-Keychain/account/team/window lifecycle is still unaccepted.

Phone v3 passes distinct saved values. Its lost-close case reaches a durably closed
original but the synthetic switch tap stays off; the standalone v4 investigation
is still running. This mobile interaction and the iPad suite are not accepted yet.
The implementation is committed as gated work in progress, not rollout approval.

`pre-row-to-final.patch.gz` preserves the exact source corrections from the pre-row phase. Historical summary files omit unrelated macOS menu subtrees. The unrelated archived OS system log is excluded from this repository.

## Resumed iPhone acceptance

All four targeted iPhone journeys now have passing current-product evidence across
v2 (already-applied and normal replacement), v3 (distinct values) and v4 (standalone
lost-close retry and exact cold proof). v4 passes with no code change and no
reported runtime warnings; its reviewed-replacement image was inspected and is
readable. v3’s combined-run switch tap did not select the value, so that unexplained
automated interaction remains recorded and open. A later standalone pass does not
erase it. The four-case iPad suite is running next on the same signed app products.

## iPad acceptance and next scope

The current signed iPad products pass all four targeted cases in one v1 run:
already-applied recovery, reviewed replacement, distinct saved values and lost-
close retry, including the saved cold-return assertions. No runtime warnings are
reported. Two inspected screenshots show readable values and saved feedback in
the native scrollable sheets. No app or test source changed for this run.

Targeted Mac and iPad suites are accepted within this synthetic scope. All four
iPhone journeys have passing phase evidence, with the unexplained v3 combined-run
automated tap explicitly retained. This does not accept genuine credentials,
team/account/window/hosted or spoken lifecycle, ordinary exposure or the remaining
child migration. Next implementation is independent child completion with its
existing completion epochs/history and receipt-certified Undo, then structural
commands and legacy bridge/adoption work. General field edits continue to refuse
completion changes.
