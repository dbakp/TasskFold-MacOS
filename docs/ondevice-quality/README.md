# On-device suggestion checks · 6 November 2026

Both engines now check cancellation before validating the goal or consulting model availability. An already-cancelled request now reports CancellationError before input/setup checks. They explicitly select `SystemLanguageModel.default`, keeping the existing on-device-only policy and no cloud inference fallback. Apple Intelligence setup guidance is now neutral so filter suggestions do not incorrectly talk about suggesting task steps.

Two new cancellation cases fail against the prior Mac implementation with three assertions, then pass in both owners. Each independently owned focused suite passes 26 ordinary checks; its two explicit-model checks are skipped by default. Those skips do not count as model-generation acceptance. Existing source/session review, literal titles, grammar, destination/date revalidation and saving contracts are unchanged.

`python3 Scripts/test_ondevice_quality.py --run-model --output /tmp/taskfold-quality-NEW.json` explicitly runs only built-in synthetic examples through the actual owning engines. It captures three task goals, including Spanish, and three filter goals with monotonic request durations. Filter acceptance checks actual matching results, relative dates against a future reference day, planned dates versus deadlines, completion, and an exact project versus its child. There are no task/filter writes and no private library or catalog is supplied to the model. The driver requires all six observations, both completed tests and unchanged source; unavailable/skipped checks return a separate non-success status. A separate ordinary check proves each semantic oracle accepts its intended expression and rejects a plausible wrong one. Task-title usefulness/language still require reviewing the real outputs; shape success is not a general quality claim. The probe has a ten-minute limit and signals only its owned process group on timeout; this timeout path is not claimed as exercised by the unavailable run.

The initial real probes reported Apple Intelligence disabled; System Settings also visibly showed its switch Off. The user said they would enable it. The agent did not enable Apple Intelligence, change Siri settings or request model downloads. Actual model quality/latency remains unaccepted until a ready-model run completes and its outputs are inspected. Provider, rollout, distribution and phone-installation deferrals remain; installed Mac23 and phone34 are unchanged.

The local SDK confirms the explicit SystemLanguageModel initializer. Apple documents [SystemLanguageModel as its on-device model](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) and requires [checking availability before generation](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models). No private-cloud model or other provider is selected.

## Prepared daily package

Mac 1.2.0 (27) is built as optimized Release, signed and archive-readback verified. It remains uninstalled; installed Mac23 and phone34 are unchanged. Mac includes app, widgets and incoming Share. Existing development expiry remains 2026-11-10T18:32:04+00:00. No setting, hosted service or ordinary rollout gate was changed.

## Final probe result

The final current-source probe returned status 2: both explicit model tests skipped because Apple Intelligence was disabled, with zero generated examples. Its source and driver hashes match the final files. `model-probe.json` deliberately has `realGenerationAccepted: false`; current model quality and latency are not accepted. The setting remains a user setup action, not a newly deferred goal.
