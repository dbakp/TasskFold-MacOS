# Critical capture/editor accessibility findings

Current checkpoint, 11 October: normal has 3 and largest has 2 unfiltered clipping findings. Accessibility-size notes now wrap in both app sources; two native phone preview/persistence workflows pass, and largest notes clipping is absent. Mac rendering and full VoiceOver/keyboard acceptance remain open. See [notes-wrap-evidence.json](notes-wrap-evidence.json). Earlier sections below retain their dated scope.

10 October 2026. The native audit prompted two concrete fixes: iOS subtask creation now has a 44-point target, and Quick capture explicitly resigns the keyboard responder. The Mac subtask-add button now has a contextual accessibility name. Five native functional cases pass across isolated phone/tablet Simulators; both apps build. Full accessibility acceptance remains open.

## Completed functional checks

- Create two named subtasks, assert the add target is at least 44 by 44 points, complete one independently, save and relaunch, verify both states, then complete the other: phone and tablet at dark accessibility XXXL.
- Enter a 25-minute capture with the keyboard visible, dismiss it, assert the actual keyboard disappears and Save/More options remain hittable, expand/save/relaunch and verify the task and estimate: phone normal/light and largest/dark, tablet largest/dark.
- Inspected large-text captures show the keyboard absent, capture controls readable, saved subtask titles wrapping and independent completion states.

## 10 October diagnostic results and triage

Each of four viewports starts in a fresh app/fixture: Quick capture, editor overview, editor subtask actions and saved task list. The audit checks sufficient descriptions, hit regions and clipped text. These are visible viewport checks, not coverage of every offscreen editor control. It reports zero insufficient-description findings in both modes. The two diagnostic test cases **fail** their unfiltered final assertions; neither is accepted release evidence.

| Finding cluster | Normal/light | Largest/dark | Current evidence and next check |
| --- | --- | --- | --- |
| Quick capture clipping | 3 untargeted | 1 on the 25 min preview | Inspected largest-text capture shows the full estimate and Date/Priority/Inbox controls after actual keyboard dismissal. Retain the warnings; identify the untargeted nodes before dismissing them. |
| Photo/Reminders clipping | 2 | 0 in these viewports | A focused phone normal/XXXL workflow now verifies both actions, picker cancellation and complete draft save/relaunch. The largest Reminders label split a word; a text-only accessibility-size label now fits, with inspected final capture. Photo action wraps fully. Photo selection and VoiceOver remain open; `editor-picker-evidence.json`. |
| Task-row fragment hit regions | 3 | 0 | One warning identifies the description; two have no associated node. The text shares a parent tap region with a 44-point minimum. Verify actual focus/activation and the parent target in the critical VoiceOver journey before classifying the warnings. |
| Native search placeholder and description preview clipping | 2 | 2 | The inspected largest native search placeholder is readable. Description truncation is an intentional one-line preview; its full text remains in the audit element and the editor. Verify semantic reading/activation; do not remove the preview limit solely to satisfy the heuristic. |

Raw [normal report](accessibility-audit-reports/normal.txt) and [largest report](accessibility-audit-reports/largest.txt), hashes, scoped results and captures are recorded in [critical-accessibility-evidence.json](critical-accessibility-evidence.json). These clusters require targeted triage; they are not a count of confirmed product defects. No findings are whitelisted in the diagnostic.

## Repeating the diagnostic

Use the isolated DEBUG Simulator test bundle. Copy its xctestrun beside the original in Build/Products, set `TaskfoldUITests.EnvironmentVariables.TASKFOLD_RUN_ACCESSIBILITY_AUDIT` to `1`, and select `testCriticalCaptureAndEditorAccessibilityAudit()` and its `DarkLargest()` variant. The original test configuration remains unchanged. Without the opt-in the diagnostic cases explicitly skip; a skip is not a pass. Export the assertion descriptions and per-viewport captures. The current implementation also writes per-viewport finding attachments before the final failing assertion.

The earlier interleaved largest audit encountered an XCTest hierarchy/type mismatch. Fresh-process viewport setup completed all eight viewports. Build v5 only improves diagnostic attachment logging; the production source, screen setup, audit types and assertions match the final v4 runtime checks.

