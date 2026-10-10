# Critical capture/editor accessibility findings

10 October 2026. The native audit prompted two concrete fixes: iOS subtask creation now has a 44-point target, and Quick capture explicitly resigns the keyboard responder. The Mac subtask-add button now has a contextual accessibility name. Five native functional cases pass across isolated phone/tablet Simulators; both apps build. Full accessibility acceptance remains open.

## Completed functional checks

- Create two named subtasks, assert the add target is at least 44 by 44 points, complete one independently, save and relaunch, verify both states, then complete the other: phone and tablet at dark accessibility XXXL.
- Enter a 25-minute capture with the keyboard visible, dismiss it, assert the actual keyboard disappears and Save/More options remain hittable, expand/save/relaunch and verify the task and estimate: phone normal/light and largest/dark, tablet largest/dark.
- Inspected large-text captures show the keyboard absent, capture controls readable, saved subtask titles wrapping and independent completion states.

## Diagnostic results and triage

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

Full VoiceOver/keyboard journeys, physical devices and Mac runtime remain required. The Mac change is build-verified only. No real account/task data or Mac GUI was used, and no synchronization or persistence contract changed. The diagnostic reseeds local fixtures; its final phone task is Accessible launch brief with an open subtask, while the tablet retains its local keyboard-check capture.

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
