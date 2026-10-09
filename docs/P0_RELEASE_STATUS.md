# Current P0 release acceptance

Audited 9 October 2026 against the original widget collection, the Todoist port plan's acceptance conditions, current native source and retained evidence. Reviewed iOS `86eeee8` and macOS `01b45ea`. This is the current execution checklist; dated implementation entries elsewhere are historical records, not a growing list of additional release requirements. The full requested objective remains active.

## Implemented versus accepted

The core P0 feature families exist in both independently owned native repositories: current API importer/review, quick-entry planning, saved filters/favorites/preferences, independent deadlines, estimates/hourly planning, multiple reminders, recovery/export/restore, and the twelve widget kinds. Implementation and compilation do not establish release acceptance. The evidence below is deliberately scoped; a Simulator pair plus Mac transport does not prove native iOS ↔ Mac operation.

| Requirement | Evidence already obtained | Remaining acceptance |
| --- | --- | --- |
| Import preview, pagination, mapping and duplicate-free retry | API/response fixtures, transactional receipt checks and native preview/error/retry walks; `todoist-import-review-evidence.json` | Actual disposable Todoist provider account: preview → import → persistence → retry; Mac UI |
| Quick entry and supported date/repeat/reminder grammar | Native phone/tablet save/edit/decline/relaunch walks; `strict-clock-evidence.json`, `natural-clock-evidence.json`, `readable-capture-evidence.json` | Mac native workflow and mixed-version preservation; retain unsupported syntax as explicit feedback |
| Saved filters, favorites, view settings and ordering | Core/HTTP contracts, native editor/board/favorite/relaunch walks, signed-in phone/tablet filter round trip; `saved-filter-continuity-evidence.json` | Combined native organization handoff, offline/relaunch and account isolation; Mac UI |
| Independent deadlines, estimates, planning and recurrence | Native editor/bulk/planner walks and Core DST/recurrence checks; paired estimate/daily-recurrence continuity; `recurrence-continuity-evidence.json` | Rich task-field handoff including independent deadline/reminders; concurrent recurrence retry invariant; Mac UI |
| Recovery and portable export/restore | Encryption/validation/ID-mapping/HTTP contracts; one native offline restore to another client; `restore-continuity-evidence.json` | Native richer-workspace restore and real file-picker export/import round trip; Mac UI |
| Local reminders and Focus alerts | Actual Simulator permission, background, cold-process and action checks; `cold-notification-evidence.json`, `system-snooze-evidence.json` | Physical signed/closed-app delivery, account changes and Mac runtime |
| Remote reminder delivery | Native consent/authority, registry, private queue and provider adapter implemented; fixture/SQL/native handoff evidence; `reminder-authority-evidence.json` | Credentials, signed physical registration, APNs acceptance/delivery/actions, ambiguity/cancellation, bounded operational rollout |
| Calendar overlay and honest capacity | Native iOS EventKit grant/deny/recovery/disconnect and event privacy; unsupported-hour capacity fails explicitly; `calendar-integration-evidence.json`, `capacity-version-safety-evidence.json` | External provider calendar and Mac/physical acceptance; actual capacity widget host |
| My list / Today / Focus / Week ahead / Quick capture | Existing views; My list installed small selection, routing, privacy, warm/cold completion and one recurring successor; `widget-host-evidence.json` | My list **two different selected views**, rename/delete/account refresh; remaining supported sizes/surfaces, including Lock Screen/Desktop and physical hosts |
| Deadline radar / A small window | Deadline/estimate projection and native source previews; small-window installed default-budget task/link | Installed deadline content/ranking; changed small-window budget/selected scope; remaining supported hosts |
| Day capacity / Project pulse / Inbox reset | Native screens and model/projection evidence; installed Inbox total/batch and independent five/all instances survive host restart | Installed capacity and pulse configuration/refresh; remaining Inbox sizes/hosts/account changes |
| Pinned note / Focus session | Native selection/edit/privacy, timer pause/resume/relaunch/conflict and state contracts | Actual paired native note/timer switching and offline recovery; installed hosts/reboot/physical/Mac behavior |
| Access loss and unsynced work | Live existing-task edit and new shared-task creation recover to encrypted copies; unrelated personal work syncs; owner data unchanged; `revoked-project-evidence.json` | Broader native organization/account-switch path; actual Mac runtime. Model variants do not constitute native coverage |
| Premium and accessible interaction | Retained phone/tablet light/dark/largest-text walks and inspected captures across major features | VoiceOver/keyboard critical journeys and Mac interaction; fix functional clipping/unreachable actions. SpringBoard child-text loss remains a host/accessibility limitation |
| Independent releases | Both repos own source/resources/tests/release scripts; build and packaging checks | Provisioned physical app/widget installs; Developer ID signed/notarized Mac package containing the extension and installed-host verification |