Full VoiceOver/keyboard journeys and Mac runtime remain required. The user accepts Xcode iPhone/iPad Simulators for ordinary native usability testing; signed physical APNs delivery remains a separate notification gate. The Mac change is build-verified only. No real account/task data or Mac GUI was used, and no synchronization or persistence contract changed. The diagnostic reseeds local fixtures; its final phone task is Accessible launch brief with an open subtask, while the tablet retains its local keyboard-check capture.

## Saved-preview touch activation checkpoint

Three native functional cases pass on 10 October: phone normal/light and accessibility XXXL/dark, tablet accessibility XXXL/dark. Each creates a task with a 25-minute estimate and longer instructions, saves, terminates/relaunches, taps the description preview, verifies the entire editor value, saves, taps the estimate, verifies the entire value again, and checks the task remains open. Result bundles report zero skips, failures or runtime warnings. See `preview-details-evidence.json`.

The one-line description preview remains intentional. Largest-text phone/tablet captures were inspected: the preview uses an ellipsis and the estimate remains readable; the editor wraps instructions. The phone screenshot is a viewport, not proof that all instructions fit in a single frame. These checks establish touch activation and retained text only. They do not clear audit warnings or establish VoiceOver/keyboard acceptance. Mac runtime remains unverified; no production behavior changed.

## Hardware modifier preflight

10 October: An optional focused-field Save probe initially appeared to expose app shortcut routing failures. The retained baseline trace instead shows injected Command–S appending a literal capital S, despite the Save button being enabled. A new independent Command–A select-all/replacement preflight also fails: the input is appended rather than replacing the selection. The final diagnostic fails before evaluating Save, with zero skips. See `keyboard-input-evidence.json` and `keyboard-audit-reports/modifier-preflight.txt`.

These observations establish that this Simulator input path is unsuitable for accepting hardware modifier behavior; they do not establish an app-side shortcut defect. The test is opt-in via `TASKFOLD_RUN_KEYBOARD_AUDIT=1`; default skips are not acceptance. Full Keyboard Access tab navigation, a physical keyboard and VoiceOver remain unverified. A particular optional Save accelerator is not a new P0 release gate.

All experimental toolbar/content/native-host implementations were removed. Production code is unchanged. The existing largest/dark phone capture-dismissal and saved-preview detail workflows both pass on the restored implementation with zero skips/failures/reported runtime warnings. Final build v7 only adds the diagnostic preflight. Mac inspector autosave and Return capture were source-inspected only. Seven terminal prototype result bundles were pruned after retaining their summaries (168,926,623 file bytes); final baseline and preflight bundles remain available.


## Subtask draft readability

10 October: Inspection of the retained editor capture exposed a separate composing issue: the single-line new-subtask field truncated even “Send the estimate” at accessibility XXXL. The iOS draft field now grows to four lines at accessibility sizes, with the 44-point add action aligned to its top. Two final native phone/tablet workflows pass with longer titles, independent completion and save/relaunch; saved snapshots retain both complete titles. Inspected captures show complete wrapped drafts on both devices. Normal entry keeps its single-line layout. The first tablet geometry assertion failed because a short title fitted on one line; the final fixture uses titles long enough to wrap in both widths. See `subtask-draft-evidence.json`.

Mac saved-subtask editing already wraps; its desktop entry retains Return-to-add. No new data fields or synchronization changes. These results do not clear the unfiltered audit or establish VoiceOver, keyboard-submit or Mac runtime acceptance.


## Editor Reminders and photo-picker return — 10 October 2026

One final native iPhone case completes both normal/light and XXXL/dark modes with zero skips/failures/reported runtime warnings. It opens Reminders and returns, opens/cancels the actual Photos picker, then saves/relaunches and verifies the complete title/instructions. Both action rows are at least 44 points. Pre-fix functional coverage passed but its inspected largest-text capture exposed “Re-” / “minders”; iOS now uses a text-only Reminders label at accessibility sizes. Final inspected capture shows the complete word on one line; normal sizes keep the bell. Choose a photo wraps completely. The final task remains open, has zero attachments and no queued changes. See `editor-picker-evidence.json`.

