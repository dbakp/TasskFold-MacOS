# Remaining product backlog

Updated 24 October 2026. The agreed P1 batch is complete; see `p1-completion-audit.json`. This plan audits the advanced backlog recorded in `TODOIST_PORT_PLAN.md`; it does not claim a new audit of Todoist's current product.

## Immediate priority correction

Account removal now has a deployed protocol-2 service and genuine iPhone Simulator deletion/recovery acceptance, including confirmation after deliberate pruning of a synthetic retry receipt. Mac private-Keychain/runtime, expired pre-proof legacy state, residual-file repair and wider fault/concurrency checks remain open; see `ACCOUNT_REMOVAL.md`. Scoped rank-3 note-save recovery now passes. Rank-6 automation acceptance and rank-7 Watch implementation are both in progress. Scoped credentials, task operations and gated native management are implemented; both repo-owned server sources now pass hosted lifecycle/timeout acceptance. Signed-in phone/tablet management against the hosted service now passes; the webhook transport now passes local and hosted acceptance. Account-bound subscriptions and receiver proof now pass local SQL/HTTP acceptance. The task outbox/dispatcher and gated native controls are now implemented; hosted queue/delivery, signed scheduling and scoped phone/tablet native Auth/relaunch/account-isolation flows now pass; scoped clipboard/spoken secret controls now pass; native recovery and the remaining spoken checks remain in progress. Hosted server-session expiry and temporary encryption-key restoration now pass in both repo-owned services; hosted same-account webhook, queued-task and API-key recovery now pass on phone/tablet; wider spoken acceptance remains open. Signing-dependent Mac runtime stays deferred. Actual paired Simulator live capture/completion/replay and normal foreground relaunch now pass; offline Watch relaunch is durable. The startup authority fix and ready-update retry now pass paired Simulator cold capture return; 88 focused cases cover the queue/binding/retry policy. Paired offline completion, hardware/background/cloud and native/spoken acceptance remain open. These priorities preserve the full backlog and existing user deferrals.

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

Phone and tablet native cancellation, selection replacement, Preview, Apply, parent Save, relaunch and largest-text dark appearance pass in the scoped cases. Scoped iOS failed-save/retry and stale-Apply acceptance now passes in `p2-note-recovery-evidence.json`. Mac native acceptance, workspace changes, broader live concurrency and VoiceOver remain open. Exact tests and limits are in `p2-note-formatting-evidence.json`. Print/PDF is tracked separately below; additional view controls and broader hierarchy acceptance remain open in rank 3.

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
