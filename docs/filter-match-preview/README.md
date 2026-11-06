# See matching tasks before using a filter · 6 November 2026

Both owners now show a read-only sample of up to five matching tasks alongside the exact existing count and meaning in Suggest a filter. Each sample includes a task title, current project name (or Inbox) and explicit completion state. A separate empty state explains that a zero-match expression can still be useful for future tasks. The sample follows the same access-filtered, archived-project-aware matching query as the ordinary preview count; the cap limits displayed samples, not the count. Samples have no completion or navigation action.

Editing the expression invalidates the proposal/sample. After asynchronous checks, freshness is checked again immediately before updating the draft; an observed stale preview also cancels in-flight work. Changes to the observed task revision, workspace access/project revision, day, time zone or date preferences clear a checked preview; minute changes apply to clock-window queries. Use expression checks the same revision stamp directly as well as retaining the existing fresh catalog/date/workspace/source validation. The selected expression still updates only the draft; the separate filter-editor Save remains required. The expression has a Clear control; the two fields have distinct focus targets, and iPhone text entry offers an explicit keyboard Done action.

No task data is sent to the on-device model: generation still receives only the entered description. No cloud fallback, service/schema change, normal feature-gate change, installation or release-package update is included.

Owning source builds/signatures pass. The final native result and its separately scoped functional proof are retained alongside this note. Real model generation, Mac/iPad interaction, live revision invalidation, speech/largest-text and broader account/access cases are separate from this bounded preview journey.

The synthetic fixture warms ordinary startup preferences before taking its immutable all-table baseline. Its nine tasks include seven open matches, one completed task and one archived-project task. This avoids mistaking initialization of Today/Upcoming preferences for a preview write. Earlier failed attempts and the corrected focus/input path are retained in attempts.json.

Visual follow-up: the long confirmation label crowded the iPhone sheet title. Its visible label is now “Use,” with the full “Use expression” accessibility label retained. The source-bound before screenshot is retained as iphone-preview-before.png; this visual correction does not claim to fix the separate keyboard warning.

## Recorded verification

Current owning app builds and strict signatures pass. The current iPhone Simulator test passes exact five-of-seven samples/count, archived-task exclusion, empty and completed queries, exact typed input, Clear/Done, edit invalidation, Use changing only the draft, Cancel, and all-table preservation after cold relaunch. The final screenshot has a readable full title; see [after](iphone-preview.png) and [before](iphone-preview-before.png).

The strict wrapper still rejects one keyboard-focus frame warning. `iphone-functional.json` deliberately records functional success separately from `cleanRuntimeAccepted: false`; `iphone-strict-run.json` retains the rejection. No warning was suppressed and no clean-runtime or full assistant acceptance is claimed. Live task/access/date invalidation, actual model generation, Mac/iPad interaction, largest text, speech and broader account/context cases remain open. No checkpoint or substep is promoted by the diagnostic/test totals.
