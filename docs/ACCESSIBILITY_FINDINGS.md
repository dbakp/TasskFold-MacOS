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
| Photo/Reminders clipping | 2 | 0 in these viewports | The inspected largest-text photo action wraps fully. Reminders is outside that largest subtask viewport, so its absence is not acceptance. Reuse the existing reminder workflow evidence and check the specific label if needed. |
| Task-row fragment hit regions | 3 | 0 | One warning identifies the description; two have no associated node. The text shares a parent tap region with a 44-point minimum. Verify actual focus/activation and the parent target in the critical VoiceOver journey before classifying the warnings. |
| Native search placeholder and description preview clipping | 2 | 2 | The inspected largest native search placeholder is readable. Description truncation is an intentional one-line preview; its full text remains in the audit element and the editor. Verify semantic reading/activation; do not remove the preview limit solely to satisfy the heuristic. |

Raw [normal report](accessibility-audit-reports/normal.txt) and [largest report](accessibility-audit-reports/largest.txt), hashes, scoped results and captures are recorded in [critical-accessibility-evidence.json](critical-accessibility-evidence.json). These clusters require targeted triage; they are not a count of confirmed product defects. No findings are whitelisted in the diagnostic.

## Repeating the diagnostic

Use the isolated DEBUG Simulator test bundle. Copy its xctestrun beside the original in Build/Products, set `TaskfoldUITests.EnvironmentVariables.TASKFOLD_RUN_ACCESSIBILITY_AUDIT` to `1`, and select `testCriticalCaptureAndEditorAccessibilityAudit()` and its `DarkLargest()` variant. The original test configuration remains unchanged. Without the opt-in the diagnostic cases explicitly skip; a skip is not a pass. Export the assertion descriptions and per-viewport captures. The current implementation also writes per-viewport finding attachments before the final failing assertion.

The earlier interleaved largest audit encountered an XCTest hierarchy/type mismatch. Fresh-process viewport setup completed all eight viewports. Build v5 only improves diagnostic attachment logging; the production source, screen setup, audit types and assertions match the final v4 runtime checks.

Full VoiceOver/keyboard journeys, physical devices and Mac runtime remain required. The Mac change is build-verified only. No real account/task data or Mac GUI was used, and no synchronization or persistence contract changed. The diagnostic reseeds local fixtures; its final phone task is Accessible launch brief with an open subtask, while the tablet retains its local keyboard-check capture.