The final picker finished loading its Photos/Collections privacy notice; selection/import was not exercised. Mac desktop source was reviewed only, with no code or runtime change. This is touch/draft-preservation evidence, not a cleared unfiltered audit, VoiceOver/keyboard, photo import, external-provider or Mac acceptance result.


10 October: Native photo attachment workflow now passes one actual iPhone case: select the synthetic checker in Photos, save/relaunch, render all four checker quadrants in Quick Look, and close back to the persisted attachment. Zero skips/failures/reported runtime warnings. Saved PNG bytes exactly match the independent 166-byte fixture and pending queue is empty. One Mac-owned Core integration case reads that final native snapshot and preserves the complete attachment through portable cross-account restore and duplicate-free retry. No production changes or Mac GUI launch. See `photo-import-evidence.json`; cloud image handoff, external providers, physical hosts and full accessibility remain unverified.


10 October: Both apps now name task-row subtask progress, comments and attachments descriptively for accessibility; visuals and stored fields are unchanged. Two native iPhone cases pass with zero skips/failures/reported runtime warnings: the saved photo row exposes “1 attachment” and its preview/return still works; largest/dark subtask progress exposes “1 of 2 subtasks completed” after relaunch, then “2 of 2” after independent completion. Saved parent remains open, both subtasks completed, pending queue empty. Both apps build. Comment-count semantics are source/build verified only; Mac GUI, full VoiceOver/keyboard and the unresolved unfiltered audit remain open. See `metadata-accessibility-evidence.json`.


### 11 October — refreshed unfiltered accessibility diagnosis

The current normal/light capture/editor audit completes all four viewports and still fails its unfiltered assertion: eight findings (three unidentified capture clipping reports, three saved-row hit-region reports, and description/search clipping). Editor overview and editor subtask/action viewports report no findings. Four captures are inspected; the normal capture visibly leaves the Inbox chip partly outside its horizontally scrolling controls. Adaptive control visibility is the next concrete fix within the existing critical usability work. The untargeted audit nodes cannot be assigned to that chip conclusively. Intentional description truncation and native search findings remain unresolved pending semantic/VoiceOver inspection.

Largest-text refresh is incomplete: the first run audits three viewports with zero findings but saves an incomplete ~25 token during saved-list setup; the second stops at a new complete-input assertion. Their causes are not established, and neither is acceptance. The diagnostic now verifies complete input and settled touch geometry, explicitly selects the disposable local workspace, retains per-viewport hierarchies, and continues to reject every reported finding without whitelists. No production source was changed. The original cloud task and selected cold note/Focus routes pass a separate cleanup case with no reported runtime warnings; full original cloud/widget data and Mac cache remain unchanged. Duplicate diagnostic exports were pruned with hash receipts while all native results remain retained. See `accessibility-current-evidence.json` and `accessibility-audit-reports/current-normal.txt`. Full accessibility and broader P0 acceptance remain open.


### 11 October — capture field visibility correction

Normal-size iOS quick capture no longer partly hides Inbox in a horizontally scrolling strip. Fields and actions stay on one row when their intrinsic widths fit; otherwise the fields wrap above the action buttons. The existing accessibility-size draft controls remain separate. One focused native iPhone test passes with zero skips/runtime warnings: complete control bounds above the open keyboard, actual Today/Inbox menu selection, keyboard dismissal, More options with title/25-minute estimate retained, Save and relaunch. The existing three consecutive keyboard-open captures also pass with this layout. Four final screenshots were individually inspected.

The unfiltered normal accessibility audit completed all four viewports: capture 0 (previously 3), editor overview 0, editor subtask actions 0, saved list 5. It still fails, with no suppression: three saved-list hit-region findings and two text-clipped findings (description preview and native search). Largest-text setup, VoiceOver and complete accessibility acceptance remain open. The original cloud Today task, selected note and ended Focus cold routes pass after cleanup; the complete original cloud cache and original widget account/note/Focus/pending fields equal their baselines, pending sync is zero, both local/cold-fixture preferences are false, and the original Mac cache is unchanged. See `capture-controls-wrap-evidence.json` and `accessibility-audit-reports/capture-wrap-normal.txt`.