## Bounded work packages still available locally

Complete these as coherent user workflows. Do not create a new release gate for every possible field combination or rerun unchanged full matrices.

- [ ] **Rich workspace handoff:** one isolated two-client workflow covers projects/sections/labels, favorites/order/view choices, an independent deadline with planned time/estimate/reminders, a pinned description, and a Focus session. Include an offline edit/relaunch/reconnect and inspect original identities and drained queues. Existing task conflict, delete, restore, weekday and access-loss evidence is reused. The Mac native leg remains a separate required step.
- [ ] **Recovery boundary:** export that workspace through the native file picker, preview/restore into isolated state, confirm relationships and repeated-restore safety. Reuse existing malformed-input/encryption tests; do not repeat them absent changes.
- [ ] **Installed widget acceptance:** verify the remaining named widget conditions above, including two My list selections and login/logout isolation. Reuse existing Inbox and My list completion evidence. Use rendered captures plus native outcomes when Simulator widget child accessibility is absent; do not claim VoiceOver acceptance from those captures.
- [ ] **Critical usability pass:** capture → edit → plan → complete/undo → recover in light/dark and accessibility settings, fixing actual unreachable or misleading behavior. Reuse existing passing feature walks; Mac interaction and physical checks remain explicit.

The next local workflow is rich workspace handoff, starting with the pinned note and Focus session states that have native single-device evidence but no actual paired native checkpoint. This is a specific missing device-switching requirement, not further parser expansion.

## External release gates

- [ ] **Mac runtime:** permission to launch the Mac app remains outstanding. Do not launch, replace or install `/Applications/Taskfold.app`. Transport tests and builds may continue, but cannot close this gate.
- [ ] **Physical delivery and widget hosts:** a provisioned iPhone/iPad and the APNs signing configuration are required. Their earlier requests remain unanswered. Do not enable delivery based on Simulator receipts.
- [ ] **Provider migration:** disposable Todoist provider-account access is required for a genuine import/retry. Fixture responses cannot close this gate.
- [ ] **Mac distribution:** Developer ID identity, profiles and notarization inputs are required. Apple Development Simulator signing does not substitute for them.
- [ ] **External calendars/files:** actual provider-backed calendar and file workflows need suitable test-account/provider access where the Simulator cannot supply it.

Read-only backend checkpoint on 9 October: native reminder cron inactive, general authority rollout disabled, zero unexpired pilot accounts. No provider secret value or real APNs delivery was verified. Keep delivery gated until the complete provider/device/operations acceptance passes.

## Scope and stopping rules

The original Phase 1 explicitly starts with a documented filter subset; the backlog also describes fuller Todoist syntax. Preserve that backlog without making every additional parser form a substitute for data/delivery acceptance. Subprojects/archive/templates, external calendar mirroring, goals/Karma, location/urgent reminders, advanced teams and wearables retain their original later-phase priority. The explicitly requested productive widgets and all P0 feature families remain in scope.

A new defect found in a required workflow is work to fix. An unavailable credential/device is an external dependency to record, not a reason to manufacture more fixture tests. A passed narrow check remains narrow. Mark the full objective complete only after all applicable rows and external gates have authoritative evidence. Continue committing and pushing completed changes separately to both repositories.
