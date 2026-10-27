# Remaining product backlog

Updated 27 October 2026. The agreed P1 batch is complete; see `p1-completion-audit.json`. This plan audits the advanced backlog recorded in `TODOIST_PORT_PLAN.md`; it does not claim a new audit of Todoist's current product.

## Current implementation focus

Workflow Undo body sizing now counts JSON structure/UTF-8 escaping directly,
retains Foundation's numeric spelling with a per-call raw-bit memo, and keeps the
original encoder/scanner as an unchanged fallback. The frozen 1,377-case corpus
and exact byte-budget boundaries match; no admission or depth quota changed.
Each repo reports 173 selected Core passes and four existing live-fixture skips.
All five native cases pass on Mac, iPhone and iPad with no XCTest runtime warnings.
The same flat 5,000-root fixture saves in 1.66/1.67/1.85s on phone/tablet/Mac.
A fresh Mac baseline was 1.95s; mobile comparisons use the previous stage. These
are variable-load Debug observations, not release or smooth-rendering guarantees.
The remaining main-thread pause and background widget work are still open.
See workflow-body-size/validation.json and its exact evidence.

Mac Print now uses a persistent window command target with owner-checked list
registration, rather than publishing fresh callbacks from replaceable list views.
The original build reproduced a silent Print failure after navigating to empty
Inbox. Three print cases now pass strict native verification: repeated shortcut /
Inbox routing, actual long PDF Save / Print cancellation / cold return, and
Calendar disable / explicit return to a list. Four note recovery cases individually
pass against the identical app binary; their mixed suite was not accepted as a
passing suite because its Calendar harness matched a clipped title. The corrected
standalone Calendar case passes. App focus-update logging is absent in these
runs. Four Services-menu / accessibility data-detector priority warnings remain,
so the strict note-runtime gate stays open. See mac-print-focus/validation.json.
No new iOS implementation or native acceptance is claimed by this Mac follow-up.

Rank 3 remains active. Headings have a compatible persisted contract and gated
native editors, including separately negotiated personal cloud support; normal
authoring stays off. Productive child work now feeds
Today/Upcoming, Inbox, project/label/filter lists, primary widgets, day planning,
week/month/year calendars, current project progress, combined activity and Insights.
Separate immutable child history, custody and reviewed project-adoption history
are implemented in source; hosted deployment/exposure has not been enabled.

Template/workspace files, reviewed Todoist mapping, Taskfold workflow CSV and
explicit text transfer preserve known types. Generic CSV column mapping now has
owned file/text intake, explicit task/heading and parent-reference choices, a
separate contents review, and a private reusable project-definition save. Its exact
supported fields and exclusions are in `TASK_CSV_SOURCE_MAPPING.md`.

Shared heading templates now have native private/shared entry and recovery
acceptance on Mac, iPhone and iPad; see PRIVATE_HEADING_WORKFLOWS.md.

Reusable definition authoring now admits explicitly mapped CSV headings in a
signed-in private workspace and offers root/nested Task / Heading editing. This
uses the separate client opt-in; personal live heading creation now checks its
own service compatibility signal. See DEFINITION_HEADING_AUTHORING.md and
PERSONAL_TASK_HEADINGS.md for acceptance and remaining limits.

Workflow creation retries preserve later server edits. Atomic personal workflow
Undo and full-size append/queue/widget publication have source and isolated
acceptance. The ten workflow cases plus background-publication/intent checks now have
installed passing coverage on each phone, tablet and Mac; the former workflow UI Automation gate is resolved.
See workflow-creation-scale/ for exact matrix/targeted evidence and scope.
Widget construction/encoding now uses a serialized latest-request worker after
the durable workflow save. Immediate privacy changes and widget receipts retain
their synchronous path. Timestamp preparation now reuses parsers within each save
without changing old signatures, including invalid Unicode spellings. The full
20,001-command save returns in 2.48/2.47s on phone/tablet; full widget readiness is
14.44/14.40s. The final Mac automation recheck now passes after the user's
approval. Fresh local creation now indexes root/child history once per transaction;
all five selected native cases pass on each platform. Local date processing now
reuses per-pass formatters/memos while preserving a frozen 375-case output corpus.
The same local-history 5,000-root fixture saves in 1.90/1.88/2.03s on phone/tablet/Mac,
with widget readiness at 8.83/8.83/10.09s from save start. The remaining save pause
and background work still need improvement. These Debug results do not prove
release latency or smooth production-screen input. Durable-cache encoding/I/O,
assignment-heavy scaling, production rendering and hosted/paired bulk delivery
remain open. See history-date-preparation/ and local-creation-history/ for the
new scoped evidence. See workflow-widget-publication/ and workflow-token-preparation/
for exact scope and evidence. Prior source migrations remain
undeployed, and normal authoring/rollout gates remain unchanged.

Remaining rank-3 work includes wider native Mac/spoken/largest-text and installed
widget acceptance, provider/file-handoff and cross-device checks, flat task-row
sharing acceptance (implementation in TASK_ROW_CSV.md), older literal-copy conversion acceptance (review implemented in
TODOIST_HEADING_CONVERSION.md), and remaining shared template/import adapters and native runtime
acceptance (TEAM_TASK_TYPE_NATIVE.md). The user-deferred older-client rollout dependency remains before hosted
exposure. See `TASK_HEADINGS.md`, `TASK_CALENDAR_WORK.md`, `TASK_WORK_HISTORY.md`,
`TASK_CSV_SOURCE_MAPPING.md` and their evidence folders. Historical checkpoints
below retain their original scope; their former “next” items are not current status.

Native completion recovery and permanent encrypted selection drafts are implemented
in both clients. Missing-source/occurrence authored task/comment work now also has
an explicit encrypted saved-edits path with review, copy and export. After cold startup, readable blocked individual/group actions can
open matching recorded or cancelled reviews. Explicit acceptance keeps current
viewer/archive/write-pause restrictions and preserves queued or separately saved
draft work. See the dated stages at the end of this plan for verification and
remaining limits; older paragraphs record preceding checkpoints.

The Watch departure/reconnect follow-up now passes actual paired local-workspace
acceptance, including immutable offline work and explicitly reviewed recovery.
Cloud Auth, physical phone/reinstall, background and native input/spoken gates
remain open; see the dated Watch stage below.

The next priorities within rank 6 are:
1. Finish broader recurring provisional cohorts and unsupported legacy conversation context
   without guessing legacy or unsupported preference history. Individual
   cancellation drafts now pass Core and iPhone/iPad native acceptance; broader
   Mac native acceptance still needs execution. Captured
   task list-order/pin histories and connected version-1 mention read/unread
   markers now have explicit encrypted preservation with native relaunch/export
   acceptance. Arbitrary view_preferences fields remain protected. Broader
   hosted/series acceptance remains open.
2. Finish backup/vault I/O-phase races and broader provisional draft histories,
   native Mac recurring history and remaining keyboard/accessibility behavior.
   Individual ordinary-root failure/retry now passes three native scenarios on
   each platform, including cancelled-receipt recovery after quitting. Delayed
   HTTP reply/session/access/account-switch safeguards and group storage checks
   also pass. Full account-picker and hosted flow acceptance remains open.
3. Finish large-selection live UI/archive-I/O responsiveness and genuine hosted
   team flows before enabling the default-off collaboration rollout. Core draft
   preparation now covers the full 50,000-row and 1,000-command limits; see the
   dated performance stage below.
4. Continue the remaining advanced/wearable backlog listed below. User-deferred
   release/distribution, server notifications, older-client rollout safeguards,
   OAuth/provider setup and physical location delivery remain deferred.

### Earlier implementation checkpoints

Completion batches now reconcile connected queued histories transactionally,
including Undo/Redo, scoped edits and mixed selections. Each repo passes 587 Core
checks and its own Debug app build. Native review/runtime integration is next; see
`p2-completion-cohort-evidence.json`. No hosted rollout changed.

The completion selection Core/storage/transport stage now passes 564 selected
Core checks per repo and both app builds. Whole receipt validation and isolated
confirmation are implemented; touching later cohorts remain protected and need
reconciliation before native bulk controls. See `p2-completion-client-evidence.json`.

Newest source stage adds atomic shared completion/Undo/Redo selections, with
243 real isolated SQL checks per repo (110 batch-specific). Native durable group
commands and reviewed selection UI are next; see
`p2-completion-batch-service-evidence.json`. No hosted rollout changed.

The latest follow-up connects native shared root checkboxes to the captured
completion/reopen path. It retains the existing atomic recurrence and linked Undo
commands; each repo passes 551 selected Core checks and its own app build. See
`p2-native-completion-evidence.json` for installed acceptance scope and limits.

The latest shared batch stage adds reviewed portable-label Add, exact Remove and
Clear all. It retains whole-selection source/access checks, one durable command
and linked Undo. Each repo passes 124 isolated SQL/advisor checks, 500 focused
Core regressions and its own app build. See `p2-shared-bulk-labels-evidence.json`
for the installed-test scope. Mac runtime remains pending the requested unlock;
no hosted deployment, rollout or user deferral changed.

Shared workflow runs now have the default-off atomic service, durable typed
requests and native destination/content/recovery reviews. Each repo passes 146
focused Core cases and its own arm64 Debug build; the preceding 93 isolated
service checks stand unchanged. Four native scenarios pass on each iPhone/iPad,
with exact recovery repeated after the sync/pending-edit guard. Mac native
acceptance is the next verification step. See `TEAM_WORKFLOW_RUNS.md` and
`p2-team-workflow-run-native-evidence.json`. No hosted deployment or rollout
changed; shared runs, rank 6 and wider Px remain open.

Latest follow-up adds inline copy/export name validation. Native iPhone/iPad
share-popover cancellation/reopening and final file cleanup now pass; see
`p2-team-template-handoff-evidence.json`. External provider delivery and the
remaining work below stay open.

Newest native stage implements the team-owned library catalog, publication and
replacement/removal reviews, private request recovery, and reviewed private-copy/
portable-export paths. Fresh scope/content checks precede artifacts; refresh keeps
the draft name, and errors/refresh controls remain visible. Each repo passes 111
focused Core tests and an independent arm64 Debug build. Four installed scenarios
are accepted per iPhone/iPad using only a signed isolated app and synthetic HTTP
peer; final transfer scenarios pass targeted reruns. See
`p2-team-template-transfer-evidence.json` for exact per-run limits and retained
initial failures. The gated service's prior 96 isolated SQL checks still stand.

Next are Mac shared-run runtime/accessibility/window,
external file-handoff and genuine hosted acceptance. These client checks do not
close team templates, rank 6 or the wider Px goal. No hosted deployment or rollout
change occurred; all user-deferred release/provider/device work remains deferred.

The preceding source stage adds an explicit contents review before copying readable
shared project/section/task work into a private reusable template. Shared root
and subtask label names retain their own context; personal catalog IDs and colors
cannot rewrite them. Full source rows, selected branch/order and opening
workspace/session/origin/access are rechecked before saving. Both repositories
pass 87 focused Core cases and independent app builds. Three installed scenarios
pass on each of iPhone and iPad, with four preview/refusal images inspected. See
`p2-shared-template-capture-evidence.json` for exact current acceptance limits.
This does not add team-owned template catalogs or template runs into team projects;
those integrations and the full rank-6/Px goal remain open.

The preceding source stage adds reviewed assignment for a complete shared selection.
Choices intersect the eligible recipients of every selected project; picking a
teammate refreshes every project again. Clear and You support captured offline
intent. Final Save uses the existing atomic shared command and linked Undo,
with server-side live recipient checks. Both repositories pass 96 isolated SQL
checks and 502 focused Core cases, plus the final sparse-Undo batch rerun. Three
final installed scenarios pass independently on iPhone and iPad. See
`p2-shared-bulk-assignment-evidence.json` for exact current acceptance scope.
Rollout and the rest of rank 6/Px remain open.

The preceding stage adds shared deadline/estimate input with opening-time source
admission, explicit Review/Back/Cancel and the existing atomic Save/Undo path.
Personal selections gain an undoable estimate picker through their personal
writer. Bounds, current values and preserved plans are explicit. Each Core suite passes
493 tests; the final five installed scenarios pass on both iPhone and iPad. See
`p2-bulk-planning-pickers-evidence.json` for the current native/build scope.
Shared rollout, broader native/live acceptance and the rest of rank 6 remain open.


Latest implementation: reviewed shared date/priority selections now have a source-only atomic planning command and native review entry in both apps. Complete source baselines, one durable request, one RPC and linked Undo preserve the whole selection. Scoped installed phone/tablet review, Cancel, Save, Undo/relaunch, changed-source and failed-save retry now pass; see `p2-team-planning-selection-native-evidence.json`. Broader native/live acceptance remains open; the newer deadline/estimate bulk entry is described above.

Earlier, shared-task creation uses the complete native editor and
an explicit Add. Shared list selections now have a frozen, reviewed atomic deletion
and linked Undo path in both apps. Missing or changed members stop the whole action;
no personal/shared mixture is partially deleted. See `p2-team-creation-evidence.json`
and `p2-team-selection-deletion-evidence.json` for verification scopes. Shared
Repeat/reminder/label/assignment/checklist and single-deletion evidence remains in
its stage files. Team rollout and broader live/Mac acceptance stay open.

Rank 6 is active: source-custody and opening-time editor admission are in place.
A gated native team overview now shows organization roles, folders and permitted
directory/invitation information through account-bound read adapters. Reviewed
team creation, naming, archive/reopen and folder changes now use private
stable-request recovery; team rollout stays disabled. Gated invitation responses,
membership/role/ownership and leave/delete controls are now implemented. Next:
broader native/live role/account and draft-cohort acceptance, then remaining
scoped team-task adapters. Scoped profile/confirmed-email presentation is now
implemented; its live-service acceptance remains open. Gated Projects now adds
catalog, creation, visibility/folder and access/reset reviews with separate
private request recovery; team-task rollout remains disabled. The captured native
editor bridge now has isolated iPhone/iPad title/notes and role-loss recovery
acceptance; Mac runtime and remaining field adapters stay open. Rank 7 now passes scoped paired offline completion/Undo/stale/recreated checks;
its recorded native/hardware/cloud gates remain open. User-deferred release,
provider and device dependencies remain deferred.

## Immediate priority correction

Account removal now has a deployed protocol-2 service and genuine iPhone Simulator deletion/recovery acceptance, including confirmation after deliberate pruning of a synthetic retry receipt. Mac private-Keychain/runtime, expired pre-proof legacy state, residual-file repair and wider fault/concurrency checks remain open; see `ACCOUNT_REMOVAL.md`. Scoped rank-3 note-save recovery now passes. Rank-6 automation acceptance and rank-7 Watch implementation are both in progress. Scoped credentials, task operations and gated native management are implemented; both repo-owned server sources now pass hosted lifecycle/timeout acceptance. Signed-in phone/tablet management against the hosted service now passes; the webhook transport now passes local and hosted acceptance. Account-bound subscriptions and receiver proof now pass local SQL/HTTP acceptance. The task outbox/dispatcher and gated native controls are now implemented; hosted queue/delivery, signed scheduling and scoped phone/tablet native Auth/relaunch/account-isolation flows now pass; scoped clipboard/spoken secret controls now pass; native recovery and the remaining spoken checks remain in progress. Hosted server-session expiry and temporary encryption-key restoration now pass in both repo-owned services; hosted same-account webhook, queued-task and API-key recovery now pass on phone/tablet; wider spoken acceptance remains open. Signing-dependent Mac runtime stays deferred. Actual paired Simulator live capture/completion/replay and normal foreground relaunch now pass; offline Watch relaunch is durable. The startup authority fix and ready-update retry now pass paired Simulator cold capture return; 88 focused cases cover the queue/binding/retry policy. Paired offline completion/Undo/stale/recreated cases now pass; account/phone/reinstall, hardware/background/cloud and native/spoken acceptance remain open. These priorities preserve the full backlog and existing user deferrals.

## Priority and delivery order

| Rank | Work | Delivery and acceptance |
| --- | --- | --- |
| 1 | Portable workflow templates | Versioned files for project, section and task definitions. Native export, bounded import, editable name and full preview before saving a private copy. Never create tasks merely by opening a file. Preserve source work, fresh run identities and relative scheduling. Reject incompatible/malformed files. |
| 2 | Reviewed share and browser capture | Independent native share extensions, bounded text/URL intake, editable source link and task preview. Persist account-bound drafts before handoff; signing out or changing workspace must not deliver to a different account. Cancel creates no task. Verify Safari and another sharing app, suspended/closed host, offline retry and duplicate handoff. |
| 3 | Notes, output and view control | Safe rich text with a readable plain-text fallback; coherent native print/PDF layouts; accessible grouping and gestures where genuinely useful. Extend saved-view grammar for descendant projects and parent/child scopes; shared/personal and assigned-by conditions must use real membership and recorded metadata, never guessed authorship. Non-completable headings require a compatible persisted contract before shipping. Preserve the existing typography, spacing and editing flow. Test malformed links, long content, large text and printed pagination. |
| 4 | Reviewed voice drafts | Device transcription into the existing editable multiline preview, including transcript correction and explicit Apply. Permission refusal/cancellation must preserve the draft. Cloud AI breakdown/filter assistance stays disabled until its provider, cost and data handling are chosen. Generated task/query proposals must validate against the existing schema. |
| 5 | Advanced reminders and recurrence | Define sub-day scheduling, travel, holiday policy, location and urgent-alert behavior before implementing separate opt-in capabilities. Do not describe ordinary local notifications as urgent/critical delivery. Assigned-recipient delivery depends on authenticated server delivery and stays with the deferred remote-reminder work. |
| 6 | Automation and advanced teams | Scoped/revocable API credentials, idempotent email intake and webhook retries; separately authorized team roles/folders/admin. Establish sender verification, quotas, recipient permissions and real server fixtures before enabling capture. Independent child-task records and audio comments require explicit migration/storage/access rules. Role enforcement cannot rely only on the new app UI. |
| 7 | Wearable clients | Start with Apple Watch Today, reviewed capture and durable offline completion using the proven account/task-generation contract. No silent retargeting after reconnect/account changes. Wear OS/Android remain separately owned work; neither Apple repository should absorb their deployment code. |

## Dependencies kept deferred by the user

Server-delivered reminders and device/reinstall recovery, older-client rollout safeguards, distribution signing/install/update verification, and genuine Google/Microsoft OAuth registration/provider acceptance remain deferred. Calendar write/mirroring must wait for genuine provider acceptance plus explicit deletion/retry/loop rules. New role enforcement and incompatible task contracts must resolve the older-client dependency before rollout. This backlog does not reopen those release tasks.

## Current implementation

Portable template files are implemented independently in both repositories, with native Mac, iPhone and iPad acceptance recorded. Templates has an Import action and an Export action in each saved template's context menu. The file has a strict `taskfold-template` envelope, schema version, name and validated definition. Import reads at most 2.1 MB plus one rejection byte, opens the existing definition preview and saves a new account-owned template only on Add to templates. Provider-backed file reads are coordinated and bounded, and run away from the interface with a cancellable result; leaving the screen or changing workspace invalidates late results. The captured workspace generation is rechecked before save. Repeated runs continue using fresh task/project/generation identities. Cancel discards the review.

Export first opens a contents review, then a native Mac save panel or the iOS save/share menu. Export excludes the template record's account/identity metadata and replaces project, section and nested task references with file-local references. Label names/colors and intentionally authored workflow notes are included; users should review their content before sending the file to someone. Discussions, files, completion and assignments are excluded by the existing definition contract. Unsupported definitions stay saved and cannot be exported as a misleading partial workflow.

Validation is tracked in `p2-template-files-evidence.json`. File import/export uses the system picker; Taskfold does not publish an online sharing link. The chosen file provider controls its storage destination. Rank 1 does not include a public template catalog, online sharing links or registering JSON as the default app file type.

## Share capture implementation (rank 2, acceptance in progress)

Each repository owns a native `TaskfoldShare` extension, its sources, entitlements and embedded target. The Share menu accepts text and one web URL. The extension reviews editable title, notes and source, displays the captured workspace, and saves only on **Save draft**. It does not fetch the webpage or access account credentials. Drafts remain on this device until the user opens **Shared drafts**, reviews the destination and chooses **Add task**. Cancel keeps tasks unchanged. A count beside Shared drafts helps surface captures when returning to Taskfold.

The draft mailbox has a cross-process lock, atomic writes, a 64-draft capacity, a bounded 8 MB read and a 100 KB title/notes limit. It uses the existing app-group boundary and protection until first device authentication, matching the account cache/widget handoff. A workspace session change invalidates an open extension review; saved drafts remain bound to the original account. A task and its local receipt save together. A failed mailbox acknowledgement can retry without recreating a task after deletion or Undo. Shared words do not implicitly schedule, prioritize, label or assign a task.

Current evidence is split by milestone. `p2-share-capture-evidence.json` retains the original mailbox, Safari, host Cancel/disk-full retry/Add and relaunch checks. `p2-share-provider-evidence.json` adds bounded/cancellable provider intake and genuine Maps capture with a quit host; its full Core suites report 1,288 iOS / 1,320 Mac cases, with 13 / 33 optional skips and no failures. `p2-tablet-share-evidence.json` adds actual iPad Maps extension/host review, durable Add/relaunch in normal light and largest-text dark layouts, plus a current iPhone regression. Captured screenshots are visually inspected. Layout runs use isolated local workspaces; scoped real iPhone account-switch/offline-return checks now pass in `p2-share-cloud-evidence.json`; native Mac share-menu interaction, spoken accessibility and wider device/network variants remain gates. These checks are not satisfied by a successful build. Real distribution acceptance stays deferred.

## Note formatting implementation (rank 3, acceptance in progress)

Both apps now offer selection-based formatting tools, a native readable preview and original-text access. Notes stay in the existing portable description string; Apply edits a draft and the existing durable Save/Undo path remains responsible for persistence. Links accept web addresses only, without embedded credentials; previewing never fetches images, webpages or metadata. Compact task/widget previews remove supported formatting while preserving the complete saved text. Large or excessively fragmented notes retain a complete literal fallback.

Phone and tablet native cancellation, selection replacement, Preview, Apply, parent Save, relaunch and largest-text dark appearance pass in the scoped cases. Scoped iOS failed-save/retry and stale-Apply acceptance now passes in `p2-note-recovery-evidence.json`. Representative Mac personal-task formatting, Cancel, failed-save retry, simulated stale-Apply refusal and cold return now pass four native cases; four inspector-opening thread-performance warnings keep strict runtime acceptance open. Workspace/access changes, broader text/layout, live concurrency and VoiceOver remain open. See mac-note-formatting/. Exact tests and limits are in `p2-note-formatting-evidence.json`. Print/PDF is tracked separately below; additional view controls and broader hierarchy acceptance remain open in rank 3.

## Native print and PDF (rank 3, acceptance in progress)

Task lists and pinned notes now open a read-only paginated review. Lists reuse their actual filtered ordering and groups, including collapsed groups; notes and complete nested checklists are optional. A separate native Options sheet keeps large-text settings clear of the preview. Users choose A4 or US Letter, then explicitly Save PDF or open the system Print panel. A changed source or workspace invalidates the review. No task mutation or automatic print job occurs.

Each app owns its Core Text/Core Graphics renderer and PDFKit preview. Exports retain selectable text, native script/emoji fallback, portable formatting, complete note fallback, page numbers and coherent paragraph/heading breaks. Background work measures within page bounds and supports cancellation. Oversized or unsupported source fails explicitly instead of reporting a truncated PDF as success. Resolved labels/assignees and scheduling metadata are included; account/record identifiers, discussions and files are excluded.

Scoped phone/tablet native Save/readback/relaunch, native Print cancellation, content/paper options and save cancellation pass, with exact saved-snapshot preservation. Largest-text main/Options panels and all pages of the long A4/Letter fixture are visually checked. Exact proof and remaining gates are in `p2-print-output-evidence.json`; these checks are distinct from compilation. Mac native Save/Print and VoiceOver, source/account-switch and output-error UI acceptance remain open. Physical printer delivery and real distribution are not claimed. Other view controls and broader hierarchy acceptance are still pending.

## Quality gates for each rank

Retain independently owned app/resources/extension/tests/build inputs. Use the existing native controls and Store/Workspace durable mutation and Undo paths. Validate malformed input, workspace changes, offline retry, normal relaunch and cancellation using synthetic data. Check phone, tablet and Mac layouts and accessibility where affected. Commit and push completed changes to each corresponding repository; leave exact acceptance limits visible instead of treating compilation as end-user proof.


## Project and subproject filters (rank 3)

The builder now offers **Project and subprojects**. Expressions accept `##Work` or `project-tree:"Work"`; names containing spaces or literal stars must be quoted. This stores one project identity, includes that project plus accessible descendants, and follows moves and renames. Existing `#Work` / `project:"Work"` conditions keep their exact-project meaning. The condition does not invent a capture destination.

App lists, preview counts, separate query groups and widget publication resolve the same parent graph. Archived branches, ambiguous IDs, cycles and excessive depth are excluded even inside NOT/OR. A missing/archived target invalidates the condition. An accessible shared project may have an unshared ancestor: its own readable branch remains usable, without granting access to that ancestor or other projects. Widget payloads contain resolved task membership, not the hierarchy or filter document. Existing version-1 envelopes remain; older strict readers reject the new field as unsupported rather than silently substituting an exact-project filter.

Eight new core cases cover grammar/literal names, move/rename cache invalidation, inaccessible targets and Boolean expressions, archive/cycle/duplicate safety, shared boundaries/depth, independent queries/completed scope, widget membership/revocation/privacy and queued snapshot persistence. Native acceptance and exact limits are recorded in `p2-project-tree-filters-evidence.json`. Parent/child and sharing integrations are recorded below. Assigned-by implementation and recorded acceptance are described below; other view controls and headings remain unfinished rank-3 work. This milestone does not close the full rank or reopen deferred rollout enforcement.


## Parent/child filter foundation (rank 3, unfinished)

`TaskHierarchyIndex` now provides complete, bounded, read-only root/subtask/parent selections, stable path identities and parent-title context. A nested result inherits only project, section and owner containment; its dates, labels, priority, assignment and completion use its own stored values. Completing a parent does not rewrite child statuses, matching the existing checklist contract. Archived/inaccessible project branches are excluded. Unsupported trees, missing/duplicate child IDs, excessive depth or oversized projections fail explicitly without creating identities or returning partial results. Legacy checklists need the existing organizer's save/normalization before this opt-in hierarchy projection can index them.

The child edit planner captures the workspace incarnation, root generation/creation/location and selected child content. It accepts current accessible roots/projects, refuses moved/replaced/deleted selections, protects concurrent changes to the edited field and any changed content under a deletion, and preserves unrelated current fields and siblings. Independent sibling/ancestor-field edits coalesce into one real root patch. Overlapping branch edits are rejected; no synthetic task identity enters the task table or durable queue. Root mutations retain the existing save/sync/Undo/redo contract. Completion retries with the same intent become no-ops. Read limits are 100,000 items, 32 nested levels, 400-character identities and 32 MiB of encoded reference storage; a child batch accepts at most 1,000 edits. Refusals return no mutation.

The foundation was initially available only through an isolated DEBUG fixture. Public saved-filter integration is now implemented below; the full parent/child feature remains unfinished. Output context and child-widget integration are now implemented below. Reviewed recovery for damaged references and text-only legacy entries is now implemented in `CHECKLIST_RECOVERY.md`; unfamiliar structures remain preserved. Broader workspace/access/layout/accessibility acceptance remains open. The rest of rank 3 and all explicit user deferrals remain unchanged. Historical core foundation evidence: `p2-task-hierarchy-foundation-evidence.json`.


## Native child action bridge (rank 3, unfinished)

A captured nested selection now opens the existing iOS embedded detail editor through a contextual presentation. Save compares authored fields with that selection and commits real root subtree patches through Store. The flat-result row shows its parent path; completion and deletion use the same guarded root transaction and existing Undo feedback. Child projections also carry the root's revision as read-only action context; it is never copied into the saved child. Ordinary task detail presentation retains its existing Save path. Each Store rejects direct synthetic child IDs in task-row mutations, so unfinished commands cannot enqueue fake backend tasks.

Four additional core cases verify native draft field selection, identity/containment/opaque-field refusal, completion timestamp preparation and projected root-incarnation changes. The native fixture exercises real row/editor/Store code, gated by the exact isolated bundle, local test account and explicit DEBUG launch flags. That historical fixture does not replace production All tasks. Public entry now uses the saved-filter controls described below. Native acceptance, current source hashes, test diagnostics and remaining gates are recorded in `p2-child-editor-bridge-evidence.json`. Mac controllers are connected independently; their native flat-result acceptance remains unfinished. No new server contract or release/provider claim is made.


## Saved hierarchy filters and mixed actions (rank 3, acceptance in progress)

Saved filters now support **Main tasks** (`root`), **Subtasks** (`subtask`) and **Tasks with subtasks** (`parent`) in both the condition builder and expression editor. Existing filters keep their root-only scope. A hierarchy condition opts its own query into nested candidates; comma-separated queries retain independent scopes. Results use each node's own fields, inherit project/section containment and show an ancestor breadcrumb. Preview counts share the same candidate cache. Unsupported child data produces an explicit filter error; reading never creates missing identities. Expressions proven to select only roots can still use older ID-less checklists.

Mixed selections now coalesce root and child edits into real root transactions, with guarded completion/reopen, dates, deadlines, priority, duplication and deletion. Redundant descendant deletions collapse into their selected ancestor; destructive ancestor/child-edit conflicts refuse the whole action. Duplication copies each selected branch once, refreshes identities and completion state, and keeps child copies beside their source. Main-task recurrence retains its existing successor and action identity; child completion does not create a parent recurrence. The existing durable commit and Undo paths remain responsible for saving. Child project moves are unavailable because containment stays with the parent.

Mac hierarchy lists remain flat, with parent context and guarded selection commands. Ordinary expandable lists retain their existing behavior. Nested drag/reparent semantics are not expanded by this milestone. This milestone initially left child-needed widget filters explicitly unavailable. The widget and output integration below supersedes that temporary restriction. Native Mac mixed commands, broad bulk-action/layout/accessibility acceptance and live concurrent-account acceptance remain open. Exact verification is recorded in `p2-hierarchy-query-actions-evidence.json`.


## Hierarchy widgets and filtered output (rank 3, acceptance in progress)

Saved hierarchy filters now publish a separate nested display catalog and resolved list membership. The ordinary Today/Inbox/planning catalogs remain roots only. My list can show nested results with parent paths, credential-free completion tokens and account/root-incarnation-bound links. Encoded paths retain their case throughout action requests, receipts and lookups. Missing nested catalogs require refresh; incomplete membership is unavailable instead of a false All clear. Hidden-title presentation also hides parent names.

Child completion revalidates the current subtree, root incarnation/location, account and accessible project before preparing a real root-subtasks mutation. Completion, the existing durable receipt and feedback retain the same save/retry/Undo contract. The feedback row can link back to the same completed child; its parent remains unchanged. iOS routes use the contextual child editor; Mac routes restore the containing project and expand the ancestor path. Moving/replacing/deleting a branch or leaving its workspace invalidates the old route/action as appropriate. No synthetic child is written as a task row.

Hierarchy-filter Print/PDF captures current displayed rows with parent breadcrumbs and excludes nonmatching descendants, even when a matching row is itself a parent. Capturing stale/replaced results, missing/moved rows or unsupported identities refuses output. Ordinary list checklists and pinned-note output retain their existing behavior. A4 and Letter fixtures are rendered and visually inspected. Exact current checks and remaining native WidgetKit/Mac/accessibility/account gates are tracked in `p2-hierarchy-widget-output-evidence.json`. These changes do not close rank 3 or reopen deferred distribution/provider work.


## Shared and personal saved filters (rank 3, acceptance in progress)

Both apps now support **Shared projects** (`shared`) and **Personal work** (`personal`) in the condition builder and expression editor. Shared means a readable project has another accepted member. Personal includes the current user's Inbox and projects they own without accepted collaborators. Pending/declined invitations do not make a project shared. A task author's identity does not override its project's sharing state; each subproject uses its own direct memberships. These predicates are read-only and grant no access.

Classification uses the already synchronized `project_collaborators` table, whose current read policy exposes accepted membership to accessible project members. It does not infer sharing from ownership alone, from an ancestor, or from the cached display-name RPC. A missing catalog is unknown, distinct from a successfully synchronized empty catalog. Missing/ambiguous/inaccessible/malformed references remain excluded under NOT/OR; incomplete sharing context gives an explicit sync error with the saved query/draft preserved. Local workspaces use their local membership table (or an explicitly empty local catalog). Offline results use the last synchronized snapshot, like the rest of the app.

Membership-derived flags participate in query cache identity, so accepting/removing collaborators updates results without task edits. App matching, preview counts, grouped/independent queries, nested task results and widget publication use the same references. Widgets receive resolved task membership, never collaborator rows or invitation emails. Capture defaults never invent a shared destination or create an invitation. Version-1 query envelopes remain; older strict readers reject unsupported fields.

At the sharing-filter milestone, the live schema/policies/enums were inspected read-only, with no database, permission, account or credential change. Assignment actors are now recorded separately from editable task fields in the later foundation/integration below; task authors, invitation senders and assignees remain invalid substitutes. Exact current verification and remaining native/paired/offline/accessibility gates are in `p2-sharing-filter-evidence.json`. All user-deferred release/provider work and the rest of the backlog remain unchanged.

Recorded assignment-actor metadata and its saved-filter integration are now implemented below. The completion/planning/movement activity ledger does not substitute for assignment authorship. Legacy and otherwise unattributable history remains explicitly unknown; broader older-client rollout enforcement remains deferred.


## Recorded assignment-actor foundation (rank 3, unfinished)

The backend now records actual authenticated assignment transitions in a separate read-only `task_assignment_provenance` table. Reads follow current task access and root incarnation, including accepted membership and revocation; clients cannot write the table or call its private trigger. New assignment events are distinguished from unrelated edits, child reparenting and same-recipient retries. Stable child removal/Undo preserves the original assignment; explicit unassignment and reassignment creates a new event. Unsupported historical trees never acquire invented identities. No existing task data or historical actors were backfilled.

Legacy/missing history, system actions without an actor, removed actor accounts and recognized recurring successors remain explicitly unknown. Recurrence markers supplied by a client do not attest another person's authorship. A restored root is a new incarnation. Imports/new copies record only their new Taskfold assignment action, never an inferred external historical actor. The client resolver checks current recipient, root generation and exact nested path; portable exports exclude this metadata and generic client write paths refuse it. The catalog is not yet synchronized or used by saved filters.

The actual migration and rolled-back disposable fixture pass both independently owned local PostgreSQL checks and the real backend's current policies/triggers. The hosted check leaves zero fixture accounts/tasks. Full core suites report 978 iOS / 1,002 Mac cases, with 12 / 32 existing integration skips and zero failures. Both isolated native apps build and pass strict deep signature checks; compilation is not native acceptance. The signed-in schema-discovery advisory for the intentionally readable table is documented with the actual RLS tests; existing unrelated advisories remain unchanged. See `p2-assignment-provenance-evidence.json`.

The initial synchronization/predicate/control gates here are superseded by the assigned-by integration below. Trusted recurring inheritance and remaining native/accessibility/concurrent acceptance are still open. No full rank or deferred rollout/distribution/provider gate is closed by the foundation.


## Assigned-by saved filters and synchronization (rank 3, acceptance in progress)

Both apps now connect the recorded assignment actor to **Assigned by** controls and strict `assigned-by:me`, `assigned-by:others`, `assigned-by:unknown` or exact-person expressions. Preview, saved/grouped/independent queries, nested results and widget membership share the same current catalog. Unknown historical attribution stays distinct from unassigned work and unconfirmed data; negation does not turn unknown into another person. The query captures no actor or invented assignee defaults.

Optional account-incarnation-fenced reads distinguish unavailable from synchronized empty data without blocking core task sync. A fresh task read without corresponding history clears the old catalog. Optimistic transitions, including new assignments and A→B→A cycles, remain unconfirmed through queue replay/acknowledgement until fresh server evidence arrives. Explicit local-workspace recording preserves real actions, moves and Undo without fabricating legacy or recurring history; portable backups exclude the catalog. Immutable metadata participates in query cache identity, with timestamps parsed once for responsive large lists.

Independent core checks, genuine disposable owner/member/outsider HTTP checks and actual phone/tablet native builder/expression/save/relaunch acceptance pass. Actual saved JSON and published widget membership agree for Me/Others/Unknown, with no raw actor metadata exposed. Exact counts, artifacts, resource-signature repair and acceptance limits are recorded in `p2-assigned-by-filters-evidence.json`; the contract is in `ASSIGNED_BY_FILTERS.md`. This supersedes the initial unsynchronized/unexposed foundation restrictions above. Native Mac/layout/accessibility, exact-person picker and installed-widget/wider concurrent/offline acceptance remain open. Trusted recurring inheritance remains separate; copies stay explicitly unknown. The rest of rank 3, the overall backlog and all user deferrals remain unchanged.


## Row gesture controls (rank 3, in progress)

iPhone/iPad now implement device-local leading/trailing action choices, optional full-swipe execution, consistent list/day-card actions and cancellation/workspace/task guards. Full-swipe deletion is removed; Edit/Delete require activation. See `ROW_GESTURES.md` and `p2-row-gestures-evidence.json` for exact verification and remaining gates. Mac implementation and current verification are recorded below; physical Mac input acceptance, broader VoiceOver/layout/drag interoperability and the rest of rank 3 remain open. This adds no persistent task contract and reopens none of the explicit user deferrals.


### Native Mac gesture implementation and RTL correction

Mac now owns trackpad row controls and device-only preferences, with full-swipe execution off by default. Core, AppKit routing and offscreen row/settings rendering checks are implemented; see `p2-mac-row-gestures-evidence.json`. The checks exposed and corrected a double RTL offset reversal in both apps. Physical trackpad, native settings/list/Undo/account-switch walkthroughs, VoiceOver and mouse/keyboard/drag interoperability remain open while the Mac is locked. This advances the existing rank-3 gesture work; it does not close rank 3 or the full Px objective.


## Reviewed voice drafts (rank 4, implementation with acceptance gates)

Both apps now own on-device-only recording adapters and a correction/review sheet in Add multiple tasks. Apply appends bounded text to the unchanged, workspace-bound draft; it does not save tasks. Existing multiline preview, metadata/destination validation and explicit Add still own mutations. Cancel/refusal preserve the original draft, recording tokens fence late callbacks and account changes, and recording/finalization are time-bounded. See `VOICE_DRAFTS.md` and `p2-voice-drafts-evidence.json`. Genuine microphone/transcription, OS permission/recovery/audio-session and full Mac/VoiceOver/account-switch acceptance remain open. Synthetic speech fixtures are not real speech acceptance. Cloud AI assistance remains disabled; this does not complete rank 4 or the full Px backlog.


## Elapsed reminder schedules (rank 5, foundation only)

Elapsed repeating reminders are the first rank-5 capability: a fixed anchor plus a user-chosen interval, reviewed upcoming alerts, count/end limits and no catch-up burst. Both apps independently compile the bounded schedule/receipt-membership foundation. It is not exposed or persisted yet. The spec/editor, durable save/import/Undo, notification projection/action integration and genuine native/delivery acceptance remain required. See `ADVANCED_REMINDERS.md` for the explicit travel/holiday/location/urgent work order and `p2-interval-reminder-foundation-evidence.json` for exact foundation checks. No full rank or deferred release/provider gate is closed.


### Interval reminders connected to native editing and local scheduling

The independently owned interval model now connects to a version-3 local-only reminder spec, native interval/count/end controls and upcoming-alert preview, durable task/backup/queue paths, per-occurrence notification identity and exact response validation. The previous committed readers are compiled to prove opaque preservation without a substitute alert. Repeating task successors retain the original anchor/count; completing the original task cannot retarget its notifications. Current server compatibility inspection was read-only and remote delivery stays disabled/deferred. `ADVANCED_REMINDERS.md` describes the contract; `p2-interval-reminders-evidence.json` separates native acceptance, Core checks and remaining Mac/OS-action/lifecycle gates. This supersedes the foundation-only implementation status above; rank 5 remains incomplete.


### Saved reminder time zones and travel clarity

Calendar reminders now have a native searchable time-zone choice and up-to-five source/device clock previews. An explicit zone change preserves the authored civil day/clock/rule/limits while moving alert instants; preview and Cancel do not mutate data or task planning. A skipped civil date is refused. Existing version-2 data and notification signatures remain in use; no server migration or provider permission is needed. `REMINDER_TIME_ZONES.md` and `p2-reminder-time-zones-evidence.json` record exact checks and remaining Mac/live-OS-zone/cloud/accessibility gates. Holiday and Time Sensitive implementation progress is recorded below; floating device clocks and location behavior remain unfinished.


### Opt-in Time Sensitive presentation

Custom reminders now have an explicit Time Sensitive choice, separate from a default-off device/workspace allowance and the OS setting. Normal fallback preserves schedule/identity; Focus finish alerts stay normal. Version-4 local-only wrappers preserve prior readers' opaque settings and bind the new presentation into response signatures. `REMINDER_PRESENTATION.md` and `p2-reminder-presentation-evidence.json` distinguish scheduling/native checks from genuine capability/Focus/distribution acceptance. This independent opt-in work does not resolve the still-open holiday-source/location contracts, close rank 5 or reopen user-deferred release work.


### Reviewed holiday source and reminder policy

Added a bounded all-day iCalendar source review, explicit region/year coverage and separate Skip/Move plus weekend choices for independent calendar reminders. The next-alert preview uses the transformed dates; task planning and other reminders retain their own settings. Version-5 local-only schedules and optional Time Sensitive wrapping preserve older readers' opaque settings. Reimport is reviewed, never a silent source update. `HOLIDAY_REMINDERS.md` defines count/end/collision/privacy and supported-file behavior; `p2-holiday-reminders-evidence.json` records exact verification and still-open native/provider/notification gates. Automatic country calendars are now the primary source, using explicit country/year fetching, regional Public filtering, review-before-apply and offline snapshots; calendar files remain secondary. Provider commercial sponsorship remains a release dependency. Location reminders and the rest of Px remain unfinished; user-deferred release/provider/remote work stays deferred.


### Device-private location reminder foundation

Next in rank 5: reviewed Arrive/Leave notifications on iPhone/iPad, using the system location-notification trigger with When In Use access and no continuous tracking. Both apps now own a strict proposed version-6 reference, private place geometry model and serialized one-shot journal/registration engine. References bind the original task incarnation and device; private coordinates/names do not enter authored task rows or notification receipts. A durably prepared explicit intent is required, submitted/consumed requests never silently rearm, late account callbacks are cancelled, and retired intents cannot block waiting capacity. A cleanup-only pass prepares for shared admission with the existing 60-alert queue. The app still treats these rows as unsupported and does not expose or write them. `LOCATION_REMINDERS.md` preserves the complete native storage/UI/permission/action/delivery acceptance work; `p2-location-reminder-foundation-evidence.json` records exact foundation checks. Location reminders and the full Px objective remain incomplete.


### 22 October — protected place storage and native picker

Advanced reminder work now includes an independently owned atomic private place/journal store in each app and an iOS map/search/radius/management component. The picker remains behind an exact isolated debug route while task save/cancel, consent, OS delivery and action routing are unfinished. Every-visit mode and private desktop-to-phone authoring remain in scope. Current implementation and checks are separated in `LOCATION_REMINDERS.md` and `p2-location-place-storage-evidence.json`; this is progress on rank 5, not completion of location reminders or remaining Px.


### 22 October — native location adapter and iPad keyboard flow

iOS now owns native location-trigger construction/inspection, typed permission/capability/capacity refusals and scoped cleanup. Actual native format and unavailable-device paths pass in the isolated Simulator, with durable refusal closure and unrelated-alert preservation. The Simulator reports region monitoring unavailable; positive registration/delivery is still open. iPad keyboard Search now passes the full private-place save/relaunch/edit/delete flow; direct Search taps while typing remain unresolved. Normal task location UI and the coordinated time/Focus/location scheduler are still unfinished, alongside repeated visits and private desktop-to-phone authoring. This is rank-5 progress, not full Px completion. See `p2-location-system-adapter-evidence.json` and `LOCATION_REMINDERS.md`.


### 22 October — shared notification admission

Both independently owned schedulers now coordinate an optional location engine with the existing time/Focus queue. Cleanup precedes additions; durable location intents reserve at most 20 slots; Focus and explicit snoozes have priority; all other native pending requests consume capacity. Account/installation changes fence late work, and a full native queue produces waiting feedback instead of false snooze success. Normal Store location bootstrap/consent/task/action wiring remains unfinished and the location editor stays hidden. Every-visit mode, private desktop-to-phone authoring and positive capable-device location delivery remain open. See `LOCATION_REMINDERS.md` and `p2-notification-admission-evidence.json`; this milestone does not complete rank 5 or Px.


### 22 October — private consent and normal workspace lifecycle

The iOS Store now loads the protected private archive, installs the shared location engine during ordinary scheduling refreshes and rechecks account, workspace session, task and saved-place bindings around submissions. Account changes invalidate old work immediately; leaving and returning to the same account cannot acknowledge an old in-flight addition. Concurrent refresh callers wait for the latest hydration/admission pass. Both independently owned private stores persist explicit account consent in a version-2 private archive; legacy version 1 and a fresh identity start with consent off. Consent stays outside shared tasks, widgets and portable backups. Normal iOS cleanup handles revoked/unreadable/reset private state and preserves unrelated notification requests.

The Store allowance API refuses unsupported or unapproved native delivery and never prompts automatically. Public consent controls and task location editing are still absent; version-6 task rows remain opaque. The isolated normal-Store checks and precise remaining scope are recorded in `p2-location-workspace-evidence.json` and `LOCATION_REMINDERS.md`. Every-visit mode, private desktop-to-phone authoring, native response actions and positive capable-device location delivery remain open. Full rank 5 and Px remain incomplete.


### 22 October — reviewed location task drafts

Added the iOS reviewed Arrive/Leave/place/area editor and parent task Save/Cancel bridge behind the exact isolated DEBUG route. A memory-only review cannot arm an alert before a successful task save; ordinary builds still expose no location authoring. Normal iOS mutations now retire removed/undone location intents, including preparations that have not reached the OS. Private journal version 2 adds monotonic receipt revocations so restoring an old row cannot authorize a deliberately retired alert. Both repos own their compatible models and tests; Mac adds lossless phone/tablet reminder presentation without location permission.

This milestone is not full location-reminder or Px completion. Native actions/categories, durable recovery between a task commit and private retirement, capable-device delivery/permission acceptance, every-visit mode, private desktop-to-phone authoring and broader accessibility remain open. `LOCATION_REMINDERS.md` and `p2-location-task-drafts-evidence.json` separate the implemented editor from those remaining gates. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — durable location cancellation handoff

The iOS task-cache writer now atomically saves pending location cancellations with the task change, including sync/recovery writes. Outstanding cancellations survive snapshot replacement and Undo; acknowledgement is saved only after private-journal retirement. Relaunch replays either side of that handoff idempotently. Missing private authority and unreadable authority are treated separately; unreadable files retain their jobs and suppress location admission. Both repos own compatible, validated optional outbox models and independent tests; Mac adds no native location service. No names/geometry enter the outbox, widget projection or portable workspace export.

Exact verification is recorded in `p2-location-retirement-outbox-evidence.json`. This closes the volatile task-to-private-retirement gap for process termination; it does not claim power-loss durability, native location notification actions, repeated visits, private desktop-to-phone authoring or capable-device delivery. The reviewed editor stays experimental and rank 5/Px remain incomplete. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — location notification actions and durable explicit snoozes

Connected iOS Open/Complete/Tomorrow/Snooze routing, strict native boundary/followup decoding, fresh protected-state validation and atomic mutation receipts. A separately versioned local time-snooze namespace shares time/Focus/location capacity, preserves its target while waiting, reserves before OS submission and recovers without silently replaying consumed/ambiguous opportunities. Snoozing a snoozed alert creates a new explicit intent without rearming its boundary. The row shows the saved snooze date/time. Both repos own compatible ledger/queue models and tests; Mac gains no native location service.

Native integration exposed that calling Start local in an already-open readable local workspace reset its session and cleared native alerts. Both Stores now make that call idempotent; real workspace changes keep their cleanup. Evidence and precise limits are in `p2-location-notification-actions-evidence.json` and `LOCATION_REMINDERS.md`. Region-delivery/OS-origin boundary acceptance, repeated visits, private desktop-to-phone authoring, public setup/accessibility and safe action-history reclamation remain open. Normal authoring remains gated and rank 5/Px are incomplete; user deferrals remain unchanged.


### 22 October — explicit every-visit location reminders

The isolated iOS reviewed editor now offers Every visit until completed, defaulting to off. Version 7/reference 2/r10 and native v2 receipts distinguish it from unchanged one-shot rows. Both repos independently own journal-3 recovery epochs, repeated-trigger retention, per-delivery replay keys, compatible explicit time snoozes and cancellation/Undo fences. Mac describes the phone/tablet choice without gaining a location service.

Evidence is in `p2-location-repeat-evidence.json` and the current section of `LOCATION_REMINDERS.md`. Simulator drafts, response fixtures and genuine native time snoozes pass; these do not establish real region delivery or background/locked/cold callbacks. Normal authoring remains hidden. Public setup, private desktop-to-phone authoring, accessibility and history reclamation remain open. Rank 5/Px and other documented P2 gates remain incomplete; user deferrals are unchanged.


### 22 October — explicit ended location-action cleanup

Added a confirmed maintenance action in the experimental iOS editor to clear receipts whose exact private intent is permanently denied. Ordinary writes still preserve missing receipts, and active/actionable/unknown/other-account histories remain protected. Both repos independently own the policy and tests; Mac adds no location UI/service. A retired private tombstone continues rejecting old responses after cleanup and task Undo.

See `p2-location-action-cleanup-evidence.json` and `LOCATION_REMINDERS.md` for native save-failure/retry, cancellation/replay and UI evidence. This recovers capacity from known retired actions; unknown/previous-installation history, active-repeat rollover and full private identity-reset recovery remain gates. Public authoring, capable-device delivery, desktop-to-phone authoring and wider P2 acceptance remain incomplete. User-deferred remote delivery, general older-client rollout, distribution and genuine OAuth provider work stay deferred.


### 22 October — recoverable private location reset

Added a confirmed whole-device private reset to the experimental iOS Places flow. It writes a fresh consent-off private identity and durable reset receipt before clearing old action records; normal hydration finishes cleanup after a failed cache save or relaunch. A private writer lock and identity revalidation prevent stale reset proofs from deleting newer receipts. Tasks and unrelated time/Focus alerts are retained; old references require review. Both repos independently own the private archive-3 format and policy; Mac adds no location service or reset UI.

Exact native process-loss, selected previous-reader, Core and screenshot evidence is in `p2-location-reset-evidence.json` and `LOCATION_REMINDERS.md`. This closes the explicit reset/capacity-recovery implementation gap, not public authoring or genuine physical delivery/permission/account-switch acceptance. Wider location/P2 work and all user deferrals remain open.


### 22 October — normal place-reminder setup preview

Normal iOS Notifications and task Reminders now link to central Place reminders setup. It provides explicit separate consent, actual device-capability/status feedback, saved-place/reset/history management and refresh after system settings. Capable devices expose reviewed task authoring as a preview; raw restored rows still cannot prepare alerts. Unsupported devices retain time delivery and can revoke existing private consent. Revocation write refusal has explicit session-only feedback and an off-retry action. Exact test-only producers remain separately isolated. Mac adds read-only phone/tablet setup guidance.

See `p2-location-setup-evidence.json` and the current `LOCATION_REMINDERS.md` section for normal Simulator navigation/no-write/large-text, real private-file lock refusal/retry, editor regression and Mac build scope. Positive capable-device permission/delivery/callback acceptance, spoken accessibility, private desktop-to-phone authoring and wider P2 work remain open; this does not complete rank 5/Px or reopen user-deferred release/remote/provider work.


### 22 October — durable ordinary snooze recovery

Closed the known in-memory waiting gap in the combined reminder queue: ordinary explicit time snoozes persist before admission, keep their chosen instant across restart, reserve durably before native submission and never replay an ambiguous/consumed installation. Revocation epochs and current task/workspace/occurrence checks protect cancellation and Undo. Both repos independently own the bounded local outbox, Store integration and regression tests; Mac refreshes now coalesce hydration/admission like iOS. `REMINDER_SNOOZE.md` and `p2-time-snooze-recovery-evidence.json` distinguish deterministic recovery/native capacity checks from real notification-action delivery, physical device, Mac live UI and reinstall/OS recovery acceptance. Wider Px and the existing user deferrals remain open.


### 22 October — reviewed malformed-checklist recovery

The organizer now reviews missing, malformed and duplicated child references, rekeys every ambiguous occurrence and converts explicit text-only legacy items without losing their words. Recovery stays in the draft until the existing Save flow; unknown structures stay intact with bounded original-data viewing/sharing. Preparation is cancellable and off the interface thread. Added guards against replacing unknown containers and ambiguous native Mac child paths. `CHECKLIST_RECOVERY.md` and `p2-checklist-recovery-evidence.json` distinguish implemented recovery and native/Core evidence from still-open Mac live interaction, spoken/concurrent/paired acceptance and arbitrary future-format recovery. This advances the rank-3 recovery gate; independent child records, non-completable headings, wider Px and user deferrals remain unchanged.


### 22 October — private desktop-to-phone transport foundation

Added an account-private, bounded place-draft protocol and deployed its unexposed table/RPC/retention migration. Authenticated project collaborators cannot read each other's private drafts. Fixed expiry, immutable retry contents, one-device review claims, terminal geometry removal and task-incarnation/access checks are covered by independent client and local/hosted SQL checks. Normal app code makes no upload or import call, and existing device-private places stay local.

`PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-transport-evidence.json` distinguish this foundation from the still-required native sending/review UI, durable private nonce, atomic task import receipts, relaunch/Undo recovery and paired-device acceptance. Mac gains no native location service. This does not complete desktop authoring, rank 5 or Px; real location delivery and all user-deferred release/remote/older-client/provider work remain open.


### 22 October — durable receiving commands and interrupted-save recovery

Both repos now own protected review-ticket persistence and a monotonic local import ledger. The iOS Store reserves the nonce before Claim, revalidates the server before a reviewed Save, saves a stable private pin, and atomically writes the task mutation with its receipt under the private writer lock. Normal hydration can finish an interrupted private-intent preparation only for that exact saved task and consent epoch. Task completion/removal/Undo, private reset and off/on consent changes prevent rearming. Finish acknowledgement retries preserve the original nonce and never repeat task creation; unavailable acknowledgement does not hide other drafts.

This closes the deterministic reservation/task-receipt/preparation recovery implementation gap. It does not expose sending or receiving screens, establish real Auth/PostgREST paired-device behavior, or prove a native geofence alert. `PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-recovery-evidence.json` record exact tested scope, bounded storage and remaining gates. Rank 5/Px and all user deferrals remain open.


### 22 October — native private place-draft handoff

Connected Mac saved-task authoring/search/map/review/send/status/pending-discard and the iOS signed-in Place drafts inbox with map review, Not now/resume, explicit Save and confirmed discard. No bulk place upload or permission activation. The receiving UI uses durable reservation/task-receipt/consent-epoch recovery; Mac retry keeps one immutable proposal. Native Simulator tests cover postponing/relaunch, failed Save/retry, missing Finish acknowledgement/relaunch and largest-text dark iPad discard. An isolated Mac app passes seven actual Store/Backend command checks; live Mac interaction stays unverified while locked.

`PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-screens-evidence.json` distinguish those client/fixture checks and form layouts from genuine Auth/PostgREST paired transport, physical geofence delivery and spoken/live Mac acceptance. Both app/extension builds and full Core suites pass; old Mac calendar-grid type inference was factored without changing behavior. All user deferrals, history-maintenance gates and wider Px remain open.


### 22 October — bounded share intake and Apple Maps compatibility

Automatic country holiday calendars remain the primary holiday source, with explicit country/year review and offline saved dates. Continuing the highest outstanding share-capture acceptance work uncovered an actual Apple Maps compatibility issue: its separate opaque preview previously rejected otherwise readable text and URL providers. Both apps now leave that exact ancillary preview unread, accept only its valid text/link companion, and explain the omission in review. Unknown attachments still refuse the whole selection. One 20-second provider budget spans every attachment; cancellation and late responses cannot revive a dismissed review. Neither mailbox version nor task schema changes.

`SHARE_CAPTURE.md` and `p2-share-provider-evidence.json` record the independent Core suites, real source-app checks and remaining native/account/accessibility gates. This increment does not close all of rank 2/Px or any user-deferred release, provider, older-client or remote-reminder work.


### 22 October — iPad share review and large-text acceptance

Actual iPad Apple Maps capture now passes from the source extension through editable review, save with Taskfold quit, host review, explicit Add and relaunch with one durable task/receipt. Normal light and largest accessibility text in dark appearance both pass; screenshots verify readable preview-omission text and reachable Save/destination/Add/Cancel. The same current test helper passes on iPhone. Both apps own nonvisual review-form identifiers so tests scroll the actual modal rather than the source app or background list. The Maps test now targets its exact place-card Share control and waits for onboarding, avoiding the unrelated Share My Location action.

`p2-tablet-share-evidence.json` records current source fingerprints, actual native results, failed initial onboarding/selector iteration and cleanup. Core/task/mailbox contracts are unchanged; this does not close cloud/offline/account-switch, live Mac or spoken-accessibility acceptance, all of rank 2/Px, or any user-deferred release/provider work.


### 22 October — genuine cloud share isolation and offline return

Two fresh real Auth accounts now pass actual iPhone Safari share intake, an open review across A → B, and offline Add across A → B → A. A stale review is refused without creating a draft/task in either account. An offline Add commits one private task/receipt and one pending command; the server remains empty while B is active. Returning to A sends exactly one task and drains its queue, with no remaining draft after relaunch. Independent authenticated server reads and private caches agree. The outage is an exact Debug-bundle/disposable-account URLSession failure, not a claim of physical airplane-mode acceptance.

Actual screenshot review found save errors hidden behind the keyboard. Both apps now pin source-share errors below the header; native visibility/keyboard checks are recorded in `p2-share-cloud-evidence.json`. Mac native sharing/VoiceOver and wider device/network variants remain open. The live endpoint inventory also uncovered a separate P0 account-removal gap; `ACCOUNT_REMOVAL.md` is now the next priority. No user-deferred release/provider/remote work is reopened.


### 22 October — account-removal service candidate and hosted rollback proof

Both repositories now independently own the authenticated, bounded, retryable server deletion candidate and matching migration/SQL fixtures. Twelve mocked-HTTP cases per repository and both local SQL suites pass; the exact candidate also passes against actual hosted guards in a fully rolled-back synthetic transaction. Another account's tasks/membership survive, shared comments retain anonymous attribution, and stale JWTs cannot upload/overwrite after removal starts. Both Core account suites pass 33 cases, including explicit completion acknowledgement and delayed account/session-switch rejection. `ACCOUNT_REMOVAL.md` and `p0-account-removal-service-evidence.json` distinguish these results from still-required deployment, genuine Auth/Storage/native deletion and current-device cleanup. No persistent hosted change or real account removal occurred; this P0 and the full Px objective remain open.


### 22 October — durable native account-removal recovery and scoped device cleanup

Both apps now save private retry authorization before deletion, retain confirmed progress for interrupted cleanup, bind confirmations to the opening workspace and erase only the confirmed account's device cache/queue, private places/receipts, sharing/widget state, calendar credentials and recovery backups/key. Pending edits/sync are fenced; delayed writers and a late accepted sign-in cannot recreate the deleted cache. A different active account stays signed in with its saved work. Definite authorization refusal can renew only the same account/server. Normal sign-out keeps its separate unfinished command. Accurate confirmation copy excludes user exports/other devices and explains anonymous retained shared history.

Three actual iPhone Simulator Store cases pass: failed reply/retry, held A response across A → B, and expired authorization/conditional renewal. Checks include real encrypted backup roundtrip and Keychain key deletion, outsider preservation, private pending widget publication and stale confirmation/reopen refusal. Both full Core suites pass (iOS 1,303 reported / 13 skipped / 0 failures; Mac 1,335 / 33 / 0), including 45 account/removal cases without skips; both full apps build. `ACCOUNT_REMOVAL.md` and `p0-account-removal-recovery-evidence.json` preserve exact scope and failed harness iterations.

Mac runtime reached the missing private-Keychain capability; enabling it requires a development profile deferred with signing. Existing fixture defaults stay unchanged, with explicit opt-in preparation for that future check. No weaker credential mechanism or Mac runtime pass is substituted. The service remains undeployed; real Auth/Storage byte cleanup and actual native confirmation UI/live-account tests remain required. Physical location delivery is deferred at the user's request; Simulator/Core work continues. No real account was deleted, and the full Px objective remains active.


### 22 October — reviewed account-removal UI and accessible recovery

Replaced the iOS destructive popover with a scrollable review and explicit Cancel, preserved deletion errors across intentional workspace dismissal, and made recovery available from Settings. Both independently owned apps use a concise adaptive recovery card; Mac's failed sheet retries the durable command. Final native Simulator acceptance: four phone cases (including actual VoiceOver) and one largest-text dark iPad case pass without failures/skips. Screenshot review found and corrected banner/navigation overlap before the final repeat. Both app builds pass; Mac runtime/profile and live server/Auth/Storage deletion remain open.

See `ACCOUNT_REMOVAL.md` and `p0-account-removal-ui-evidence.json` for exact synthetic scope, failed iterations, speech limits and cleanup. Test apps/runners are closed/uninstalled, VoiceOver is restored, and 386,741,583 logical bytes of obsolete artifacts are pruned. No real task/account or hosted configuration changed. Full P0/Px and all user deferrals remain unchanged.


### 22 October — deployed account removal and genuine iOS/server proof

Deployed the shared migration and endpoint once, with independently owned version-matched files in both repos and an explicit version-1 client requirement before privileged calls. Real Auth/Storage/REST deletion and original-token success retry pass; another account’s task/file bytes and anonymous shared history survive. A timed pending-account Storage request waits 4.2 seconds for the account lock then refuses. First-authorization/full endpoint race variants remain distinct and open.

A normal isolated iPhone Auth → Account review → live deletion → cache erasure → signed-out normal relaunch passes, followed by independent server/outsider verification. Both apps build; 45 account Core cases and 13 handler cases per repo, both local SQL suites and all three current native Store proofs pass. `p0-account-removal-deployment-evidence.json` records the exact scope, failed orchestration attempts and cleanup. All ten disposable identities/content and temporary credentials are gone; four completed hash receipts expire normally. Mac runtime/profile and genuine native network-fault variants remain open, alongside the wider Px backlog and all user deferrals.


### 22 October — real discarded-reply recovery and bounded review copy

Two genuine iPhone Auth → Account → server deletion cases now pass after deliberately discarding the first real success acknowledgement: visible Retry and an ordinary no-fixture relaunch. A separate server observer verifies deletion and outsider preservation while the complete native cache is still retained; both recoveries use the same original authorization and erase the cache only afterward. Both app builds and 45 Core account cases per repo pass. The final seven-day review wording also passes native Cancel/cache/relaunch inspection.

`p0-account-removal-lost-reply-evidence.json` states the client fault-injection scope, real backend checks, actual successful cron tick, separately aged/manual-cleaned receipt and cleanup. Late-expiry recovery of an unconfirmed attempt remains an explicit P0 gap; current code preserves local copies but cannot recover an already deleted Auth account after its receipt expires. Mac runtime/profile and wider fault/concurrency acceptance, the wider Px backlog and all user deferrals remain open. No backend configuration changed; all four disposable identities and temporary credentials are cleaned up.


### 22 October — note editing recovery and readable failure controls

The iPhone/iPad task editor now presents rejected durable saves inside its own
sheet, keeping the formatted draft open and retryable. Previously, a simulated
out-of-space write closed the editor behind the workspace-wide error alert.
The new native path confirms full-cache preservation on failure, exact draft
retention, successful Retry, unchanged other tasks and normal relaunch. An ordinary
formatted-note Save remains accepted. A failed write does not make the unsaved
draft durable across app termination; the successful retry is what reaches disk.

Both independently owned formatting views make the whole recovery warning
scrollable, keep Copy text outside that scroll area and dismiss the keyboard on a
refused Apply. Formatting tools yield space while a warning is present and return
when writing resumes. Current phone and largest-text dark iPad checks verify a
changed saved note cannot be overwritten by stale Apply, preserve the formatted
draft, keep Copy reachable before/after warning scrolling, and retain the newer
saved note through Cancel and relaunch. Screenshot review caught a clipped warning
and an inaccessible large-text Copy action before the final layout passed.

`p2-note-recovery-evidence.json` records five accepted native cases across the
scoped batches and both app builds, with exact source fingerprints and failed
iterations. The concurrent edit is a second synthetic Store action in one local
workspace, not real two-device sync. Clipboard activation, workspace switching,
Mac native editing/Undo/failure and spoken accessibility remain separate gates.
Full Px and all prior user deferrals remain active.


## Automation access — rank 6, task operations implemented as an inactive candidate

Both repos independently own credential management transport, private hashed-key
storage, get/list reads and create/update/complete/reopen/reviewed-delete RPCs.
The real HTTP handler connects those operations to actual guarded native SQL.
Scope names are implemented; the feature remains disabled and undeployed.
`AUTOMATION_API.md` defines the current protocol, limits and retry contract.

Verified account/session checks govern credential management. Task keys authorize
current account, scope, expiry, access and successful-operation budgets inside
the same transaction as effects. Permanent immutable request claims bind operation,
body hash and generation, reauthorize root and successor on replay, and roll back
with failed effects. No raw key or task body is stored in the journal.

Writes implement field-level conflict review, project/section/assignment checks,
recursive checklist preservation and separate progress capability, locked default
preferences, native-compatible recurrence/clocks and full reviewed cascade deletion.
Read revisions use a private HMAC secret. Portable relative/fixed/calendar/interval/
holiday reminders and Time Sensitive wrappers can now be authored and edited.
Future/private rows and extensions remain protected. Native-reader goldens and
actual writes cover the new formats; hosted acceptance remains required.

23 October verification: each repo passes 101 actual local mutation SQL assertions,
18 real loopback HTTP-to-handler-to-SQL assertions, 17 mocked handler tests, lint
and 49 selected native transport tests. Isolated iPhone build-for-testing and
unsigned Mac Debug build succeed. Earlier 316 date and 49 full-successor goldens
remain the recurrence evidence; historical milestone files retain their snapshot
context. Current checks do not prove hosted TLS/Auth/PostgREST, every production
trigger, cross-connection races, native screens or release installation.
A read-only hosted metadata check confirms no candidate migration, private key/
journal/revision-secret table, task RPC or automation Edge Function is deployed.

Next required, in order:

1. Finish hosted native management and lifecycle/accessibility acceptance. Both
   apps now implement the gated premium screens, one-time hidden/reveal/copy review,
   app-only device Keychain recovery and revoke/paging/workspace-safe cancellation.
   Both apps now persist discard intent before a cancellation request and cannot
   resume creation after reply loss/relaunch. The service either revokes an owned
   existing key or permanently blocks late creation for the account/ID. Stable
   empty lock files coordinate private recovery across processes; an exact prior
   private reader refuses the new discard state. Each repo passes 74 Core checks,
   including real independent-process lock tests, 55 cancellation SQL assertions,
   the credential regression, 101 mutation/18 loopback checks and ten management
   handler tests. Current three-scenario Simulator results and exact limits are in
   `p2-automation-enrollment-cancellation-evidence.json`. Mac Keychain/UI/clipboard acceptance remains deferred with signing. Local iPhone/iPad clipboard acceptance passes four UI cases; both repo-owned server sources now pass 80 hosted lifecycle/deadline checks. Native signed-in phone/tablet hosted management remains next. No candidate is
   enabled or deployed. The normal entry stays hidden.

2. Project/section discovery now implements read-scoped current-access paging,
   archive availability, native order and hidden-parent privacy. Each repo passes
   72 actual destination SQL assertions, the existing 101 task-mutation checks,
   25 real loopback HTTP assertions and 21 handler tests/lint at that checkpoint.
   Portable advanced-reminder validation now follows in the next candidate: 131
   native-reader goldens, 221 portable SQL assertions, 101 mutation and 31 loopback
   assertions plus 170 selected Core tests pass per repo. Private location markers
   stay behind native private-place review. Next: rejected-request controls and
   hosted acceptance, without reopening user-deferred work.
3. Rejected-request admission now covers both handler entry points with independent
   task/management global, IP and full-credential budgets. Each repo passes 157
   admission SQL assertions, 140 real loopback checks, 40 Deno tests and lint;
   existing 221 portable/101 mutation regressions pass. Its explicit IP trust mode
   stays unset. The hosted proxy check now passes: use the first XFF address only
   when it matches CF-Connecting-IP; the old last-hop mode is retired. Real local
   PostgreSQL 17.6 contention passes 20 checks per repo, including 12-connection
   final-slot races and actual advisory-lock timeouts. Local task-effect races now
   pass 99 additional real PostgreSQL checks per repo, including actual HTTP
   contention/retry behavior. Real hosted Auth/Edge/PostgREST lifecycle now passes 42 checks from each repo-owned source. Next: native signed-in phone/tablet hosted management with disposable users; Mac runtime remains deferred with signing. Function-level admission does not close provider-level
   invocation billing or network protection.
4. Verify signed-in phone/tablet and scoped Mac flows, then deploy the coherent
   gateway/client together. No user release-signing or physical-location gate is reopened.
5. Continue idempotent email intake, verified sender/recipient permissions, signed
   webhook retries, advanced teams and the remaining wearable backlog.

Current native/cancellation hashes and limits are in
`p2-automation-enrollment-cancellation-evidence.json`; the mutation milestone
retains its separately scoped SQL/HTTP proof.
The original full Px goal remains active. All user-deferred work stays deferred.


23 October destination checkpoint: the candidate remains disabled and undeployed.
The 92 selected Core checks per repo include automation transport, location draft,
region engine and notification admission contracts. They are local Core tests,
not positive OS region registration/delivery or a fresh Simulator UI walkthrough.
The user deferred physical-iPhone delivery again; continue available Simulator work
without reopening that gate. Exact scope and fingerprints are recorded in
`p2-automation-destinations-evidence.json`. All other user deferrals remain intact.


23 October portable reminder authoring: all implemented portable schedule kinds
now support API create/edit/remove, including nested child reminders. Current
field-level merge semantics preserve disjoint stale edits and refuse overlapping
ones. Unknown/private rows remain exact, and extension values cannot be dropped
while changing a supported row. Reminder recurrence and task recurrence remain
separate; root and child successors preserve independent schedules and drop only
fixed absolute reminders, matching native behavior. This does not deploy/enable
the API, fetch provider calendars or prove OS delivery. The 170 Core checks are
native-reader/scheduling contracts, not a new Simulator UI walkthrough. Evidence:
`p2-automation-portable-reminders-evidence.json`. The full Px goal stays active.


23 October admission checkpoint: durable admission commits independently of task
failures, with short-lived HMAC-only counters, bounded pruning, route-separated
capacity and negative-only worker caches. Invalid/malformed requests are charged
before validation; cached denials never grant access. Production entry points use
the gate by default, and unknown proxy configuration fails closed. No hosted
candidate was applied/deployed; the explicit forwarding mode is not yet verified
or enabled. Local fixed-clock SQL and controlled loopback results are scoped in
`p2-automation-ingress-evidence.json`; real multi-connection races, upstream trust,
hosted native/clipboard acceptance and full Px remain open. User deferrals persist.


23 October hosted-ingress checkpoint: the signed, expiring diagnostic verified the
production matching-header extractor from two network sources and was deleted.
It rejected the unstable final-hop assumption; no previous forwarding mode had
been enabled. Actual mode configuration, automation endpoints and all nine
candidate migrations remain absent. Both repos now own the authenticated probe,
its six tests and a digest-pinned PostgreSQL 17.6 independent-connection runner.
Each passes 20 real contention checks, the existing 221 portable/101 mutation/
140 HTTP regressions, 46 Deno tests and lint. Test databases were removed and the
initially stopped Docker runtime restored. Evidence and limits:
`p2-automation-hosted-ingress-evidence.json`. This closes the observed header
contract and local admission-contention checks; it does not close task-effect
races, hosted Auth/PostgREST/timeout/native/clipboard acceptance or the full Px goal.


23 October task-operation contention: each repo independently passes 99 actual
PostgreSQL 17.6 checks, 221 portable/101 mutation/140 HTTP regressions, 48 Deno tests
and lint. Real controlled blockers prove requests overlap before effects. Native
identity coordination remains unchanged; transient contention now exposes a safe
one-second retry hint. An actual deadlock rolls back the waiting edit; its exact
retry refuses the replaced generation. Root/child deletion review and all three
successful-operation quota layers remain atomic. Owned databases and HTTP hosts
were removed and Docker restored to Off. No new app host was launched.

A nonpersistent, data-excluding Supabase acceptance branch has been created:
`859b1e42-dac6-494a-be4d-df279d914853` / project `ntbwkyhruxepackrxpph`.
Its compute is healthy (PostgreSQL 17.11), but historical migration replay is
`MIGRATIONS_FAILED` after version `20251203213110` (28 applied). The next main
migration is `20260911123547` / collaboration_foundation. No new automation
migration or test account has been applied there. Diagnose and repair that staged
replay before hosted tests; delete the acceptance branch after testing and never
merge it into main. Keep all branch credentials outside Git and chat. The main
project remains PostgreSQL 17.6 with zero automation candidates applied.

`p2-automation-task-concurrency-evidence.json` records actual local proof and the
separate staging state. Full Px and all user deferrals remain active. Hosted
Auth/PostgREST/timeout/native/clipboard work remains required; local proof does
not close those gates.


23 October hosted lifecycle checkpoint: the empty acceptance branch recovered
from its historical replay failure. The branch-only repair recreated the owner
insert policy, restored the six original tables' recorded CRUD grants and kept
the repaired migration's original identity. Its own collaboration verification
passed; rebase then applied all 82 main migrations. All nine exact automation
candidates applied on that branch only (91 entries total). Main is unchanged.

Each repo-owned hosted runner independently passes 42 checks through real Auth,
Edge Functions and PostgREST: enrollment/retry, cancellation before and after
creation, account isolation, service-wrapper protection, scoped access, paging,
task CRUD/completion/reopen, exact replay, sign-out and revocation. Temporary
endpoints and users were removed; SQL confirms zero test users/tasks/keys/journal
rows. The acceptance branch is deleted and its private connection export removed. Final cleanup
state and exact limits are recorded in `p2-automation-hosted-lifecycle-evidence.json`.
This supersedes the earlier staging-failure status; native UI, Keychain/clipboard
and hosted timeout/cancellation gates remain open. Full Px is not complete.


23 October native clipboard checkpoint: two actual UI scenarios pass on each of
the iPhone and iPad Simulators (four passes, no failures or skips). They copy
through the real view, observe the production one-minute OS expiration, preserve
a later synthetic clipboard entry, hide the revealed key after background/return,
and finish/relaunch without setup recovery returning. The clipboard probe is
DEBUG-only, restricted to the exact disposable local fixture and an additional
explicit flag. It reports fixed states, never clipboard/key contents, and clears
only its own replacement sample. The actual Simulator Keychain remains in use;
metadata HTTP uses the existing owned fixture. Both app targets build.

`p2-automation-native-clipboard-evidence.json` records the exact results and limits.
Mac private-Keychain/runtime is still deferred with signing; the Mac compile is
not a runtime pass. Next independent work: hosted timeout/cancellation and the
remaining automation intake backlog. Native management against a hosted service
remains required before coherent API/client enablement. No release/provider/remote
or physical-location dependency is reopened. Full Px remains active.


23 October deadline and uncertain-result checkpoint: each repo-owned hosted source
passes 80 checks. Actual PostgREST management/task write statement timeouts fire
at approximately ten seconds and roll back their key/task/journal effects. A
known account lock produces a management refusal after approximately three
seconds, with no key; exact retry creates one. Private deadlines and service-only
wrapper permissions were read back. All 53 Deno tests, 55 cancellation SQL,
221 portable/101 mutation/140 local HTTP checks and lint pass per repo.

The hosted gateway did not roll back either controlled client-disconnected write:
both committed. Retrying the same key ID/task request recovered exactly one
effect. Key management now propagates caller cancellation to Auth/RPC and bounded
response readers; uncertain write copy explicitly preserves the retry identity.
The tenth inactive candidate sets management-only lock/statement deadlines. No
main migration, endpoint or normal native entry was enabled.

The empty, nonpersistent acceptance branch is retained for the immediate next
phone/tablet native hosted check: `faa2f628-7c48-4db5-b57a-218672229442` /
`janyfroruofnmpxvhwfn`. All temporary endpoints and synthetic users were removed;
SQL confirms zero users/tasks/keys/journals/deadline controls. Its private CLI
connection export stays outside Git. Delete the branch after this next acceptance
work; never merge it. No app host was launched this turn. Exact proof and limits:
`p2-automation-timeout-evidence.json`. Full Px remains active.


23 October signed-in native hosted checkpoint: both iPhone and iPad pass two UI
scenarios each (four passes, zero failures/skips) through real Auth, canonical
Edge Functions and PostgREST with the normal Store/Backend/Simulator Keychain.
Ordinary cold relaunch preserves sign-in and recovers the same private enrollment;
acknowledgement removes pending recovery, revocation persists, and A → B → A
keeps unfinished setup with its owning account. Independent hosted readback passes
eight checks, requiring exactly two new A keys per device, zero B keys and every
key revoked. One earlier fully revoked tablet key is an explicit baseline, not a
retry duplicate. Final harness refinements handle only tablet system-password
interruptions, scrolling and navigation; production app sources did not change.

The retained acceptance branch is now deleted (absence verified), canonical test
endpoints/users removed, and SQL confirms zero users/tasks/profiles/keys/journals/
deadline controls. Private native credentials and the connection export are
removed. This supersedes the preceding retained-branch checkpoint. Exact native
results, harness hashes, failed iterations and limits are recorded in
`p2-automation-native-hosted-evidence.json`. Mac signing-dependent private-Keychain/
runtime remains deferred. Main API/migrations and the ordinary native entry stay
off. Next independent feature work is webhook delivery, followed by verified email
intake, advanced teams and wearables; full Px remains active.


23 October webhook transport checkpoint: each repo independently passes 11 local
tests (seven TLS/HTTP substeps), lint/types/format checks and nine actual hosted
checks. Delivery pins a checked public IP, then upgrades that socket with the
original TLS hostname; signed bodies, bounded responses, retry hints and encrypted
receiver-secret envelopes work in the hosted runtime. A locally passing Node HTTPS
approach was rejected after hosted handshake failure; the direct path replaces it.
No native app UI or production schema changed. The temporary branch and private
acceptance token are removed, and main has no webhook endpoint or migration.

This completes the transport foundation only. Next: authorized subscriptions,
recipient verification and a durable task-change outbox/dispatcher, then native
setup, delivery status and recovery controls. Full automatic webhooks and the
remaining email/team/wearable backlog are still open. Complete requirements and
limits: `WEBHOOKS.md`; exact proof: `p2-webhook-transport-evidence.json`.


23 October webhook subscription checkpoint: private account-bound setup and
receiver-secret proof are implemented independently in both repos. Echo endpoints
cannot connect; verification needs an HMAC proof not present in its request.
Fresh session/project checks, expiry, superseded attempts and revocation guard
activation. Setup/discard history is permanent for the Auth lifetime; removal
blocks survive receipt pruning and physical Auth deletion cleans the private rows.

Pause/Resume now has a revision baseline and durable command identity. A delayed
old Pause retry cannot override a newer Resume. Per-source checks pass: 83 SQL,
43 actual PostgreSQL 17.6 assertions with eight observed barriers, and 26 Deno
tests (seven TLS/HTTP substeps), plus lint/types/format. Main schema/endpoints remain
off. These scoped local checks do not replace hosted Auth/PostgREST/receiver or
native UI acceptance. Temporary databases/TLS files are removed; Docker stays on
because it is serving another project. No Taskfold host was launched.

Next: the actual task-change outbox and leased dispatcher, including large-task
payloads, current-permission revalidation, retries and failure history; then native
setup/status/recovery and hosted acceptance. Full webhooks/Px remain unfinished.
Details: `WEBHOOKS.md`; evidence: `p2-webhook-subscriptions-evidence.json`.


23 October webhook outbox checkpoint: each repo now owns transactional capture,
immutable complete snapshots/multipart frames, bounded per-subscription queues,
leases, final after-TLS authorization, dispatcher, retry/history APIs and payload
retention cleanup. Local source checks pass 143 SQL assertions, 35 actual PostgreSQL
17.6 assertions with five observed barriers, and 40 Deno tests/eight TLS substeps.
Task edits remain responsive during outstanding network leases; old workers cannot
acknowledge a recovered lease, and lost access/removal blocks final sending.

No real tasks changed and no remote schema, endpoint or scheduler was deployed.
Owned PostgreSQL containers/TLS fixtures are removed. No Taskfold app was launched;
Docker remains on for unrelated workloads. Next: native setup/status/recovery UX
(including quota-gap guidance), secure scheduling and hosted end-to-end acceptance.
Full webhooks/Px remains active; email intake, advanced teams and wearables follow.
See `WEBHOOKS.md` and `p2-webhook-outbox-evidence.json` for limits and exact proof.


## Native task connections — 23 October (acceptance in progress)

Each app independently owns a gated **Task connections** screen in Account.
Setup reviews a receiver name/address, Inbox/one-project/all-accessible reach,
event choices and expiry, with explicit trust consent before creating a setup.
The review explains full-note/checklist delivery, shared work included in broad
scope, and bounded paused capture. The receiver secret starts hidden, can be
revealed/copied with device-only clipboard options, and is retired after explicit
save acknowledgement. Receiver verification is a separate action; setup alone
never means connected. Pause/Resume and Revoke have their own controls, with
revocation confirmation explaining the in-flight request boundary.

Interrupted setup is retained exclusively in an app-private secure-item envelope,
coordinated across processes. Exact settings/ID/secret retry, durable discard
before cancellation, original-server binding and account-removal cleanup are
implemented. View/workspace/backend-session leases fence late results; inactive
root and modal screens cover private content. One unfinished setup per account
prevents competing windows from silently replacing a secret.

Delivery history pages only redacted metadata. It shows status, part progress,
attempts, last issue, optional event/task references and reviewed manual retry.
Uncertain state/retry actions preserve their command identity until retry or an
explicit reload of server state. Queue-gap warnings explain that missing changes
require fresh task reconciliation by the receiver; Resume cannot replay them.
Counts are cumulative. There is no automatic resync or warning-dismissal claim.

The native client uses its fixed account server, authenticated session fence,
no cookies/redirects, no-store policy, a 25-second request timeout and a 256,000-byte
response bound. No native app receives service/master/worker credentials. Both
ordinary entries remain off behind a separate `TaskfoldWebhooksEnabled` gate.
Local source checks and Simulator view fixtures do not prove hosted receiver
integration, OS Keychain recovery or Mac runtime behavior. Secure scheduling and
hosted/native end-to-end acceptance remain required before enablement; full
webhooks and the remaining Px backlog stay active. Exact verification is recorded
in `p2-webhook-native-evidence.json` after this milestone’s checks.


Native checkpoint verification: 44 focused Core tests pass per owned repository;
11 webhook cases were rechecked after the final wording change. Both complete app
inputs build. Four scoped UI tests pass on iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: reviewed setup/secret/verification and failed-delivery retry,
plus largest-text dark Cancel. The phone now scrolls from secret acknowledgement
to its connection. Final screenshots are visually reviewed; toolbar labels fit
ordinary phone width. These are synthetic in-memory service/storage checks, not
hosted or OS Keychain acceptance. An unrelated recovery banner in the unsigned
Store host remains outside this accepted scope. Clipboard expiry, spoken checks,
live account/relaunch/Keychain and native Mac runtime remain open.

Both disposable Simulator apps and runners are closed and uninstalled. About
1.05 GB of redundant artifacts from these attempts is removed; current useful
build caches, final accepted results, screenshots and text logs are retained.
No real tasks or hosted services changed. Main webhooks stays disabled. Next:
genuine private-storage/native service acceptance and secure hosted scheduling/
delivery checks, then email intake, advanced teams and wearables. Evidence:
`p2-webhook-native-evidence.json`; full Px stays active.


## Signed private-storage recovery — 23 October

The opt-in native check now uses the production `Backend.webhookReceipt`,
URLSession and `Store.webhookEnrollmentVault` with the actual private OS Keychain.
The synthetic HTTP peer intercepts only the fixed owned test URL; its persistent
file contains metadata and one-way intent hashes, never receiver secrets. This
extends the earlier in-memory view check rather than substituting a mock vault
for recovery. The ordinary feature entry remains disabled.

Eight scoped checks pass across signed iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator. Lost-create recovery keeps the same setup ID, settings and
secret across a process restart and creates one connection. Saved acknowledgement
and revocation clear the private draft across a fresh successful read. A durable
discard survives a lost cancellation reply; another fixed account cannot see it,
and returning to the first account restores Retry discard. A final restart after
retry has no setup. Signatures and embedded Simulator application/App Group
identities are verified with the existing development certificate.

The correctly signed host also has no account-removal recovery banner. The banner
visible in the historical unsigned screenshots is not a product-state acceptance
finding. Both independent app inputs build; no Mac runtime or hardware Keychain
security is inferred from Simulator tests. Live Auth account changes and hosted
receiver integration are still unaccepted. Exact proof and limits:
`p2-webhook-keychain-evidence.json`.

The disposable Simulator apps/runners are closed and removed. Superseded owned
source/results are pruned; useful current caches and accepted results are kept.
No real tasks, hosted services, release signing or device privacy settings changed.
Next: secure hosted scheduling and end-to-end native Auth/webhook delivery, plus
remaining clipboard/spoken checks. Full webhooks/Px and the email/team/wearable
backlog remain open; user release/provider/reminder deferrals stay in force.


## Hosted delivery acceptance — 23 October

All 61 checks pass independently for each repository’s service source. Format,
Node syntax and receiver Deno type checks pass. No native app build was needed
for these diagnostic-only additions.

The owned diagnostics now exercise actual password Auth, scoped task writes,
Edge management, PostgREST, private outbox capture and pinned TLS delivery on a
no-data disposable preview branch. Both repositories own their runner, receiver
and SQL fixtures. The receiver checks exact HMAC bytes, stable message IDs,
immutable retries and absence of native Authorization/API-key/cookie headers.

The runner covers create/update/complete/reopen/delete, full Unicode multipart
notes and checksum reassembly, pause/resume replay, retry/backoff, sign-out,
receiver refusal and explicit recovery, pending versus accepted project access,
membership removal, retained owner access and account-removal cancellation.
Project memberships are service-seeded synthetic fixtures: invitation acceptance
through the native app is outside this milestone. Branch history lacks the
main database's independently installed native base, so a guarded fixture bridge
supplies inspected base fields/grants/helpers. Common feature migrations from
6 October onward are hashed unchanged; earlier platform histories differ.

Run `prepare-webhook-hosted.mjs <owner-private-connection-json> <schema-receipt>`,
then `test-webhook-delivery-hosted.mjs <connection> <receipt> <result>` from this
repository's Scripts/Diagnostics. Setup checks API and database hosts against the
same owned, nonpersistent, no-data branch and refuses main. The runner deploys
only the five test functions, uses random ephemeral secrets and synthetic users,
and removes them in finally. Delete the owned preview branch afterward and remove
the private connection file. Do not run overlapping tests on the same branch.
The private JSON uses Supabase branch connection fields SUPABASE_URL,
SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY and POSTGRES_URL; never commit it.

This is hosted service acceptance, not an app-native UI walkthrough or secure
scheduled invocation. Main schema, endpoints and ordinary app feature gates stay
disabled. Secure scheduling, native hosted account/relaunch acceptance and the
remaining clipboard/spoken checks are next. Remote-reminder, old-client and release
signing/distribution deferrals are unchanged. Full webhooks/Px remains unfinished.
Exact results and limitations: `p2-webhook-hosted-delivery-evidence.json`.


## Signed automatic dispatch — 23 October

Both repo-owned service copies pass 73 hosted checks, including actual minute
dispatch, one-use proof admission, transport health and no delivery on the next
tick after disable. Each also passes 42 local SQL checks and 45 worker/transport
tests (8 real TLS steps). Main remains unchanged.

The candidate `20261023074744_webhook_scheduler.sql` owns a disabled minute
job and operator-only configuration/state. No migration enables delivery.
The scheduler resolves `taskfold_webhook_worker_token` from Vault at each tick,
binds its HMAC to the project, timestamp and random nonce, and enqueues only a
90-second signed proof. The Edge worker verifies it before service-only atomic
admission; a consumed nonce cannot start another run. Disable/reconfigure clears
pending proofs. An already admitted worker may finish its bounded run; use
subscription pause/revoke for the existing per-delivery authorization fence.
The existing private bearer path remains for trusted operator
invocation, but the cron request never contains that reusable credential.

This design accounts for a hosted platform constraint: pg_net's queue/result
objects have PUBLIC grants owned by supabase_admin. A postgres REVOKE reports
success with a warning but cannot remove those grants. They are not exposed by
the Data API by default; do not expose the net schema or grant untrusted database
login access. A copied signed tick cannot change the destination, extend its
validity or bypass its one-use admission. SQL login roles remain a trusted
infrastructure boundary. See Supabase's [pg_net permission guidance](https://supabase.com/docs/guides/troubleshooting/revoking-access-to-pg_net-objects-has-no-effect-0bbc16).

Only the database operator can call configure_webhook_scheduler(project_ref,
true/false). Enabling requires the matching dedicated 64-character lowercase hex
worker credential in Vault and the Edge worker environment. Disable requires no
credential. The job uses a fixed HTTPS Supabase dispatch path, a 60-second network
timeout and a 55-second enqueue interval floor; durable outbox leases protect
actual delivery. State retains request ID, queue time and prior transport status,
never response bodies or task content. A network timeout is not a delivery receipt:
inspect per-event history for confirmation. Health is refreshed on the next tick;
it can lag by a minute, and pg_net response retention is finite.

Use the existing hosted runner's fourth argument `--scheduler` to test actual
minute dispatch and the next disabled tick, in addition to the full delivery
suite. It generates its credential inside Vault without a secret SQL literal,
arms only the owned no-data branch, then disables cron and removes the credential
in finally. Clean the branch afterward even if a run is interrupted. Ordinary
native feature entries and the main service remain disabled pending native
hosted acceptance. No reminder scheduler or deferred release capability is armed.
Exact results and limits: `p2-webhook-scheduler-evidence.json`.


## Native hosted receiver acceptance — 23 October

The signed iPhone/iPad Simulator app now exercises real password Auth, the
production Store/Backend transport and private OS Keychain, the hosted receiver
proof, native task capture, signed minute dispatch and the real history response.
The controller configures the app-generated receiver secret through an owner-only
local channel. It never supplies a mock UI response or intercepts app HTTP.
Normal relaunch keeps the same unfinished setup; acknowledgement, verification,
delivery history and revocation complete through the actual service. Switching
A → B → A hides A's unfinished setup in B and recovers it only in A.

Four scoped native cases pass across iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: one delivery/relaunch and one account-isolation case per device.
The controller confirms both exact native-created task titles at the HMAC-checked
receiver. Phone and tablet runs are sequential because this disposable receiver
uses one configured secret at a time. The final tablet screen also confirms the
wording fix: “1 of 1 part · 1 attempt”. Both independent app inputs build.

This round uses the iOS app and iOS-owned service source. It is not Mac AppKit
runtime or hardware Keychain acceptance; that remains deferred with signing.
Nor does ordinary successful-create relaunch prove genuine native HTTP-loss,
offline, token-expiry or master-key recovery. Earlier lost-reply Keychain checks
used a synthetic HTTP peer and remain separately scoped. Those native fault
variants and clipboard/spoken checks remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Main schema, endpoints and ordinary feature gates stay disabled; no real tasks
or deferred reminder/distribution capabilities changed.

The no-data branch's recorded web base omits native table grants. The fixture
bridge now mirrors the inspected main CRUD grants on tasks/projects/memberships,
sections/profiles/labels; it changes no RLS policies and never runs on main.
The temporary apps/runners, accounts, functions, Vault worker credential and
preview branch are removed after proof. Typed-password action logs are redacted;
raw Xcode result archives are pruned after exporting summaries and safe images.
Exact scope, versioned runs, source hashes and cleanup:
`p2-webhook-native-hosted-evidence.json`.


## Native clipboard and spoken secret review — 23 October

Six scoped cases pass: three each on iPhone and iPad Simulator.

The receiver-secret Reveal and Copy controls now use independent button targets
inside the Form. Previously, tapping Copy could also activate Reveal and expose
the raw value in the accessibility tree. The regression checks both directions:
Reveal must leave the clipboard untouched, and Copy must keep the value masked.
Backgrounding conceals a revealed value; continuing setup requires another
explicit Reveal.

The local acceptance host uses a synthetic in-memory service and enrollment
vault. Clipboard and VoiceOver observations use the real Simulator OS services,
not substitute clipboard or speech implementations. The Debug-only probe is
restricted to exact isolated bundle IDs and explicit test arguments. It observes
the real one-minute expiry, preserves newer clipboard content, and reports only
fixed outcome strings. It never exports a receiver secret.

The spoken check traverses the masked value and Reveal/Copy buttons with the
actual VoiceOver service, activates Copy, and revisits the updated Copied control.
This verifies its spoken label; it does not claim an automatic announcement on
label change. The test restores VoiceOver's original state afterward.

This is separate from the earlier hosted Auth/receiver/Keychain acceptance.
Mac source has the same button fix and compiles independently; Mac pasteboard
and spoken runtime acceptance remain open. Hardware clipboard handoff, native
HTTP-loss/offline/token-expiry/master-key recovery, and the wider consent/history
spoken walkthrough remain outside this round. Normal feature entries and main
webhook schema/endpoints remain disabled. Exact results and cleanup:
`p2-webhook-clipboard-speech-evidence.json`.


## Hosted native recovery acceptance — 23 October

Two scoped native cases pass, one per device. The tablet retry keeps the exact
saved intent after an interrupted UI run; the hosted fingerprint stays unchanged.

This runtime/controller round uses iOS-owned app and diagnostic inputs. The
commands below describe that iOS verification; Mac runtime remains unaccepted.

The isolated native recovery runner now covers a committed create whose reply
never reaches the enrollment model, a retry during a controlled webhook-service
outage, and normal recovery after terminating/relaunching the app. The successful
create is real HTTPS through Auth, Edge and PostgREST; the Debug-only hook throws
`networkConnectionLost` after decoding that actual account-bound receipt. It does
not replace the API with a fixture peer. The outage hook refuses webhook calls
locally before sending; ordinary Auth and task sync still use their real service.
These are controlled client fault injections, not physical radio loss or a TCP
reset at the server. Both hooks require an exact isolated bundle, explicit flags,
a disposable UUID email account and a non-main Supabase origin. They are absent
from Release. The fault proof contains only account/setup UUIDs and a boolean.

A private controller inspects the hosted subscription at commit, after the
outage and after normal retry. There must be exactly one subscription for the
disposable account, with the same ID, revision, settings, encrypted secret,
creation time and expiry. Receiver proof and an actual native-created task then
exercise the recovered secret through scheduled delivery, native history and
revocation. The Mac app owns its matching hook source and builds independently;
Mac Keychain/AppKit runtime acceptance is still deferred.

The existing `--native` mode continues to require its four normal delivery and
account-isolation cases. `--native-recovery` instead requires the recovery case
on both phone and tablet, using the same guarded no-data branch setup, private
controller files, signing helper and cleanup procedure. Run
`testHostedWebhookLostCreateResponseRecoversAcrossRelaunch` sequentially on both
devices before finishing that controller.

The walkthrough also exposed a presentation follow-up: an error notice can sit
above the automatically scrolled pending setup. Bring new failures into view
before enabling this feature; that round explicitly scrolled to inspect it.
The persistent-feedback milestone below resolves this presentation issue on iOS;
Mac source compiles but its runtime acceptance remains open.
Session-expiry recovery, server master-key failure/recovery and the wider
consent/history spoken walkthrough remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Remote reminders, older-client safeguards, distribution/OAuth registration and
physical location acceptance remain deferred. Main schema/endpoints and normal
feature entries remain disabled. Exact outcomes and cleanup:
`p2-webhook-native-recovery-evidence.json`.


## Persistent connection feedback — 23 October

Eight scoped iPhone/iPad Simulator cases pass on the final source. Actual
VoiceOver reads the pinned failure after scrolling, and its original Off state
is restored. Screenshots at largest text and in history were visually reviewed.

Connection-action and delivery-history errors now sit below the navigation bar
in a safe-area banner, outside the scrolling form/list. Pending-setup restoration
and ordinary scrolling cannot move the message offscreen. The banner reserves
space instead of covering the retry/review controls, uses system text/background
styles, wraps at large text sizes, and exposes the message as one readable text
element. Only the decorative icon has a size cap; message text keeps the full
accessibility scale. History uses an explicit compact title on iOS. There is no programmatic keyboard or VoiceOver focus change.

Successful retry or reload removes the banner through the existing model state.
Unconfirmed setup still says its draft was kept; history/control errors without
a pending setup instead ask the user to reload the latest status or retry the
same action. This does not claim that an unconfirmed request failed on the server.
The enrollment, secret-review and idempotency contracts are unchanged.

The local Debug fixture deliberately loses two create replies after storing one
in-memory row, then succeeds, and refuses the first history load before recovery.
It requires the exact isolated bundle, local test mode and explicit notice flag.
It does not exercise hosted Auth, HTTP, Keychain or server recovery; those results
remain in the earlier hosted evidence. This round accepts presentation only.
Mac owns the same view/model change and compiles independently; Mac runtime,
automatic spoken announcements and the wider spoken walkthrough remain open.
Normal feature entry and main webhook service remain disabled.

Exact layout/retry checks, source revisions and cleanup:
`p2-webhook-notice-evidence.json`.


## Independent key-review actions — 23 October

Four scoped cases pass on the corrected source: two each on iPhone/iPad
Simulator. The unchanged baseline failed before the button-style correction.

The API-key review row now gives Reveal/Hide and Copy independent borderless
button targets in each app. The unchanged iOS baseline failed the strengthened
regression: tapping Reveal started the clipboard probe. This confirmed that the
Form row could invoke Copy as well. The fix changes only that row's button style;
it preserves enrollment, permissions, secret storage and clipboard policy.

The native regression now requires Reveal to leave the clipboard probe untouched,
backgrounding to conceal the raw value after an actual background/suspended state,
and Copy to leave every accessible label/value free of the raw key prefix. It
rechecks masking after the real one-minute pasteboard expiry or preservation of
newer clipboard content. Acknowledgement and normal relaunch still check actual
private OS Keychain cleanup. The API peer is synthetic and exact-host guarded;
these runs issue no hosted credential and modify no real task or account.

The earlier clipboard milestone did not assert action independence or masking
immediately after Copy. Its historical green results therefore do not prove those
properties. This round's scoped outcomes and baseline failure are recorded in
`p2-automation-review-controls-evidence.json`. Mac source builds independently;
Mac gesture/pasteboard/Keychain runtime acceptance remains open.
Normal feature entry and main API enablement remain unchanged and disabled.
The full Px objective and its existing user deferrals remain in force.


## Hosted session and encryption recovery — 23 October

Both independently owned server sources pass 50 hosted checks each, plus 29
handler/dispatcher tests each. Cleanup readback confirms zero synthetic users,
tasks, subscriptions and queued events, no owned functions or secrets, and an
inactive scheduler; both preview branches and private connection files are removed.

The hosted delivery runner now supports `--service-recovery` in each repository.
It uses that repository's handler, dispatcher and migrations on a separate,
non-persistent preview with no copied data. Temporary fault entrypoints use the
real factories with an empty master catalog or a one-bit change to each master.
They require the exact acceptance project at runtime. Production sources gain no
fault flag, and normal app entries and the main service stay disabled.

The runner expires a disposable account's actual server session through its
`not_after` value. List, create and revoke must refuse the existing token; a new
password sign-in must reconfirm the same enrollment without replacing its
ciphertext, identity or expiry. This checks server session expiry, not elapsed
JWT lifetime, native refresh-token handling or a user-facing reauthentication flow.

Missing and incorrect masters must refuse receiver verification, preserve the
pending enrollment and keep authenticated metadata/cleanup available. Restoring
the original master must finish the same unexpired verification attempt. New
creation with no master must leave no row, and discarding it must remain possible.

For delivery, each fault defers one actual task event for the real five-minute
backoff without contacting the receiver. History must show a pending event and a
safe configuration issue, with no task text. Pause/resume keeps the event's payload
fingerprint, and the normal dispatcher must not immediately release the queue.
The runner waits for the original real deadline;
the normal dispatcher must then deliver each original event once to the HMAC-
checking TLS receiver. The complete received bytes must match the original
payload SHA-256, and history must confirm delivery. The encrypted secret
and its original validity period must not change. Revoke must still work while a
master is unavailable. This is restoration of the original key, not recovery of
an irretrievably lost key or a key-rotation implementation.

The first draft of this test incorrectly expected a terminal failure; inspection
confirmed the existing SQL intentionally retains a pending event for five minutes.
The corrected test checks that contract without changing the SQL or shortening its
clock. A second test-setup correction gives the two delivery scenarios separate
accounts: pausing intentionally retains new events, so sharing an account had
correctly queued an extra event. Both preliminary failures are harness assumptions,
not product regressions; their synthetic resources were cleaned before rerunning. Exact independent runs, source hashes and cleanup are recorded in
`p2-webhook-service-recovery-evidence.json`. Native reauthentication, Mac runtime,
wider consent/history speech, email intake, advanced teams and wearable clients
remain open. Existing user deferrals remain in force; full Px is not complete.


## Concealed review after an unconfirmed action — 23 October

Both apps now remove the previous secret-review confirmation when a connection
operation reports an error. The exact private enrollment stays in its existing
account/server-bound vault; an uncertain webhook control keeps its original
retry intent. Successful control retry alone does not reveal the secret again.
Continuing enrollment can reconfirm the same setup, and its native Reveal/Copy
state resets so the raw value requires another deliberate Reveal tap.

Connection requests still attempt one automatic credential renewal. A repeated
401 on the two management routes, or a documented invalid/expired refresh-session
code, now produces a fixed sign-in message instead of server details. The notice
says a private setup was kept only when one exists. Rate limiting, server failures
and unknown refresh errors are not treated as confirmed session expiry. A rejected
refresh from a superseded account/session becomes cancellation, so it cannot
request sign-in for the newly active account. This does not log out the user,
remove tasks or erase recovery.

The regression failed on the unchanged iOS key and webhook models (two cases,
five failed assertions). Both full Core suites now pass (iOS-owned: 1,365 cases,
13 optional skips; Mac-owned: 1,397 cases, 33 optional skips; no failures).
Four iPhone/iPad native checks pass, with no skips, and their normal/largest-text
screenshots are visually inspected. Exact results and the verification limits are
recorded in `p2-connection-review-failure-evidence.json`. Native cases use the
production view/model with an exact isolated Debug-only, in-memory service refusal;
transport cases separately exercise real URLSession through a synthetic peer on
the Mac-hosted Core test target.
They do not claim hosted native expiry/refresh acceptance or an in-place sign-in
sheet. That end-to-end recovery walkthrough, wider consent/history speech, Mac
runtime, email intake, advanced teams and wearables remain open. Normal automation
entries and main services stay disabled, and all user deferrals remain unchanged.


## In-place connection sign-in recovery — 23 October

Automation keys and task connections now offer **Sign in again** after a confirmed
session refusal. The native sheet renews only the current account, on the same
server and session incarnation. A response for a different account is rejected
before credentials are saved. Stale contexts and late cancelled requests cannot
replace the active session; cancelling an older sheet cannot cancel a newer sign-in.
Cancel remains available while the request is pending and is disabled only during
the serialized credential save. Password errors stay visible above the form,
including at the largest accessibility text size.

Successful renewal rebuilds the connection manager against the new session and
its existing private enrollment vault. It deliberately avoids the full account-entry
Store reset, preserving the current workspace and Undo state by construction.
Continuing setup retries the original enrollment; it returns to a masked review
and never reveals a secret automatically. The native synthetic peer rejects any
changed enrollment body, including changed private material. Delivery-history
notices also offer the same recovery action after dismissing history.

Both independent Core suites pass (iOS-owned: 1,372 executed, 13 optional skips;
Mac-owned: 1,404 executed, 33 optional skips; no failures). Subsequent focused runs
cover the final concise feedback copy and an additional foreign-origin/signup guard.
iPhone/iPad native results and reviewed screenshots are recorded in
`p2-connection-reauthentication-evidence.json`. Each app owns its source and project
inputs; the Mac app compiles independently.

The native fixture uses the production Backend and real URLSession through a
synthetic HTTP peer, with memory-only credentials and enrollment storage. It does
not establish genuine hosted Auth, Keychain persistence, Google account-selection,
cached/queued-work or Undo runtime acceptance. Those remain separate acceptance
work, alongside Mac runtime and wider consent/history speech. Normal feature
entries and main services remain disabled. Email intake, advanced teams and
wearables remain open; full Px is not complete. Remote reminders, older-client
rollout safeguards, distribution verification, OAuth registration/provider
acceptance and physical location-reminder delivery remain deferred by the user.


## Hosted sign-in recovery and profile continuity — 23 October

A real no-data preview Auth response exposed a wire-format gap: a refused refresh
returned HTTP 400 with numeric `code: 400`, `error_code: "session_expired"` and a
message. The client previously checked only string `code`, which classified that
response as a generic failure and omitted **Sign in again**. Both apps now prefer
a nonempty `error_code`, falling back to the normalized string `code` format.
Only the existing four recognized session reasons and allowed error statuses
request sign-in; unknown reasons, throttling and server failures retain their
separate classification. Message text never determines session expiry.

Optional profile hydration now saves updated user details without entering the
full sign-in acceptance path. It keeps the current account/session incarnation,
open connection leases and pending explicit authentication attempt. After awaiting
persistence it rechecks the account incarnation and updates only profile metadata
on the latest live credentials, preserving tokens renewed during the save.
Full sign-in, sign-out and account changes retain their original invalidation.

The old profile path failed a regression with three assertions. The old raw Auth
parser failed five assertions, including a conflicting-field case. Both independent
transport suites now pass 55 cases. The full suites passed after the profile fix
(iOS-owned: 1,376 executed, 13 optional skips; Mac-owned: 1,408 executed, 33 optional
skips; zero failures); the final localized wire-parser change is covered by the
subsequent full transport suites. Both native app targets compile independently.

The iOS repo owns `--native-reauthentication` in its guarded hosted controller and
`testHostedWebhookReauthenticationPreservesSetupWorkAndUndo`. It uses actual
password Auth, HTTPS management, OS Keychain, native task capture, Undo/Redo and
normal relaunch. The controller expires only disposable users' server sessions via
`not_after`; it does not mint or edit JWTs, advance device clocks, or claim natural
wall-clock access-token expiry. It compares the complete original connection and
saved-task fingerprints, verifies a new real server session, and checks persisted
Undo/Redo. Its app-specific lost-reply flag discards one actual successful setup
response; all subsequent replies are real. The mode leaves the webhook scheduler
inactive. Exact runs, corrections, cleanup and acceptance limits are recorded in
`p2-hosted-connection-reauthentication-evidence.json`.

This does not close the full advanced backlog. Native API-key hosted renewal,
queued-edit recovery across renewal, real Google selection, Mac runtime/Keychain
and wider spoken consent/history remain separate checks. Email intake, advanced
teams and wearables remain open. Normal feature entries and main services remain
disabled; all existing user deferrals remain unchanged.


## Queued task sync after sign-in renewal — 23 October

Both apps now offer **Sign in again** directly beside a confirmed expired-session
sync warning, explaining that edits remain saved on the device. The action uses
the existing same-account sheet and avoids the full workspace-entry reset. Success
retries the saved queue; a workspace-bound deferred retry also handles renewal
finishing during an older sync. Account changes, sign-out and account removal
invalidate recovery. Renewal in connection settings also retries task sync.

Actual hosted iPhone and iPad Simulator checks pass without skips: a native create
stays queued through refused refresh, restart, wrong password and Cancel, then
automatically syncs with its original ID/generation after renewal. The original
saved task's complete server fingerprint stays unchanged, the server contains
only one matching queued task, and normal relaunch uses renewed Keychain
credentials. Only the local Debug refresh-due timestamp is controlled; this does
not claim natural JWT expiry or exactly one network invocation. Both independent
Core suites pass (iOS: 1,378 executed, 13 optional skips; Mac: 1,410 executed,
33 optional skips; zero failures), and both app targets compile.

See `p2-queued-sync-recovery-evidence.json` for exact runs, reviewed images, the
diagnostic-only startup-log correction, cleanup and limits. The temporary branch,
credentials and installed test apps are removed. Mac runtime, queued edit/delete
and held-sync variants, API-key-specific hosted renewal, Google selection and
wider spoken checks remain open. The advanced backlog is not complete; all user
deferrals remain unchanged. Normal automation/webhook feature entries stay gated.


## Hosted API-key sign-in recovery — 23 October

The remaining API-key-specific native renewal check now passes on iPhone and
iPad Simulator (one test each, no failures or skips). Actual Auth, HTTPS and OS
Keychain are used. After synthetic server-session expiry, wrong password and
Cancel preserve setup; same-account renewal and Continue return to the original
concealed key. Server comparisons verify one key with unchanged ID, secret hash,
permissions, expiry and counters, plus an unchanged complete saved-task
fingerprint. Normal relaunch recovers that setup with renewed credentials; native
acknowledgement and revocation persist through another relaunch.

No product defect was found, and Release behavior is unchanged. The iOS repo
extends its exact Debug host allowlists and owns the native test/controller; both
repos retain independent unchanged production services. This does not claim Mac
runtime, Google selection, natural JWT expiry, all queued-edit variants or wider
spoken acceptance. Exact runs, reviewed masked screenshots, source fingerprints
and verified test-app/preview cleanup are in
`p2-hosted-api-key-reauthentication-evidence.json`. Core and Mac app code are
unchanged; their previous committed suite/build evidence remains applicable.

Next feature implementation: idempotent email-to-task intake, followed by advanced
teams and wearable clients. The user will configure the provider/domain later; live
mail delivery must stay gated until configured and verified. Full Px remains
active, and all existing user deferrals stay unchanged.


## Email intake preparation — 23 October

The user has deferred provider/domain setup and authorized preparation now. The
first independently owned server component normalizes bounded plain text and
provides a provider-receipt/route key separate from content fingerprint, so the
atomic journal can distinguish safe retries from changed-content conflicts.
Both repos pass ten Deno cases and lint. This milestone sends no mail, creates no
task and exposes no endpoint. The later database milestone below adds route authorization, quotas and journal
enforcement. Native setup, trusted provider integration and real delivery remain open.
`EMAIL_CAPTURE.md` gives the ordered contract and gates;
`p2-email-content-evidence.json` records exact scope.


## Email intake journal — 23 October, local acceptance

The disabled database candidate now atomically saves one task per verified
provider receipt, preserves retries across user edits/deletion, and supports
account-bound route pause/resume, rotation, revocation and setup cancellation.
Current confirmed Auth email is the only approved sender. Destination permission,
account removal, sender changes and quotas are checked under transaction locks.
Each repo passes 119 functional checks, 32 real PostgreSQL concurrency checks and
43 existing webhook-fixture compatibility checks. Local advisors have no findings
for the new email objects; unrelated minimal-fixture findings remain.

This does not enable email or complete rank 6. The management gateway milestone below now passes locally. Native
address setup/recovery and verified provider integration remain next.
Additional verified senders, source links, scheduled inactive-account maintenance
and hosted/native/live-mail acceptance remain open. See `EMAIL_CAPTURE.md` and
`p2-email-intake-journal-evidence.json`. All existing user deferrals remain in force.


## Email route gateway — 23 October, local acceptance

Both repositories independently own a strict native-management handler using live
Auth plus SQL session/account checks, the existing durable management admission
budget, bounded/cancellable input and upstream reads, and filtered no-store
receipts. Missing configuration preserves list/pause/revoke while refusing new
setup. Enabling actions bind the reviewed domain; uncertain changes retain the
same setup/revision for retry. Raw aliases never enter management requests.

Each repo passes 22 handler and nine existing admission tests, plus 20 HTTP-to-real
PostgreSQL checks with a synthetic local Auth adapter. Nothing is deployed; this
does not prove hosted Auth/forwarding or native UI behavior. Next implementation
is the premium native address setup/vault/recovery flow. Provider adapter,
additional verified senders, source links, scheduled maintenance and real delivery
remain open. See `EMAIL_CAPTURE.md` and `p2-email-routes-gateway-evidence.json`.
Full rank 6/Px remains active and user deferrals are unchanged.


## Native email setup — 23 October, candidate and scoped acceptance

Both apps independently own destination/sender review, concealed addresses,
expiring local Copy, pause/resume, replacement and revocation, using the existing
account settings patterns. Device-only private storage durably records one pending
action before sending; lost replies and failed private saves retain the exact
setup. Workspace/session changes reject late replies, and account removal cleans
the private email vault. The fixed native HTTP path is bounded, refuses redirects
and disables cookies/cache. A versioned 256-bit address convention agrees across
Swift and the internal Web Crypto helper. Production feature flags remain off.

Scoped model/vault/HTTP tests and phone/tablet synthetic-peer walkthrough evidence
are in `p2-email-native-setup-evidence.json`, with exact counts and limitations.
The real private-Keychain path, hosted native recovery, Mac runtime and spoken
acceptance remain open; source/build success does not close those gates. Provider
adapter/attestation, source links, scheduled cleanup and additional verified senders
remain unfinished. The durable-domain milestone below implements a retire-and-re-enroll rule;
real hosted migration acceptance remains open.
Provider/domain configuration stays deferred by the user. The full Px objective,
advanced teams, wearable clients and all existing release/provider deferrals remain
in scope; rank 6 is not complete.


## Email domain binding — 23 October, protocol 2 candidate

The database now records each address's immutable domain and authorizes reviewed
create/resume/replacement under its configuration lock. A stale worker cannot
silently enroll against a different domain. Configuration changes require explicit
revocation of live/paused addresses; disabling alone cannot bypass the rule. A
service-only helper and trigger refuse unsafe changes, including unsupported
snapshot-isolated operator transactions. Pre-binding unknown-domain addresses are
retired without altering tasks or delivery receipts. Native/gateway protocol 2
requires bound receipts and preserves safe pause/revoke on configuration mismatch.
Delivery v2 additionally checks the provider-attested original recipient domain;
old hash-only delivery is disabled rather than guessing a domain.

Per repo: 57 migration/config checks, 119 intake checks, 43 real PostgreSQL
concurrency checks (12 observed barriers), 26 real SQL HTTP checks, 40 Edge cases
and 28 native Core cases pass. Both apps build; scoped phone and large-text dark
tablet protocol-2 fixture walks pass. No cloud change or feature activation occurs.
See `p2-email-domain-evidence.json` and `EMAIL_CAPTURE.md` for exact limits.

Next: real private-Keychain/hosted recovery acceptance and trusted provider/MIME/
sender/receipt integration, source links and scheduled inactive-account maintenance.
Extra verified senders and real domain migration/re-enrollment acceptance remain
open. Provider/domain configuration stays deferred. Rank 6, advanced teams,
wearable clients, remaining Px and all existing user deferrals stay in scope.


## Email private recovery — 23 October, scoped Simulator acceptance

Production device-only Keychain recovery now passes on signed iPhone and largest-
text dark iPad Simulator hosts: lost reply, injected confirmation-write failure,
process relaunch, unchanged retry identity, separate synthetic account sessions,
and verified removal of both owned private records. Three scoped UI cases per
device pass. Recovery messages/actions stay visible after a phone walkthrough
found the old Form could hide Retry. Both independent apps build; this is not
Mac runtime or genuine hosted account/provider acceptance. See
`p2-email-keychain-recovery-evidence.json` and `EMAIL_CAPTURE.md`.

Next: genuine hosted native recovery/reauthentication and verified provider
adapter preparation, then source links, scheduled maintenance and additional
verified senders. Provider/domain configuration remains deferred by the user;
keep email delivery and its native release flag disabled. Advanced teams and
wearable clients remain in the full ranked backlog; existing release deferrals
stay in force.


## Email inactive-account maintenance — 23 October, local acceptance

Both repos independently prepare an inactive, operator-only five-minute cleanup
job. It visits at most 20 accounts and deletes at most 500 eligible records per
metadata table/account, preserves task content and fresh retry identity, skips
busy work and wraps its durable cursor. Partial-account rollback and existing
account-removal/intake fencing are verified. Each repo passes 70 actual PostgreSQL
checks, 14 actual pg_cron timer/deadline/mode checks and the 43-case intake
concurrency regression. Temporary containers and compiled extension files are
removed; no hosted service or job is enabled.

The deadline is verified in libpq scheduler mode; background-worker mode is
explicitly refused at configuration and runtime rather than implying a bound its
executor does not supply. Hosted environment acceptance remains open. Do not
change a project's global scheduler settings to bypass this gate. Exact evidence
is in `p2-email-maintenance-evidence.json`; operator steps are in `EMAIL_CAPTURE.md`.

Next: genuine hosted native email recovery and verified provider/MIME/sender
integration, source links and additional verified senders. User provider/domain
configuration remains deferred. Advanced teams, wearable clients, wider acceptance
and the full ranked Px objective remain active with the existing release deferrals.


## Hosted email management — 23 October, scoped acceptance

The unchanged gateway and email SQL pass 36 genuine hosted checks per repository
on an owned, nonpersistent no-data preview: actual password Auth and confirmed
accounts, strict protocol/domain review, exact setup retry, complete route-row
preservation, account isolation, real server-session expiry and renewal, pause/
resume, rotation/retry, revocation and cancellation. A saved synthetic task remains
unchanged. Direct native RPC/provider-attestation bypass is refused. Hosted
advisors report no email-object findings; other preview advisories are retained.
The preview, synthetic accounts/function/environment and private connection files
are removed after testing. Main and production flags are unchanged.

This closes the scoped hosted management boundary, not native app UI/relaunch or
real mail delivery. Next: native hosted email setup/recovery using the real vault
and reauthentication flow; verified provider/MIME/sender integration, source links
and extra verified senders remain. Provider/domain configuration is still deferred
by the user. Advanced teams, wearable clients and wider acceptance remain in the
full Px goal. See `p2-email-hosted-management-evidence.json` and `EMAIL_CAPTURE.md`.


## Advanced team implementation prerequisites — source audit, 23 October

Current project sharing has a deliberately small permission contract. The
invitation guard accepts only owner-created pending `collaborator` invitations
and prevents changing their role later
(`20261022193804_account_removal_service.sql`).
`automation_lock_project` authorizes an accepted project collaborator, while
`automation_writable_project` adds archive checks; neither currently represents
team admin/member/guest or read-only roles. No team-membership or project-folder
tables are present in the current migrations. These findings describe the current
project-sharing model, not a completed team implementation or an existing grant
to unsupported roles.

Implementation order for the advanced team portion of rank 6:

1. Define durable team/project ownership and explicit role/invitation/transfer
   records, including what happens when the creator leaves or removes an account.
   Preserve existing personal-project and invitation behavior.
2. Enforce the new role authority at every server write boundary: native guarded
   mutations, direct Data API writes, API credentials, email delivery and shared
   content. Test role changes, revocation, concurrent writes and membership loss
   using actual database authorization, including older clients.
3. Add the native team switcher, project folders and reviewed admin/member actions
   in each independently owned app after those permissions and ownership rules
   work. Retain account/workspace fencing, offline drafts and clear recovery.
4. Verify account removal, backups, activity attribution, widget privacy and
   transfer/revocation against the new ownership model before rollout. The user's
   general older-client rollout safeguards and distribution work remain deferred;
   enabling new team roles must respect that dependency.

Email provider integration and native recovery remain their own ongoing work.
This audit does not change the ranked full Px scope or claim team features shipped.


## Native hosted email recovery — 23 October, scoped acceptance

Production native sign-in, management and device-only Keychain recovery now pass
a complete iPhone and largest-text dark iPad workflow with zero failures/skips.
Sixteen actual server assertions confirm unchanged task fingerprints, original
address identity, controlled session expiry/new-session renewal, durable Pause
retry, Resume and terminal revocation. Ordinary relaunch and actual account
leave/return preserve the private copy; the other account shows an empty list.
Both final cases clear their private test setup and sign out.

The iPad walkthrough found a real late-session-observer race; both views now
recognize the session already restored by the sheet before resetting state, and
resume workspace-bound sync. Both apps build; this does not claim Mac runtime.
An unrelated system-password-prompt tap was corrected in test navigation. Full
walkthroughs were rerun with fresh accounts after explicit orphan-record cleanup.
The default hosted harness retains its 36 passing regression checks per repo.
See `p2-email-native-hosted-recovery-evidence.json` and `EMAIL_CAPTURE.md`.

Next: verified provider adapter/MIME/sender and original-envelope/receipt
integration, source links and additional verified senders, with provider/domain
configuration still deferred by the user. Mac/private fault/spoken/wider native
acceptance remains scoped separately. Advanced team permissions/ownership,
folders/admin and wearable clients remain active; existing release deferrals stay
in force. No main service or shipping email feature is enabled.


## Provider-independent MIME decoding — 23 October

The next rank-6 email stage now decodes actual bounded RFC822 bytes into the
existing task-content/retry contract. Plain/HTML alternatives, international
encodings and explicit attachment omissions work without network permissions;
encrypted/image-only unsupported cases and excessive structure fail explicitly.
Both repo-owned implementations pass 18 new MIME cases plus 41 existing
content/alias/management cases. No provider is selected, configured or enabled.
`EMAIL_CAPTURE.md`, the module README and `p2-email-mime-evidence.json` retain exact
limits and verification. Verified signed event/envelope/sender/receipt integration,
ingress budgets, delivery, source links and extra verified senders remain open.
Team permissions/ownership and wearable clients remain in the full backlog;
existing user deferrals and broader native acceptance are unchanged.


## Apple Watch candidate — 24 October, rank 7 in progress

The iOS repository now owns a real, independently buildable Watch target with
Today, reviewed capture, Pending and a protected atomic outbox. Its immutable
commands bind phone/Watch installations, account/epoch and task incarnation/token;
only an exact saved receipt acknowledges work. Sixteen contract/archive cases pass.
The isolated 42 mm Simulator app launches and its Today layout is visually reviewed.
The target remains unembedded: phone projection, atomic task/receipt saves and full
paired acceptance are next. No iPhone task mutation or wearable completion is
claimed. Native input, VoiceOver, wider layouts and hardware background/protection
acceptance remain open; Apple does not support background user-info transfer in
Simulator. See the iOS-owned `docs/WATCH_COMPANION.md` and
`docs/p2-watch-client-evidence.json`. The Mac build gains no Watch dependency.

This proceeds alongside the still-open verified email adapter/senders/source links,
advanced team authorization/ownership and wider acceptance. Provider/domain and
existing remote/release/calendar/location deferrals remain intact; full Px is active.


## Watch iPhone save path — 24 October, rank 7 in progress

The iPhone command planner now connects to normal Store mutations and an atomic,
private receipt saved with the task/queue. Lost replies cannot duplicate captures
or re-complete work after Undo/recreation. Both independently owned app caches
preserve the new private metadata monotonically and exclude it from portable
backups/shared rows. Receipt-capacity reset/fencing remains a pre-shipping gate.

All 26 isolated native local Store/cache/relaunch assertions pass. The full iOS
suites execute 1,434 cases (13 existing optional skips), Mac 1,442 (33 skips),
with no failures. Both apps and the moved-source Watch target build. No genuine
cloud-account or paired-delivery result is claimed. See
`p2-watch-phone-save-evidence.json` and the iOS-owned `WATCH_COMPANION.md`. Next
are durable peer/workspace authority, Today projection, lifecycle invalidation
and the paired receiver, then full acceptance before embedding. Rank 7 and full
Px remain active alongside the remaining email/teams/voice/native gates and
existing user deferrals.


## Watch connection and Today projection — 24 October, candidate

The iOS repo now owns durable peer/workspace authority, a production paired
receiver, bounded Today projection and startup/signout hooks. Definitive
connection refusal conceals cached Watch content while retaining immutable
pending intents. A relaunch check found and removed an accidental dependency on
notification snooze settings. Forty focused cases and 53 properly signed local
iPhone assertions pass. Peer identity is injected in native tests: actual paired
transport/background delivery, cloud accounts, parked-intent recovery UI,
capacity/reset recovery, hardware/VoiceOver/input/layout and embedding/resources
remain open. The feature flag stays off; no full Watch or Px completion is claimed.
See iOS-owned `WATCH_COMPANION.md` and `p2-watch-connection-evidence.json`. Mac
receives ordinary guarded task sync; it gains no Watch target dependency. All
remaining email/team/native acceptance work and user deferrals retain scope.


## Watch pending-action review — 24 October, candidate

The Watch now offers deliberate review of actions parked after an account/phone
change or a stale refusal. Users see the original workspace and words, can edit
the copy, and explicitly save a new Inbox capture to the displayed current
workspace. A completion request is never retargeted into a completion elsewhere.
The destination is frozen for the open review and checked again at save. Original
commands remain immutable; private recovery metadata prevents repeated copies,
including after receipt, discard or relaunch. Existing ambiguous saves carry an
explicit duplicate warning. Cancelling leaves work untouched.

Ten recovery cases and the prior 40 focused cases pass, with no skips/failures.
The actual 42 mm Watch Simulator review screen was inspected and its native Save
button exercised: one new capture, exact original retained, a second tap refused,
and the real private archive unchanged across relaunch. This isolated DEBUG
fixture uses synthetic work with transport disabled; it does not prove paired
phone delivery or modal dismissal/VoiceOver. Both Watch configurations and the
actual iPhone app compile. The Watch flag remains off and the target unembedded.
Capacity/reset fencing, paired/background and cloud acceptance, wider input/
VoiceOver/hardware, resources and embedding remain open. Existing email/team/
other Px work and user deferrals retain scope. See iOS-owned
`p2-watch-recovery-evidence.json` and `WATCH_COMPANION.md`.


## Watch capacity recovery — 24 October, candidate

Full Watch action history now publishes an explicit capacity state and leads to
Watch connection in iPhone Account settings. A confirmed restart preserves task
rows and unsent changes, clears the full private receipt history, and advances
a durable generation fence in the same atomic account-cache write. The receiver
requires a fresh phone/epoch binding before accepting another action. Restoring
an older peer archive cannot restore old authority; failure to save the rotated
peer also refuses old commands. The current physical peer receives a reconnect
notice where application-context delivery is available. This callback is tested
locally; genuine paired delivery is still open.

Both repos independently preserve the generation through ordinary Undo, restore
and merge, reject unauthorized advancement, and ignore receipt baselines predating
a reset. The marker is private and excluded from portable backups. Startup/account
checks, an exact reviewed workspace/generation, full capacity and an atomic save
are required for restart. Old pending Watch actions remain immutable for review;
reviewed new Inbox copies can save after reconnect. No original completion is
silently retargeted. The Watch warns about full history and disables new capture/
completion controls until capacity returns.

Verification: 57 focused iOS cases and nine independent Mac cases pass. Full iOS
suites execute 1,463 cases (13 existing optional skips), Mac 1,447 (33 optional
skips), without failures. Signed isolated iPhone runs pass 16 real Store/codec/file
checks plus three cold-relaunch checks, with only OS peer identity injected.
Native recovery confirmation was also exercised: Cancel preserves exact cache
bytes; Confirm advances once, reclaims all 4,096 receipts, keeps task rows and the
sync queue, and shows readable reconnect guidance with Restart disabled. The
actual iPhone, Mac and Watch Debug/Release targets compile. No new Mac runtime UI
acceptance or paired/cloud/hardware result is claimed.

The shipping flag remains off and the Watch target unembedded. Older clients do
not enforce this new marker; the already-deferred old-client rollout safeguards
remain a release gate. Paired live/background delivery, cloud-account/write
acceptance, wider native review/edit/dictation/VoiceOver/layout, hardware-storage,
icons/resources and embedding remain open. The full email/teams/Wear OS/native
backlog and all user deferrals keep scope. See iOS-owned
`p2-watch-capacity-evidence.json` and Mac-owned
`p2-watch-capacity-compatibility-evidence.json`.


## Resumable Watch capture and action review — 24 October, candidate

Code review found that unsent capture words existed only in the open sheet. The
Watch now owns one private, bounded capture draft in its existing atomic archive.
Editing does not enqueue a command or include draft text in a wire snapshot.
Close is wired to persist before dismissing; reopening uses the original draft
identity, phone and workspace. Account/epoch/phone changes never silently adopt a
new destination. A separate destination review rechecks the chosen workspace, and
Save atomically moves the latest words into one new capture while clearing the
draft. Failed writes, capacity refusal and stale reviews keep the durable draft.
Explicit draft removal leaves existing pending commands untouched. The native
input field is accompanied by a wrapping full-title review and its destination.

The action sheet now has separate review/removal rows, an explicit Done control
and an empty state. Its name is Watch actions because retained original references
also count; it does not imply that every reference is awaiting delivery. Known
full phone history refuses recovery copies before consuming the original. Failed
local changes show a plain retry message instead of a raw file error.

Seventy focused cases pass (12 new draft cases plus one new full-history recovery
case, no failures/skips). The actual isolated Watch client and private archive
pass 15 assertions across two process relaunches, including a blocked filesystem
write, edit retry, changed workspace, explicit adoption, atomic Save, repeat Save
and independent draft discard. Packet updates are injected and transport is
turned off; these do not prove iPhone delivery, native typing or button input.
Watch Debug/Release and the actual iPhone app build. Release excludes fixture
flags. The automatically presented Capture and Watch actions sheets render on
42 mm, with full sample title/destination and distinct action rows inspected.

The Mac remained locked, so the full button-driven open/edit/Close/Cancel/Save/
return flow, dictation and spoken acceptance remain open. Prepared DEBUG routes
reduce the setup for that later check. No fresh full-suite, Mac runtime, paired,
cloud or hardware acceptance is claimed. The test app is removed and the Watch
Simulator returned to shutdown; reusable caches are retained. Exact scope is in
iOS-owned `p2-watch-draft-evidence.json`.

The new field is optional, private Watch state; wire commands and iPhone task/cache
schemas are unchanged. Mac gains no code or build dependency. The Watch flag
remains off and the target unembedded. Earlier paired/background/cloud/storage,
input/layout/VoiceOver, icons/resources and embedding gates, the broader email/
teams/Wear OS/native backlog and every user deferral retain scope. This closes
neither rank 7 nor the full Px objective.


## Signed email handoff — 24 October, internal preparation

Each repo now independently owns `_shared/email-ingress`, an internal composition
layer with no serving entrypoint, deployment configuration or service credential.
A future trusted provider adapter can sign a strict bounded original-envelope
handoff. HMAC binds exact bytes, deployment audience, immutable provider namespace,
key ID and attempt time. Original delivery ID/receipt time remain unchanged across
retries. Sender/domain/receipt facts come from the signed adapter attestation,
never MIME From/To/Date/Message-ID/Authentication-Results headers. This does not
implement real provider, SPF, DKIM or DMARC verification; the signer must establish
those facts under a reviewed provider-specific policy before attesting them.

The handler requires explicit admission before reading and again after signature
verification but before MIME parsing. It has no permissive production default.
The existing native/API budgets cannot stand in for independent durable email
admission. A sealed verified handle feeds the existing pinned MIME normalizer and
prepares only the arguments of the service-only atomic email journal. Missing or
uncertain journal proof cannot become a success response. Headers, raw bytes,
chunk count and deadlines are independently bounded; errors expose no mail,
aliases, signatures, credentials or upstream messages. No message download occurs.

Both repo-owned Deno suites pass 114 cases each (55 new handoff/composition cases
plus the prior 59 MIME/content/alias/management cases), without failures or skips.
Frozen cached dependencies and no runtime permission grants are used. Lint,
format and type checks pass. Each independent real PostgreSQL fixture passes 27
checks using actual signed-message preparation followed by the existing journal:
exact retries, changed content/time, sender/domain rejection, deletion safety,
pause/resume/revocation and service-only access. This is a staged local pipeline,
not a deployed provider HTTP service; preparation admissions are injected. Official
read-only advisors report no email warnings/errors in those owned fixtures; other
fixture findings remain recorded. Both containers are removed.

Provider/domain configuration remains deferred. Real provider verification,
message download/admission wiring, durable shared email budgets/in-flight bounds,
genuine delivery/retry acceptance, source links, additional verified senders and
wider native/accessibility checks remain open. No SQL, native app, live account,
release flag or deployed function changed. Watch/advanced-team/other Px work and
all user deferrals retain scope. See `p2-email-signed-handoff-evidence.json` and the
module README; this is neither rank-6 nor full-Px completion.


## Watch offline date refresh — 24 October

The iOS-owned Watch Today screen now reevaluates the cached list on the native
minute schedule and on active-scene redraws, even without a reachable iPhone.
Expired rows give way to the existing refresh guidance and historical count.
The original update stamp remains visible, formatted for the phone's time zone;
older civil dates include the date, and daylight-saving changes do not relabel
an earlier update with the later offset. No receipt, task or wire schema changes.

Seven new boundary/presentation cases and the previous 70 focused Watch/receipt
cases pass without failures or skips. Actual Watch Debug/Release and iPhone Debug
builds pass. The isolated 42 mm Watch Simulator crosses the existing 24-hour age
boundary without another packet, relaunch or input: task rows retire while the
actual private archive stays byte-identical. This is local scheduled-render proof,
not paired/background delivery, native input, midnight hardware or spoken proof.
Mac owns no Watch runtime code or build dependency. Full Watch/teams/email/native
acceptance and every user deferral retain scope. Exact evidence is in the iOS repo's
`p2-watch-freshness-evidence.json`; no full rank or Px completion is claimed.


## Watch icon resources — 24 October

The iOS-owned Watch target now includes a circular Icon Composer document using
Taskfold's existing red gradient and exact layered check/fold vectors. Watch owns
its resource copies and resource build phase; both configurations name the primary
icon. The target generator preserves this setup for future project creation.
Debug and Release Watch Simulator builds pass and contain the named primary icon,
watch-specific layered assets and raster compatibility rendition. Native Icon
Composer renders are visually reviewed, and the installed isolated Simulator app's
asset archive matches the built archive. The install check does not prove launcher,
Settings or notification appearance; those remain native acceptance gates.
No Swift, task/wire contract, phone or Mac target changed. Mac gains no resource
or build dependency. The Watch stays disabled/unembedded; paired/native/hardware,
advanced-team/email and other Px work and every user deferral retain scope. Exact
scope is recorded in the iOS-owned `p2-watch-icon-evidence.json`.


## Paired Watch Simulator and startup authority — 24 October

A real iPhone Air–42 mm Watch Simulator pair now passes Connect, literal reviewed
capture, completion, saved receipts and exact live replay using production
WCSession peer discovery/transport and actual Store/files. No peer identity or
packet is injected. Initial local workspace/readiness preparation is explicit;
normal subsequent foreground relaunch uses no paired-fixture route and preserves
the phone/workspace identity, work and receipts while advancing the live revision.
Watch capture also stays durable across its own relaunch while the phone Simulator
is shut down; independent reads confirm no phone task/receipt was created offline.
Simulator reachability stayed true despite shutdown, so it is not delivery proof.

Phone cold return exposed a production bug: publication before session activation
could treat undefined SDK peer fields as a different peer and retire authority.
The bridge now supplies an explicit ready-observation gate, required by the driver.
Before activation, publication preserves authority and emits nothing. Incoming
unconfirmed peers still fail; account retirement and confirmed peer absence keep
their original fences. Twenty first-run plus eleven relaunch native Store/file
checks pass, including four new startup checks. Those regression checks inject
the OS peer boundary and are distinct from the actual paired Simulator evidence.

The live pair cases preceded the gate fix. A fresh fixed paired phone-reboot
return is still required; the failed original intent was never silently rebound
to manufacture success. Debug iPhone/Watch and Release Watch builds pass, with
verified native Simulator identities/signatures and no Release fixture flags.
Shipping flags/embedding remain off. No Mac code/build dependency or shared
wire/task/receipt contract changes. Real hardware/background/cloud/input/spoken,
email/team/Wear OS and wider Px gates and all user deferrals retain scope. See the
iOS-owned `p2-watch-paired-simulator-evidence.json` for exact accepted limits.


## Watch ready-update retries and cold capture return — 24 October

The fresh paired retake confirmed the startup authority fix, then found a second
gap: the Watch received the phone's ready publication but left an unacknowledged
capture waiting after the earlier live request failed. The client now retries
eligible original commands on a fresh validated publication. Duplicate/old frames,
explicit Retry/stale receipts, full history, concealment and changed bindings do
not create a publication loop. One bounded ephemeral credit per command handles a
ready update overlapping an older request; explicit Refresh/session retry behavior
remains available. No command, destination or receipt is invented or rewritten.

Eighty-eight focused checks pass (11 new policy/overlap cases plus the previous
77, no failures/skips). Current iPhone Debug and Watch Debug/Release builds pass;
Release excludes fixture flags and diagnostics. The actual paired Simulator run
now proves capture return after phone OS reboot, including a real failed send,
an unsolicited ready-update retry and matching acknowledgement in the same Watch
process. Seventeen independent file/identity/receipt checks pass. All four earlier
synthetic tasks/receipts remain exact; only the original fifth command's task and
receipt appear, and the Watch outbox clears. A separate short-outage run also
passes. Read-only DEBUG observations establish the retry path; no peer or packet
is injected. Phone uses normal foreground startup with only the synthetic-cache
selector, and Watch receives no manual Refresh/Connect or restart on return.

This supersedes the earlier pending **cold capture return** gate only. Paired
offline completion/stale/Undo/account variants, hardware/background/system launch,
cloud/storage, native input/spoken/layout/icon and eventual embedding gates remain
open. No shared stored/wire contract or Mac runtime/build inputs change. Watch
shipping flags remain off; advanced teams/email/Wear OS, wider Px and all user
deferrals retain scope. Exact proof is in the iOS-owned
`p2-watch-cold-return-evidence.json`. Five superseded generated test-build caches
were also removed (about 3.2 GiB allocated); source, saved app data and Simulator
devices were not pruned, and current reusable build caches remain.


## Team organization foundation — 24 October, rank 6 in progress

Both repositories independently own the disabled team lifecycle migration and
real PostgreSQL acceptance harness. The foundation implements owner/admin/member/
guest roles, verified-email invitations, folders as metadata, archive/reopen,
explicit accepted ownership transfer, deletion tombstones and account-removal
ownership protection. Current sessions/roles, reviewed revisions and exact retry
receipts govern mutations. Quota/paused states preserve revocation and recovery.
No team/folder grants project access; existing native sharing remains unchanged.

Each repository passes 144 checks, including actual competing writes, role
revocation and session expiry while waiting, and the last daily creation slot.
The official advisors find no team warnings/errors; the minimal fixture's
pre-existing is_project_owner search-path warning is recorded separately. Owned
containers/ports are removed. No hosted changes, native rollout or app build is
claimed. See TEAM_ORGANIZATION.md and p2-team-foundation-evidence.json.

Next: integrate every project/task/native direct-data/API/email/storage boundary
without bypasses, then the premium native team switcher/folders/admin flows and
backup/account-removal/audit/widget privacy acceptance. Team configuration stays
off until those gates pass. This does not complete advanced teams, rank 6 or the
full Px scope; Watch/Wear OS/email and all existing user deferrals retain scope.


## Team content custody — 24 October, rank 6 in progress

The source/hosted-schema audit found cascading Auth ownership on team-relevant
content. Both independently owned candidates now preserve existing creator UUID
fields through a private content-identity registry and private team project/task/
file custody. Author removal preserves team work/history/generations; personal
cleanup retains the prior behavior. Ownership transfer does not rewrite tasks.
Deleted-account personal creation, admission/removal races and object-cleanup gaps
are fenced. Team deletion waits for file cleanup and purges content atomically.

Each repo independently passes 93 PostgreSQL checks, including native SQL guarded
edits, authenticated transfer/delete, actual service API create/get/list, personal
regressions and three real transaction overlaps. Advisors report no errors or new
custody/helper warnings; fixture init-plan findings remain documented. No hosted
write, native UI/build claim or actual Storage-provider delivery is included.
See TEAM_CONTENT_CUSTODY.md and p2-team-content-custody-evidence.json.

Team data is deliberately closed to native/direct/service legacy access until
current role enforcement and reviewed admission replace those gates. No admission
API or team UI is enabled. Next: permissions across all write/read paths, then
premium native organization/admin flows and backup/account/activity/widget checks.
Rank 6, remaining Watch/Wear OS/email, the full Px objective and every existing
user deferral retain scope.


## Team project roles and native read bridge — 24 October, rank 6 in progress

Both independently owned candidates now implement team/private project visibility,
manager/editor/viewer overrides, guest-only explicit scope, reviewed new project
creation/folder/access changes and UUID identity tombstones. Live native sessions
and current membership govern reads; departed creator IDs do not grant history,
file or directory access. Legacy team email lookups and cross-workspace personal
writes are fenced; personal sharing/service task pages remain supported.

Each repo passes 145 real PostgreSQL checks, including three transaction overlaps.
Each SwiftPM run passes 48 selected checks (8 new team cases, existing automation/
email regressions; zero failures/skips), decoding its actual SQL-produced fixture
and testing account-switch/response bounds. Both apps own the models, read API and
Xcode source registration. No hosted change, native UI/runtime or Storage delivery
is claimed. See TEAM_PROJECT_ACCESS.md and the project access/native evidence.

The native-read flag defaults off. Task/comment/file/service writes remain closed
and the native client rejects task-edit capabilities. Next: finish those write/
assignment/structural adapters, then premium native team/folder/admin/invitation
flows and workspace/cache/filter/widget/backup/account acceptance. This does not
complete advanced teams, rank 6 or wider Px; every existing user deferral retains
scope.


## Guarded team task edits — 24 October, rank 6 in progress

Both independent candidates now have a disabled adapter for existing task text,
planning and completion edits. Current live membership/role and project state
are locked and checked; captured workspace/generation/baseline and durable
request receipts prevent stale permissions, conflicting writes and old retries
from replacing newer work. Direct team writes remain closed. Native scoped
queues retain rejected drafts, validate replies, preserve Undo/review context and
cannot be discarded through legacy unavailable-project recovery.

Each repo passes 70 PostgreSQL checks (including two transaction overlaps) and
59 selected SwiftPM checks (11 new, 48 project/automation/email regressions), with
zero failures/skips. Advisors have no errors/new warnings; owned containers are
removed. See TEAM_TASK_EDITS.md and both task-edit evidence files. There is no
hosted or native UI/runtime claim. Editing stays off; catalog capabilities remain
read-only until workspace/role refresh and remaining write adapters are ready.

Next: create/delete/restore/recurrence, assignment/structural/checklist/reminder,
comment/file/API/email adapters, then premium team organization/admin UI and
workspace/privacy/recovery acceptance. Rank 6 and the full Px goal remain open;
all user deferrals remain unchanged.


## Team task lifecycle — 24 October, rank 6 in progress

Both independently owned candidates now create team tasks, delete against a
whole-task baseline and restore through a consumed, content-certified Undo
receipt. Fresh generations and shared nonce receipts prevent resurrection or
late deletion of restored work. Later occurrences survive deletion; Undo restores
only unchanged, currently editable links. Current assignment roles and deleted-
author custody are preserved. Legacy unscoped team edits now require review,
with current clients retaining their drafts.

Each repo passes 89 PostgreSQL lifecycle checks, 70 edit regressions against the
new migration, and 137 selected SwiftPM checks (10 new; zero failures/skips).
Unsigned Debug app/embedded-extension builds pass for Mac and iOS Simulator.
Official advisors report no new warnings/errors; owned containers/build outputs
are cleaned up. See TEAM_TASK_LIFECYCLE.md and lifecycle evidence files.

Team UI/editing remains disabled. Shared-conversation recovery, atomic linked
batches, structural/assignment/reminder edits, service/email/file boundaries,
current-role workspace refresh, premium team organization/admin UI and full native
privacy/recovery acceptance remain required. Full Px and user deferrals are unchanged.


## Team discussion recovery — 24 October, rank 6 in progress

Task delete/Undo now preserves shared discussions through private, encrypted
30-day recovery copies. Undo creates new comment/mention identities, preserves
content and read history, excludes departed recipients and fences stale callbacks.
Corruption/interrupted writes roll back atomically. Expiry, successful Undo,
account removal and team deletion clean up keys/ciphertext; real Cron cleanup is
verified locally. The preceding conversation-deletion hold is removed.

Each repo independently passes 70 recovery + 89 lifecycle + 70 edit + 11 real Cron
checks (240 database checks total), and 167 selected SwiftPM tests (4 new; zero
failures/skips). Advisors have no errors/new warnings, and owned fixtures/Cron
staging files are removed. See TEAM_CONVERSATION_RECOVERY.md and its evidence.
No new app-runtime/build, hosted deployment or distribution pass is claimed.

Next: atomic linked-task deletion/Undo, remaining task/comment/mention/file/service
adapters, current-role workspace refresh and premium native team administration,
then full privacy/recovery acceptance. Team UI remains off. The full Px objective,
Watch/Wear OS and all user deferrals retain scope.


## Atomic linked team selections — 24 October, rank 6 in progress

Linked selections now delete and Undo atomically across projects within one team.
Deletion runs children first; recovery runs parents first with fresh generations
and verified parent mappings. Unselected occurrences and discussions survive.
Any changed/inaccessible member or later failure rolls back the whole selection.
Current account/roles and shared nonce receipts guard retries and split-Undo.

Each app independently owns a persisted batch model and Store/Undo/Redo integration.
No client splitting or single-task fallback is used. Each repo passes 301 database
checks (72 new plus discussion/lifecycle/edit regressions) and 177 selected SwiftPM
checks (10 new), with zero failures/skips. Both unsigned Debug app/extension builds
pass, including Store and main-target source registration. Advisors show no new
errors/warnings; owned fixtures/build output and registrations are removed.
See TEAM_TASK_BATCHES.md and batch evidence. No hosted/runtime/distribution pass
or enabled team UI is claimed.

Next: remaining native editing/comment/mention/file/service adapters, current-role
workspace refresh and premium team organization/review UI, then full privacy and
recovery acceptance. Wider Px, Watch/Wear OS and user deferrals remain unchanged.


## Team task planning — 24 October, rank 6 in progress

The guarded team edit adapter now supports assignment, labels, same-project
sections and portable reminders. Live recipients/current roles, locked section
references, durable retries and final merged-value validation protect shared work.
Recorded retries cannot reassign departed recipients. Private/unknown reminder
choices and future extensions survive supported edits; oversized concurrent merges
roll back. Each app independently persists these intents and preserves Undo/Redo.

Each repo passes 363 database checks (132 planning/edit + 72 batch + 89 lifecycle
+ 70 discussion), 182 selected Swift tests (five new) and unsigned Debug app/
embedded-extension builds. Advisors have no new warnings/errors; owned containers,
build outputs and temporary Mac registration are removed. See
TEAM_TASK_PLANNING.md and the planning evidence files. No hosted/runtime/
distribution acceptance or enabled team UI is claimed.

Next: checklist/recurrence completion and comment/mention/file/service adapters,
current-role workspace refresh and premium native team organization/review UI,
then full privacy/recovery acceptance. Full Px and existing user deferrals retain
scope.


## Team checklist editing — 24 October, rank 6 in progress

Nested team checklists now edit, merge, complete, delete and recover through the
existing guarded task RPC. Item epochs/revisions fence completion cycles and old
text/delete callbacks after restoration. Receipt-bound recovery preserves original
discussions, files, private reminders, unknown fields and server timestamps; private HMAC/tombstone
metadata prevents history forgery or identity reuse. Whole-task Undo preserves its
certified tree exactly. Each app owns preparation, persistence and Undo context.

Each repo passes 452 database checks (221 checklist/planning/edit, 89 lifecycle,
72 batch and 70 discussion), 196 selected Swift tests (14 new), and unsigned Debug
app/extension builds. Advisors show no new errors/warnings; owned containers,
derived builds and temporary Mac registration are removed. See
TEAM_CHECKLIST_EDITS.md and checklist evidence. Team editing stays disabled;
there is no hosted/native-runtime/distribution acceptance claim.

Next: atomic recurring completion/Undo, comment/mention/file/service adapters,
current-role workspace refresh and premium native team organization/review UI,
then full privacy/recovery acceptance. The full Px goal and user deferrals remain
unchanged.


## Atomic team recurring completion — 24 October, rank 6 in progress

Team completion and next-occurrence creation now share one guarded transaction.
Actor-bound retries, source/series generations and durable write epochs protect
concurrent edits, Undo and Redo. Undo preserves later work; native acknowledgment
keeps provisional drafts when another generation wins. Both independent apps own
the persisted command, projection, transport and history integration.

Each repo passes 583 database checks (131 completion + 452 existing regressions),
262 selected Swift tests (17 new completion tests; broader recurrence coverage),
and unsigned Debug app/extension builds. Owned test containers/build products and
temporary Mac registration are removed. See TEAM_RECURRING_COMPLETION.md and the
completion evidence files. Native team editing stays disabled; no hosted/runtime/
distribution acceptance is claimed.

Next: dedicated review and current-role workspace refresh, remaining team
structural/comment/mention/file/service adapters, premium native organization UI
and full privacy/recovery acceptance. Cross-project existing series occurrences
currently fail safely and require explicit UX acceptance. The full Px scope and
user deferrals remain unchanged.


## Team completion outcome review — 24 October, rank 6 in progress

Both native apps now read and display a saved completion's authoritative outcome.
Recorded actions can resume sync without another write when acknowledgment is safe;
unrecorded actions retain their exact nonce and allow checking/retrying. The native
sheet compares current task/next-occurrence content and protects edited provisional
drafts. Read access, live sessions and frozen identities are checked before receipt
lookup; nonce locking resolves in-flight requests without implying cancellation.

Each repo passes 67 review database checks + 131 completion regressions, 271
selected Swift tests (nine new review tests), and unsigned Debug app/extension
builds. See TEAM_COMPLETION_REVIEW.md and review evidence. Owned containers,
temporary builds and Mac registration are removed. Team editing stays disabled;
no hosted/runtime/visual/accessibility/distribution acceptance is claimed.

Next: explicit rejected-action cancellation/rebase and provisional-draft
reconciliation, current-role workspace refresh/privacy, remaining team adapters,
premium organization UI and full native acceptance. Full Px scope and existing
user deferrals remain unchanged.


## Durable completion cancellation — 24 October, rank 6 in progress

Use synced task now cancels an unrecorded completion/Undo through its durable nonce
before removing an untouched local projection. The original workspace and queue
are saved in encrypted Recovery first. A racing recorded completion is reviewed;
lost responses, failures, permission changes and newly authored dependent work keep
the appropriate queue/drafts. Unrelated optimistic completion cycles are no longer
replayed twice, and related later atomic batches stay together for review.

Each repo passes 259 database checks (61 cancellation, 131 completion and 67 review
regressions), 328 selected Swift tests (13 new; includes 44 backup tests), and
unsigned Debug app/extension builds. Owned containers/builds and temporary Mac
registration are removed. See TEAM_COMPLETION_CANCELLATION.md and cancellation
evidence. Team editing stays disabled; no hosted/runtime/visual/distribution
acceptance is claimed.

Next: explicit rejected-action rebasing and edited-provisional-draft reconciliation,
current-role workspace refresh/privacy, remaining team adapters, premium native
organization UI and complete native acceptance. Full Px scope and the user's
release/provider/hardware deferrals remain intact.


## Explicit completion rebase — 24 October, rank 6 in progress

The native review can now complete the currently reviewed task or explicitly
reopen its current completion while preserving its existing next occurrence.
A Recovery copy and durable cancellation precede a fresh, persisted guarded
request. Updated content requires another visible review; current edit/series
capabilities disable unavailable actions and default closed for older servers.
New history belongs to the fresh action, and unrelated queued work stays intact.

Each repo passes 319 database checks (60 rebase/capability + 259 regressions),
338 selected Swift tests (10 new; includes 44 backup tests), and unsigned Debug
app/extension builds. See TEAM_COMPLETION_REBASE.md and rebase evidence. Owned
containers/builds and temporary Mac registration are removed. Team editing stays
disabled; no hosted/runtime/visual/distribution acceptance is claimed.

Next: explicit reconciliation of authored provisional drafts/related cohorts,
current-role workspace refresh/privacy, remaining collaboration adapters, premium
native organization UI and consolidated native acceptance. Full Px scope and the
user's existing release/provider/hardware deferrals remain intact.


## Saved provisional drafts — 24 October, rank 6 in progress

A recorded completion that adopted another occurrence can now park direct edits,
local deletion and comment drafts from its unused provisional generation. A full
Recovery copy and separate encrypted draft precede a durable generation fence;
only then are selected callbacks removed and the current shared rows acknowledged.
The Saved team drafts shelf exposes task details and copy/share controls without
automatic replay or retention eviction. Scope/cleanup gates protect private files.
Purely provisional history cannot poison fresh canonical creation or valid Undo.

Each repo passes 375 database checks (56 retirement + 319 regressions), 351 selected
Swift tests (13 new; includes 44 backup tests), and unsigned Debug app/extension
builds. Owned containers/builds and temporary Mac registration are removed. See
TEAM_PROVISIONAL_DRAFTS.md and provisional evidence. Team editing stays disabled;
no hosted/runtime/visual/distribution acceptance is claimed.

Next: unrecorded and compound/root/batch draft cohorts, explicit full-detail
reapplication, current-role workspace refresh/privacy, remaining collaboration
adapters, premium native organization UI and consolidated native acceptance. The
full Px goal and existing user release/provider/hardware deferrals remain intact.


## Completion review workspace preflight — 24 October, rank 6 in progress

A missing cached project now disables rebasing at preview time, using the same
requirement as final application. The review explains the missing project while
keeping the recovery-backed Use synced task path available. Three new regressions
pass in both repositories (65 completion tests each). See
TEAM_COMPLETION_REBASE.md and p2-team-rebase-project-evidence.json for final build
verification. No team-edit enablement or hosted changes; the prior remaining
rank-6 work and user deferrals remain unchanged.


## Reviewed saved-draft copies — 24 October, rank 6 in progress

Saved team drafts now offer an explicit preview and a same-project independent
task copy preserving authored details, certified files and extension data. Current
assignments and portable reminders are separately reviewed; off suppresses the
automatic planned alert. Old discussion/history stays in the encrypted archive.
A saved request prevents duplicates across retries/relaunch; durable cancellation
allows new choices, while an already-recorded copy is recovered instead.

Each repo passes 144 database checks, 481 selected native tests (19 new) and
unsigned Debug app/extension builds. Owned containers/builds and temporary Mac
registration are removed. See TEAM_DRAFT_COPY.md and each repo’s database/native
evidence for verification.
Remaining rank-6 scope includes other unrecorded/root/compound/batch draft cohorts,
current-role workspace/cache refresh/privacy, remaining team adapters, premium
organization UI and consolidated native acceptance. This stage does not enable
team editing, deploy hosted changes or reopen the user's release/provider/hardware
deferrals. The full Px goal remains in progress.


## Current-role workspace boundary — 24 October, rank 6 in progress

Refresh now validates current project roles around the full table read, filters
inaccessible content and restarts partial reads after access changes. Blocked
intents/cohorts stay queued with Recovery protection; unchanged quarantine does
not generate duplicate backups or immediate retry loops. Historical UUID custody
fences late legacy callbacks. A device-private presentation/fence protects widgets
and current read sources even while backup waits, fails or the app relaunches.
Partial team services never silently fall back to legacy sync.

See TEAM_WORKSPACE_ACCESS.md and each repository’s independent database/native
evidence. Team editing stays disabled; no hosted or native runtime/visual
acceptance is claimed. Remaining rank-6 scope includes raw-cache repair and full
open-editor/thread/readonly-control invalidation/native acceptance, other draft
cohorts, remaining collaboration/organization adapters and premium team UI. The
full Px objective and existing release/provider/hardware deferrals stay intact.

Verification: 57 database checks and 653 selected core tests pass independently
in each repository; iOS additionally passes 79 Watch tests. Both unsigned Debug
app/extension builds pass. Owned temporary builds and database containers were
removed. See the workspace evidence files for source and log hashes.


## Unreadable device workspace — 24 October, rank 6 in progress

Both apps now offer explicit preserve-and-reopen recovery for an undecodable
primary cache. A verified encrypted byte-for-byte original precedes replacement;
unsynced work stays archived for repair, while cloud sync and normal reviewed
backup restoration can resume. Originals can be exported and survive daily-copy
retention. No automatic salvage/replay or remote deletion is inferred. See
RAW_WORKSPACE_RECOVERY.md and per-platform evidence for verification. Remaining
rank-6 scope includes open-editor/thread/readonly-control invalidation, other
draft cohorts, remaining adapters and premium team UI/native acceptance. Existing
provider/hardware/release deferrals and the full Px objective remain intact.

Verification: 88 focused core tests per repo (including 6 new recovery cases)
and both Debug app/extension builds pass. iPhone and iPad native Cancel →
preserve/reopen → restore → relaunch checks pass; independent disk checks confirm
the restored task and encrypted original. iPad uses the largest text size in dark
appearance. Mac native runtime and VoiceOver acceptance remain open. Owned test
apps, builds and temporary Mac registration were removed.


## Open discussions follow current access — 24 October, rank 6 in progress

Discussion/mention projections, cached counts/cursors and late replies now follow
the live access boundary. An open composer withdraws Send and shared baseline
content after access changes while retaining private authored text and Save draft.
Team commands stay gated; blocked requests retain their original identity. See
DISCUSSION_ACCESS_REFRESH.md and platform evidence for verified scope. Ordinary
task-editor/inspector invalidation and unsent edit recovery remain open, alongside
other rank-6 draft cohorts, adapters, premium organization UI and acceptance.

Verification: 105 selected core tests per repo and both Debug app/extension
builds pass. The iOS app passes native held-reply → viewer → revoked → private
draft → relaunch checks on iPhone and largest-text dark iPad. Native disk proofs
confirm zero shared tasks/comments/mentions and one matching authored draft. The
existing iPhone offline-send/relaunch regression also passes. Mac runtime and
VoiceOver remain open. Owned test apps, builds and Mac registration are removed.


## Editor recovery vault and reviewed Inbox copy — 24 October, rank 6 in progress

The independent recovery mechanism now preserves full editor records and extra
state in encrypted per-account/backend checkpoints with revision/source fences.
Saved edits can be reviewed as a separate insert-only Inbox task or exported in
full for repair. Originals, shared history and permissions are not replayed;
assignments/reminders are off in the copy. See EDITOR_RECOVERY.md and platform
evidence for verified scope. This is the recovery foundation: live iOS editor and
Mac inspector capture/invalidation, pending-save/quit handoff and child editor
acceptance remain to be connected. The full Px goal remains active.

Verification: 111 relevant core tests pass in this repository, with a successful
Debug app/extension build. Mac runtime and VoiceOver acceptance remain open.
Live editor capture/invalidation and inspector autosave handoff remain unfinished.
Owned isolated test apps/builds/results were removed after preserving evidence;
2.25 GiB of temporary files reclaimed. No Mac test app was launched this stage.


## Live editor sessions and pending-save handoff — 24 October, rank 6 in progress

Store-owned recovery sessions now retain edits independently of the editing view.
The iOS task editor and Mac inspector pause on source/workspace/access changes;
Mac delayed saves stop and quit verifies retained checkpoints. iOS backgrounding
also flushes checkpoints. Note-formatting and checklist organizers register their
own unsent text/tree state. Successful saves/discards close a session and fence
late writers, while failed checkpointing retains the in-memory draft for retry.
See EDITOR_RECOVERY.md and p2-live-editor-evidence.json for exact verification.
The full role/account/child-flow acceptance matrix and native Mac/VoiceOver checks
remain open; team-native writes stay disabled and the full Px goal stays active.

Verification: 115 relevant core tests pass in this repository; the independent
Debug app/extension build passes. Mac runtime and spoken acceptance remain open.
Owned test apps, builds and results removed after preserving evidence; 1.75 GiB reclaimed. No native Mac app launched this stage.


## Nested editor source custody — 24 October

TaskEditorSourceContext separates the persisted access root from the record being
edited. Nested note formatting and checklist organizers now receive the complete
edited record plus its actual root ID. A recovered child retains its own title,
notes and checklist, rather than the root title/notes or unrelated siblings.
Only root/path/generation/project identifiers enter the recovery source identity.

Admission rechecks the captured root generation, owner and project, and resolves
the exact captured child path. Ordinary text updates and sibling reordering are
allowed. Missing/moved paths, ambiguous child UUIDs and changed child creation or
generation stamps refuse continuation. A new child cannot retarget a newly
persisted matching UUID. Root access checks remain separate from these identity
checks; no new team write adapter or organization permission is enabled.

Core and native scope are recorded in p2-editor-context-evidence.json. The broader
account/role transition matrix, additional draft cohorts, native Mac/VoiceOver
acceptance, remaining adapters and premium organization UI remain in progress.
Existing user deferrals remain unchanged; the full Px goal is still active.

Verification: 119 relevant core tests pass independently in each repository,
with successful Debug app/extension builds. Mac runtime/VoiceOver and the broader
role/account matrix remain open; Simulator acceptance is not Mac runtime proof.
Owned test apps/builds/results removed after evidence preservation; 1.82 GiB reclaimed. No native Mac app launched this stage.


## Editor opening admission and queued capture — 24 October, rank 6 in progress

Editor requests now capture their workspace incarnation and source root at the
opening action. Existing tasks require a matching stored source; deleted or
replaced records cannot silently become new tasks. New tasks require their
creating account and an unused identity. Nested opening values retain the
parent's workspace/root rather than resolving them again in another account.
Calendar, list, widget/notification, Inbox-review, pinned-note and nested editor
routes use the captured admission. Current Store write permissions are checked
separately before controls or mutation paths are admitted.

Quick Add → More checkpoints the authored task before deferred presentation. Its
Store-owned session and device vault remain bound to the original account while
the sheet is queued. A blocked presentation can preserve/close that original
checkpoint without writing in the current account. An unchanged, unsaved new
task is still an authored draft; it no longer disappears merely because it was
unchanged since More. Successful Save or explicit discard retires its session.
Private preservation is allowed while ordinary editing is paused (including an
unreadable cache or sign-out in progress); removal fences still prevent account
recreation. Recovery status directs the user to the original workspace.

See p2-editor-admission-evidence.json for core/build and synthetic native scope.
The test identities are local-only, not evidence of live cloud Auth, service role
transitions or Mac runtime/VoiceOver. Those checks, remaining draft cohorts,
scoped adapters and premium organization UI remain in progress. The ranked
backlog and every explicit user deferral remain intact; full Px is not complete.

Verification: 124 relevant core tests pass independently in each repository;
Debug app/extension builds pass. Mac native runtime, real cloud transitions
and VoiceOver remain open. Simulator proofs do not establish those gates.
Owned test apps, builds and results removed after evidence preservation; 1.75 GiB reclaimed. No native Mac app launched this stage.

## Native organization overview (24 October 2026)

Both app repositories now independently own the gated Teams overview and its
strict, ephemeral service models. Active/archived teams lead into role-aware
folders and directories. Incoming invitations and ownership offers are visible
without sending any email or performing a membership change. Refresh and
workspace/session/access invalidation discard prior directory contents; stale
reads cannot populate a different account. Organization membership never grants
project/task permission.

The disposable PostgreSQL harness now optionally exports actual list/get/invite
responses for all four roles; each repository generates and tests its own fixture.
See `TEAM_ORGANIZATION.md`, `p2-team-overview-evidence.json` and
`p2-team-overview-postgres-evidence.json`. Organization mutations, live service
rollout, broad native role/account acceptance and the remaining advanced-team
work are still open. This milestone does not complete rank 6 or Px.

## Reviewed native team/folder administration (24 October 2026)

Rank 6 now includes native Create/Rename team, Archive/Reopen and Create/Rename/
Remove folder, implemented independently in both repositories. Reviews retain
account/backend/revision identity. A private account/server-bound Keychain vault
saves the original command before send and keeps uncertain results through
relaunch; retries reuse the same body/ID and never rebase or renew an expired
request. Current authority still comes from the service. Local clearing is an
explicit review and does not undo remote work. Confirmed changes use existing
workspace sync so access projections can refresh.

The SQL harness exports real minimal command receipts for all seven actions as
an independent native-decoder fixture in each repository. See
`p2-team-commands-evidence.json`, `p2-team-commands-postgres-evidence.json` and
`TEAM_ORGANIZATION.md` for exact client, database, build and native scope. This
stage does not complete advanced teams or Px. Invitation responses and membership/
role management, ownership, leave/delete flows, broad live/native acceptance and
the remaining team-task/admission work stay open; user deferrals remain unchanged.

## Gated membership and ownership administration (24 October 2026)

Rank 6 now connects all eighteen organization actions to the native surface in
both independent apps. Incoming verified-email offers can be joined/declined;
existing members cannot join again. Owners/admins get the appropriate role,
revocation and removal controls; ownership requires a separate accepted offer.
Paused/archived teams retain allowed recovery actions, and deletion requires the
reviewed team name. Visible role descriptions, target account references and
explicit consequences support the review. None of these organization roles grant
project/task permission, send mail or enable team rollout.

Private recovery now also binds the original active/archived state without adding
unsupported RPC fields; invite/transfer receipts validate their new identifiers.
Verified leave/delete navigation happens before background task sync and is
scoped to the reviewed context. Actual PostgreSQL fixtures cover successful
receipts for all eighteen actions, including new positive leave/revoke cases.
Exact evidence is in `p2-team-members-evidence.json` and
`p2-team-members-postgres-evidence.json`. Real service/Auth/Keychain and broader
role/account/draft acceptance, verified identity presentation, Mac/runtime/spoken
checks and the remaining team-task adapters remain open. This milestone does not
complete advanced teams or Px; user deferrals remain unchanged.


## Scoped directory identity presentation — 24 October, rank 6 in progress

Team owners/admins can now identify members by saved profile name and confirmed
email rather than an opaque account suffix alone. Duplicate names retain separate
email/account references; role/removal/ownership reviews repeat the selected
identity. Names never grant authority, and commands retain exact account IDs
without saving the directory in recovery/task/widget storage. Missing or unsafe
identity text falls back safely. The Join review discloses directory visibility.

The source-only service wrapper enriches only authorized owner/admin directory
rows after the existing session/team lock; it adds no account-search endpoint.
Queued demotion returns the current lower role without directory content. See
`TEAM_ORGANIZATION.md` and `p2-team-directory-evidence.json`. Live-service and wider
native account/role acceptance, remaining draft cohorts, Mac/spoken checks and
scoped team-task adapters remain open. Teams stays disabled and all user-deferred
release/provider/device work remains deferred. The full Px goal is active.


Verification: 91 relevant core cases and 213 owned PostgreSQL checks pass in each
repository, with successful independent Debug app/extension builds. The phone and
tablet pass directory → exact member review → Cancel → lower-role view → owner
relaunch in normal and Accessibility XXXL sizes. Saved-state checks show no peer
mutation file or pending command. All eight screenshots are visually inspected;
large-text roles stack below names and the review email uses a separate full-width
line to avoid the standard label's truncation. Native Mac/spoken and live-service
acceptance remain open. Temporary test apps/builds/results were removed after
evidence preservation; approximately 1.08 GiB reclaimed. No Mac test app launched.


## Gated project catalog and access management — 24 October, rank 6 in progress

Projects now connects a team to its permitted project catalog and native create,
visibility/folder and access reviews in both independent apps. All four existing
management actions retain account/backend/team/project identity and revisions in
an independent private journal. Unknown results retry the same request after
relaunch. Reset explains the actual team-default outcome; team-role management
and guest restrictions stay enforced. Read fences prevent partial catalog/people
publication during access or account changes. No team task edit or rollout flag
is enabled, and no personal project/task path substitutes for this workflow.

See TEAM_PROJECT_ACCESS.md and p2-team-project-management-evidence.json for exact
client/service/native scope. Next remains live authenticated acceptance, broader
role/account/editor/cache/widget transitions, current-role task/comment/file and
service adapters, personal project adoption/templates/subprojects, and the other
ranked backlog. Native Mac/spoken and all user-deferred release/provider/device
work stay open. This does not complete rank 6 or the full Px objective.


Verification: 109 relevant core tests (including 10 new project-management cases)
and 152 owned PostgreSQL checks pass independently in each repo, with successful
Debug app/extension builds. Actual SQL fixtures cover 13 accepted receipts across
all four actions. The Mac canonical directory migration also passes its 213-check
regression run with unchanged SQL bytes. iPhone and iPad native tests pass create,
visibility/folder changes, lost reply/relaunch/same-request retry, guest Viewer
access, reset/removal and final relaunch. Saved records show one project, revision
4, four unique writes and no pending request. Accessibility XXXL create/settings/
access cancellation creates no peer file or pending command before the lifecycle.
All twelve screenshots are inspected. Native testing uses synthetic peer/private
IO, not genuine cloud Auth/Keychain. Mac runtime/spoken and broader live workspace/
editor/widget acceptance remain open; rollout/task-write flags stay disabled.
Owned test apps/builds/results are removed; approximately 1.11 GiB reclaimed.


## Reviewed project rename, archive and reopen — 24 October 2026

The gated project surface now offers Rename, Archive and Reopen, with explicit
active/own-archive/inherited-archive status. Older services without the versioned
state fields remain unknown and do not receive these new controls. A structural
review shows the complete affected project count and explains preservation before
confirmation. Cancel creates no command. The server rejects a branch if the
actor cannot manage every child, or if a reviewed branch changed. No child names
are disclosed by that review. Reopening a parent preserves individually archived
children; reopening under an archived parent requires reopening the parent first.

All seven project commands use the existing separate private project journal.
The archive review token/count, account, backend, IDs, revisions and request ID
survive uncertain results and relaunch. Exact retries return the original minimal
receipt without applying the operation again, including an old archive retry
after a later reopen. Fresh archive is available as a narrowing/recovery action
while setup is paused or the team is archived/at its budget; rename/reopen retain
the normal setup/team/budget restrictions. Requests expire after 15 minutes.

The canonical source-only migration is 20261024172109_team_project_archiving.sql
in each repo. A private, transaction/actor/team/root/project/operation scope lets
only the reviewed project metadata fields change. Existing task/comment/file
write guards stay untouched. The real legacy hierarchy cascade derives inherited
archive state while retaining child own flags. Team and hierarchy locks serialize
reviews against branch changes; affected project locks serialize against task
writers. Every affected binding revision and access boundary changes on apply.
The existing trusted whole-team cleanup scope remains separate. No hosted schema
or native rollout/task-write flag was changed.

Verification: 114 focused Swift tests, 93 owned PostgreSQL metadata checks and the
152-check project access regression pass independently in each repo. Actual SQL
review/command fixtures are decoded by each native core test suite. The database
suite covers lost responses/replay, stale branch/revisions, explicit manager and
lower roles, private/foreign/personal children, corrupt cycles/depth, paused/team
archive/quota recovery, unchanged task/discussion/file/custody/grant rows, epochs,
concurrent writes and project locks, direct-write rejection, exact scope rejection
and existing empty whole-team cleanup. Both Debug app/extension builds succeed.
See p2-team-project-archiving-evidence.json for native results and limitations.

This advances rank 6; it does not complete team collaboration or the full Px
objective. Live Auth/RLS/Keychain acceptance, Mac runtime/spoken checks, broader
workspace/editor/widget transitions, scoped team task/comment/file adapters,
project deletion with retained custody/Storage API cleanup, project adoption/
templates/subprojects and remaining ranked work remain open. All user-deferred
provider/device/release work stays deferred.

Native verification: iPhone and iPad each pass the two final normal/Accessibility
XXXL workflows. The saved peer contains one project at revision 4, exactly three
unique accepted changes (rename/archive/reopen), and no pending request. Sixteen
screenshots are visually inspected. Accessibility-size review titles shorten to
fit; long body copy remains in the scrollable form. The test waits for a control’s
center to be visible before tapping. Intermediate failed UI trials are described
in the evidence and are not counted as acceptance. Native tests use a one-project
synthetic file peer; task/content and descendant preservation are real owned-SQL
checks. Mac runtime/spoken and genuine hosted Auth/Keychain acceptance remain open.

Owned isolated test apps/runners and temporary host/build/result/attachment folders
were removed after preserving evidence; approximately 1.22 GiB of allocated artifacts removed. No Mac test app launched. Persistent core caches and unrelated apps, containers and runtimes remain intact.


## Paired offline Watch completion — 24 October, rank 7 in progress

The iOS-owned Watch client now uses its pending/review status for automatic
transport outages. Automatic activation/foreground refresh no longer leaves an
obsolete connection alert after a saved action. Explicit Refresh still reports
unavailability; validated phone updates clear that temporary error without
clearing unrelated save/protocol failures. No stored/wire fields changed.

A real iPhone Air/42 mm Watch Simulator pair passes 47 checks across three
independent offline completions: normal delivery plus ordinary phone Undo and
exact replay; an already-completed task; and a deleted/restored task with a new
incarnation. Each original pending command survives an offline Watch relaunch,
then the same Watch process receives the actual saved/stale receipt on phone
return. Normal replay leaves the task open with its one retained mutation proof.
Rejected replay and explicit local discard preserve every actual phone-cache
byte and add no mutation proof. No peer/packet or authority is injected. A
read-only observer verifies no obsolete connection error in the original process.
The final initial Watch viewport is visually reviewed: 2 due, matching the two
open phone tasks, with no obsolete alert. This is not native input/VoiceOver proof.

The paired fixture now isolates backend/session/recovery configuration, and its
fresh preparer is byte-compared with compiled inputs. Current phone/Watch Debug
and Watch Release compile; real-team signatures/native identities pass, and
Release excludes completion fixture/transport diagnostics. The 88 iOS Watch/
receipt cases and 9 Mac receipt-compatibility cases pass. The initial observer
trial ended before genuine delayed delivery; its result was observed saved before
a corrected fixture/feedback retake. It is not counted as full acceptance.

See p2-watch-offline-completion-evidence.json in the iOS repo and WATCH_COMPANION.md
there for exact scope. The Mac implementation has no Watch target or iOS build
dependency; only the unchanged private receipt contract is checked here. Genuine
cloud/hardware/background/system launch, account/phone/reinstall and native
controls/spoken/layout/icon acceptance remain open. Watch stays disabled and
unembedded in shipping sources. Rank 6 and the full ranked/Px objective remain
active; all user-deferred release/provider/device work stays deferred.

The disposable phone/Watch apps are closed and uninstalled; the selected Air/42 mm pair is restored to Shutdown. Both owned native build caches and prepared copies were removed after evidence preservation (approximately 1.3 GiB allocated). Existing phone/tablet boot states, core caches, user data, unrelated apps and runtimes remain intact. No device was erased or unpaired.

The [iOS-owned paired acceptance record](https://github.com/dbakp/TaskFold-iOS/blob/ed0c1189a4021079b89b83aed0d7be4cc461e0c3/docs/p2-watch-offline-completion-evidence.json) is committed at `ed0c118`; this is not a Mac runtime claim.


## Captured native team editor bridge — 24 October 2026

The captured draft now travels with existing-root editor admission. iOS Save uses
its explicit scoped Store path before personal label creation, reminder defaults
or personal task merging. The Mac inspector retains autosave and captures its
context once when opened; it renews the baseline only after a successful durable
save. An explicit denied admission cannot acquire fresh authority on appearance.
Note formatting and checklist sheets inherit the same context. Admission rejects
another root/workspace's context; secondary sheets cannot reset its baseline.

Title, notes, planning and checklist controls use this bridge. Project moves,
assignments, labels, recurrence, reminder management, root completion/deletion,
attachments, legacy comments and note pins are withheld where they still need
separate native team adapters. Quick entry and reference suggestions respect the
same limits. Ordinary personal Store writes still cannot infer a team scope.
The iOS Form is split into typed sections to keep SwiftUI compilation bounded;
its native layout and explicit Save remain in place.

Each repository passes 111 focused team/edit checks and 69 backup/recovery checks,
with no failures. Both native Debug app builds pass. The iOS widget extension also builds; the
isolated Mac helper omits its widget target. The isolated iPhone and
iPad each pass title editing, note-formatting application, exact scoped PATCH and
opening baseline persistence, different-creator/opaque-field preservation,
relaunch retention, and edit-to-viewer loss with a privately encrypted unsent draft
and no task write. The iPhone also passes the existing personal checklist
cancel/move/save/relaunch workflow. A separately selected personal-root test is
skipped because its exact namespace guard excludes this fixture; it is not counted
as a pass. The initial team-save attempts failed because simulated Command-A did
not select text. The test now uses the native Select All menu and asserts the
replacement before saving. Six final screenshots were inspected and retained in
the iOS repository. The native test backend rejects every HTTP request locally;
this proves client/UI/durable-disk behavior, not hosted authorization or delivery.

The Mac bridge is independently compiled; Mac runtime/autosave, hosted multi-actor
conflicts, broader account/role transitions, team checklist interaction and the
remaining field-specific adapters still need acceptance. Computer use reported
the Mac locked again, so no additional manual unlock was requested. Teams remain
disabled in both shipping Info.plists; only the reserved isolated copy enables the
switch. No schema, hosted service, provider, release setting or real data changed.
Rank 6 and the full Px objective remain active, with all user deferrals preserved.
See `p2-native-team-editor-bridge-evidence.json`. Reproduce the isolated copy with
`Scripts/prepare_team_editor_native_test.py --output <new-temporary-directory>`;
launch with `--team-editor-testing`, adding `--team-editor-reset` only to seed the
synthetic workspace.

Both isolated Simulator apps/runners are uninstalled. Owned temporary builds,
results, prepared copies and scratch files are removed (1.18 GiB allocated
across both repos). No Taskfold native app/test process remains; baseline Simulator
boot states and persistent core caches are preserved.

The iPhone/iPad runtime records and six screenshots belong to the independent
iOS repository at commit `8bdcd1913607526bb8ed2a01115f9f87b5212c19`. They do not
substitute for Mac runtime acceptance or create a build dependency.


## Native team checklist custody and acceptance — 24 October 2026

A real iPhone/iPad check found that a role downgrade removed the editable parent
form and dismissed its checklist sheet. The screen then showed only the parent’s
paused message, losing the checklist’s own recovery feedback. Both native editors
now own checklist presentation outside the editable form. One transient request
carries the local binding and frozen admission together. iOS also hosts child
Details outside the organizer’s editable branch, so a paused child retains its own
private draft and recovery state. No sheet opening refreshes team authority.

Checklist recovery now shows Preserving until the encrypted revision is verified,
then identifies its original workspace and Unsent task edits. An unchanged iOS
child closes directly on Cancel; edited children still require Discard changes.
The existing organizer layout, local review and parent Save flow are preserved.

Final iPhone acceptance passes six tests; iPad passes five, with no failures or
skips. The cases verify unchanged/edited child cancellation, organizer cancellation
with exact saved-cache preservation, child Save held locally until parent Save,
one scoped parent PATCH with the opening checklist baseline, preserved opaque child
fields and a concurrently observed sibling edit, relaunch, and role loss while
editing either the organizer or child Details. Role-loss cases verify the saved
private-draft message, unchanged stored checklist and no queued task mutation.
Existing team title/notes formatting Save/relaunch passes on both, and the existing
personal organizer cancel/move/save/relaunch passes on iPhone. All ten final
screenshots were inspected; six new checklist/recovery captures and one diagnostic
before-fix frame are retained in the iOS repository. Initial test selector and
DEBUG-toolbar ambiguities were corrected before relying on these final checks.

Each repository passes 143 focused workspace/checklist/tree/recovery tests. The
iOS app, widget extension and UI runner build; the independent Mac app builds with
its isolated helper’s widget target omitted. Mac interaction remains open: computer
use still reported the Mac locked, and no further unlock question was sent. The
native tests use synthetic accounts, a synthetic access boundary, a simulated
concurrent sibling observation and a Backend configured to reject HTTP. Hosted
multi-actor authorization, broader account/read-loss transitions, VoiceOver and
Mac runtime are separate acceptance work. Team rollout remains off in both source
Info.plists. No schema, hosted configuration, provider or real data changed.

Assignments/labels and other field-specific native team controls, independent child
records, wider native/live acceptance and the full Px objective remain open. All
user-deferred release/provider/device work stays deferred. Reproduction uses each
repo’s `Scripts/prepare_team_editor_native_test.py` and the four `testTeamChecklist`
methods in the iOS native suite. See `p2-native-team-checklist-evidence.json`.

Owned temporary copies/builds/results, frame-extraction cache and scratch files
are removed (1.28 GiB allocated across both repos). Both isolated iOS
apps/runners are uninstalled. No Taskfold native app/test process remains; baseline
Simulator boot states and persistent core caches are preserved.

The independent iOS runtime summaries and inspected captures are recorded at
`TaskFold-iOS` commit `b1ca194e50ffcebf8fbc1a7445a835e2eff078c8`. This is an
evidence reference only; the Mac app has no build dependency on that repository.


## Project-scoped team assignments — 24 October 2026

The gated team editor now offers Unassigned, You and teammates with current
editing access to the exact project. iOS retains the choice in the task draft
until Save; the Mac inspector uses its existing scoped autosave path. The picker
uses native rows, search, selection feedback and explicit refresh/error states.
It keeps display names only in memory and never loads the manager directory or
uses a retained task creator as authority. Personal assignment controls are
unchanged. Team quick-entry assignment remains excluded until it has its own
scoped adapter.

A source-only recipient RPC returns a bounded, account/project/access-fenced
catalog with IDs, project roles and sanitized display names. It discloses no
emails, invitations or organization-wide directory. Live actor/session and access
checks reject viewers, unrelated projects and disabled/archived contexts. New
recipient membership/access is checked on selection. Connectivity failure may
retain an already reviewed choice as a frozen offline intent; authentication,
malformed responses and access loss never use that fallback. The write service
still independently validates the recipient. Self and Unassigned remain usable
without a directory request. Closed or retargeted pickers ignore late replies.

Both repositories independently pass 34 synthetic PostgreSQL checks with no new
advisor warnings/errors. Each owns its migration, lookup/client/model/view, SQL
fixture and nine new core tests. Full core suites passed before the final bounded
transport refinement (iOS 1,707 tests, 13 environment-gated skips; Mac 1,739 tests,
33 environment-gated skips). After that refinement, all 76 focused recipient,
workspace, edit and project-access tests pass in each repository without skips.
The Mac isolated app compiles unsigned; its helper omits the widget target.
Native iPhone/iPad results and exact evidence are recorded in
`p2-team-assignment-evidence.json`. Initial native harness failures were corrected:
use a measured short drag to reveal the full row above the tablet sheet edge
(the broad swipe overscrolled), scope child controls to the child
form, and assert the parent’s actual absent assignment rather than assuming an
explicit JSON null. These did not require changing the saved-task implementation. The initial iOS compile caught a helper placed
on the presentation wrapper; it was moved to the editor before native testing.

No hosted migration, team rollout switch or real account/task changed. Native
checks use an exact DEBUG bundle/argument fixture; only its synthetic recipient
RPC is answered locally, and all other requests fail without network. Mac
interactive/spoken acceptance, hosted multi-actor acceptance, remaining native
field adapters and the full rank-6/Px scope remain open. All user deferrals stay
in place.

Final assignment acceptance passes four tests on iPhone and four on iPad,
with no failures or skips. The four new picker/recovery screenshots were inspected
and retained in the iOS evidence directory; both displays show readable, complete
rows and status text. Native Mac interaction remains a separate open gate.

Stage cleanup removed 1,318,117,376 allocated bytes of owned temporary builds,
results and scratch files across both repositories. Both isolated apps/runners
are uninstalled, with no Taskfold native app/test process left. Baseline Simulator
boot states and persistent core caches are preserved.

The independent iOS Simulator evidence is recorded at `TaskFold-iOS` commit
`8e27b0147691d7ec3af4cf2822f2a2e05ec9ee33`. This is an evidence reference; the Mac build owns all its inputs.


## Shared task labels — 24 October 2026

Gated team Details now opens a dedicated shared-label editor. It supports adding
and removing portable label names, existing legacy entries, and suggestions from
visible tasks and nested children in the same project. Personal catalogs and
other projects never supply those suggestions. Apply returns the choice to the
iOS task draft (or the Mac inspector’s scoped autosave); Cancel keeps the task
unchanged. Captured editor scope and the original label baseline remain in charge.
The sheet stays present after access loss, keeps its edit in the private encrypted
recovery vault and blocks callbacks into the wrong task/workspace.

A team label is text, not a lookup into an individual’s label table. Scoped task
mutations now preserve that text without personal name-to-ID normalization.
Personal label rename/delete only considers personal task records, including when
a shared task has the same label name. Team quick-entry no longer resolves label
references through personal IDs; its separate shared-label adapter remains open.
Personal editing retains the previous normalization behavior.

New names allow 1–100 characters (at most 400 UTF-8 bytes), with no controls,
bidi overrides or UUID-shaped catalog IDs. Existing nonempty strings up to the
service’s 1,024-byte limit remain exact, ordered and removable; unsafe names/IDs
appear as Saved label instead of being resolved through personal data. Duplicates
remain until explicitly removed. A future/unsupported list is read-only and
preserved. No list is silently truncated. Project suggestions inspect at most
2,048 nodes/4,096 values and offer up to 200 names, keeping large projects bounded.
The service’s 256-label task limit and guarded replacement baseline still apply.

Both repositories pass 71 focused team/model checks and 140 label/conflict/
quick-entry/recovery regressions. After tightening the suggestion work bound,
all seven new model cases pass again. These cover text/legacy preservation,
invalid/future/oversize values, Unicode, project-only suggestions, frozen scoped
mutations/relaunch encoding, personal normalization and shared-task exclusion.
The existing server planning validator/contract is unchanged; this stage adds
no migration, hosted configuration, permissions or new network endpoint.
Native phone/tablet and build results are recorded in `p2-team-labels-evidence.json`.

Each app owns its code, model and tests independently. Team rollout stays off.
Mac interactive/spoken and hosted multi-actor acceptance, remaining field adapters,
independent child records and the wider ranked/Px work stay open. All existing
user deferrals are preserved.

Final native acceptance passes five tests per device on iPhone and iPad, with no
failures or skips. Four label cases cover typed-text Apply, scoped Save/relaunch,
unchanged personal catalogs, Cancel, encrypted access-loss recovery, child labels
and actual personal label rename/reset/delete without changing shared tasks. The
existing assignment Save/relaunch regression passes too. Six new label/recovery
screenshots were inspected and retained with both summaries in the iOS repository.
The initial native reveal helper imposed a 60-point margin on a fully visible
last debug row; its label-form margin is now 12 points. Review also fixed Apply
dropping unsubmitted name text; the final native Save case types without Add.

Stage cleanup removed 1,278,590,976 allocated bytes of owned temporary builds,
results and scratch files. Both isolated apps/runners are uninstalled, with no
Taskfold native app/test process left. Baseline Simulator boot states and
persistent core caches remain intact.

The independent iOS runtime evidence is at `TaskFold-iOS` commit
`80dff267d9bda5fafba2559e57b90ae3e2735ffd`. This is an evidence reference only; Mac build inputs remain independent.


## Shared reminder controls — 25 October 2026

Gated team task Details now opens Shared reminders. The existing native settings
editor is reused for relative/planned, fixed-time, repeating calendar, elapsed
interval, reviewed holiday and Time Sensitive choices. Apply returns the complete
list to the iOS parent task draft; the Mac inspector uses its scoped autosave.
The shared sheet has no notification-permission, remote-delivery or private-place
setup controls. Device delivery stays opt-in separately. Existing private/future
and non-local-channel rows are shown generically and retained unchanged; their
names, geometry and hidden payloads are not displayed or resolved.

A bounded task-local review preserves unique reminder identities and the existing
20-choice service limit. Unknown list shapes stay read-only. Only recognized,
local portable rows can be changed or removed. Appending to an implicit empty
list retains the existing planned alert; removing the last editable choice adds
an explicit disabled planned row so it cannot reactivate an implicit alert.
Duplicate enabled schedules and stale child-editor row snapshots are rejected
without a partial change. Future row/rule/interval/holiday/origin extension fields
survive known-setting and schedule-kind changes, matching the current service
contract. No server migration, permission or endpoint changes are introduced.

The shared list owns a private editor checkpoint. The nested settings editor
reports its unfinished fields (including text that does not yet parse) to that
same checkpoint. On access loss it hides editing controls, blocks Done/time-zone/
holiday callbacks and retains the settings sheet with verified preservation
feedback. Cancel during ordinary editing clears only the child draft; Cancel on
the shared list leaves the parent task unchanged. Changed reminder/label sheets
block interactive dismissal, and access-loss Close requires a successful flush
rather than assuming an absent first revision means no preservation failure.
Empty unchanged sheets close their unused editor session. Recovery remains a
private record/export; it never grants authority or automatically replays reminder
settings into a shared task.

Each independent repository passes 157 reminder/planning checks (eight new cases)
and 131 label/workspace/checklist/recovery regressions. The model checks exercise
portable variants, extension retention, locked rows, legacy defaults, limits,
identity/shape failures and atomic stale-input rejection. Build and native device
results are recorded in `p2-team-reminders-evidence.json`. Initial native harness
corrections use the Time Sensitive switch thumb plus a value-change assertion,
and keep phone task-editor taps clear of the isolated debug bottom toolbar.

Team rollout stays off. Source/native tests use synthetic accounts and intercepted
networking; no real task or provider configuration changes. Mac interaction and
VoiceOver, broader live account/concurrency/fault and nested holiday/time-zone
acceptance, remaining task field adapters, independent child records and the full
ranked/Px objective stay open. All user-deferred release/provider/device work
remains deferred.

Native acceptance: all five selected checks pass without skips on both iPhone
and iPad Simulator. Six reminder screenshots were inspected and retained with
result summaries in the iOS repository. The Mac app builds independently; Mac
runtime and spoken checks are not claimed. Temporary host apps/runners and stage
build/results are removed after preserving evidence; baseline simulator states
and reusable core caches are retained.


## Shared task repeat controls (rank 6, acceptance scoped)

The team task's Repeat action now opens the complete existing native recurrence
controls in a review sheet. It supports daily/custom intervals, selected weekdays,
monthly dates or ordinal weekdays, yearly dates, completion-based scheduling,
end dates, occurrence limits and the existing upcoming-occurrence preview.
Apply changes the iOS parent draft; its ordinary Save remains responsible for the
scoped durable mutation. The Mac inspector commits the reviewed fields through
its existing scoped autosave path. Cancel keeps the parent unchanged. Personal
Repeat controls keep their existing flow. Unfamiliar or malformed source rules
are shown as saved/read-only instead of being rewritten by incomplete controls.

A repeat edit captures the original rule, legacy end date, planned date/time and
zone, completion state/time and completion revision as one review context.
The native scope rejects missing/stale context; the server repeats that check
under the existing task lock. An intervening complete/reopen cycle is detected
by its revision even if its visible state returned to the original. Unrelated
notes may still merge. Completing and editing a repeat rule are separate actions;
series parent links, generations and completion bookkeeping remain server-owned.
Undo/redo carry the applied/original contexts through the existing history path.
Stable-request retries acknowledge an already accepted edit without replaying it.

The sheet registers a private recovery session before editing. Access loss stops
Apply, keeps the unsent rule with its source workspace, and requires a verified
flush before Close. Changed sheets resist interactive dismissal; a clean cancelled
sheet releases its unused session. Recovery remains a private record/export and
does not restore authority or automatically replay the rule to a shared task.

`20261024222451_team_task_repeat_edits.sql` is source-only in each repository.
It extends the existing private reviewed edit function and adds two private pure
validators. No new public endpoint, table, grant, rollout switch or hosted change
is introduced. Existing role/session/lock/retry/checklist behavior stays in the
same function. Provider, remote-delivery, old-client and distribution dependencies
remain deferred. The full ranked/Px objective is still open; scoped test results
must not be read as live multi-account, Mac runtime, VoiceOver or release proof.

Verified stage evidence: each repository passes 53 new PostgreSQL checks plus
221 existing team edit/planning/checklist checks against the new migration,
including advisor checks. Full suites ran 1,732 iOS Core cases (13 optional skips)
plus 79 Watch cases, and 1,764 Mac cases (33 optional skips), with no failures.
After one additional review-boundary test, the final focused suite passes all
191 selected cases with one optional live-concurrency fixture skipped; all ten
new repeat cases pass. Both native apps build independently. The final iPhone
and iPad runs each pass five native checks without skips, covering saved rule/
legacy end date, queue/relaunch, Cancel, private role-loss recovery, future-rule
preservation and the existing reminder-Cancel regression. Six captured images
were inspected and retained with result summaries in the iOS repository.

The initial iPad helper rejected a visible first switch by one point at its
scroll boundary; its three reveal assertions failed while subsequent state
assertions passed. The corrected helper passes the final runs. Xcode's optional
diagnostic collection after the completed failed run was stopped before its
replacement run. Exact source hashes and limits are in the stage manifests.
Owned temporary apps/runners and stage builds/results are removed after evidence
capture; baseline Simulator states and reusable Core caches are retained.


## Reviewed native shared-task deletion (rank 6, acceptance scoped)

Single shared task deletion now opens a review showing the current captured task,
project and deletion scope. The details editors and ordinary list actions use the
same explicit scoped Store path. The Mac selection command routes a single root
through a workspace sheet and registers the existing Edit-menu Undo; the iOS list
uses its existing confirmation/Undo toast. Existing independent occurrences stay
in place. Checklist items remain part of their parent and cannot accidentally open
a parent deletion review. Native team batch/child deletion and broader layout/
accessibility/live acceptance remain open rather than falling back to personal
writes.

The review retains its opening `TeamTaskEditorDraft` and one operation nonce.
Every confirmation revalidates the account, workspace/session incarnation, backend,
access fence, current role and exact saved task contents. It sends the whole frozen
source to the existing lifecycle service; it never substitutes a newer observed
row, strips unfamiliar values or truncates an oversized request. A refused or
failed durable save leaves the review, task, queue and history intact. A retry uses
the same intent; successful deletion dismisses once. Existing restore receipts,
fresh task generations, scoped history, linked-occurrence preservation and server
conversation archives own Undo. The current session's device history and current
server permissions still bound recovery; this is not a new permanent trash bin.

Unsent parent task fields, comments, checklist input and note-pin changes prevent
deletion from details. iOS paused-editor Close now also verifies an open recovery
session contains the actual latest task and extras before flushing; an absent,
closed or failed first revision cannot be mistaken for a protected edit. The
failure message offers Retry. Personal and nested Mac deletion feedback and iOS
personal list feedback now appear only after their durable commit succeeds.

When the review becomes unavailable, its old task/project content is hidden and
confirmation is disabled. The review never reacquires authority after a role,
workspace, session or backend change. No new server endpoint, migration, grant,
provider registration or hosted data change is introduced. Team rollout stays
off; all user-deferred release/provider/remote-delivery dependencies remain as
recorded. The full ranked/Px objective is still active.

Verification: both repositories pass 230 focused Core cases without skips or
failures, including eight new whole-source/authority/Undo/payload-boundary cases.
Each owned PostgreSQL fixture passes 70 conversation lifecycle/recovery checks
using the current workspace/lifecycle loader. The existing fixture still leaves
linked batch completion unclaimed. Both independent apps build. All seven native
flows pass on both iPhone and iPad: changed source, Cancel, failed save/retry,
actual TaskScreen context-menu/Undo toast, deletion/Undo/relaunch, role loss and
unsent-title/private-recovery Close. The context-menu case includes two long
XCTest idle waits but finishes successfully; no live run was restarted.

Visual inspection caught a destructive action that looked active while disabled.
Its label now uses an explicit semantic secondary color when paused. Both apps
were rebuilt; the paused-state case passes once more on each device. Eight
representative review/failure/recovery images and complete summaries are retained
in the iOS repository; the final paused images replace the pre-polish versions.
Mac runtime/keyboard, VoiceOver, wider native/account/concurrency/fault/large-text
acceptance and the remaining ranked/Px work stay open. Owned temporary apps,
runners, prepared hosts, build/results and scratch files are removed after evidence
capture. Baseline Simulator states, reusable Core caches and unrelated files stay.


## Full shared-task creation — 25 October 2026, rank 6 in progress

Shared projects now enter the complete task editor through an explicit creation
admission. iOS project + opens Add Task; Mac Quick Add opens the full inspector
as a creation sheet. Notes, planning, scoped assignment, shared labels/reminders,
Repeat and checklists remain available. Secondary Apply stages this new task;
only Add creates it. The existing Mac inspector still autosaves existing tasks.
Mac creation failures stay in a sheet-local alert and preserve the draft.

Creation captures the actor, project/team, access token, session and workspace at
opening. It requires a fresh identity and zero completion state, rejects copied
private content/bookkeeping and unsupported changes as a whole, then emits one
insert-only scoped lifecycle command. Existing task edits keep their current-row
requirement; creation cannot upgrade into PATCH or deletion after an ID collision.
Nested editors inherit the same admission. Private recovery records preserve text,
not authority. Personal writers and catalogs cannot infer a shared destination.
No migration, hosted configuration or distribution setting changed. Rollout stays
off and every user-deferred dependency remains deferred.

Both owned repositories pass 106 focused cases (eight new creation cases) without
failures/skips. Full suites pass: iOS 1,749 Core cases (13 optional skips) plus 79
Watch cases; Mac 1,781 cases (33 optional skips), all without failures. Each owned
PostgreSQL lifecycle fixture passes 89 checks with conversation regression enabled,
removes its own container, and makes no hosted change. Both Debug arm64 apps build.
Five native flows pass on each iPhone/iPad Simulator: actual project + entry,
Cancel, notes/labels staging and single insert/relaunch, role loss, and failed
Store save/retry. Eight screenshots and both summaries are retained by iOS.
The first diagnostic runs corrected two test-harness issues (AX field type and a
missing toolbar hook); final acceptance uses the fixed fixture. Failed diagnostic
collectors were stopped only after every case ended and sampling confirmed their
collector state. No active scenario was replaced or restarted.

Mac runtime/keyboard, spoken feedback, wider native field/account/fault/layout and
hosted/concurrency acceptance remain open. Moves/adoption, linked native batches,
templates/conversations/files and the rest of ranked Px remain in scope. Watch
navigation was not accepted: the native-control tool again reported the Mac locked
after the unlock reply; no repeated manual unlock was requested. Disposable apps,
runners and owned temporary builds/results are removed after evidence capture;
Core caches, baseline Simulator states and unrelated files remain intact.


## Reviewed atomic shared-task deletion — 25 October 2026, rank 6 in progress

Both apps now route shared root-task selections through an explicit review of
every selected title and project. One immutable command deletes 2–100 tasks from
one team, including linked repeat occurrences, through the existing atomic batch
service. Projects and retained creators may differ. Single-task deletion keeps its
separate review. No ordinary personal writer infers shared permission.

Opening-time rows, member nonces, group nonce and access context remain frozen.
Changed/missing/recreated tasks, role/token/session/workspace changes, duplicate or
mixed selections, selected cycles and oversized requests stop the entire action.
The review never drops a missing member, adopts a newer baseline, chunks a large
selection or falls back to single-task writes. Both list entry points detect a
previously known shared ID even after its row disappears, before any personal or
nested recursive writer can run. A failed durable save keeps every task and the
review intact. Failure messages are consumed inside the review, preserving retry.

The existing atomic local projection, persisted queue, one RPC and receipt-scoped
Undo/Redo own delivery. The actual native list check deletes a selected parent and
occurrence while retaining an unselected occurrence, then restores the selected
links with fresh generations through Undo. Queue identities and restored contents
remain exact after relaunch. Task/project text is hidden when review is paused.

Both independently owned repos pass 319 focused team Core cases with no failures
or skips, including ten new selection/custody/bounds/linked-Undo cases. Each owned
PostgreSQL fixture passes all 72 existing batch checks against the current complete
workspace loader, including rollback, permissions, replay and discussion recovery;
the fixtures remove their containers. No hosted schema/configuration or migration
changed. Both Debug arm64 apps build; the Mac test helper omits widgets.

Five new production-list scenarios plus the existing single-task failed-save
regression pass on each iPhone/iPad Simulator: linked deletion/Undo/relaunch,
Cancel, changed member, role loss, and failed save/retry. Eight screenshots are
visually reviewed and retained with both complete six-test summaries by iOS. The
initial native diagnostic used an identifier stripped by the system Menu; it now
selects the real “Select tasks” label. Its failed collectors were terminated only
after all cases ended and process samples confirmed diagnostic collection. An
initial unit fixture also needed canonical sorting of randomly generated project
IDs; no app validation was weakened. Final runs pass normally. Full non-team
suites were not repeated after the immediately preceding creation milestone.

Mac runtime/keyboard and spoken acceptance, wider native mixed/account/large-text/
fault/concurrent cases and hosted lifecycle acceptance remain open. Task moves/
adoption, templates/conversations/files, independent child records, remaining
Watch/Wear OS and the full ranked Px objective stay in scope. Team rollout remains
disabled; every user-deferred release/provider/remote-delivery dependency stays
deferred. Owned test apps/runners and temporary builds/results are removed after
evidence preservation; baseline Simulator states and Core caches remain intact.


## Shared-task move service and client recovery — 25 October 2026, rank 6 in progress

Both repositories independently own a disabled same-team task-move service and
its typed client/recovery foundation. This stage does **not** add a native Move
screen or complete task moves, personal-project adoption, or rank 6.

A review identifies the exact source/destination, literal task, destination
visibility, discussion count and assignments to clear/restore. Its short-lived
server proof binds task/discussion epochs and the workspace-access boundary.
The transaction preserves identity, creator, generation, notes and other task
fields; moves comments with incremented revisions; retains mention read history;
updates custody; and clears section/root/child assignments. Undo/Redo restore
reviewed placement through encrypted, 30-day recovery with existing cleanup and
account-removal lifecycles. Receipt/key locking and a final key check prevent
using a recovery copy erased while Undo waited. Provider-bound attachments stop
for their own transfer review; cross-team moves and personal destinations stop.

The client saves one exact IDs/proof-only request privately per account/server
before sending. Lost replies, write/remove faults, foreign acknowledgements,
account switches and another window's changed request preserve safe recovery.
An expired saved request may still reach the server for acknowledgement of a
previously accepted action; the service rejects its first application after
expiry. No ordinary task writer gains a shared-project move path. Account
removal erases the separate move vault.

Each repo passes 334 focused team Core cases (15 new move cases), 90 owned
PostgreSQL move checks, and the existing 72 batch checks with this migration
loaded. No focused failures or skips remain. Both isolated Debug arm64 apps
build; the Mac helper omits its widget extension. The batch regression exposed
an unsafe trigger branch for linked-task detach updates; type-specific nested
branches fix it and the complete 72-case run passes on each current schema.
Advisors report no new warnings; known fixture-policy performance notices remain.

Next: native reviewed destination selection with queued-edit/session/workspace
fencing, durable retry/clear, fresh cache reconciliation and linked Undo/Redo;
phone/tablet/Mac layout, runtime, keyboard and spoken acceptance; broader hosted
lifecycle/concurrency acceptance; and a separately reviewed personal-project
adoption workflow. Per-task provider file custody, templates/conversations/files,
independent child records, remaining Watch/Wear OS and wider Px work stay open.
No hosted migration/configuration or rollout switch changed. All user-deferred
release, older-client rollout, remote-delivery, OAuth/provider and real location
dependencies remain deferred. See `p2-team-task-move-foundation-evidence.json`.


## Reviewed native shared-task moves — 25 October 2026, rank 6 in progress

Both apps independently own the native same-team Move flow from existing task
inspectors and single-task list moves. The destination picker admits only active,
writable projects in the same team. Confirmation identifies the literal task,
source/destination, destination visibility/audience, discussion count and assignment
changes. Opening-time task contents, workspace/session and access token are frozen;
changed source/access or queued local writes stop preparation. Existing personal
writers remain separate. Mixed/shared batches, cross-team moves and personal-project
adoption are not silently treated as a sequence of single-task actions.

Recent moves are reachable from task-list options and team-project management.
One private atomic envelope owns pending delivery and the 20 most recent move
chains. Accepted delivery cannot erase its retry request before durable history is
saved. Reviewed Undo/Redo stay in one chain across relaunch; a delayed earlier
acknowledgement cannot rewind later history. This is explicit move history, separate
from the app's general local Undo/Redo stack. It contains IDs/proofs rather than
notes or discussion text, preserves the previous one-command journal's exact nonce,
and participates in account-removal fencing and cleanup. Clearing a retry keeps
accepted history and does not cancel or undo an accepted server move.

A confirmed receipt triggers a fresh normal workspace sync rather than projecting
an old task reply over local changes. Refresh failure keeps accepted history and
offers explicit refresh. Closing an uncertain result keeps the saved retry;
closing a confirmed screen completes its inspector/list presentation once.

Both repositories pass 340 focused team Core cases, including 21 move cases.
The new cases cover atomic journal failure, old-envelope migration, linked durable
history, stale acknowledgements, scoped removal, corrupt/foreign history and full
source/access/queue admission. Both isolated Debug arm64 apps build; the Mac helper
omits widgets. There are no schema or hosted-configuration changes in this stage;
prior owned move/batch PostgreSQL evidence remains in the foundation evidence.

Six scenarios pass on each iPhone/iPad Simulator through real native controls:
actual-list selection and Move, Cancel, changed source, role loss with hidden review
contents, lost reply/relaunch/exact-nonce retry, and move/Undo/Redo/relaunch with
normal Done cleanup. The native peer is a separate file-backed synthetic server,
with its accepted request identities checked independently from the actual saved
Store cache. All HTTP stays intercepted. An initial exact-Undo assertion exposed an
omitted section field in the fixture; seeding SQL's explicit null fixed the fixture
without weakening the whole-record comparison. Final runs pass all six cases.
Screenshots and complete summaries are retained by iOS. No Mac runtime, genuine
hosted or spoken acceptance is inferred from these Simulator checks.

Next: personal-project adoption with a separate ownership/audience/contents review;
shared batches and broader task-move history/keyboard integration; Mac runtime and
keyboard, spoken/large-text/dark/account-switch/private-save and simultaneous-window
acceptance; provider-bound per-task file transfer, templates/conversations/files,
independent child records, remaining Watch/Wear OS and the rest of ranked Px.
Rollout remains disabled. All user-deferred release, older-client, remote delivery,
OAuth/provider and physical-location dependencies remain deferred. Owned apps,
runners and temporary builds/results are removed after evidence capture; baseline
Simulator states and Core caches stay intact. See `p2-team-task-moves-native-evidence.json`.


## Project-adoption ownership boundary — 25 October 2026, rank 6 in progress

Both repositories independently own the source-only transaction boundary needed
for personal-project adoption. The transfer API/client/native screens are still
unimplemented; this milestone does not complete adoption or rank 6. The full
intended protocol, access decisions, forest/linked-work preservation and required
commit ordering are recorded in `TEAM_PROJECT_ADOPTION.md`.

Identity-only per-row epochs detect authored edit/revert and project delete/reuse
without serializing unrelated task edits on one project counter. Private deferred
realm tickets reject a personal task edit/insert, discussion, subproject or pending
invitation acceptance that would otherwise finish after team custody changes.
Shared/exclusive try-locks avoid waiting while holding rows needed by the other
side. Unrelated projects keep saving. The private binding writer can approve only
its own transaction's deliberate cutover, never another writer's ticket.

Exact private project/parent/visibility/folder scopes permit a future reviewed
forest admission. Deferred placement verification still checks the final binding
and parent after temporary scope rows are erased. Personal invitation retirement
skips automatic assignment clearing only in an exact private adoption scope; this
keeps eligible assignment provenance intact. The future service must explicitly
compute and apply every ineligible assignment change. Ordinary collaboration
removal still clears departed assignees, and native owner/member team-project
creation remains accepted. No new public adoption or scope-authority API exists.

Each independent owned PostgreSQL fixture passes 52 new ownership-boundary checks,
90 existing task-move checks, 95 project-hierarchy checks and 72 batch checks with
this migration loaded: 309 checks per repo, no final failures. The focused fixture
loads actual assignment-provenance code and inspected invitation/assignment-cleanup
definitions, and verifies mention read epochs and personal Auth cleanup. Advisors
show no new warning categories beyond known auth-initplan policy notices. Current
app code is unchanged, so no new native build/runtime acceptance is claimed.

The first diagnostic fixtures corrected a missing-row JSON-null helper and an
unsupported direct comment write by the authenticated fixture role; the latter is
now explicitly a privileged synthetic write, not a claimed native API. That early
control failure exposed a test-helper cleanup gap. Cleanup now removes its owned
container even when the control session has already failed, retains SQLSTATE and
preserves the primary error. The one leaked diagnostic container was inspected and
removed. A dedicated failed-control case verifies the repaired helper.

Next is the reviewed inspect/review/adopt controller with exact immutable manifests,
collaborator/effective-access decisions and durable retries, followed by native
review/recovery on both platforms. Storage custody, paused personal integrations,
shared batch/history/keyboard work, remaining Mac/spoken/layout/account/window and
hosted acceptance, independent child records, remaining Watch/Wear OS and wider Px
remain open. No hosted schema/configuration or rollout switch changed. Every
user-deferred release, general older-client, remote-delivery, OAuth/provider and
physical-location dependency stays deferred. See
`p2-project-adoption-fences-evidence.json` for exact scope and cleanup.


### 2026-10-25 — Reviewed project-adoption service (source only)

Implemented inspect/review/adopt for owned personal project branches. The review
binds all selected descendants, complete content/row epochs, destination ancestry,
team/access state and explicit collaborator decisions. It distinguishes retired
personal grants from access supplied by team visibility/admin status and counts
exact ineligible root/checklist assignment clears. Inline and nested attachments,
completed work, archived projects, discussions, mention read history and eligible
assignment provenance remain accounted for; there is no automatic custody Undo.

The atomic commit keeps original identities/creators, closes personal invitations,
places the branch under the reviewed team parent/folder/visibility and saves an
identity-only durable receipt. Exact retries work after expiry, access loss,
disabled rollout and subsequent task moves without rewinding later work. Source
changes, forged decisions, request collisions and live-session loss are rejected.
A disabled-by-default `native_project_adoption_enabled` flag gates new commits.

Personal service authorization rechecks custody after its row lock, and personal
webhook capture excludes team custody and exact adoption scopes, including global
subscriptions enrolled later. Old snapshot-isolated personal writers cannot
bypass the commit ownership check. These are cutover safeguards; broader deferred
old-client rollout work is still separate. No provider/network/rollout is enabled.

Both independent fixtures pass 148 SQL checks with real email/domain, webhook/
outbox, hierarchy, assignment-provenance and guarded task-move migrations loaded.
Checks include mid-transfer rollback, a late old-client task, a waiting personal
service caller, normal post-adoption moves/workspace refresh, uppercase legacy
assignees, a full 1,000-collaborator transfer, 32 MiB contents/256 KiB command bounds,
quotas and exact receipt recovery. Advisors add no new warning categories. No new
native app build/runtime or hosted acceptance is claimed. Test sessions and owned
artifacts are cleaned; details are in `p2-project-adoption-service-evidence.json`.

Still required: private native command/recovery, premium Mac/iPhone/iPad review
screens and draft-preserving refresh; explicit file-custody and personal integration
pause/retarget adapters. Affected transfers currently fail atomically with a clear
review requirement. This does not complete rank 6 or the wider Px scope. Remaining
shared batch/history/keyboard, Mac/spoken/layout/account/window/hosted acceptance,
independent child records, Watch/Wear OS and all other open plan items remain open.
Every user-deferred release, provider and physical-device dependency stays deferred.


### 2026-10-25 — Native project-adoption review and recovery (source)

Implemented each app's independent typed adoption client, private recovery journal
and native branch/location/contents/access/final-review flow. The UI defaults to
private visibility, requires an explicit decision for each accepted collaborator,
shows resulting effective access, affected descendants, own/inherited archive
outcomes and exact assignment/invitation counts, and explains custody/Undo before
confirmation. Unsupported file-custody and integration cases remain blocked.

Requests persist only UUIDs, role choices, proofs and expected receipt counts/IDs
before sending. No task text, project names, invitation emails or file bytes enter
the private retry. Account/origin/process/removal/lease fences protect it, and the
adoption envelope supports 1,000 decisions while other reviewed team commands keep
their prior default bound. Lost applied replies retry the exact same request after
relaunch/expiry; foreign/stale/closed callbacks and failed cleanup keep recovery.
Unreadable recovery blocks fresh authoring. An account-level Saved project transfer
entry remains reachable after team-access loss or ordinary team navigation changes.

New authoring requires current owner-only personal custody, an empty outbox, no
unresolved sync conflicts and closed affected task editors. Context/access/content
changes invalidate the review. Accepted replies invoke normal workspace boundary
refresh and draft/Recovery handling; they never overwrite tasks with old response
contents. The UI provides an explicit success focus target and recovery/refresh
controls. Native HTTP uses the exact operation/body RPC contract, current session
fencing, no-store/cookie/redirect protections and a streamed 3 MB response cap.

Both repos pass 361 focused Team Core checks (21 adoption cases), with no failures
or skips, using independently generated actual SQL inspect/review/adopt fixtures.
Both isolated Debug app builds pass with signing disabled: iOS Simulator and Mac.
No app was installed/launched, no system settings or hosted configuration changed,
and no installed UI/layout/keyboard/spoken/live-Keychain acceptance is claimed.
Owned temporary builds are pruned; baseline Simulators and Core caches are kept.
See p2-project-adoption-native-evidence.json for exact checks and cleanup.

Next is installed native acceptance and the file-custody/personal integration
pause/retarget adapters, followed by genuine hosted acceptance. This does not
complete rank 6 or the wider Px scope. Shared batch/history/keyboard, remaining
Mac/layout/account/window/accessibility/hosted checks, independent child records,
Watch/Wear OS and other open plan items remain open. All user-deferred release,
provider and physical-device dependencies stay deferred. Rollout remains disabled.


### 2026-10-25 — Team template catalog client foundation

Each app now owns its typed library metadata/page/detail reader, bounded private
HTTP transport and fenced browser. All pages must share the original account,
origin, team, role/state and library revision before any names are published; a
workspace boundary surrounds the read. Failed continuations, late account replies
and overlapping older refreshes cannot publish stale contents. Invalidation clears
metadata and definitions synchronously. Opaque future documents remain intact and
read-only; current definitions require the full workflow validator before use.

Both repositories pass 50 focused Core checks (23 library, 27 adoption regression),
with no failures or skips. Independent Debug app builds pass with signing disabled,
including an incremental build after the last source edit. HTTP checks exercise the
actual Backend with an intercepted synthetic transport. Initial fixture failures
and final logs are retained in team-template-reader; exact scope/hashes are in
p2-team-template-reader-evidence.json. No app was installed or launched, no hosted
service/configuration or real data changed, and the library stays disabled. Owned
temporary builds/logs were removed after proof retention; source caches and the
baseline Simulators were preserved. Native Watch controls still reported the Mac
locked, so no new Watch navigation acceptance is claimed.

Next: encrypted publication/replacement/deletion recovery and exact retries, then
premium native library/detail/publication review and private-copy/export flows.
Installed layout, spoken, account/window and hosted acceptance, shared run
destinations and the wider ranked Px scope remain open. All user-deferred release,
provider and physical-device dependencies remain deferred.


### 2026-10-25 — Native team template publication and private recovery (source)

Each app independently owns the library catalog/detail, audience/contents/name
publication review, replacement/rename and removal review, plus Account recovery
for an original request after team/rollout loss. Current team audience and catalog
are read inside the same boundary. Unsupported future definitions remain read-only
and can be removed using reviewed metadata. Saved request text/definitions are not
shown from recovery without current access. Team deletion now explains library
removal and preservation of prior copies/work.

The exact supported definition/name, original CAS revision and stable nonce persist
before HTTP in one bounded AES-GCM file per account/origin. Only the existing backup
key is in Keychain; full definitions do not enter the small Keychain command store.
The private directory/file use 0700/0600 permissions, file protection and backup
exclusion. Account removal removes the nested files/key and blocks recreation.
Lease, process/removal and session fences preserve uncertain requests; retries do
not rebase or mint identities. Stop retrying explicitly does not undo server work.
Replayed receipts acknowledge the original change without claiming current contents.

Source review adds a single-submit guard and checks the frozen name/document again
after durable save. Account/phase/access changes mask the native review, and source
changes refuse the send. Draft state remains in memory while its review is paused.
These UI interactions still require installed acceptance; compilation is not proof
of buttons, layout, focus, speech or multiple-window behavior. Private-copy/export
and shared run destination flows also remain open.

Both repos pass 106 focused Core tests (22 command, 24 catalog, 27 adoption,
22 project management and 11 account-removal), with no failures/skips. Independent
arm64 Debug app builds pass with signing disabled, including final incremental
builds after the last source edit. Actual Backend requests use intercepted synthetic
URLSession peers; journal tests use real temporary files and synthetic keys. Initial
test-fixture compilation and build-argument mistakes are retained alongside final
proof in team-template-publication; see p2-team-template-publication-evidence.json.
No app was installed/launched, no real data, hosted schema/configuration or rollout
changed. Owned temporary builds/logs were pruned after retention; source caches and
baseline Simulators remain. Next is isolated installed review/recovery acceptance
and private-copy/export, then shared run destinations and the wider ranked Px work.
Every user-deferred release, provider and physical-device dependency stays deferred.


### 2026-10-25 — Team template copy/export and installed client acceptance

Both independent apps now offer full-content private-copy/export review, with a
fresh exact-definition/account/origin/workspace/session check before creating an
artifact. Private copies get a new personal identity and preserve the definition;
portable exports remap internal references through the existing workflow format.
A changed/removed/unsupported definition cannot silently become an artifact.
“Review latest definition” preserves the typed name and the reserved private-copy
identity while explicitly presenting the latest supported contents. Errors and
refresh actions are at the top, the name keyboard closes before save, and status
has an accessibility focus target. iOS revokes temporary exports on context loss
or dismissal; Mac uses its native file-save panel and normal private-template Undo.
Publication source selection now has a full-row active area and keeps custom names.

Each repository passes 111 focused Core tests: 31 catalog/transfer, 22 command,
47 workflow and 11 account-removal cases. Both arm64 Debug app builds pass. The
installed iPhone/iPad app uses only an exact reserved DEBUG namespace and a local
synthetic HTTP peer. Four scenarios are accepted per device: changed private source
and revoked access; real local encrypted-request lost-reply/relaunch/retry plus
replacement/removal; copy/export preparation/temporary cleanup/future read-only
behavior; and external definition change, refusal, preserved-name refresh and save.
The final transfer-only rerun passes two cases per device after setup/presentation
changes. Earlier signed full runs pass 4/4 on phone and 3/4 on tablet; the tablet
setup failure is retained and superseded by the external-peer update case. We did
not rerun unchanged curation scenarios after the transfer-only presentation fix.

Signing-disabled Simulator builds lacked the identity entitlements needed by
Keychain and count only as compile evidence. Signing-enabled builds plus the
existing development identity pass: actual installed signatures/Mach-O identities
and main/debug binary hashes match the final products. The cold app relaunch
restores the original request through the normal Simulator Keychain/file path;
no client pending request or receipt is injected. An iPad fixture change control
missed its action; the final test changes the synthetic provider file directly,
which represents an external teammate edit. Initial failures and final reports
are retained in team-template-transfer; scoped proof is in
p2-team-template-transfer-evidence.json. Curated phone/tablet screenshots are saved,
including the now-visible error/refresh card. No real tasks/accounts, hosted
schema/configuration or rollout changed.

Export acceptance covers preparation, portable file contents and cancellation
cleanup, not external share-provider delivery. Mac runtime/dialog/keyboard/spoken/
window and native account-switch acceptance, hardware protected storage, genuine
hosted acceptance, shared run destinations and wider ranked Px remain open.
Source build caches and baseline Simulators are preserved; owned temporary builds/
results/source copies are removed after evidence retention, and both isolated
app/runner installations are closed/uninstalled. Release/distribution, remote
reminders, old-client rollout, provider and physical-device deferrals are unchanged.


### 2026-10-25 — Native reviewed shared workflow runs (in progress)

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


### 2026-10-25 — Reviewed shared bulk labels (rank 6 in progress)

Both apps independently implement Add, exact Remove and explicit Clear all for
one captured shared selection. New names use the existing bounded name rules and
trim outer whitespace. Removal matches saved readable names literally, including
spaces, case and older longer names. Suggestions come only from selected tasks;
private label catalogs and IDs never normalize shared values. Existing opaque
values, duplicates and order survive unrelated edits. Unknown/missing label
shapes pause the whole selection until refreshed so Undo has an exact baseline.

The editor shows current labels and selected projects; the complete review shows
every resulting label set, including already-correct members. Back keeps the
choice, Cancel writes nothing, and Save uses one durable linked batch/RPC. Undo
restores each task's own original labels and refuses changed source/access. Root
labels alone change; notes, plans, assignments, conversations, children, other
labels and unselected tasks remain under their existing contracts.

The source-only migration admits labels to the existing frozen edit batch. Live
Auth/session/team/project/task checks, bounded envelopes, canonical locks, quotas,
whole-source comparisons, HMAC receipts, exact replay and all-or-nothing rollback
are retained. Existing single-task validation checks each label array. No table,
RPC, grant, hosted schema/configuration or rollout flag is added/enabled.

Each independent repository passes 124 isolated PostgreSQL checks with advisors
and fixture removal, plus 500 selected Core regression cases. Six new bulk-label
cases cover per-member add/remove/clear, exact whitespace/case/legacy behavior,
limits, malformed source/name refusal, durable encoding, Undo/Redo and stale
inverse protection. Final app builds compile. Native results and their scoped
limits are recorded in p2-shared-bulk-labels-evidence.json; no live hosted or Mac
spoken/account/window acceptance is implied. Rank 6 and wider Px remain open,
with all release/provider/device deferrals unchanged.


Native verification: three scenarios pass on each signed isolated iPhone/iPad
Simulator host. Tests exercise exact Remove/Clear with Undo, Add review/Back/
Cancel/Save/Undo/normal relaunch, invalid-name refusal and source-change masking.
They compare complete saved rows (including unselected work) and the one linked
queue entry, not just visible text. Final installed binaries/signatures match the
tested products; preparation-only namespace changes are hashed against source.
Light-mode label-set, Clear and paused-state screenshots were inspected. The
initial lazy-Save test failure is retained with the test correction. Native tests
intentionally skip cloud sync; the 124 real local
PostgreSQL transaction checks are separate. Mac runtime still awaits unlock.


### 2026-10-25 — Bind feedback Undo to its exact change

Toast, confirmation and planner feedback now capture a logical history entry,
workspace and session, rather than using the undo-stack count. At the 30-entry
limit a newer edit no longer makes an old feedback button target that newer edit.
A supplied stale request is refused before either stack or saved work changes.
Undo/Redo retain the logical entry identity while transport mutations retain their
existing fresh request identities. This metadata is local and ephemeral; persisted
formats and service authorization are unchanged. A confirmed shared move has no
local inverse and therefore offers no unrelated Undo action.

Each repository passes 545 selected Core regressions, including seven new logical
entry/direction/workspace/session checks. Mac Debug compilation passes. Native
iPhone/iPad acceptance and the attempted Mac runner are scoped in
p2-history-binding-evidence.json. Initial fixture/locator failures are retained.
Mac native runner initialization was denied by system authentication before the
app launched; computer use independently reported the Mac locked after the user
unlock reply. No Mac runtime or spoken acceptance is claimed. Existing native
UndoManager grouping, failure/retry and window/text routing still need their own
acceptance; this change does not close all history integration work.

Rank 6, Watch/Wear OS navigation and the remaining ranked Px scope stay open.
Release, hosted rollout, provider credentials and physical-device deferrals remain
unchanged. No hosted configuration, service schema or real task data changed.

Final native result: all three selected iPhone cases passed, with zero skips and
zero runtime warnings. The actual Store proof confirms depth 30, a newer logical
entry, stale-request refusal and unchanged snapshot/stack identities. It then
undoes the newer edit, applies the exact original feedback Undo, and Redoes it.
Shared-label review/Back/Cancel/Save/Undo/relaunch and planner scheduling/Undo/
relaunch also pass. Both installed hosts match signed build hashes.

The final iPad run is explicitly unaccepted: planner Save reported hit point
{-1,-1}, then the label test stalled on invalid form-scroll geometry. That exact
run was interrupted (exit 75), with log, partial summary and screenshot retained;
the history-limit case was not reached. No app change or repeated run was made
to disguise those input failures. Earlier v2 label regression passes remain
separately recorded. Current iPad and Mac runtime acceptance remains open.


### 2026-10-25 — Native shared-task checkbox admission

The regular list checkbox previously sent an ordinary personal mutation for a
known team task. The existing workspace guard refused that write. Both native
apps now explicitly capture the visible root task, current workspace/session,
team role/access token and service origin before preparing its completion.
Calendar/other native callers of Store.toggle use the same admission. Mac shared
roots use it before the hierarchy-filter path; personal writers stay separate.

Completion prepares the existing single TEAM_COMPLETE command, including a
recurring successor and its original action identity when appropriate. Reopen
uses the existing scoped revision-checked edit and preserves later occurrences;
Undo alone can remove its own unchanged provisional successor. A stale visible
row, missing incarnation, changed workspace/session/access, viewer role or
disabled rollout refuses the action. Unknown repeat semantics are preserved
without forecasting a successor. No scope is inferred for ordinary editor saves.

Both independent Core suites pass 551 selected regressions, including six new
cases for this native admission, source/context refusal, recurrence/Undo and
reopen preservation. Final Debug app builds pass. Initial test snapshots omitted
the required project row and failed; the fixture was corrected and the initial
logs retained. See p2-native-completion-evidence.json for exact native scope.

This fixes single native root gestures; atomic multi-task completion, other
remaining shared adapters, native Mac/spoken/window/hosted checks and the full
ranked Px objective remain open. No hosted schema/configuration, rollout, real
task data or user-deferred release/provider/device work changed.

Installed verification: two actual scenarios pass per signed iPhone/iPad, with
zero failures, skips or runtime warnings. The real checkbox writes one captured
completion; Undo writes its linked inverse and survives normal relaunch with the
complete cache unchanged. Unselected rows remain equal. The 30-entry history/
Redo regression now passes on both devices. Actual final caches, history proofs,
logs, summaries and matched installed binary hashes are retained. Phone/tablet
completion feedback renders without clipping; the iPad relaunch capture includes
a navigation transition and is not stable-layout acceptance. No cloud/Mac runtime
or installed recurrence/reopen acceptance is implied. The earlier iPad planner
input failure remains open. Next: atomic reviewed shared multi-task completion.


### 2026-10-25 — Atomic shared completion selection service (source only)

Both repos independently own an atomic completion/Undo/Redo endpoint candidate:
`taskfold_complete_team_tasks(_action, _body)`. One group contains 1–100 distinct
root tasks, one team, a group nonce and each existing complete-task envelope.
The body is bounded to 2 MB and each member to 128 KB. History carries
`related_request` for the original group and the corresponding `undoes`/`redo_of`
for every original member. Partial, substituted or reused history is refused.
Replies have `batch_protocol: 1`, the original group identity, operation, relation,
all sorted per-task receipts and an explicit replay bit; responses are bounded.

The transaction reserves recipients, team/config/project rows, request identities
and every known source/series/planned/adopted successor in canonical order. It
rechecks permissions after waiting. A successor discovered only after the lock
wait produces a retry conflict before any delegated operation. Each existing
completion routine retains its source, revision, generation, role, recurrence,
retirement, successor ownership and receipt checks. No loop of client RPCs is
used. A late failure rolls back every task, successor, history link and receipt.

The existing private batch ledger and member links bind the action identities.
A private transaction-scoped table admits only the exact group members and
relations; RLS and revoked grants prevent caller insertion or settings-based
forgery. Single-task RPCs cannot replay/Undo/Redo bound members individually.
Access checks run before private history inspection. HMAC fingerprints bind actor,
operation and the frozen group intent. Lost replies can acknowledge an exact
recorded group without reapplying; pruned or incomplete receipts stop safely.
Whole-group Undo/Redo lineage is consumed once, and actor/team deletion uses the
existing cascading ledger cleanup. Existing single-task SQL differs only by the
private batch-history guard; its retirement-aware implementation is retained.

Each independent repository passes 243 actual isolated PostgreSQL checks, including
110 batch-specific checks. Coverage includes cross-project permission/archive
loss, all-or-nothing completion and inverse failures, exact concurrent retries,
overlapping different groups in reversed order, convergence, fresh successor
generations on Redo, expired sessions, request/response identities, payload limits,
RLS/grants, forged context refusal, source/receipt replacement and cleanup.
Official read-only advisors run on each owned fixture: only the pre-existing
auth_rls_initplan warnings are allowed. Owned containers are removed. Initial
argument-limit, SQL-name ambiguity and lock-observation fixture failures are
retained with the final verified run; see p2-completion-batch-service-evidence.json.

Not yet connected to native multi-selection. Next: typed durable group commands
and whole-receipt validation, transactional local apply/confirmation and linked
history, then native review/Cancel/Save/Undo/Redo/relaunch and recovery acceptance
in both apps. Preserve original group intent through lost replies and access
changes; never decompose a saved selection into individual retries. Current
native single-checkbox acceptance is unchanged. Broader rank 6, child records,
Watch/Wear OS and all remaining Px stay open. No hosted schema/configuration,
rollout, real task data or user-deferred release/provider/device work changed.


### 2026-10-25 — Durable completion selection client (Core stage)

Each app independently extends the existing TeamTaskBatch carrier with complete
and undo_complete. Mutation's outer format is unchanged; the internal restores
reference maps to related_request for completion history. Member TeamCompletion
commands retain their frozen clocks, sources, scopes, generations and nonces.
Body validation rejects mixed contexts, nested groups, reused identities, invalid
relations, unbounded content and independent multi-completion queue writes.
Old deletion/restoration/planning selections retain their existing contracts.
Updated clients are required for the new operation values; this is not older-
client rollout or upgrade acceptance.

Local projection uses a temporary snapshot and publishes only after every source
and member applies. One history entry contains the complete inverse selection.
Actual Undo/Redo obtain fresh group/member request identities and current source
revisions; frozen transport retries retain their original logical payload.
Recurring Redo chooses fresh successor incarnations; converging members share
one projected future occurrence. The existing recursive team-access mask knows
every member/source/proposed successor and refuses the whole unavailable group.
Shared groups are excluded from ordinary personal conflict/project recovery.

Backend uses one taskfold_complete_team_tasks RPC, with origin/account/session
fences, no-store/no-cookie transport, redirect refusal, 25-second timeout and a
4.3 MB streamed reply bound. It validates the whole reply before exposing a saved
receipt: exact group identity/operation/relation, complete sorted member list,
per-member completion proofs and consistent replay bits. Errors retain saved
intent and do not expose server detail or fall back to individual task calls.
A late reply cannot cross another account or a new session for the same account.

For a front-of-queue group with no touching later work, complete acknowledgement
merges all receipts on a temporary snapshot and removes the group only after all
members succeed. Unrelated queued work remains unchanged. Missing projects,
invalid/partial/foreign/reordered replies and authored provisional-row conflicts
keep the entire original snapshot/queue. Touching later cohorts (including queued
completion → Undo → Redo) currently refuse acknowledgement and stay durable.
They still need full cohort reconstruction before the native bulk entry is added;
no claim of finished offline batch history or native bulk completion is made.

Both repos pass 564 selected Core regressions, including 13 new completion-batch
cases, and independent final arm64 Debug app builds with signing disabled. Actual
SQL-generated complete/Undo/Redo/recurring envelopes and replies come from each
repo's independently accepted 243-check service fixture. HTTP tests exercise the
actual Backend with synthetic intercepted requests. Initial byte-order retry
assertions were corrected to compare JSON values: object-key order may differ
while every request identity, field and array order is frozen. Initial failures
and final logs/hashes are retained in p2-completion-client-evidence.json.

Next: reconcile complete dependent cohorts transactionally, preserve authored
provisional edits through adoption/recovery, then add captured native selection
review/Cancel/Save/Undo/Redo/relaunch acceptance in both apps. Mac runtime/spoken/
window and hosted acceptance, other rank-6 work, Watch/Wear OS and the full Px
objective remain open. No UI control, hosted migration/configuration, rollout,
real task or user-deferred release/provider/device setting changed.


### 2026-10-25 — Completion receipt reconciliation across queued cohorts

A front completion batch can now confirm while dependent edits remain queued.
An identity adjacency index finds the complete connected cohort, including an
earlier edit to another task that a later mixed selection joins. Saved baselines
reconstruct the pre-action state; replay of every selected command must explain
the current optimistic rows before any confirmed state is published. The group
receipt is then merged on a separate copy and all dependent intent is replayed
in its original order. Only the confirmed front request leaves the queue.

Completion → Undo → Redo retains the correct current counters and successor
incarnations. Later scoped root/provisional edits, mixed planning selections,
scoped deletion and deletion/restoration can survive confirmation without new
nonces or rewritten bodies. Timestamp/null normalization affects temporary
projections only. Unrelated tasks, queued actions and non-task snapshot state
remain intact. Confirmed remote fields can survive beside independent local
edits; conflicting changed-field baselines, replacement generations and authored
provisional content that would be displaced refuse the complete acknowledgement.
An unedited projection may adopt the confirmed occurrence; an authored draft
never silently changes incarnation. Observed loss of access on the original or
an added cohort member, project/ancestor archive and missing projects keep the
original action and complete cohort. Unsupported/inconsistent cohorts also stay
durable for review. No personal writer gains shared scope during reconstruction.

Both independent repositories pass 587 selected Core regressions, including 36
completion-batch cases (23 added here plus the preceding 13), and final arm64
Debug app builds with signing disabled. The complete/Undo/Redo sequential test
uses each repo's actual independently generated SQL bodies and receipts. Other
checks cover recurring Undo/Redo, authored latest occurrences, adoption refusal
and safe adoption, remote-field preservation/conflict, mixed cohort ordering,
whole-selection deletion, restored incarnations, duplicate-row refusal, role loss
and archive races. Full pending commands are compared, not just task counts.
See p2-completion-cohort-evidence.json for current hashes and retained logs.
Service SQL is unchanged; no new hosted or native runtime acceptance is claimed.

Next: captured native bulk completion review/Cancel/Save/Undo/Redo/relaunch,
visible whole-cohort conflict recovery, and runtime acceptance in both apps.
Confirmation work also needs large-selection responsiveness checks and an
appropriate snapshot/generation fence if moved off the UI thread. No bulk entry
point is enabled here. Mac installed/spoken/window and genuine hosted acceptance,
independent child records, remaining Watch/Wear OS and the wider Px goal remain
open. All user-deferred release/provider/device work stays deferred. No hosted
schema/configuration, rollout, real data or external account was changed.


### 2026-10-25 — Captured native shared bulk completion review

Complete selection now opens a native grouped review for shared roots. The
opening captures exact source rows, workspace/session/access authority and one
frozen completion envelope. It lists all selected roots (already-completed roots
stay unchanged), the active count and next repeat occurrences. Cancel makes no
saved changes. Revalidation never creates new requests or acquires new sources;
changes to a selected row, its series/occurrences or permission pause the entire
review and hide the captured contents. Shared mixed/nested unsupported selections
refuse rather than reaching a personal writer. Mac review saves through native
history; iOS uses its existing bound Undo feedback. All members persist together.
The sheet uses existing forms, spacing, typography and feedback. Grouping its
presentation with selection sheets keeps the Mac root view within SwiftUI's
compiler limits.

Both independent repos pass 594 selected Core cases, including 43 completion-batch
cases and seven new capture/authority/lifecycle checks. The final isolated iOS
app/test products build and are signed with preserved Simulator identities; the
final arm64 Mac app build passes with signing disabled. On both phone and iPad,
one actual UI test passes with no runtime warnings: Cancel leaves the entire
cache unchanged, Save queues one TEAM_BATCH for both selected roots, untouched
work is preserved, linked whole-group Undo restores both roots (with monotonic
completion revisions), and normal relaunch preserves the exact final cache and
queue. Installed executable, debug library and Info.plist hashes match the tested
products. Review screenshots are readable without clipped text. These native
fixtures are ordinary roots; recurring preview behavior is covered by Core.

See p2-native-bulk-completion-evidence.json and native-bulk-completion/. The Mac
runtime remains unverified in this stage: desktop control still reports locked.
Native Redo/window/spoken acceptance, visible whole-cohort conflict recovery,
large-selection responsiveness and genuine hosted acceptance remain open. This
is not full rank-6 or Px completion. Teams rollout remains off; no hosted schema,
configuration, real tasks/accounts, release signing or deferred provider/device
work changed. Existing personal selection behavior stays on its original path.


### 2026-10-25 — Whole-selection completion recovery service

Added source-only review/cancellation RPCs for the exact saved completion or
Undo/Redo batch. A group has one terminal status: unrecorded, recorded or
cancelled. Every selected project/series must still be readable before any
private receipt is inspected. Group and member identities, actor, action,
history links and the complete original body are checked together. Nonce and
task locks follow the existing writer's canonical order; current task rows are
locked before gathering member observations.

Review does not create ledger entries. Recorded groups return a complete replay
receipt assembled from the existing strict member receipts. Cancellation of a
recorded group returns that proof and does not Undo it. Cancellation of an
unrecorded group atomically reserves its header/member nonces, links and private
cancellation marker; task content is untouched. A completion that wins a race is
returned as recorded; a cancellation that wins prevents all later exact or
isolated-member execution. Retrying after a lost response recovers the same
proof. Partial/pruned receipts refuse rather than inventing success. Viewers and
archived projects can retire their own unrecorded intent with current read access;
this confers no editing capability. Cancelling an unrecorded Undo does not consume
the original completion's history link.

Both independent repositories pass 348 actual isolated PostgreSQL checks: the
prior 243 plus 105 recovery/cleanup checks. These cover exact read/retry proof,
changed remote content, actor/role/session boundaries, malformed/partial requests,
recorded completion/Undo/Redo, retired Undo and fresh Undo, late cancellation fault
rollback, real completion-versus-cancellation contention, concurrent identical
cancellations, private second-project refusal without partial content, read-access
loss while waiting, archive/write-pause recovery, aggregate/request byte bounds,
RLS/grants, pruned ledger refusal and actor/team deletion cleanup. Official
Supabase advisors report no new warnings (existing auth_rls_initplan warnings
remain). Both owned containers were removed. Actual own generated request/review
examples are retained for the forthcoming native client parser.

See p2-completion-batch-recovery-evidence.json and completion-batch-recovery/.
This stage changes candidate SQL and its independent harnesses, not native app
behavior. Whole-cohort local draft preservation, native review/refresh/retry/
recorded-acknowledgement/cancellation UI, native Redo and Mac runtime acceptance,
large-selection responsiveness and genuine hosted acceptance remain open. No
schema was deployed, no rollout flag enabled, no real task/account changed and no
user-deferred release/provider/device work resumed. The full Px goal stays open.


### 2026-10-25 — Native whole-selection sync recovery

Both independent clients now parse the versioned group review against the exact
saved completion/Undo/Redo envelope. They reject partial, reordered, contradictory,
foreign, oversized or mismatched observations and receipts. The private transport
uses account/origin/session fencing, no cookies/cache, redirect refusal and bounded
streaming. A native grouped review shows every member and offers Later, Check
again, exact retry, recorded acknowledgement and Keep synced tasks. Refresh updates
the existing presented review rather than leaving an obsolete copied sheet.

Recorded acknowledgement reuses the connected-cohort reconciler off the main actor,
then verifies the complete snapshot and session before persisting. Keep synced
tasks first saves an encrypted recovery copy, obtains terminal whole-group
cancellation proof, and atomically adopts only the completion-owned rows. Separate
series parents remain untouched. Independent pending work is retained byte for byte.
Dependent edits, conversation drafts or unexplained source edits refuse cancellation
before any server request; their entire queue remains saved. A recorded winner is
reviewed rather than undone. Persistence failure rolls back the in-memory projection.

Verification: 605 Core cases passed per repo, then all 55 completion-group cases
passed per repo after the final separate-series preservation regression (606 unique
cases in this stage). The final class run also includes strengthened byte-limit
assertions. Both app builds succeeded. Three actual native tests passed separately
on iPhone and iPad with no runtime warnings: Later/refresh/exact retry preserves
saved bytes; recorded acknowledgement removes one whole group; cancellation saves
an encrypted backup and keeps synced roots through relaunch. Installed executable,
debug library and Info hashes match the signed tested build on both devices.
Screenshots were inspected for readable controls. Runtime fixtures use two ordinary
synthetic roots and an isolated local transport peer; the parser additionally uses
each repo's own previously generated PostgreSQL wire fixtures. These are not hosted
acceptance tests. The last separate-series-only safeguard followed these native
runs and is covered by the final Core regression, not a second native run.

See p2-native-completion-group-review-evidence.json and native-completion-group-review/.
A new Mac attempt after the user unlocked timed out enabling XCTest automation
before any case ran, including on the preserved older workflow checkpoint. This is
not Mac runtime acceptance. Native recovery with dependent authored cohorts, recorded
acknowledgement after role/archive/write-pause changes, missing incarnations,
recurring-group/Undo/Redo UI, native storage faults/account-race/spoken acceptance,
large-workload responsiveness and genuine hosted acceptance remain open. Teams
rollout stays off. No hosted schema/configuration, real tasks/accounts or deferred
release/provider/device work changed. The full rank-6/Px goal remains active.


### 2026-10-25 — Preserve connected edits during selection recovery

Keep synced tasks can now save connected typed task work as a permanent encrypted
selection draft before retiring the original completion group. This covers scoped
edits/deletes, transitive mixed selections, recurring completion/Undo/Redo histories
and supported task-comment drafts. The whole connected cohort is reconstructed and
compared against the actual local projection before any write. Unsupported scopes,
unexplained changes, indirect preference references and wrong-generation comments
leave the original queue intact. Independent pending work and comment drafts remain
unchanged. A read-only preview never authorizes dropping intent; only the terminal
whole-group cancellation proof can publish the rollback.

The Store saves and reads back the encrypted draft before requesting cancellation,
then rechecks the entire captured snapshot, account generation and current review
after every suspension. A recorded winner stays in review. Network/disk failure or
a changed workspace leaves the queue saved; persistence failure rolls back memory.
The saved archive remains available after these failures and retries deduplicate
identical work. Account-removal fences cover writes and late key-backed reads.

Saved team drafts now includes saved selections. Their native details show authored
task text, checklist state, earlier title/notes changes and comment drafts, including
the last known content of a queued deletion. Users can copy/share the full text or
export connected details as a JSON review file; it is explicitly not a workspace
backup or automatic replay. Exports exclude unrelated rows/outboxes, the private
workspace/access snapshot and device receipts. Full raw recovery context remains
encrypted internally. Explicit drafts have no retention eviction; ordinary backup
rotation cannot remove them. Each draft is limited to 16 MB, with 20 drafts / 64 MB
per account/origin; reaching a limit refuses to discard queued work.

See p2-completion-selection-drafts-evidence.json and completion-selection-drafts/.
These are independent client-only changes; no SQL, hosted schema/configuration,
rollout switch, real task/account or user-deferred release/provider/device work
changed. Read-permission/archive acknowledgement for recorded groups, explicit
missing-incarnation recovery, unsupported cross-table cohorts, native recurring/
Undo/Redo/spoken/storage/account-race acceptance, Mac runtime, large-workspace
performance and genuine hosted acceptance remain open. The full rank-6/Px goal
remains active.

Final lock-order check: selection enumeration, load, save and deletion all acquire
the account disk fence before the shared process lock. A coordinated reader/saver
regression proves that a reader waiting on that fence does not block an in-fence
save. Each repo passes all 68 completion-group checks after this follow-up. The
broader selected run passes 712 of 713 cases with one live shared-conversation test
skipped; including the new lock-order case gives 713 unique passing Core cases
and one explicit live-service skip. Both final Debug builds succeed.

Native acceptance: the final exact signed isolated iOS build passes the new
end-to-end draft/relaunch/JSON-sharing/popover-cancellation scenario separately
on iPhone and iPad, with no runtime warnings and matching installed binary hashes.
Screenshots were inspected for readable saved text/actions and the actual return
from sharing. Actual encrypted selection-file hashes/sizes and recovery index
metadata are retained without keys. Three earlier recovery scenarios also pass
per device in the initial four-case runs; their failed fourth case and subsequent
picker/selector attempts remain visible in evidence. Final export uses in-memory
Transferable JSON sharing, which avoids the system picker's unreliable Cancel
proxy; no actual external delivery is claimed. This is not Mac runtime acceptance.


### 2026-10-25 — Acknowledge recorded selections with current read access

An explicit recorded group review can now acknowledge its already-synced result
when the user is a viewer, the project is archived or native editing is paused.
A private read authority binds the validated full group receipt to the account,
backend, active team and currently readable source/series projects. Every connected
later typed task cohort must remain readable too. Missing/foreign/inactive/disabled
boundaries and forgotten historical custody refuse without changing the snapshot.
The ordinary send/acknowledgement path keeps its edit-access checks.

The reviewed path reconstructs and validates the entire local projection even
without a later task cohort. Untracked authored fields refuse; supported later edits
and Complete/Undo/Redo histories keep their exact typed bodies/nonces. Displaced
incarnations cannot orphan comment drafts or indirect preference intent. The result
persists the captured current read boundary and historical team/task custody rather
than an older writer cache. Later queued changes remain blocked by their real
permissions; acknowledgement grants no write capability. The Store checks account
generation, complete snapshot, read revision, full current access cache and visible
review after detached reconciliation and before publishing/persisting. Failure
keeps the selection and queued drafts. Native copy distinguishes queued later work
from a separate draft saved by the Keep synced tasks path.

Each independent repo passes 723 of 724 selected Core cases, with one live shared-
conversation integration case explicitly skipped for lack of disposable service
accounts. This includes 78 completion-group cases (10 new read-recovery cases),
actual previously generated SQL complete/Undo/Redo wire fixtures, recurring
histories, transitive mixed-project cohorts, separate cross-project series parents,
read loss, write pause/archive/viewer states, historical custody, untracked content
and orphaned drafts. Both Debug app builds succeed.

Three actual installed UI cases pass separately on each iPhone and iPad with no
runtime warnings: viewer with a later edit, archived project without reopening it,
and paused editing with a later edit. They start with an older writer cache on disk
and a newer read-only access mask, then prove recorded acknowledgement persists the
current read boundary, leaves rows and pending values intact, and survives relaunch.
Before/after snapshots and semantic comparisons retain every value while treating
only Codable Set identifier lists as unordered. Earlier raw-cache assertions failed
on process-dependent Set ordering; failed-run summaries/logs are retained, and the
final tests compare all actual saved values. Runtime fixtures are synthetic ordinary
roots and a local protocol peer; this is not hosted service or Mac runtime proof.

See p2-recorded-completion-read-recovery-evidence.json and recorded-completion-read-recovery/.
Missing-incarnation authored recovery, unsupported cross-table cohorts, native
recurring/Undo/Redo and spoken/storage/account-race acceptance, Mac runtime, large-
workload responsiveness and genuine hosted team acceptance remain open. No SQL,
hosted schema/configuration, rollout flag, real task/account or user-deferred
release/provider/device work changed. The full rank-6/Px goal remains active.

This stage covers an explicit existing recorded review. Automatic discovery of
that review when the app starts with its head already blocked remains the next
source integration task; no cold-start discovery acceptance is claimed here. After
the final text-only queued-edit/draft distinction, the viewer/later-edit/relaunch
case passed once more per device with no runtime warnings. Final installed hashes
match that signed build; the earlier three-mode acceptance remains separately
retained and the other two modes were not repeated for the wording change.


### 2026-10-25 — Discover recorded blocked selections on startup

The normal sync loop now checks a blocked completion-group head before sending it
or merging remote tables. Discovery requires a fresh readable account/backend/team/
source/series boundary, a blocked exact queue head and unique pending identities.
It freezes the full snapshot/access observation off the main actor and rechecks
account generation, snapshot, read revision, current access and competing reviews
before/after the status RPC. A matching recorded proof opens the existing review
and returns before writers or workspace merge. Discovery never acknowledges a
command or changes task rows; explicit Continue remains required. Unrecorded,
cancelled, unsupported or unreadable heads do not gain permission or disappear.

The same read eligibility is shared with explicit recorded-review acknowledgement.
Every saved group nonce, member body, completion time and independent tail remains
unchanged. A late head/body/snapshot/access change discards discovery. Normal writable
heads retain their existing path. Cold single-task completion discovery and other
terminal-state recovery are not introduced by this group-only stage.

Each independent repo passes 728 of 729 selected Core cases with one live shared-
conversation test explicitly skipped for lack of disposable accounts. This includes
83 completion-group cases and five new discovery cases covering viewer/archive/
write-pause eligibility, foreign/missing/disabled/inactive access, malformed and
unrelated heads, recorded versus unrecorded/cancelled status, late context changes,
and complete/Undo/Redo envelopes with independent tails. Both own Debug builds pass.

Three actual UI tests pass on each iPhone and iPad with no runtime warnings. Each
quits while a recorded selection is still queued, relaunches into the production
sync loop under a fresh viewer/archive/write-pause boundary, discovers review and
proves no tasks/queue changes before approval. Every captured trace contains exactly
two POST reads: taskfold_workspace_boundary and taskfold_review_team_completion_batch.
There is no completion writer or workspace-table fetch before review. After explicit
Continue, the exact later-edit tail/current read-only permissions and all task values
survive a second launch. Only Codable Set identifier ordering is canonicalized in
whole-snapshot comparisons. Installed binary/library/Info hashes match the signed
isolated build; screenshots were inspected for readable review presentation.

The reserved DEBUG peer enables the actual sync loop only with its explicit test
flag and answers only synthetic access/status reads; all other HTTP remains blocked.
Fixtures contain ordinary roots; Core covers Undo/Redo discovery. This is not hosted
service, recurring native-history or Mac runtime acceptance. See
p2-cold-completion-discovery-evidence.json and cold-completion-discovery/.

No SQL, hosted schema/configuration, rollout flag, real task/account or deferred
release/provider/device work changed. Single-task/cancelled-head discovery, authored
missing-incarnation and cross-table recovery, native recurring/Undo/Redo/spoken/
storage/account-race acceptance, Mac runtime, large-workload and genuine hosted
acceptance remain open. The full rank-6/Px goal remains active.

## 25 October 2026 — Individual completion discovery after reopening

The normal sync loop now inspects an access-blocked individual completion as well
as a completion selection before a workspace merge. Discovery captures the full
snapshot, head request, account/origin and current read boundary. Only a matching,
validated recorded response opens the existing completion review. It neither
resends nor acknowledges the action. Writable heads use their existing send path;
unrecorded, cancelled, unreadable, malformed and unrelated heads remain protected.

Accepting an individual recorded review now retains the current read boundary on
disk rather than restoring earlier writer access. Fresh read access must cover the
source and repeat-series projects. Connected later edits retain their exact typed
commands and nonces; malformed/foreign scopes, lost cache custody and comment or
other pending references to a displaced occurrence refuse acknowledgement. Existing
single-action reconciliation handles its supported recurring complete/Undo/Redo
history; mixed connected groups still need the broader cohort work. No refusal
removes the saved action or authored work.

Native refresh and Continue capture the complete snapshot/access/account context;
late changes discard their result. Final reconciliation runs away from the main actor
and is rechecked before persistence. A failed refresh keeps the review available.
The existing premium completion review explains that later edits stay queued until
current project access permits syncing.

Each independent repo passes 735 of 736 selected Core cases, with one live shared-
conversation test skipped because disposable accounts are not configured. Seven new
cases cover cold eligibility and exact status, stale snapshots/access/envelopes,
malformed and unrelated heads, view/archive/pause recovery with typed edits,
recurring Undo/Redo and independent tails, lost custody and displaced comment drafts.
Actual recorded/Undo wire fixtures from the existing SQL tests are reused. SQL and
local date/time representations are compared semantically; authored values and
queued commands remain exact. Both final Debug app builds pass.

Five actual UI tests pass on each iPhone and iPad with no runtime warnings:
three individual cold-recovery cases (viewer/archive/write pause), a grouped
cold-recovery regression and a refresh case that changes the observed instructions.
Each cold case verifies unchanged task/queue values before review, exactly two POST
reads (workspace boundary and the matching single/group status endpoint), explicit
Continue, current restrictions and exact remaining commands after a second launch.
The refresh case verifies newer instructions are displayed before acceptance,
without changing the queue/task projection, then saved on Continue. All retained
cold snapshots compare equal after sorting only Codable Set identifier arrays.
Installed binary/library/Info hashes match the signed final test products. Phone
individual-review and iPad refreshed-review screenshots were inspected for readable
presentation. Initial four-case runs per device also passed; final five-case runs
cover the final source. Mac runtime is not claimed.

The native individual command is seeded from one actual captured completion member
inside the reserved DEBUG fixture, with the other synthetic members restored before
testing. Native wire delivery is through the isolated local HTTP peer, not a hosted
service. See p2-single-completion-discovery-evidence.json and single-completion-discovery/.

The reserved DEBUG peer and fixture use synthetic ordinary roots. Native recurring
history, Mac runtime/window/spoken checks, storage/account-race acceptance, other
terminal-state discovery, authored missing-incarnation/cross-table recovery,
large-workload and genuine hosted acceptance remain open. No SQL, hosted schema,
service configuration, rollout or real account/task changed. All user-deferred
release/provider/device work remains deferred; the full rank-6/Px goal stays active.


## 25 October 2026 — Mac completion recovery harness ready; runtime pending

The Mac repo now owns a reserved DEBUG-only recovery peer, synthetic completion
seeding and controls that open the real individual/group review screens. The
fixture can exercise the actual normal sync loop after a saved blocked action is
reopened. Network access outside the synthetic peer remains denied. Its app ignores
stale window restoration only in the reserved debug fixture, so a forced test quit
can be followed by a new main window. Production release behavior is unchanged.

Seven native cases compile in the current, separately sandboxed Mac app: individual
and group recovery after viewer/archive/write-pause changes, and refreshed current
instructions before acceptance. The cases assert exact saved tasks/queue before
review, two read requests, exact later commands/current restrictions after Continue
and relaunch, plus one main window. They use the existing production Store methods
and review views; the peer only answers synthetic ordinary-root access/status reads.

The final app and test runner build and pass strict/deep verification with the
existing Apple Development identity. Own-source namespace transformations,
synthetic backend, private service/App Group identifiers and seven compiled test
methods were checked. Initial signing configuration and an overwritten App Group
literal were corrected before launch, then the final isolated products rebuilt.

No runtime case was executed: native computer use reports the Mac locked on both
inspections, and the requested unlock is pending. The signed host and test build
are preserved, with no test app process running, so the same build is ready for
actual desktop acceptance after unlock. These compiled assertions do not close Mac
runtime, window, keyboard or spoken acceptance. iOS app code is unchanged this stage.
See p2-mac-completion-recovery-preparation-evidence.json; the Mac repo also retains
mac-completion-recovery/ build, signature and source-isolation evidence.

No service/schema/configuration, rollout, real account/task or user-deferred
release/provider/device work changed. All broader rank-6/Px requirements remain
open as listed above; this checkpoint is test preparation, not feature completion.

## 25 October 2026 — Discover and retire already-cancelled completions safely

Cold discovery now recognizes both durable terminal states: recorded and cancelled.
Individual/group status reads still own the exact head, complete snapshot and current
read boundary. An unrecorded response never removes work or opens terminal recovery.
Discovery returns before any task write, acknowledgement or workspace-table merge.

An already-cancelled review uses its validated durable proof on explicit acceptance;
it does not issue a second cancellation RPC. The normal safety backup and encrypted
selection-draft/readback requirements remain. Retiring independent work or parking
connected work now installs the current read cache, rather than leaving older writer
permissions on disk. Viewer/archive/write-pause restrictions survive relaunch.

All asynchronous backup, vault and cancellation steps capture the complete snapshot,
account, read revision and full access cache; late changes discard their result.
Single provisional-draft parking also retains this access cache. Rebase requires
current write access and keeps that same boundary in both its base and result.
Cancelled read access permits only local recovery of the exact reviewed envelope;
it grants no authority to send connected edits. Missing scope, lost cache custody,
malformed/duplicate identities or unexplained authored work keep the queue protected.

Each repo passes 742 of 743 selected Core cases, with one live shared-conversation
integration case skipped because disposable accounts are not configured. The 181
completion cases include seven new cases for actual SQL cancellation/Undo proofs,
exact cold discovery, read-only retirement, fresh rebase permissions, independent
work, encrypted authored group retention and refusal of unsafe/unrecorded contexts.
Existing per-repo SQL wire fixtures are reused; no service SQL changed or reran.
The isolated iOS app and current signed Mac test app both build.

Six actual UI cases pass on each iPhone and iPad with no runtime warnings:
four new cancelled cases (single viewer/archive and group viewer/write pause) plus
recorded individual/group viewer regressions. All cold traces contain only the
access/status reads before review, with tasks and queue unchanged. Cancelled
acceptance traces contain no completion write or repeated cancellation request.
Current restrictions and full post-acceptance snapshots survive another launch;
only knownTasks/quarantined Codable Set ordering is canonicalized. Both group
cases reopen their permanent encrypted draft and read the authored title/notes.
Core separately verifies exact encrypted snapshot/save/readback identity.

Installed app, debug-library and Info hashes match final signed products. The
individual cancelled-review and persistent iPad draft previews were visually
inspected. Actual native data uses ordinary roots and a local synthetic HTTP peer;
no hosted or native recurring-history acceptance is claimed. Mac source namespaces
and final app/runner development signatures verify, but its seven prepared UI cases
remain unrun: the native availability check still reports the Mac locked.

The Mac's seven prepared recorded-recovery UI cases remain unexecuted pending the
requested unlock. Its current-source signed host/build are retained. Native recurring
history, Mac window/keyboard/spoken checks, storage/account-race acceptance, authored
missing-incarnation/cross-table recovery, large-workload and genuine hosted acceptance
remain open. Single cancellations with unsupported connected authored work remain
protected for separate review; no action silently drops those drafts.

No SQL, hosted schema/configuration, rollout, real task/account, OAuth/provider or
user-deferred release/device work changed. See p2-terminal-completion-recovery-evidence.json
and terminal-completion-recovery/. The broader rank-6/Px goal remains active.

## 25 October 2026 — Native recurring history and Mac recovery follow-up

Three new actual native recurring cases pass on each iPhone and iPad: recorded
individual, recorded group, and already-cancelled group with a permanent saved
draft. Two ordinary cold-recovery regressions also pass on each device. All ten
cases have zero failures/skips and no runtime warnings. The tests use the actual
list checkbox/group confirmation, Undo toast and Task options → Undo & redo → Redo.

Captured snapshots independently confirm source revisions 1/2/3 and states
complete/open/complete, removal of the generated next occurrence on Undo, exactly
one next occurrence on Redo with a fresh generation/nonce, the same captured clock,
linked history identities, reset checklist children and preserved notes. A later
scoped edit to the latest occurrence is added through the reserved fixture. Cold
sync reads only the current boundary and matching status before review. Recorded
acceptance preserves the queued Undo, Redo, edit and complete task projection;
cancelled group acceptance retains the entire connected history and edited next
occurrence in a permanent encrypted draft that reopens after relaunch. All six
recurring post-acceptance snapshots survive another launch exactly, apart from
knownTasks/quarantined Codable Set ordering.

This stage changes DEBUG fixtures and acceptance tests, not the production
completion/storage/service contracts. The peer seals only the first completion's
recorded/cancelled result and returns later Undo/Redo as unrecorded. It does not
pretend to deliver that later history to a server. Existing independent SQL fixture
checks remain separately recorded; SQL and the Core suite were not rerun here.
Installed Simulator app/debug-library/Info hashes match the final signed products.
The phone recorded individual review and iPad permanent draft were visually checked.

All seven separately signed Mac cases now execute and pass with no runtime
warnings: individual/group viewer, archived-project and write-paused cold recovery,
plus current-observation refresh. The test now locates the app's separate sandbox
through the user's passwd home and sends a Finder/Dock-style Launch Services open
request after process launch, explicitly reusing the sole existing app instance.
The DEBUG screen picks up an already-discovered review on mount and avoids a second
startup sync once that review exists. The former no-window and duplicate-read
failures are retained as diagnostic evidence; production launch behavior is unchanged.
Each cold case observes exactly two recovery reads, unchanged saved queue/tables
before review, retained later edits and current read restrictions after acceptance,
full snapshot equality after relaunch and one main window. Refreshed instructions
are saved only on acceptance. Group viewer and refreshed individual previews were
visually inspected. These Mac cases use ordinary synthetic roots; Mac recurring
history and broader keyboard/spoken acceptance remain open.

Native Mac recurring gestures/history, storage/account-race acceptance, child-series
and moved-series native cases, genuine hosted later-history/multiwriter delivery,
missing-incarnation authored/cross-table recovery, large workloads and the remaining
advanced/wearable backlog stay open. User-deferred release/provider/device work stays
deferred. No real account/task or hosted schema/configuration changed. See
p2-recurring-native-recovery-evidence.json and recurring-native-recovery/ in each
platform repository. Platform sources and build inputs remain independently owned.

## 25 October 2026 — Real storage failure and safe completion-review retry

Completion reviews now give clear guidance for recognized Cocoa filesystem errors
without exposing private file details. Full-storage errors ask the user to free
space; inaccessible/corrupt file errors explain that queued work is unchanged and
ask the user to check storage access and retry. Network and sign-in failures keep
their existing specific next steps. Transactional queue/storage/transport behavior
and account/access guards are unchanged. Each independently owned repo passes all
184 completion checks: the previous 181 plus three new error/privacy/fallback cases.

Four actual native cases pass on each Mac, iPhone and iPad with no runtime warnings:
three group storage failures plus an individual viewer cold-recovery regression.
The real workspace-cache path becomes a directory during recorded acknowledgement;
the selection-draft directory becomes a file before unrecorded cancellation; and
the backup index becomes a directory after the permanent selection draft is saved.
The production file writer, backup and encrypted vault fail naturally. Every failed
review remains retryable and its complete durable snapshot equals the original.
No cancellation reaches the local peer before the required safety copies succeed.
After repair, acknowledgement retains the exact queued edit; cancellation restores
both original source rows exactly, retains unrelated rows and leaves one reusable
encrypted draft. The draft's authored notes reopen after relaunch. All nine storage
cases retain current read restrictions and complete post-retry snapshots through
another launch (only knownTasks/quarantined Codable Set order is canonicalized).

The Mac runner correctly cannot move files in the app's sandbox. Reserved DEBUG
app controls perform its own reversible filesystem setup/repair, and a journal plus
explicit cleanup launch restores prior synthetic vaults even after a test failure.
No entitlements or user permissions changed. The Mac preview assertion reads native
Text values as well as labels. Both apps and final real development signatures
verify; installed Simulator app/debug-library/Info hashes match built products.
Mac backup-failure and iPad cache-failure previews were visually inspected and show
readable, actionable guidance. Temporary test sessions finish closed.

These cases use ordinary synthetic shared roots, viewer access and the reserved
local HTTP peer. They do not prove native individual storage failures, real disk
exhaustion/hardware corruption, account-switch/asynchronous races, native Mac
recurring history, hosted delivery or release behavior. Those checks, authored
missing-incarnation/cross-table recovery, large workloads and the advanced/wearable
backlog remain open. Existing user deferrals remain unchanged. No hosted schema,
service/configuration, rollout or real account/task changed. See
p2-storage-recovery-evidence.json and storage-recovery/ for the retained evidence.


## 25 October: completion recovery owns its workspace and error

Individual and selection review actions now capture the credential incarnation as
well as the full saved snapshot, access cache, workspace generation, read revision
and exact review. Late replies and errors cannot replace a newer observation,
retire newer authored work or alter a different account. Leaving and returning to
the same account also invalidates the earlier request. Review-screen handlers check
ownership before dismissing or consuming a message; a new request gets fresh view
state. A failure receipt binds the original action to its post-rollback state, so a
real storage failure remains actionable without consuming a later unrelated error.

Each independently owned repo passes 191 completion Core cases. Fifteen native
cases pass on each Mac, iPhone Simulator and iPad Simulator with zero failures,
skips or runtime warnings: fourteen delayed-response scenarios and a real workspace
write failure/retry control. The local peer validates typed replies before holding
them. Actual Backend session transitions, Store refresh/cancel methods and saved
snapshots are exercised. Positive controls accept a current reply and present its
current timeout; a later message is neither overwritten nor consumed. Real native
review controls still show the storage error and complete retry after repair.
All 42 race proofs retain complete interleaved snapshots and match whole-workspace
relaunches; all three storage cases preserve the failed durable workspace exactly.
Only Codable Set ordering is canonicalized. See
[p2-completion-race-evidence.json](p2-completion-race-evidence.json) and
[completion-races/](completion-races/) for retained evidence and source hashes.

The fixture initiates races through reserved DEBUG controls, not the production
account-picker UI. Read-cache equality is checked at reply delivery; a fixture-only
access downgrade is not claimed durable through relaunch. Backup/vault I/O-phase
races, native individual storage failures, Mac recurring history, broader keyboard/
spoken checks, missing-incarnation authored/cross-table recovery, large workloads
and genuine hosted multiwriter delivery remain open. No hosted schema, service,
configuration, rollout or real account/task changed. User deferrals remain intact.


## 25 October: individual review storage failure and relaunch acceptance

Three additional native scenarios now pass separately on Mac, iPhone and iPad:
recorded acknowledgement cannot write the workspace; individual cancellation
cannot write its required backup index; and cancellation reaches the local peer
but cannot save its local result. The last scenario repairs storage, quits,
relaunches and reads the same cancelled request before accepting it. Its original
queue remains intact until successful acceptance; retry does not change the frozen
cancellation receipt. The recorded case preserves its exact authored tail, and
cancellation restores the entire original source row while keeping unrelated work.

All nine scenarios assert unchanged durable workspace bytes on failure and complete
snapshot equality after final relaunch. Current viewer restrictions remain in force.
The individual review's native alert is readable and dismisses correctly before
retry. Four Mac cases pass, including the existing viewer cold-recovery control;
three cases pass on each Simulator, with no failures, skips or runtime warnings.
These are new acceptance checks of the existing production implementation, not a
new user-facing feature. No production app source changed. The preceding 191 Core
checks per repo remain associated with the unchanged production source; they were
not rerun for these test-only changes.

The initial Mac run reached all three expected alerts but selected a Touch Bar
proxy for OK; the final query is scoped to the real window. An iOS test-local name
initially shadowed the cache reader and was rejected at compile time. Both issues
were corrected before the final signed native runs. Reserved test vaults are
restored after every case, and temporary sessions are closed. See
[p2-individual-storage-evidence.json](p2-individual-storage-evidence.json) and
[individual-storage/](individual-storage/) for complete retained states and counts.

The next implementation priority is preserving authored work when an incarnation
has disappeared or been replaced, then supported cross-table recovery. Remaining
acceptance includes provisional-occurrence draft-vault failures, backup/vault
I/O-phase races, native Mac recurring history, broader keyboard/spoken checks,
large workloads and genuine hosted multiwriter flows. User-deferred release,
provider and physical-device work remains deferred. No real task/account, hosted
schema/service/configuration or rollout changed.


## 25 October: keep authored edits after a recorded task incarnation disappears

Both clients now offer **Keep edits as draft** when a validated recorded result
cannot retain its connected authored task work. This covers missing source tasks
and displaced provisional occurrences, for individual and selection reviews.
The existing typed cohort reconstruction validates every connected command and
local row first. Unexplained fields, foreign scopes, indirect preferences and
unsupported mention intent continue to protect the whole queue. A current readable
team/project boundary is required; local recovery never grants editing access.

The explicit action freezes the complete review presentation, including workspace,
credential incarnation, snapshot, access cache and read revision. An obsolete click
is rejected even when the account and head task remain the same. A safety backup
and permanent encrypted draft are saved and read back before local acceptance;
failed writes leave the exact workspace/queue intact, and retry reuses the draft.
Only connected task work and valid comment drafts move out of the active queue.
Independent commands and other rows remain unchanged. Original history bodies and
nonces remain in the archive; no completion, cancellation, copy or retirement RPC
is added by this action. Ordinary sync can resume under the current access mask.

The new account/backend-bound format lives in its own **Recorded recovery** folder,
with authenticated encryption, removal fencing, bounds, explicit deletion and no
automatic eviction. Existing selection formats and readers are unchanged. Simple
provisional drafts keep their existing task-copy workflow. Saved team drafts now
also list Saved edits, with readable text, Copy/Share and a JSON review export.
The export omits the private workspace snapshot, access cache and unrelated outboxes.
An individual command is retained exactly; an ephemeral one-member analysis wrapper
is neither persisted, exported nor sent. Expensive preparation runs off the UI
thread, and list titles do not reconstruct saved queues.

Each repo passes 203 completion Core checks (12 new cases). Five distinct native cases are accepted
on each Mac, iPhone Simulator and iPad Simulator with no remaining failures, skips
or runtime warnings: individual and selection preservation/relaunch, workspace-write failure,
draft-vault failure and the existing selection-draft control. New cases exercise
stale-presentation refusal through the real Store entry point. iPhone/iPad sharing
opens and cancels safely. Mac exports through the standard Save dialog; the actual
local JSON file matches the prepared export byte for byte, and a second Cancel
leaves both the file and workspace unchanged. No external delivery is claimed. Complete retained
snapshots, archives and exports are independently checked. Native cases use ordinary
missing sources; canonical recurring replacement, mixed/deleted task cohorts and
comments also have Core coverage. See
[p2-recorded-recovery-evidence.json](p2-recorded-recovery-evidence.json) and
[recorded-recovery/](recorded-recovery/) for exact evidence and development history.

The reserved DEBUG fixture no longer reseeds a deliberately missing task on
relaunch. XCTest teardown blocks restore prior test vaults even after assertion
failure; initial interrupted fixture vaults were restored before final acceptance.
Mac uses the native Save dialog for JSON export, with scoped completion feedback
and safe cancellation. Test sessions end closed.
The Mac Save-dialog automation initially targeted the filename instead of the
folder field. No file was written in that attempt. A broad folder lookup also timed out, while
the native dialog confirmed the
correct local destination. Narrow field/control lookups resolve both test issues.
The corrected export case passes separately; the other four cases passed in the
suite. All run summaries are retained, including both automation failures.
No hosted schema, service/configuration, rollout, real task/account, release or
provider setup changed. Rank 6 and the broader Px goal remain open: supported
cross-table recovery, broader recurring/spoken/I/O-race/large-workload acceptance
and genuine hosted flows still remain, alongside the agreed user deferrals.


## 25 October: connected mention read-state recovery

Both clients now connect a saved mention read/unread marker to its comment and
exact task incarnation when preserving recorded missing-task work or a cancelled
selection as an encrypted draft. The account, recipient, comment/mention identities,
project, task generation and expected revision are validated before local removal.
Missing, foreign, duplicate, malformed or unexplained context keeps the whole
review and queue protected. An ordinary receipt or simple cancellation cannot
silently orphan a connected marker, even when it is the only remaining local work.
The explicit recorded action still requires the existing backup, encrypted archive
and read-back before persisting the reviewed result. No extra write authority or
conversation RPC is added; saved markers are never automatically replayed.

Saved draft text explains the read/unread choice and connected discussion. Exports
with markers add only their related comment/mention rows under
`conversation_context`; original intent bodies and nonces stay exact. The private
whole-snapshot archive remains separate from export, and unrelated conversations
stay in the active workspace and out of the review file. Exports without markers
are unchanged. Both independent app repositories own their implementation.

Each repo passes 236 focused Core checks, including seven new cases. Two native
cases are accepted per Mac, iPhone Simulator and iPad Simulator: the new connected
marker group recovery/relaunch/preview/export and the existing single missing-task
regression. Mac also saves the actual JSON locally and checks exact bytes; iOS
opens and cancels native sharing. Full saved snapshot, original marker/context and
cold-relaunch state are independently checked. These are synthetic signed-host
checks; cancelled selections and unread=false use Core coverage in this stage.
See [p2-mention-recovery-evidence.json](p2-mention-recovery-evidence.json).

Next is captured preference/order/pin recovery. Unsupported or absent conversation
context, single cancelled/provisional marker flows, broader native recurring/spoken
acceptance, backup/vault I/O-phase races, large workloads and genuine hosted flows
remain open. Collaboration remains default off. Hosted schema/service/configuration,
rollout, real account/task data and all user-deferred release/provider/device gates
remain unchanged.

The Mac export test now creates and removes its unique synthetic file in the
runner’s own temporary directory. Its first self-contained setup attempt was
refused by the test runner’s sandbox at `/tmp`; no app file export occurred in
that attempt. The corrected setup has a separate retained one-case result.


## 25 October: captured list-order and pinned-note recovery

Both clients now capture optional version-1 recovery evidence when writing a
supported account-owned task ordering or note pin. It binds the actual command
identity, account/backend, complete prior and projected preference row, and the
referenced task generations/projects. Missing unrelated task IDs remain explicit
unavailable references in the ordering vector; they cannot authorize a recreated
task or be inferred as a task incarnation. The evidence stays outside row fields and
ordinary HTTP write bodies. Local mode and older/unsupported captures keep their
existing behavior; no history is fabricated for an old queue.

An explicit recorded-result or cancelled-selection draft can now preserve complete
same-row choice histories, including Pin → Undo → Redo. The current row must match
the captured final projection, each transition must join exactly, and affected task
incarnations must match the reviewed cohort. The entire ordering vector is kept;
recovery restores its prior row instead of splitting a user's choice. Other list
rows and independent task edits stay unchanged. Missing/foreign/unsupported or
changed evidence keeps the review and queue protected. Plain completion receipts
and simple cancellation cannot silently strand a connected arrangement.

The existing verified backup/encrypted-archive/read-back transaction precedes local
acceptance. Draft text explains the saved order/pin choice and prior arrangement;
JSON retains all original commands, nonces and captured evidence. Preference rows
are not misrepresented as tasks, and unrelated task descriptions remain outside
export. Undo/Redo choices receive fresh local identities and capture the then-current
row. The new capture indexes task identities once; readable summaries index titles.
Current task-write validators refuse attached preference recovery metadata.

Each repo passes 257 focused Core checks (ten new cases), including real intercepted
HTTP proof that recovery metadata is absent from the normal preference body.
Two native cases pass per Mac, iPhone Simulator and iPad Simulator: combined task,
mention, list-order and pin/Undo/Redo preservation through the production capture/
history helpers, archive/read-back, cold reopen, preview and export; plus the
existing single missing-task regression. The actual Mac JSON Save bytes match the
prepared export; iOS sharing opens and cancels safely. Complete snapshots, preserved
commands, restored prior order, untouched other list row and relaunch are retained
and independently checked. See
[p2-order-recovery-evidence.json](p2-order-recovery-evidence.json).

This adds supported task `view_orders` recovery, not arbitrary `view_preferences`
fields or guessed legacy ordering history. Single cancelled/provisional recovery
paths, missing conversation context, backup/vault I/O-phase races, broader native
recurring/spoken acceptance, large-workload responsiveness and genuine hosted
acceptance remain open. Collaboration stays default off. No hosted schema/service/
configuration, rollout, real account/task or user-deferred release/provider/device
gate changed.

## 26 October: individual cancellation drafts

Both clients can now keep connected edits as a draft when cancelling an individual
queued completion or reopen action. Admission checks the exact current review,
account/session, workspace read revision, full local snapshot and readable task
incarnations. A verified safety backup and permanent encrypted preflight draft
precede the cancellation request. The actual terminal cancellation response is
then appended atomically and read back before the live queue or cache changes.
An unconfirmed draft cannot authorize local retirement. If the action already
synced, the preflight draft remains available and the whole live queue stays intact
for recorded-result review. A failed cache write can retry after cold reopen using
the same draft and confirmed response, without sending cancellation again.

Saved drafts clearly distinguish pending cancellation from confirmed cancellation.
The separate version-2 encrypted namespace preserves the actual individual command,
original read response, complete original snapshot and bounded terminal history.
Existing recorded version-1 files and their authenticated context are unchanged.
Readable exports include authored task/conversation/order choices and cancellation
status; private snapshots, permission caches and raw review/proof responses are not
exported. No synthetic collection header is saved or transmitted. The internal
one-member adapter is used only for local analysis. Unknown or unsupported work
continues to protect the whole queue; this adds no editing permission.

Each repository passes 267 focused Core checks (ten new cases). These include
recurring successor/deletion and Undo/reopen cancellation, mixed independent work,
viewer/archive/pause boundaries, malformed/foreign/unrecorded/recorded proof
refusal, exact encrypted round trips, bounded proof history and export isolation.
Native verification and retained evidence are recorded in
[p2-single-cancel-recovery-evidence.json](p2-single-cancel-recovery-evidence.json).

The remaining work includes provisional-copy cancellation and absent conversation
context, I/O-phase account/session races, broader native recurring/spoken checks,
large-workload responsiveness and genuine hosted collaboration acceptance.
Collaboration stays default off. Hosted schema, service/configuration, rollout,
real accounts/tasks and the agreed release/provider/device deferrals are unchanged.

Five native cases pass on each iPhone and iPad Simulator: successful connected
cancellation/export, cache-write failure with cold retry, vault failure before any
cancellation request, an already-recorded race, and the existing recorded-draft
regression. Full before/after/relaunch snapshots, actual command/proof/export and
one exact individual cancellation request per scenario are retained and independently
checked. Native sharing opens and cancels without replaying saved edits. Both
installed binaries matched the strictly verified real-team signed products.

The Mac build and 267 Core checks pass. Its current native suite is pending macOS’s
interactive “Enable UI Automation” approval. Two attempts failed at runner
initialization before any app test ran. The interrupted initial observation exposed
an alert selector that matched Touch Bar instead of the window; this is corrected.
The initial already-recorded expectation also incorrectly required the preserved
disk permission snapshot to change; it now checks the whole snapshot stays exact.
These failed/interrupted attempts are retained as compact evidence, not counted as
current Mac acceptance. No additional manual listening or widget checks are needed.


## 26 October: verified provisional-draft storage

The original provisional-occurrence draft vault now reads back and compares the
actual decrypted archive after saving a draft, freezing a copy request or clearing
a confirmed-cancelled copy request. A successful filesystem write alone no longer
lets these calls return success. When verification fails after the atomic write,
the authored archive and actual saved request remain on disk for review/retry;
the code does not fabricate a rollback or mint a replacement identity. Existing
Store callers await these operations before retirement, sending a copy or accepting
cancellation. No task, wire format, draft version, authenticated encryption context
or UI flow changes.

The vault now rejects linked/nonregular files and linked vault directories. Listing checks file sizes, the twenty-file bound and the 64 MB aggregate
bound before loading ciphertext or fetching a key. Direct loads check their own
file type and size first; writes also check the complete archive budget. Files are not evicted when a bound or an
unreadable archive prevents access. The account-removal fence now protects explicit
draft deletion as well as save/copy writes; already encrypted material remains
readable for recovery under the existing policy.

Each repository passes 238 selected completion-recovery Core tests. Eight new
real-filesystem cases cover read-back key loss during all three
writes, reopening and exact-request retry, stale cancellation after a newer request,
sparse oversized files, aggregate/count refusal before key access, linked paths,
blocked destination repair and deletion fencing. Current results and limits are in
[p2-provisional-vault-evidence.json](p2-provisional-vault-evidence.json). This is
storage acceptance, not new native/hosted retirement or copy-delivery acceptance.
Both app builds pass (signed isolated Mac build; iOS Simulator compile-only).
The first storage run exposed cached folder metadata after repair; fetching fresh
metadata fixes the actual retry. Compact failed-iteration evidence is retained.
Mac interactive automation remains pending user approval. Provisional connected
edit expansion, missing conversation context, I/O-phase account/session UI races,
broader native/spoken/recurring checks, large workloads and hosted rollout remain
open. Collaboration stays default off; all user deferrals remain unchanged.


## 26 October: captured discussion context for queued mention choices

Marking a mention read or unread now captures an optional version-1 device-local
context when the current workspace has one matching task, comment and mention.
It binds the complete original intent and nonce, account/backend, exact task
incarnation/project, recipient and expected mention revision. Only supported
comment/mention columns are frozen; unrelated discussion, task records, unknown
private columns and permission caches are excluded. Missing/ambiguous capture
keeps the original read-state intent without inventing historical context. A retry
with the same operation ID never replaces its original capture.

Recorded missing-task and individual/selection cancellation recovery can use this
capture if its matching cached discussion has disappeared. Historical rows are
added only to a temporary analysis copy; they are never reinserted into the live
workspace. Existing live rows take precedence and must retain matching identities;
malformed, duplicated, reassigned or older mention identities refuse recovery.
Current workspace read access is still required. A plain completion receipt cannot
silently orphan the connected read-state choice. Readable draft previews explain
“Saved comment” when relying on captured text. Explicit export includes only the
selected discussion, marking fallback rows as captured. Legacy entries are not
assigned guessed context, and unsupported metadata keeps work protected.

Both independent repos pass 284 focused Core checks, with nine new cases for
captured read/unread preservation, exact cancellation proof, current access refusal,
malformed/foreign/stale/recreated context, encrypted reopen/export isolation,
nonce immutability, missing/ambiguous capture and actual intercepted HTTP payloads.
The existing server request body is unchanged: captured context never enters it.
Native acceptance and exact source/artifact hashes are recorded in
[p2-mention-context-evidence.json](p2-mention-context-evidence.json).

This handles supported newly captured mention choices, not arbitrary missing
legacy conversation evidence or the wider provisional-copy cohort. Mac native
acceptance still awaits interactive automation approval. I/O-phase account/session
races, broader native recurring/spoken/large-workload checks and genuine hosted
collaboration remain open. Collaboration stays default off and all user-deferred
release/provider/device gates remain unchanged.

Two native cases pass on each iPhone and iPad Simulator: the new recorded-group
recovery with both live discussion caches empty, and the existing individual
recorded-draft regression. Actual before/after/relaunch/archive/export JSON is
retained and independently compared. The frozen selected discussion survives;
it is never restored into the live cache. Native sharing opens and cancels without
changing saved state. Installed binaries match the strictly verified signed
products. Debug setup uses the production enqueue/capture helper; normal public
Mark read/unread button interaction, native cancellation/unread and hosted behavior
are not claimed by these two cases. The independent Mac app/test build and strict
signature verification pass; its matching UI test awaits automation approval.


## 26 October: large saved-draft preparation

Saved task-recovery drafts now derive their display/export content once instead
of repeatedly rebuilding the same recovery plan. Task lookups use a temporary
index while retaining the former first-match behavior. Native Mac and iOS detail
screens request text and JSON together in their existing background task, sharing
one validated plan. Account/workspace result guards remain in place; no prepared
display result is reused as authority for applying recovery.

Profiling a full-size draft also identified repeated ID scans during typed replay.
For draft analysis only, affected tasks are brought to the front of a temporary
simulation copy. Every record and every existing validation stays present. The
initial/returned workspace is separately prepared from the original cache order;
analysis ordering is never persisted or exported. Ordinary acknowledgement keeps
its existing path. No task body, draft version, encryption context or server/RPC
contract changes.

A synthetic debug case with 101 related task records, 102 queued commands and
10,000 unrelated cached tasks originally spent about 14 seconds on text and 16 on
export. Final measurements prepare both outputs together in under a second. The
full 50,000-record archive fixture prepares in about 2.3 seconds; adding the full
1,000-command queue takes about 3.3–4.4 seconds across the retained runs. These are observations from this Mac,
not release/hardware performance guarantees. Original preview-text hashes and
recovered-cache order are verified; every queued command and authored historical
note is preserved, while unrelated cache content stays outside the export.

Each repository passes all 289 selected Core checks, including five new cases.
The current Core/native results, profiling evidence, before/after observations,
prepared-source/signature hashes and exact acceptance limits are retained in
[p2-draft-performance-evidence.json](p2-draft-performance-evidence.json). Two native
cases pass on each iPhone and iPad Simulator through the actual combined-preparation
screen: captured-discussion/group/order/pin recovery and the recorded single-task
regression, including encrypted reopening and native sharing cancellation. Full
snapshots and exports are independently compared. Normal-size synthetic native
checks do not establish a maximum-size live UI, archive-I/O or hosted benchmark.
The independently signed Mac app/test build passes; Mac UI automation remains
pending interactive approval.

This advances the large-selection preparation gate; it does not close wider
provisional connected-copy cohorts, unsupported legacy conversation context,
I/O-phase account/session UI races, native spoken/recurring/maximum-workload and
genuine hosted team acceptance. Collaboration stays default off. All user-deferred
release/provider/device gates remain unchanged.


## 26 October 2026 — Connected provisional task-copy drafts

Recorded individual recurring actions can now preserve connected list-order/pin
histories and supported discussion markers without losing their explicit task-copy
workflow. The complete encrypted recovery archive is saved and read back first;
the separate task draft then links to that verified archive. The existing
actor-bound retirement operation retires only the unused planned generation. Its
actual response is retained and verified before the recovered workspace is saved.
Any actual shared replacement remains intact. Saving never creates a task copy.

Saved task details provide a direct link to the connected edits and explain the
scope of copying. Optional local metadata keeps the existing draft formats,
encryption context and RPC bodies compatible. A retry reuses the saved task-copy
request rather than changing its frozen choices. Both metadata histories have
explicit bounds without automatic eviction. Account-removal fences protect these
writes. Unsupported or unreadable histories remain queued.

Verification and remaining limits are recorded in
[p2-connected-provisional-evidence.json](p2-connected-provisional-evidence.json).
The focused Core suite passes 302 checks in each repository, including 13 new
connected-draft, encrypted-I/O, removal-fence and actual transport cases. Native
acceptance is tracked separately; this does not close the broader hosted,
maximum-workload, I/O-phase race or spoken-accessibility gates. Collaboration
remains default off, and the user-deferred release/provider/device gates stay
deferred.

Three new native cases pass on each iPhone and iPad Simulator: ordinary linked
preservation, copy-vault failure with zero premature retirement calls, and a
cache-write failure followed by cold reopen and retry. A recorded single-task
regression also passes on each device. The initial six new native cases stopped
at a task-copy control below the visible scrolling form; correcting the test's
scrolling made all six pass without changing production recovery code. Full
snapshots compare equal after sorting only the cache's knownTasks/quarantined
sets; queued commands and task/table order are compared unchanged. Actual
retirement requests/replies, encrypted readback, explicit copy availability,
linked navigation and sharing/cancellation are verified. Installed app/debug/test
binaries match the signed products. The independent Mac app/test build and strict
signatures pass; native Mac acceptance still requires UI automation approval.


## 26 October 2026 — Watch workspace departure and reviewed recovery

The iOS-owned companion now clears an active workspace through the existing
revisioned empty packet. Its revision is durably saved before publication,
including when receipt-generation rotation changes phone authority. Repeated
retirement is idempotent; an exhausted revision refuses without changing the
original authority. A stale cached reconnect notice can no longer cancel every
new connection attempt on this normal departure path. No wire/archive fields,
version or mutation-receipt contract changed.

Watch retains its privacy marker when an empty update arrives. Every client
guard derives from that saved marker plus an immediate memory fence for a failed
privacy write. Only the current explicit Connect attempt can clear privacy.
A valid current reply may follow its own equal/newer same-workspace publication;
it confirms the connection without reverting the newer projection. Older,
empty or different-workspace replies cannot reopen a concealed workspace.
Superseded automatic-refresh replies cannot cancel a newer Connect attempt.

All 104 focused iOS Watch/receipt checks pass, including 16 new cases. The Mac's
unchanged receipt contract passes its nine independent compatibility checks.
Seventeen assertions pass over the actual Air/42 mm Simulator pair across nine
native Watch phases: held actual Connect reply/signout/privacy, cold relaunch,
fresh explicit reconnect with the private draft's old destination intact,
offline completion/relaunch, phone departure before delivery, explicit return,
reviewed new Inbox capture, and exact old-completion replay. The original task
stays open and unchanged, only the reviewed copy gets a mutation receipt, and
replay preserves every actual phone-cache byte. The current phone Store/driver
also passes 16 history-reset checks plus three cold checks with its OS-peer
boundary injected; those 19 checks are separate from the real paired transport.

The first two candidate paired runs kept privacy but failed reconnect; retained traces show
a fresh reply whose attempt had already been invalidated. The third verified the
numbered signout and retained private draft but caught disagreement between the
saved marker and a separate memory flag. The final run passes with the guards
using the saved state. Initial failures, full final native data, independent
comparisons, source/signature bindings and exact limits are recorded in the
iOS-owned p2-watch-boundary-evidence.json. Phone/Watch Debug and Watch Release
builds pass; final installed debug code matches the real-signed products. Release
excludes these fixture routes.

These are synthetic local-workspace checks with controlled startup preparation
and ordinary foreground WCSession delivery. They do not prove cloud-account
Auth, physical phone/reinstall, background/system launch/protected storage,
native typing/dictation/VoiceOver or wider layouts. Watch stays disabled and
unembedded in shipping inputs. Wear OS, the rest of Px and every user-deferred
release/provider/device gate remain open. The Mac gains no Watch target,
transport or iOS build dependency.


## Heading work in Inbox and primary widgets — 26 October 2026

Default Inbox and its review cards now use the cached productive work reading.
Independent tasks beneath headings show their own details, plans and parent
context. Child completion/editing uses the strict real-root transaction path.
The Mac Inbox badge counts the same eligible work.

Moving one of these cards presents a review of the entire containing root
heading, including completed work. The review names the destination, lists the
affected tasks and warns when assignments will be cleared. Confirmation checks
the captured root, destination and workspace again; Cancel makes no change,
and one Undo restores the group. Direct synthetic-child project PATCHes are
rejected. This stage intentionally offers a whole-group move, not detachment.

Primary Today, Inbox reset, Focus, Week and planning-widget task data now
publishes independent work with exact child routes and completion authority.
Ordinary checklist children require an explicit child filter. Removing that
filter or converting a heading rejects stale completion authority. Ambiguous or
unreadable groups produce a review state rather than an empty-Inbox claim.
Five light/dark/review SwiftUI source renders use the synthetic app's saved
widget projection; these are not installed WidgetKit host acceptance.

164 iOS and 163 Mac focused Core checks pass, including seven new cases per
repo. App/widget/test builds and signatures pass. Native runtime results and
source bindings are recorded in `p2-task-headings-inbox-evidence.json` and
`headings-inbox-work/`; do not infer Mac app-flow acceptance from its build.

Next: project/label/default saved-filter projections and remaining badges,
wider calendar projections, separate child history, then broader native,
installed-widget, shared/service and cross-device acceptance. Normal heading
authoring remains disabled. This milestone does not close headings or Px,
and all user-deferred release/provider/device gates remain unchanged.

The final iPhone and iPad native scenarios both pass, with Cancel preserving the
root exactly, edited child title retained, completion/Undo, confirmed whole-group
move/Undo, published Inbox counts 2→0→2→1, and exact cold-return root equality.
Four native screenshots were inspected. The debug-only publication panel can
overlap the iPad toolbar; it is absent from normal app runs. The independent Mac
Inbox/planner/Today attempts all stop at foreground activation while the Mac
reports locked, before app-flow checks. Those remain unverified, with the prepared
Mac host preserved for a later unlocked run.


## Heading work in project, label and filter lists — 26 October 2026

Default Project, All Tasks, Completed, label and ordinary saved-filter queries now
read independent work beneath headings. Each child keeps its own labels, plans,
priority and completion. Explicit root/subtask/parent predicates retain their
existing checklist semantics, including mixed independent query sections. A
mixed filter cannot reintroduce roots from unavailable projects.

Manual project queries preserve the source outline. Existing sparse saved orders
containing only heading roots expand their anchors to retain the grouped work;
explicitly saved child positions remain respected. Project sections and widget
ordering use the same rule. Native project/label badges count productive work,
and affected badges show a lower bound when grouped data needs review. Unknown
future task types remain reachable review context without work-count credit.

Configured project, label and ordinary-filter widgets resolve primary published
children without requiring an unrelated child filter. Missing child catalog
members cannot appear as an empty ready list. Unreadable project/group data
produces an unavailable/review state; ordinary missing-root deletion tolerance
and duplicate suppression remain intact. Five actual SwiftUI source renders from
the app-published synthetic snapshot were inspected, including populated project,
label/filter and missing-child states. Installed WidgetKit action/route replay is
still a separate runtime gate.

Print capture validates the exact projected sources, retains an ordinary task's
checklist once, and avoids recursively duplicating heading work already listed.
Headings and unknown types receive no printed task total or completion box.
Default-list print keeps the existing Include checklists option; explicit
hierarchy-filter output retains its matching-only setting. The final print-review
classification and search-hidden heading-anchor corrections are Core/build
verified. Native list scenarios ran just before those two corrections; no new
native print-dialog, exported-PDF or hidden-heading search-order acceptance is
claimed by this milestone.

191 iOS and 190 Mac focused Core checks pass, including 13 new cases per repo.
App/widget/test builds and signatures pass. Both iPhone and iPad native scenarios
pass project membership, exact child details/Cancel, own-label filtering, child
editing, ordinary saved-filter membership, completion/Undo, and exact saved-root
cold return into label/Completed views. Eight native screenshots were inspected.
The Mac still reports locked; its independent project/label/filter case is built
and prepared alongside the prior Inbox/planner/Today cases, with no new native
Mac acceptance claim. See `p2-task-headings-list-evidence.json` and
`headings-list-work/` for source variants, signatures, results and exact limits.

Next: separate child activity history and broader calendar periods, then remaining
native creation/conversion/race/legacy/largest-text/spoken acceptance, installed
widgets, shared/service and cross-device adapters and generic provider mapping.
Normal heading authoring remains disabled. This does not close headings or Px;
all user-deferred release/provider/device gates remain unchanged.


### Child history recording foundation (26 October 2026)

Separate child-ledger schema, strict reader and standalone local recorder now
exist in both owned repos. 53 Core checks per app (22 new) and 49 real-PostgreSQL
checks per independent fixture pass, including actual SQL-to-Swift rows, retry,
privacy/account boundaries and 10,000-child samples. Official advisors report no
new-object findings. This stage is inactive: Store/sync/team masking/backups and
activity/Insights/Project pulse integration remain next. Hosted deployment and
normal heading authoring remain unchanged. Mac native replay was retried after
unlock, but the Mac locked before interaction; no new runtime pass is claimed.
See [the child history contract and ordered next work](TASK_NODE_ACTIVITY.md) and
`child-activity-history/evidence.json`. Px remains open.


### Child history in local edits, sync and backups (26 October 2026)

Both apps now record committed local child transitions, read the optional cloud
feed with sequence/session/epoch checks, apply team visibility masks, discard
unavailable cached history on a fresh task read, and preserve history as a
validated backup archive without replaying it. Ordinary task Undo/Redo now uses
fresh action identities; retries keep their prepared identity. Per-pass parsers
reduce a 5,000-event append validation from 2.915 seconds to about 0.14 seconds
without weakening decoding; a 5,000-distinct-root/timestamp sample takes about
0.36–0.37 seconds. 252 focused checks pass per repo, including 12 new
cases. App/test builds pass; exact native and signing scope is recorded in
`child-activity-integration/evidence.json`. Mac runtime remains unverified while
locked. No service migration or rollout flag changed.

Activity screens, Insights and Project pulse still use parent history. Next is
trustworthy historical root type/work context and a combined child activity fold,
then their UI/widget integration and broader calendar/adapters acceptance. See
[TASK_NODE_ACTIVITY_INTEGRATION.md](TASK_NODE_ACTIVITY_INTEGRATION.md) for the
contract, verification limits and ordered remaining work. Px stays active.


### Observed parent type and generation (26 October 2026)

New parent events carry optional observed type/generation metadata. Heading
events do not earn work credit, old untyped totals are preserved, and a known new
occurrence resets its counter without erasing genuine earlier credit. Typed
routes cannot open a recreated/foreign root at the same ID. The additive SQL
writer preserves the later team-custody rule and continues recording retained
parent work after Auth removal. No hosted schema or authoring flag changed.

239 Core checks, 36 PostgreSQL upgrade checks and 94 broader custody checks pass
per independent repository. App/test builds and exact native limits are recorded
in `root-activity-context/`. This is not mixed child UI/runtime acceptance.
The separate child ledger still needs team identity/role/cleanup custody alignment
before service rollout; that is now the first prerequisite for combining feeds
and wiring activity/Insights/Project pulse. See
[TASK_ROOT_ACTIVITY_CONTEXT.md](TASK_ROOT_ACTIVITY_CONTEXT.md). The full Px scope
and all user-deferred release/provider/device gates remain unchanged.


### Child custody and team read parity (26 October 2026)

Prepared child-history custody now uses stable content identities, survives Auth
author removal, keeps actual/unknown actors distinct, and follows parent-history
role/session/scope gates. Personal/account and explicit team cleanup physically
remove the appropriate child history, with file-guard rollback preserved. Existing
events and sequence IDs remain intact; guaranteed coverage advances at upgrade.
64 real-PostgreSQL and 228 focused client checks pass per repository. No hosted
change, production Swift change or new native runtime pass is claimed.

Next: adoption inspection/count/fingerprint/lock and client-review parity for the
child ledger, followed by combined history and activity/Insights/widget UI. See
[TASK_NODE_ACTIVITY_CUSTODY.md](TASK_NODE_ACTIVITY_CUSTODY.md) for the exact scope,
evidence and remaining rollout gates. Px remains open; user-deferred gates stay
deferred.


### Child history in project-transfer review — 26 October 2026

Both owned clients and prepared SQL now count/fingerprint/lock child history in
bounded transfer reviews, fence late/ABA writes and require a versioned count
contract. Native review shows task/subtask history entries. Each repo passes 35
new SQL-review checks, 55 connection-policy regression checks with the new schema,
and 64 focused Core checks. Actual old approvals become stale; existing child
rows and applied receipt/retry shapes remain intact. No hosted flag changed.

This closes bounded review coverage only. The current registry binds live task
roots, so historical-only/deleted roots and earlier project intervals still need
event-level custody, removal/read rules and acceptance before rollout. Mixed
activity/Insights/Project pulse and wider heading acceptance remain next. Mac
native replay failed to activate after the unlock reply; no UI pass is counted.
See [TASK_NODE_PROJECT_ADOPTION.md](TASK_NODE_PROJECT_ADOPTION.md) and
`node-project-adoption/`. The full Px goal remains active.


### Reviewed history survives author and task removal — 26 October 2026

Forward project transfers now assign private, per-feed/event custody to the exact
reviewed history, including deleted roots and old project intervals. This grants
no current-task authority. Every referenced state still needs current project
access; expired sessions, removed members/authors, disabled native reads and
missing/deleted projects remain closed. Separate transfers may share an immutable
event: exclusive history is removed with its team, joint history with its last
owning team. Earlier observed rows survive; guaranteed epochs conservatively
advance and no unreviewed historical repair/backfill is inferred.

Each repo passes 88 PostgreSQL custody checks plus 55 connection-policy regression
checks and 258 focused Core checks. A held real transfer proves team deletion
returns PT409 instead of acting on a stale ownership snapshot. Existing file
guards/rollback and applied receipt retry remain intact. Client wire/UI code is
unchanged; no new native build/runtime acceptance is claimed. All owned containers
are removed; hosted rollout and normal heading authoring remain unchanged.
See [TASK_REVIEWED_HISTORY_CUSTODY.md](TASK_REVIEWED_HISTORY_CUSTODY.md) and
`reviewed-history-custody/` for joint-retention semantics and exact limits.

Next: combined parent/child activity, Insights and Project pulse, then UI/widget
integration and the wider remaining heading/calendar/provider acceptance.
Retrospective orphan repair and full hosted-chain/native acceptance stay open.
The full Px goal remains active; user-deferred release/provider gates stay pending.


### Parent and child activity, Insights and Project pulse — 26 October 2026

The app now combines immutable parent/child activity with feed-specific identities
and receipt-time display order. Productive children earn corrected Insights
credit; headings, ordinary checklist details and completed imports/promotions do
not. Undo/Redo and completion-time edits keep their existing semantics, while
productive-scope conversion preserves genuine earlier work without a fake reopen.
Unknown/gap data remains partial and cannot lend current-task authority.

Project activity opens exact current children using fresh generation/owner/key
checks. Store and widgets publish the same event counts, keep current progress
separate, and show partial history without discarding verified parent counts.
Child-only local history is supported; differing recording epochs remain explicit.

Each owned repo passes 257 focused Core checks (20 new). Independent Mac Debug
app and iOS Simulator app/widget/share/UI-runner builds pass. iPhone/iPad native
flows verify child completion, 2/3 progress, one recorded event, cold saved-state
equality, exact history route and one Insights completion. Source widget renders
are inspected in partial light/dark states. Mac runtime, spoken/largest-text,
installed widgets and hosted/cross-device acceptance are not claimed. Normal
heading authoring and hosted/release configuration stay unchanged.
See [TASK_WORK_HISTORY.md](TASK_WORK_HISTORY.md) and `work-history/` for exact
source bindings/results, partial coverage rules and cleanup. Next: broader
calendar periods, remaining heading/adapters acceptance and the other Px work.
The full goal remains active; user-deferred release/provider gates stay pending.


### Calendar periods and productive work — 26 October 2026

Week, three-day, five-day, month and year calendars now project ordinary work
inside headings, using each task's own date and viewed time zone. Heading and
checklist dates do not inflate totals. Stable children use existing hierarchy
editing/completion paths; unknown identities remain non-actionable with a partial
notice. Project archive changes refresh the calendar immediately. Normal heading
authoring remains off. See [TASK_CALENDAR_WORK.md](TASK_CALENDAR_WORK.md) and
`calendar-work/` for verification, harness corrections and remaining limits.
This completes the period-projection implementation; wider native Mac,
accessibility, adapter and cross-device acceptance remains open. The full Px
goal and user-deferred release/provider gates remain active/pending respectively.


### Reviewed generic CSV workflow mapping — 26 October 2026

Both clients now accept explicitly mapped comma-separated workflows through
Templates file intake or explicit pasted text. Users choose title/notes, parent
references, exact task/heading values, dates relative to a reviewed reference
date, priority, estimate, labels, time and time zone. Unmapped columns are listed;
source account/completion/assignment/history data is not guessed or imported.
A separate full definition review precedes Add to templates; runs remain separate.
Known Taskfold files keep their strict path and normal heading authoring stays off.
Each owned repository passes 87 focused Core checks, including 12 new mapping
cases. Build/native scope, source hashes and cleanup are in
[TASK_CSV_SOURCE_MAPPING.md](TASK_CSV_SOURCE_MAPPING.md) and `source-csv-mapping/`.
This implements generic workflow mapping; provider/file handoff, flat row sharing,
shared capability adapters and wider rank-3/6/7 acceptance remain open. User-deferred
gates and the full Px goal remain unchanged.


### Reviewed flat task-row CSV — 26 October 2026

Both apps now implement Print or export → Export CSV, with row review, explicit
notes/checklist choices, native Save and guarded Share. Structured fields, status,
file-local hierarchy and complete label names survive; account/live IDs and private
non-task payloads are excluded. The explicit CSV mapper recognizes the versioned
transport without reinterpreting generic text. Source/workspace/options checks
precede handoff. Headings are counted as rows separately from productive work.
Each repo passes 64 focused Core cases; current phone/tablet cancellation and cold
preservation pass. Independent Mac build passes; native Mac, completed provider
handoff and wider source/account/accessibility acceptance stay open.
See [TASK_ROW_CSV.md](TASK_ROW_CSV.md) and task-row-csv/ for scope and evidence.
The implementation advances flat row sharing; it does not close rank 3, the wider
Px goal or user-deferred release/provider/device work.


### Reviewed older Todoist heading copies — 26 October 2026

Both apps now offer an explicit review for ordinary open rows carrying known
Todoist heading source metadata. The review separates imported and current titles,
lets the user keep or remove one leading marker, and preserves edited wording by
default. Apply rechecks the whole captured editor draft and heading availability;
the native editor retains its Save/recovery/Undo paths. Reviewed title words stay
literal rather than becoming new quick-entry date/project/priority edits.

Each owned repo passes 52 selected Core checks (7 new conversion scenarios).
Current iPhone and iPad scenarios pass review Cancel, marker choices, Apply then
parent Cancel, separate Save, exact untouched-field preservation and cold return.
Both review images were inspected. Independent Mac Debug build and strict/deep
Simulator signing checks pass. Mac native, broader live source/access races,
spoken/largest-text and shared/cloud/cross-device acceptance remain open.
Normal heading authoring and all user-deferred rollout/provider gates are unchanged.
See [TODOIST_HEADING_CONVERSION.md](TODOIST_HEADING_CONVERSION.md) and
heading-conversion/. Rank 3 and the full Px goal remain active.


### Shared type command protocol — 26 October 2026

Both independently owned clients and service sources now support negotiated root
and nested task-type edit commands. The capability defaults off and participates
in the workspace boundary token. Typed receipts, durable retry identity, explicit
Undo and root/nested completion revisions are checked. Each repo passes 158
selected Core checks, 72 isolated PostgreSQL checks/advisors and an unsigned app
build. No hosted configuration or native UI authoring gate changed.

Native Store/editor integration, creation/lifecycle, shared templates/import,
recovery/runtime and wider accessibility/cross-device acceptance are next; the
existing lifecycle whitelist still refuses typed root payloads. This does not
close shared heading editing or rank 3. See TEAM_TASK_TYPES.md and team-task-types/.


### Shared typed lifecycle — 26 October 2026

Both apps and service sources now preserve root/nested heading types through new
creation, deletion, certified restoration and atomic selection Undo. Lifecycle
transport support is advertised separately from default-off new heading authoring.
Typed acknowledgements and durable identities protect retries; known work can be
restored while new authoring is paused. The null type-column whitelist issue is
fixed. Normalized discussions retain content with fresh callback identities.

Each repo passes 179 selected Core cases, 100 isolated PostgreSQL/advisor checks
and an unsigned current-source Debug app build. No hosted or native authoring gate
changed. Native controls/recovery/races, template/import and wider cross-device/
accessibility acceptance remain open. See TEAM_TASK_TYPE_LIFECYCLE.md and
team-type-lifecycle/. Rank 3 and the broader Px goal remain active.


### Shared heading native controls — 26 October 2026

Both clients now gate root type choices and organizer type actions on captured
and live shared capabilities plus client opt-in and current edit access. Native
acceptance exposed and fixed a fresh Undo baseline missing completion context.
Five installed iPhone and five iPad scenarios now pass conversion Cancel/Save,
Undo/Redo, nested root-scoped writes, missing capability, preserved paused drafts,
creation failure/retry and cold persistence. All four images were inspected.
Each repo passes 141 selected Core checks; current app builds/signatures pass.

The Mac runtime attempt failed before test execution while Xcode tried to enable
UI automation. Its current signed harness is retained; no system setting changed.
The synthetic iOS peer pauses sync, so genuine delivery/receipt recovery, broader
native races/lifecycle/accessibility and shared template/import adapters remain
open. Normal flags and hosted rollout are unchanged. See TEAM_TASK_TYPE_NATIVE.md
and shared-heading-native/. The wider rank-3/Px goal stays active.


### Shared heading workflows and Mac runtime follow-up — 26 October 2026

Both independently owned clients and service sources now preserve headings
through reviewed shared-template publication/replacement, private copying and
shared workflow runs. Root/nested headings retain their type and child order;
review counts distinguish them from productive tasks/checklist items. Exact typed
acknowledgments preserve one encrypted request across lost replies and relaunch.
A reopened shared subtask now gets a clear save-first explanation before a type
conversion that would require a separately saved reopen.

Each repo passes 96 selected Core checks, 60 heading-specific PostgreSQL/advisor
checks and all 89 existing workflow SQL checks with the new migration installed.
Signed iPhone/iPad acceptance passes publication/copy/cold preservation and the
final heading run/lost-reply/relaunch/exact retry flow. The signed Mac runtime
also passes heading workflow review and that recovery flow. Five output images
were inspected. Earlier failures were test-harness selectors/value types/home
resolution and are retained with the final passing results.

The preceding Mac root heading editor/autosave/Undo/Redo/cold-queue test also now
passes after the user approved Xcode UI automation. Its earlier initialization
failure is resolved for that specific case. Source fingerprints, signatures,
results and limits are in SHARED_WORKFLOW_HEADINGS.md, shared-workflow-headings/
and shared-heading-native/mac-summary.json. UI acceptance uses the synthetic
HTTP peer; actual SQL acceptance is separate. Full native server delivery,
broader source/access races, accessibility/largest-text, installed widgets and
cross-device work remain open. Normal rollout and all user-deferred provider,
notification, safe-upgrade and distribution work remain unchanged. Rank 3 and
broader Px stay active.


### Private heading-template reuse — 26 October 2026

The private template screen still hid shared-workspace reuse for every heading
definition, despite the completed typed workflow protocol. Both apps now expose
the reviewed shared route for known v2 definitions when the client supports it.
Private and team-library entry points explain unavailable client support while
leaving copy/export available; a fresh workspace capability refusal explains the
specific problem before sending any creation request. Other preparation errors
retain the bounded general message. Private creation and shared creation are
explicitly distinguished in the preview.

Each repo passes 82 focused client checks. Five signed installed scenarios pass
on each Mac/iPhone/iPad: missing workspace support sends nothing, Back/cold return
preserves the source, private heading-run lost-reply/cold exact retry, ordinary
private-template reuse, and actual Info-disabled creation with a verified complete
typed private copy. The disabled-build checks use real copied app configuration,
not a fake runtime override. Seven native output images were inspected. Initial
Mac text-selector and phone lazy-list scrolling failures were test-harness issues;
final runs pass. Source definitions and existing tasks stay intact.

See PRIVATE_HEADING_WORKFLOWS.md and private-heading-workflows/. These native
checks use the synthetic HTTP peer; the preceding real SQL evidence is unchanged.
No hosted or normal client rollout setting changed. Rank 3 and broader Px remain
active. Remaining adapters include the separate local-only heading admission in
mapped-CSV definition authoring/private live creation, plus broader native delivery,
source/access races, accessibility and cross-device acceptance. User-deferred
provider, notification, upgrade and distribution work remains deferred.

## 26 October — reusable heading definitions

Closed the separate reusable-definition authoring gap: signed-in users can map
explicit CSV heading rows and edit Task / Heading in root or nested template
items when the client supports it. Child Save remains a draft operation; parent
Cancel preserves the saved definition, while parent Save preserves the full
versioned document. Existing tasks and runs remain unchanged. Actual disabled
client builds refuse new heading interpretation/type changes while allowing
ordinary mapping and preserving existing heading metadata during title edits.

Each independently owned repo passes 107 focused Core cases and 23 actual-role
isolated database checks. Installed Mac, iPhone and iPad acceptance covers all five
new scenarios on each platform. See DEFINITION_HEADING_AUTHORING.md and its
retained native evidence for exact scope and initial harness failures.

Rank 3 remains active. Personal live heading creation still has its separate
local-only guard, and wider file-provider delivery, concurrency, accessibility,
installed-widget and cross-device acceptance remains open. No normal client
flag or hosted configuration changed. The previously deferred provider setup,
remote reminders, old-client rollout safeguards and distribution stay deferred.

## 26 October — actual native task output

Closed the scoped native Save/readback gap for task-row CSV on Mac, iPhone and
iPad, plus Mac PDF Save and Print-panel cancellation. The three full task CSVs
are byte-identical, retaining heading/checklist relationships and notes without
account/record identities. Mac's explicit exclusions produce the expected three
rows with no notes. The actual saved two-page A4 PDF retains all eight sections
and the final instruction; both final rendered pages match the inspected output.
All scenarios preserve exact saved tables, including cold return.

Mac now advertises Print or Export in the list menu and the active scene's File
menu; the latter declares Command-P and disables while its review is open. Both
clients clear the preceding CSV success message when starting a new Save, so a
cancelled later attempt cannot retain that message. Four final native scenarios
pass (two Mac, one each phone/tablet). See NATIVE_TASK_OUTPUT.md and
native-task-output/ for source/signing bindings, actual files and all results.

A macOS local-network permission prompt interrupted keyboard attempts and covered
part of the Mac app screenshots. It was not accepted by automation. File-menu
and toolbar routes, readback/cancellation and cold preservation pass; the wider
keyboard and unobstructed Mac visual checks remain open, alongside source/account
races, external-provider delivery, spoken/largest-text and cross-device work.
No print job, real data, hosted configuration, normal authoring flag or user-
deferred release/provider/reminder/upgrade setting changed. Rank 3/Px stay active.

## 26 October — personal cloud heading compatibility

Connected the personal heading adapter to a separate exact service compatibility
signal. Cached support allows an opted-in personal draft; fresh preflight support
controls delivery. Missing support keeps the optimistic work and durable intention
visible, without team-access quarantine or automatic legacy fallback. Restored
support resumes the original queued command. The signal does not authorize team
writes; ordinary personal editing stays independent.

Each owned repo passes 119 selected Core cases and 36 actual-role isolated SQL
checks, including partial-install refusal and unchanged grants/RLS. Three signed
installed scenarios pass on each Mac/iPhone/iPad (nine final native passes): a lost
reply followed by a cold unsupported-service pause and exact retry, support removed
before Save/autosave with no write and preserved cold queue, and ordinary editing
with heading controls unavailable. The HTTP peer exercises Store sync and Backend
requests; genuine hosted transport and paired-device acceptance remain separate.
The three retained images were inspected; phone/tablet images show the test wrapper
and confirmed empty queue, while the Mac image shows the actual heading inspector.

See PERSONAL_TASK_HEADINGS.md and personal-task-headings/. Root cloud transport
is now accepted to that scope. Wider nested/workflow/import/restore, personal
Undo/Redo, source/account races, spoken/largest-text, installed widgets and cross-
device acceptance remain open. Normal app flags and hosted configuration were not
changed. Older-client rollout, release/distribution, remote reminders and other
user-deferred work stays deferred; rank 3/Px remain active.

## 26 October — preserve later edits when workflow creation retries

New private workflow runs now mark every generated project, section, label, task
and manual-order row create-only. The same run keeps its existing stable record
identities. A duplicate delivery uses the established owned-row readback and
acknowledges the current server row instead of merging the old creation payload
into it. Ordinary ordering edits and the separate atomic team workflow service
are unchanged. This also preserves the creation intent through the durable queue
and history Redo; it does not add a new history deletion guard.

Each independent repo passes 182 selected Core tests. Three new regression cases
cover every template kind, cold queue/history intent, and Backend requests for
all five generated table types: lose each creation reply after a synthetic later
edit, decode the saved queue, retry with ignore-duplicates and owner-filtered
readback, preserve the later row and clear only the confirmed intention. Missing
and foreign-owned rows cannot be acknowledged. Existing heading portability,
personal compatibility, backup and shared workflow suites also pass. Logs and
source hashes are retained in workflow-creation-retry/validation.json and its
adjacent log. This is an isolated HTTP peer/Core check, not new installed-native,
hosted PostgREST, SQL or cross-device acceptance.

**Next data-safety gap:** workflow Undo still uses ordinary project/section/label/
order deletion. It must gain service-side protection against later edits and new
dependent work before claiming that full workflow Undo is safe under concurrency.
Create-only Redo does not resolve that deletion risk. Wider native personal
heading Undo/Redo, nested/workflow/import/restore, source/account, spoken/widget
and cross-device acceptance remain open. Rank 3/Px are active. Normal app flags,
hosted services and the user's release/provider/reminder/older-client deferrals
are unchanged.

## 26 October — atomic personal workflow Undo

New private workflow runs carry durable run provenance. Their history inverse is
one command covering the records the run actually created, rather than separate
unconditional organization deletes. The source-only service validates the whole
owned personal set against typed creation baselines and actual schema defaults,
checks both FK and logical organization/nested-label references, and refuses the
whole Undo if any record changed, disappeared or gained outside dependent work.
No row in the set is deleted on a refusal. New and unknown FK-dependent features
fail closed; only derived assignment/reminder bookkeeping is exempt. Stable-order
relation locks fence concurrent incoming references, including hidden rows and
older columns without FK constraints. These locks can briefly contend with other
writers; largest-workflow load/latency acceptance remains open.

One account/request receipt makes a successful lost-reply retry harmless to later
recreated records. A recorded refusal reads surviving personal rows afresh; it
never serves stored content after team adoption/access changes. The private
receipt retains the fingerprint/outcome, not row content. It has RLS, no client
table privileges, and an account-cascade FK. The exposed function is invoker;
its private definer validates the real actor/session and ownership and checks
persistent team identities before returning rows or deleting. Team commands and
permissions are unchanged.

The client refuses malformed/inaccessible replies, restores current owned rows
after a refusal, reapplies later queued edits, and explains the cancelled Undo.
Redo retains create-only insertion and chooses fresh task incarnations. A new
command gets a fresh request identity; a durable retry retains its identity.
Observed local edits/dependencies prevent local deletion. Cached exact service
compatibility is required to start cloud Undo; fresh preflight compatibility is
required for delivery. Missing/removed support leaves work or a previously queued
intention intact, without legacy DELETE fallback or a busy retry loop. Local
workspaces use the same grouped history projection without a remote dependency.

Each independent repo passes 269 selected Core tests (five new regression cases)
and 54 actual-role isolated PostgreSQL checks, including a verified concurrent
incoming writer. Both full native apps compile successfully with signing disabled.
The SQL checks cover all five row types, omitted defaults, atomic edit/dependency
refusal, a logical section link with no FK, hidden/nested-label/new-feature links,
successful reply retry after recreation, fresh refusal replay, persistent team
custody, actor/session/anonymous denial, malformed requests and advisors. The Core
checks cover cold queue/history, task generation changes on Redo, exact account/
origin compatibility, local refusal, authoritative restoration with later edits,
reply ownership and atomic-RPC-only transport when the service is missing.

See workflow-undo/validation.json, its retained logs and database report. Initial
harness attempts corrected scalar JSON encoding, an omitted synthetic labels
table, the fixture's text-array label type and its team-owner membership invariant.
Two meaningful failed assertions drove explicit logical-link protection and the
persistent-team identity fence; the final runs include both cases. Full builds
are compile evidence, not installed runtime, signing or distribution acceptance.
No app was installed/launched and no real data or hosted service changed.

This closes the identified source-level organization-deletion gap for newly
provenanced workflow runs. Legacy untagged queues are not guessed or upgraded;
the deferred older-client rollout work remains separate. Installed native/cloud
workflow create/Undo/Redo/refusal/relaunch acceptance, service-deployment and paired
client acceptance, and large-workflow performance remain open. Wider rank-3/Px
scope and all existing release/provider/reminder/older-client deferrals remain
active. No normal heading flag or hosted rollout setting changed.

## 26 October — installed private workflow history on phone and tablet

Four signed installed client scenarios now pass on each iPhone and iPad Simulator
(eight final passes): actual TemplateRunView creation followed by two Undo/Redo
cycles and cold return; a lost successful Undo reply followed by cold unsupported-
service pause and exact request/body retry; incoming work causing the whole Undo
to be refused, restored and retained across cold return; and unsupported-service
Undo admission preserving the entire workspace until compatibility is restored.
The source is a private project definition with two projects, one section, one new
label, two root tasks (including a heading and productive child), two saved order
groups and multiline instructions. Tests read the actual durable client cache and
peer rows and check all six relevant tables, stable record identities, fresh task
generations on Redo, retained content/relationships, exact retry identity, one
recorded deletion, empty final queue and unchanged workflow rows on refusal.

The new peer/panel is DEBUG-only, behind exact reserved-host guards and explicit
personal/workflow flags. It calls the production template review, Store history,
queue, Backend transport, acknowledgement and refresh paths. Its deterministic
boundary fingerprint changes with project membership and compatibility, so a
post-write access-boundary change restarts the client read. No real account or
network is used. The peer models transport/outcomes; it does not prove SQL/RLS,
cryptographic authentication or hosted PostgREST semantics. The independent 54 SQL
checks from the preceding stage remain that service evidence, not a claim of new
hosted or paired-device acceptance.

The first four-per-device run also passed. After review, the peer was corrected
from a compatibility-only token to a fingerprint of its complete synthetic access
boundary, and both complete suites passed again. Initial test-harness compilation
corrected a throwing conjunction and iOS main-actor helper isolation. Final native
source/signature bindings, logs, summaries and four inspected PNGs are retained in
workflow-undo-native/. The PNGs show the debug wrapper's empty queue, restored
records and readable refusal notice; they are not a new production-layout audit.

Mac's identical scenario source compiles in its signed isolated host and strict
signature verification succeeds. Its one runtime attempt stopped before launching
Taskfold: XCTest timed out enabling UI Automation. The system reports Developer
mode disabled; the runner-initialization failure is retained explicitly and is not
counted as an app-test pass. An approval/unlock question is pending. The current
Mac host/build is retained as one bounded reusable cache for that check, with
exact paths/hashes in validation.json; no Mac Taskfold test process is left running.

Phone/tablet test hosts and runners are closed/uninstalled after evidence retention,
and their completed temporary build/results are pruned. No normal app flags,
user data, hosted service, distribution configuration or deferred release/provider/
reminder/older-client setting changed. The four Mac runtime cases, genuine hosted/
paired-client workflow acceptance, largest-workflow performance and wider rank-3/Px
scope remain open. The full goal remains active.


## 26 October: full-size personal workflow Undo

A valid 5,000-task definition with sections, labels and ordering emits 20,001
records. The former 12,000-record cap silently removed its Undo history. Both
clients now retain one command for the full set, index history/restore work, and
check the normalized PostgreSQL JSON byte budget before saving any creation.
Oversized creation gives a clear message and preserves the exact saved cache.
Large commands require the additive bulk compatibility marker; older services
continue to admit only their supported smaller commands.

The new source-only migration batches typed baseline checks, dependency checks
and deletion while preserving ownership, session, replay and whole-set refusal.
It has not been deployed. Each repo passes 272 selected Core tests, 62 isolated
SQL safety checks and 19 scale checks. Both signed native builds pass. All five
installed scenarios pass on each iPhone/iPad Simulator (10 total), including
oversize rollback and cold return. Mac runtime remains pending: Developer mode
is disabled and the existing UI Automation approval question is unanswered.

A matched 1,000-task database comparison with the same payload and 5,000 outside
tasks improves from about 4.7s to 0.94–0.96s. The full 20,001-record command takes
about 4.8s in the pinned 1-CPU/512MB fixture. Global relation locks still imply
contention; these timings do not establish production latency or responsive
large-workflow creation. Large creation preparation/UI/persistence/delivery,
hosted and paired-client acceptance, wider rank-3/Px work and existing explicit
release/provider/reminder/older-client deferrals remain open.

See workflow-undo-bulk/validation.json and its retained reports. The initial
phone incoming-row assertion failed because the row was below the viewport;
the final check scrolls and verifies it is hittable, retaining exact saved-data
checks. The numeric budget expectation was corrected against actual PostgreSQL
rendering. Scale setup exhausted fixture locks/storage when accumulating cases;
seeding in bounded transactions and separate isolated contexts retained the full
workload. Final reports use identical backgrounds for the timing comparison.


## 26 October: cancellable workflow preparation

Use template now instantiates workflows on a background worker, with a pinned
progress/Cancel bar and disabled duplicate creation. Cancellation is checked
through organization, root/child task, label, order and command preparation.
Cancel or sheet dismissal cannot later save a worker result. Before saving or
retrying a failed save, the current workspace incarnation, session incarnation,
source document, label catalog and active destination must still match.

Each repo passes 275 selected Core checks, including cancellation of a valid
5,000-task project, nested interruption, a genuinely cancelled detached task and
changed request inputs. Both full signed native test builds pass. Seven native
scenarios pass on each iPhone/iPad Simulator (14 total). Screenshot review then
found an inline progress row below the iPad viewport. Moving it to a bottom
safe-area bar fixes that visibility issue; the two affected scenarios pass again
on each device (four final targeted passes), with inspected final screenshots.
The delayed-worker tests verify exact saved-cache/peer preservation beyond the
worker deadline, retry and cold return. No manual user check was required.

These are synthetic native acceptance checks, not hosted/paired acceptance or
an installed 5,000-task responsiveness benchmark. Definition decoding/preview,
Store normalization/projection and repeated task-cache work, local activity,
persistence and remote delivery remain the next large-creation performance work.
Mac runtime is still pending existing UI Automation approval with Developer mode
disabled; the current signed host/build cache is retained, without a repeated
unchanged-state runtime attempt. Wider ranked Px work stays active. Existing
release/provider/reminder/older-client deferrals and normal rollout flags stay.
See workflow-preparation/validation.json and visual-review.md for exact evidence.


## 26 October: workflow save and widget projection scale

Personal workflow creation now normalizes against one immutable lookup/catalog,
validates every row, and appends wholly fresh owned identities to a local working
Snapshot before publishing once. Collision/retry/shared paths preserve ordinary
replay. A failed save restores the old presentation; a real UI retry verifies the
creation sheet closes and the actual task list updates. Task-cache project/label
indexes and widget section/order/preference indexes remove repeated membership
scans while preserving aliases, ordering, invalid states and every record.

Each repo passes 642 selected Core checks. Mac has two additional existing
external-fixture tests skipped (offline account-switch and organization-order
handoff inputs were not supplied). The full structured widget check publishes,
decodes and writes all 5,001 lists, 5,000 groups and 5,000 tasks in about 1.8s.
Both signed native builds pass. Ten distinct workflow cases have positive installed
acceptance on each phone, tablet and Mac (30 platform/case pairs), combining the
main matrix and narrowly targeted test-selector corrections. This is not a claim
that the first matrix was entirely green: its native alert/inline-message queries
were corrected to inspect actual Cocoa sheets/value text and visible inline
errors. The retained coverage map identifies the passing job for every case.
Mac UI Automation is now enabled following the user's approval; the former
workflow runtime initialization gate is resolved.

Measured native Store saving includes projection, durable queue/cache encoding
and widget publication, excluding template instantiation and remote delivery.
The 1,000-task phone baseline is 7.42s and 1,000 task revisions; the final phone/
tablet cases are 2.05/2.01s and one revision (Mac 1.28s). The 5,000-task structured
case still retains all 20,001 commands, one Undo and one revision: 13.30s phone,
13.54s tablet and 11.38s Mac. Before the final widget indexes, that save measured
62.56/62.73s on phone/tablet. These are isolated Debug measurements, not release
latency guarantees. The remaining 11–14s is too long on the UI thread: background
save/widget I/O, local activity-history scaling, full production-screen rendering
and genuine paired/hosted bulk delivery remain open. No source migration or
hosted change was made; wider ranked Px work and all user deferrals remain.

See workflow-creation-scale/validation.json, accepted-metrics.json and README.md.
Only synthetic data was used. Scale fixtures restore their initial state; test
apps are closed after acceptance. One current host/build per platform may remain
as a bounded working cache for the next active-goal checks, instead of repeatedly
rebuilding it. Older cache bindings in earlier stages remain historical.


## 27 October: background workflow widget publication

Fresh personal workflow saves now capture a value-only widget input after the
private cache is durable and render/encode it on one utility worker. Only the
newest pending input is retained. A cancelled success or failure cannot publish
or clear a newer projection. Workspace generation, session, access revision and
current readable account are checked again before the file replacement on the
app actor. Sign-out/access redaction and widget completion receipts retain their
immediate publication path. Failed project saves requeue their restored state;
cold startup still republishes the durable workspace synchronously.

The full 5,000-task input exactly matches the original projection, including all
5,001 lists, 5,000 groups and membership. Each repo has 88 passing selected Core
cases; Mac additionally skips one existing note/Focus fixture-dependent case.
The strengthened full-size input check and five queue cases pass again in a
six-case targeted round. Both final signed native builds pass. Twelve distinct
workflow/widget cases have passing coverage on each phone, tablet and Mac (36
platform/case pairs), combining the broad matrix and final two-case retries.
The final retries verify fresh nonce-scoped result creation, held-render privacy
fences/recovery with unchanged data, and actual intent completion/retry/Undo/cold
return. They have no runtime warnings. The broad Mac matrix retains seven
internal XCTest QoS warnings, matching the previous scale stage; its explicit
warning allowance is not clean-runtime evidence.

Some initial native attempts failed because the disposable host omitted heading
opt-in, a scale assertion expected the wrong synthetic account, Cocoa text was
queried only through its empty label, or fresh test output had no directory.
iOS DEBUG entry also seeded the widget before opening its local workspace.
Preparation now offers an explicit test-only --headings flag and checks the
actual authoring state; result folders are unique and created before use; empty
fixtures show Unavailable and completion waits for a captured token. The retained
coverage map records the passing job for every case. Production queue/capture/
persistence bodies are unchanged between the matrix and targeted fixture fixes.
Current binary hashes bind the final targeted checks; old matrix binaries were
not retrospectively hashed. Exact prepared source hashes are retained for them.

Debug timing now separates durable save return from complete widget readiness:

| Device | 1,000-task save return | Widget ready | 5,000-task save return | Widget ready |
| --- | ---: | ---: | ---: | ---: |
| iPhone Simulator | 1.52s | 2.34s | 6.82s | 19.27s |
| iPad Simulator | 1.39s | 2.23s | 6.96s | 20.08s |
| Mac | 0.89s | 1.76s | 4.45s | 18.63s |

The earlier 5,000-task synchronous save, including its widget publication, took
13.30/13.54/11.38s. Moving rendering off that path does not make total widget
availability faster, or prove responsive production input. The remaining 4–7s
save pause is still too long. Durable-cache I/O, normalization/local-history
scaling, full production rendering and hosted/paired bulk delivery remain open,
along with wider ranked Px work. All normal rollout flags and user deferrals
remain unchanged. No real workspace, hosted schema or service was changed.

See workflow-widget-publication/validation.json, accepted-metrics.json and the
source/binary/equivalence bindings. Only synthetic data was used. One current
native source/build cache per platform remains for ongoing work; obsolete owned
scratch copies, raw result bundles and test sessions are cleaned after evidence
retention.


## 27 October: stable token preparation without repeated formatter setup

Sampling the previous committed full Mac workflow save found repeated timestamp
formatter construction/parsing inside WidgetCompletion.prepare. Preparation now
owns two lazy parsers, an exact UTF-8 memo and one sorted-key encoder for a single
call. No parser or memo is shared across accounts, threads or saves. Signature
fields, digest, token/receipt formats, child signatures and error fallback remain
unchanged; no migration or token reset is introduced.

Compatibility review caught a subtle prototype regression: canonically equivalent
invalid Unicode strings could share a Swift String memo entry despite producing
different old signature bytes. The new red test demonstrates that failure. Byte
keys fix it. The final seven-case family passes mixed/invalid Unicode dates,
5,000 retained old tokens, 5,000 distinct instants, heading/child stability,
equivalent-date spelling, encoder failure recovery and independent concurrent
saves. Combined selected Core coverage is 110 distinct passing cases in the iOS
repo and 109 in the Mac repo, with no failures in accepted rounds.

The final iPhone/iPad signed hosts each pass three actual native cases: 1,000/5,000
task Store saving (all commands, one Undo/revision and every widget list), then
intent completion/retry/Undo/cold return. Six final platform/case pairs pass with
no runtime warnings. In these Debug runs, Store save return is 0.53/0.52s for
1,000 tasks and 2.48/2.47s for 5,000 tasks (phone/tablet); full widget readiness is
1.38/1.38s and 14.44/14.40s. Prior-stage 5,000-task save return was 6.82/6.96s.
These are isolated measurements, not release or production-input guarantees.

The final Mac app and extension build/sign successfully and its Core cases pass,
but the final three native UI cases remain open: XCTest failed while enabling
automation before any requested application test ran. The Mac was confirmed
unlocked with developer mode enabled. A test-service restart was denied by System
Integrity Protection; no protection or permission setting was changed. The command
continued after that failed setup and another initialization attempt failed;
further unchanged-state retries stopped. A single user question asks whether the
system automation prompt is visible. Earlier String-key prototype Mac passes are
retained as intermediate evidence and are not counted for the final byte-key code.
The sampled control timing includes profiler overhead and is not the comparison.

The remaining roughly 2.5s phone/tablet save pause, final Mac UI check, background
widget readiness, local history scaling, production rendering, hosted/paired bulk
delivery and wider ranked Px work remain open. Normal rollout flags and the
user's release/provider/reminder/older-client/geofence deferrals are unchanged.
No real workspace, schema or hosted service was changed. See
workflow-token-preparation/validation.json, source/binary bindings, retained
prototype regression and accepted metrics. One reusable native source/build cache
per platform remains; obsolete owned test artifacts are pruned after retention.


## 27 October: Mac automation recovered; local history control frozen

The user approved the system automation prompt. The same final signed byte-key
Mac build now executes all three requested application tests: 1,000/5,000-task
Store saves plus widget intent completion/retry/Undo/cold return. Three pass with
zero failures, skips or runtime warnings; final acceptance is nine platform/case
pairs across Mac/iPhone/iPad. Source, prepared-source and binary hashes were
rechecked against the earlier binding without rebuilding. The Mac saves return
in 0.45s/2.23s; complete widget readiness takes 1.28s/16.22s. These are Debug
isolated-fixture observations, not production responsiveness or release guarantees.
This supersedes the final-Mac-runner gap in the preceding entry.

A new synthetic Core control freezes existing local history before optimizing it:
100 new roots with 200 children, 20 pre-existing root events and 40 child events,
including duplicate command IDs and deleted-root history. Each repo passes its
one-case control against the same pre-refactor SHA-256. No local-history production
optimization has landed yet. The remaining save pause, background readiness,
production rendering, paired/hosted delivery and wider ranked backlog stay open.
User release/provider/reminder/older-client/geofence deferrals remain unchanged.
See workflow-token-preparation/mac-summary.json and local-history-control.json.


## 27 October: index fresh local creation history once

Fresh local workflow saves now reuse transaction-private root/child history
indices, before publishing the working snapshot. They no longer scan root
IDs/sequences or revalidate the whole child ledger for each command. Ordinary
edits keep individual recording; provenance keeps its original orphan/recurrence
repair. Case-aliased task IDs fall back to sequential projection. All scope is
checked before metadata writes. A task's captured recording time is shared by its
root/child/provenance annotations. No persisted contract or migration changes.

Each repo passes 162 selected Core cases, including nine history-family cases,
the frozen pre-change metadata digest, malformed/duplicate/overflow/epoch cases,
assignment/orphan parity, atomic scope refusal and complete 5,000-root/child
encoding. The expanded partial-duplicate gap assertion is rerun separately in
each repo after the full round. Five signed native cases pass on each Mac,
iPhone and iPad host: cloud 1,000-root creation; local 1,000/5,000-root creation
with prior immutable history; local Undo; injected save failure; and real intent
completion/retry/Undo/cold return. Those behaviors share five cases per host,
not six independent cases. Fifteen platform/case pairs pass with no runtime
warnings. Normal rollout and all user deferrals remain unchanged.

The local 5,000-root saves return in 12.45/12.23/7.59s (phone/tablet/Mac); widget
readiness is 19.53/19.18/15.54s. This is a different dataset from the earlier cloud
figures and has no pre-change native local control; it is not a regression or
speedup comparison. The pause is still too long. Per-event local metadata work,
durable encoding/I/O, production rendering, assignment-heavy scaling, background
readiness, hosted/paired acceptance and the broader backlog remain open. The
fixtures show counts instead of 5,000 production rows; child-rich native workflow
creation is unproven (Core child-history scale is covered). No new installed Mac
desktop-widget claim: its reserved host runs the intent through a test panel.
No real workspace, Todoist data or hosted service was changed. See
local-creation-history/README.md and validation.json for exact evidence and limits.


## 27 October: reuse local history date processing

Scoped sampling of a signed Mac 5,000-root local save identified repeated ISO8601
formatter setup in state normalization, validation and timestamp construction.
Local root/child/provenance recording now owns per-pass lazy formatters and raw
UTF-8 memos. Single edits own separate contexts; ordinary assigned checklists
reuse their call's timestamp. Unassigned/legacy/recurrence annotations skip an
unused stamp. No mutable formatter survives the call or crosses an account or
worker. Default read helpers and all ledger/type/sequence/epoch guards remain.

A 375-case date/state corpus frozen before the change preserves exact root/child
output and refusals, including offsets, fractions, empty/invalid/Unicode/day
values, headings, completion/reopen/reschedule/delete and boundary dates. Both
repos retain that SHA-256 and the earlier history digest; each passes 164 selected
Core tests on the final source. Five native cases pass on each final signed Mac,
iPhone and iPad host (15 platform/case pairs, no failures/skips/runtime warnings):
large local save, Undo, history preservation, injected save-failure recovery,
cloud save and actual intent completion/retry/Undo/cold return are covered by
those composite cases. Earlier intermediate native passes are superseded.

The same 5,000-root local fixture now saves in 1.90/1.88/2.03s on phone/tablet/Mac,
previously 12.45/12.23/7.59s. Widget readiness from save start is 8.83/8.83/10.09s,
previously 19.53/19.18/15.54s. These are Debug observations with load variation.
The sampled run has profiling overhead and is not used for comparison. Earlier
widget readiness reflects the shorter save; its own roughly 7–8s of background
work is unchanged. The remaining roughly two-second save pause, durable
encoding/I/O, production input responsiveness, assignment-heavy scaling,
child-rich native creation, hosted/paired bulk delivery and wider ranked backlog
remain open. Fixtures render counts rather than 5,000 production rows. No new
installed-desktop-widget or release claim is made. Normal flags and all user
deferrals remain unchanged; no real workspace or hosted service was touched.
See history-date-preparation/README.md and validation.json.


## 27 October: representative Mac note-formatting acceptance

Four signed isolated Mac native cases pass on the production inspector/formatter:
selection-based Bold and rendered preview; Apply with exact unrelated-field/table
preservation, Undo/Redo and ordinary Quit/cold return; modified formatting Cancel
with explicit discard; injected disk-save failure with retained text/readable
warning/retry; and refusal to overwrite a newer saved note, with preserved draft,
Cancel and cold return. These behaviors share four composite cases. The newer
edit is injected through the real local Store, not a live cloud peer. Four actual
window captures are individually inspected and retained.

Fifteen focused note-markup/formatting Core cases pass in each repo. Mac source
changes are DEBUG-only isolated fixture controls and native tests; normal app
formatting/save policy and iOS implementation are unchanged. Initial lookup by a
clipped title, Touch Bar duplicate selection and a non-rendered fixture toolbar
button caused harness failures. Stable task IDs, visible-window controls and a
scoped inline fixture control repair them. Earlier failed results are retained
as summaries; they are not counted as accepted cases.

The strict verifier rejects the final run's four thread priority-inversion
warnings, one around opening each inspector. Explicit functional verification
accepts the four passing cases with these warnings retained. Their origin is not
proven; no framework-only attribution or clean-runtime claim is made. Runtime
quality, VoiceOver, broader text/layout/workspace and genuine cross-device
concurrency remain open, along with the wider ranked backlog.

Read-only signing recheck finds only two iOS development profiles and no matching
Mac profile. Account-removal's genuine Mac Data Protection Keychain/profile gate
stays with the user's deferred signing work. No profile, backend function/schema,
real account/task or security setting was changed. Current Supabase auth docs
were consulted; no service work was performed. See mac-note-formatting/README.md
and validation.json for scope, warnings, bindings, captures and remaining gates.

Final Mac note acceptance additionally compares the complete saved snapshot for
Cancel, failed Apply, stale Apply and stale cold return, including queues/widget
metadata. All four cases pass on that final build; four priority warnings remain
open. The preceding table-only round is superseded by this stronger coverage.

## 27 October: workflow Undo byte-count preparation

Profiling the current isolated 5,000-root native case found substantial work in
Undo construction and local recording, rather than only cache rereading. The Undo
budget path encoded a whole payload and copied its bytes merely to count the
PostgreSQL-style representation. It now counts structural spacing and raw UTF-8
escaping directly. Foundation still chooses number spellings; a raw-bit memo lasts
only for the count. Unsupported/deep cases fall back to the original encoder and
scanner, preserved byte-for-byte. Limits, exponent expansion, negative zero,
refusals and persisted data are unchanged. No field/history/list quota was reduced.

Before changing production code, both repositories passed a frozen 1,377-case
output digest, including every valid Unicode scalar, controls/escaping/combining
forms, floating-point bit patterns, nonfinite refusals, deep nesting and a large
row set. The direct counter matches that digest and the independent fallback.
The exact maximum-minus-one/maximum/maximum-plus-one boundary is covered. Earlier
history and date digests also remain unchanged.

Each owned selected Core run reports 177 tests: 173 passes, four existing live
fixture skips and zero failures. No new hosted acceptance is claimed. Fifteen
native platform/case pairs pass, with zero failures/skips/XCTest runtime warnings:
cloud-mode 1,000-root append, local 1,000/5,000-root append with prior history,
file-save failure, and real widget intent completion/retry/Undo/cold return.
The ordinary fixture UI displays counts instead of rendering 5,000 production
rows. Native child-rich creation and assignment-heavy scaling remain open.

The fresh unprofiled Mac observation is 1.95s before and 1.85s after. Current phone
and tablet saves are 1.66s and 1.67s versus the preceding stage's 1.90s and 1.88s.
Load varied; sampled timing is excluded from comparisons. Widget readiness remains
8.49/8.54/9.57s from save start on phone/tablet/Mac; this does not prove a faster
widget worker. The roughly 1.7–1.9s save pause remains too long for premium input.
See workflow-body-size/ for source bindings, metrics, actual summaries, explicit
skip reasons and the rejected zero-test selector attempt. Full ranked work and
all user deferrals remain active. Only synthetic local fixtures changed.