Mac source assessment: `TaskCapturePanel` has a destination header and parsed chips, with no equivalent horizontal field-control strip, so this fix changes iOS production code only. No new native Mac, iPad, largest-text or long-project-label acceptance is claimed. Intermediate selector/editor-label test failures are retained and disclosed in the evidence. All native result bundles remain; duplicate intermediate attachment exports were pruned (1,581,056 allocated bytes).


### 11 October — saved-row accessibility action correction

The iOS task-content area already opened details from a minimum 44-point area, but exposed description and metadata as separate tiny accessibility targets. Non-linked rows now combine title, complete description and metadata into one accessible details button with a default action and selection-aware hint. Completion stays separate, linked rows retain individual link elements, and the visual row stays compact. Mac uses native list selection and separate AppKit controls; no corresponding Mac code change or native Mac acceptance is claimed.

Two native phone preview workflows pass, normal/light and dark/largest, with zero skips/runtime warnings: notes/estimate capture, save/relaunch, a hittable details target at least 44 points high, full notes/estimate in its accessible label, editor opening from preview and lower metadata area, original title/notes retained and no accidental completion. The previous capture visibility and original cloud note/ended-Focus cold-route flows also pass unchanged (two more cases). Four functional and four flagged diagnostic screenshots were individually inspected.

Both unfiltered audits complete all four viewports and still fail. Normal has 3 text-clipped findings: Choose a photo in the editor, search and description preview in the saved list. Largest has 3: 25-minute capture suggestion, search and description preview in the saved list. Neither reports hit-region or insufficient-description findings; the prior three normal saved-row hit-region findings are absent. The photo finding was absent in the previous run; its cause is unestablished. Largest setup completed this time, which does not establish why prior input failed. Photo/suggestion text is legible in the inspected captures and the row preview intentionally ends in ellipsis; no finding is suppressed or declared false. Full accessibility and actual VoiceOver acceptance remain open. See `row-accessibility-evidence.json` and `accessibility-audit-reports/row-normal.txt` / `row-largest.txt`.

The entire original cloud cache and original widget account/note/Focus/pending fields equal their baselines; pending sync is zero, local/cold-fixture preferences are false, and the original Mac cache is unchanged. Mac UI access was rechecked and remains locked. Every native result bundle is retained; duplicate exports were pruned after preserving the inspected evidence. Full P0 scope stays active.

### 11 October — readable notes at accessibility text sizes

Both independently owned task-row implementations now let notes wrap vertically when an accessibility Dynamic Type size is selected. Standard-size rows retain the one-line preview. Mac linked notes also use unlimited lines with word wrapping in their native text container. No stored text, account contract or widget source changes.

Two native phone workflows pass at normal/light and largest/dark with zero skips or reported runtime warnings: capture notes and a 25-minute estimate, save, relaunch, verify the full-sized accessible details action retains the complete notes/estimate, open details from the row and lower metadata area, and preserve the full title/notes without completing the task. The normal preview stays compact; the largest preview has multiple lines and scrolls through the long note to its estimate. Long paragraphs still require scrolling; the inspected capture shows the tail, not the entire paragraph at once. Both app builds pass. Mac changed-row and linked-note interaction remain build-verified only, with the desktop still locked; the running local test process may retain the earlier binary until relaunched.

Both unfiltered audits complete all four viewports and still fail. Normal retains 3 text-clipped findings (photo label, search, compact notes preview). Largest drops from 3 to 2: notes clipping is absent; the 25-minute capture suggestion and native search remain flagged. Neither mode reports hit-region or insufficient-description findings. No warnings are suppressed or classified as false positives. The suggestion and photo labels are legible in the inspected captures, which does not resolve those audit findings. See `notes-wrap-evidence.json` and `accessibility-audit-reports/notes-wrap-normal.txt` / `notes-wrap-largest.txt`.

The original selected note and ended Focus cold routes pass a separate cleanup case. The whole original cloud cache and widget account/note/Focus/pending fields equal their baselines, pending sync is zero, local/cold-fixture preferences are false and the original Mac cache is unchanged. All native results are retained; duplicate exports were pruned after preserving eight inspected captures, all findings and viewport hierarchies in both repos. Actual VoiceOver/keyboard journeys, linked-note native interaction and the remaining P0/provider/distribution gates stay open.


### 11 October — linked notes touch journey

