# Remaining product backlog

Updated 22 October 2026. The agreed P1 batch is complete; see `p1-completion-audit.json`. This plan audits the advanced backlog recorded in `TODOIST_PORT_PLAN.md`; it does not claim a new audit of Todoist's current product.

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

Current evidence: 23 focused share tests, broader core suites (889 iOS / 913 Mac cases, with 12 / 32 explicitly skipped), a real four-process mailbox exercise, owned-target/configuration checks and isolated app builds. The final iPhone run verifies genuine Safari capture, extension Cancel, save with the containing app fully quit, host review/Cancel, disk-full rollback, inline retry, Add and normal relaunch. The iPad host review/Cancel/disk-full retry/Add/relaunch case also passes. Another sharing app, authenticated cloud/offline retry, native account-switch acceptance, tablet extension/Mac layout, large text and accessibility remain gates; exact evidence is in `p2-share-capture-evidence.json`. These checks are not satisfied by a successful build. Release-input and metadata checks include the share target; real distribution acceptance stays deferred.

## Note formatting implementation (rank 3, acceptance in progress)

Both apps now offer selection-based formatting tools, a native readable preview and original-text access. Notes stay in the existing portable description string; Apply edits a draft and the existing durable Save/Undo path remains responsible for persistence. Links accept web addresses only, without embedded credentials; previewing never fetches images, webpages or metadata. Compact task/widget previews remove supported formatting while preserving the complete saved text. Large or excessively fragmented notes retain a complete literal fallback.

Phone and tablet native cancellation, selection replacement, Preview, Apply, parent Save, relaunch and largest-text dark appearance pass in the scoped cases. Mac native acceptance, concurrent/workspace-change, save-failure UI checks and VoiceOver remain open. Exact tests and limits are in `p2-note-formatting-evidence.json`. Print/PDF is tracked separately below; additional view controls and broader hierarchy acceptance remain open in rank 3.

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

The foundation was initially available only through an isolated DEBUG fixture. Public saved-filter integration is now implemented below; the full parent/child feature remains unfinished. Output context and child-widget integration are now implemented below; malformed-checklist recovery and broader workspace/access/layout/accessibility acceptance remain gates. The rest of rank 3 and all explicit user deferrals remain unchanged. Historical core foundation evidence: `p2-task-hierarchy-foundation-evidence.json`.


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