Normal/light and largest/dark iPhone linked-note workflows now pass: native capture, Save/relaunch, independent inline link → in-app browser → Close, title → complete unchanged editor, Save without completion, and original cloud return. Six captures are inspected; the synthetic unavailable host is intentional, and the largest paragraph still requires scrolling. A separate original selected note/ended Focus cold-route cleanup case passes. Whole original cloud cache and widget account/note/Focus/pending fields equal their baselines; queues are empty, local/cold-fixture preferences are off and the original Mac cache is unchanged. See `linked-notes-native-evidence.json`.

The first two cases failed only at cloud return because the agent disabled Xcode signing during the test build, dropping embedded Simulator entitlements. Restoring the normal build settings recovers the existing session; no product auth change or new login was required. The iOS signing tool now checks actual app/widget embedded Simulator application/App Group identity before and after signing, in addition to real-team signatures. All failed native bundles and two failure hierarchies remain retained. No production app code changed. Existing normal 3/largest 2 audit findings, VoiceOver/keyboard, native Mac linked-note interaction and broader P0 gates remain open.

### 11 October — live Mac importer accessibility observation

The real-provider native Mac preview visually presents six correctly labeled counts. Its AX tree combines the values into one text element labeled Projects; the receipt similarly combines ten values under Projects imported. This is an observed accessibility representation issue, not a passing VoiceOver result. Keep per-count label/value navigation open for native verification. Real import/replay and relaunch evidence is in `todoist-live-provider-evidence.json`; no source task content or token is included.

### 11 October — independent importer accessibility rows

Both independently owned importer views now expose an explicit label/value for each of the six preview counts and ten receipt rows, plus separate warning elements. This fixes the live Mac observation where a grouped form merged all values under its first label. The final isolated Mac native computer-use walk verifies those elements, failed-save explanation, visible Retry and successful token clearing; three screenshots were inspected inline. Its automated XCTest attempt failed before executing the case because macOS timed out enabling automation mode. An intermediate static-text-trait variant reintroduced merging and was removed; no passing automated Mac result is claimed.

Normal/light and largest/dark phone walks pass all count/receipt labels and values, token validation, warnings, failed-save retry, clearing and empty reopening. The first largest run failed only because equal visual edges differed by floating-point rounding; the retained failure reports 700.3333333333334 versus 700.333333333333. A 0.001-point measurement tolerance fixes that test assertion, and the largest rerun passes. Eight captures are inspected and retained. At largest text, labels wrap and the long form requires substantial scrolling; the final receipt capture shows its last rows, not all ten simultaneously. See `import-count-accessibility-evidence.json`.

The original cloud note and ended Focus cold routes pass separately. The entire phone cloud cache and widget account/note/Focus/pending fields equal their baselines; both queues are empty, local/cold-fixture preferences are false and seven Mac shared tables equal the canonical account. Both final app/test builds pass. Temporary Mac build products and duplicate exports were pruned while every native result bundle remains retained. This is scoped native/AX acceptance; full VoiceOver, keyboard, real lost-response recovery, iOS real-provider/paired imported-account flows and broader P0 gates remain open.

### 11 October — Mac task-row focus, linked notes and durable completion

Native CUA testing caught white selected-row text on a gray background while the notes editor had focus. Mac task lists now pass their explicit focus state to task rows, combined with window activity. The first environment-only adjustment failed the focused-list visual check and was replaced before commit. Final native screenshots show readable white text on accent selection and dark text on gray inspector-focus selection. Each project board column and Calendar day list has the same focus wiring; those variants are compile-verified only. This is AppKit-specific; iOS code and persisted contracts remain unchanged.

The synthetic native task retains its exact raw linked note and 25-minute estimate across relaunch. Clicking its inline link reaches the link monitor while another task and inspector remain selected; the UI-test handler intercepts external opening, so actual browser handoff remains open. Clicking the title opens exact full details. Row completion, native Command-Z Undo, restored-task relaunch, subsequent completion/relaunch and Completed inspection all pass. This supersedes the earlier build-only checkpoint for changed Mac completion/Undo. Observation precedes quitting; arbitrary forced-kill timing is not claimed. See `mac-linked-completion-evidence.json`. Actual VoiceOver, broader keyboard, paired provider sync, other widget hosts and distribution remain open.
