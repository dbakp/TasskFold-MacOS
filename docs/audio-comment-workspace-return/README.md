# Audio Save across workspace changes — 2026-10-28

An unreadable lookup could leave an automatic recovery writer frozen while the
closed presentation forgot an explicit Save that had not yet reached its journal.
The original raw account and task incarnation now retain that exact authorization
in the existing bounded recovery registry. Returning offers one Finish saving
row with the original operation, destination/revision, caption, clip, review
references and any separate-copy replacement. Discovery does not auto-save.

The registry uses the recovery entry/byte limits and coalesces reopened attempts;
23 consecutive failed presentations exercise the entry bound. Another account,
a different task incarnation or altered same-ID authorization cannot open or
replace the recording. Prepared/settled durable state releases the retained
request only while it still exactly matches the awaited lookup. Explicit Finish
settles that request; the current presentation then recomputes its recovery warning.

For a Save still held only in process memory, the UI asks the user to keep Taskfold
open. It offers Finish saving before Discard, and refuses the premature discard
handler. This is not crash/Quit protection for bytes never successfully written.
Normal Quit/background/removal/backup lifecycle remains a separate open gate.

## Evidence and scope

The frozen before-controller plus 93-check proof fails four substantive checks:
original-owner discovery, repeated presentation, exact Finish, and settled cleanup.
The subsequent expanded 106-check proof passes in each repo, including copy choice,
forged-authorization/task isolation, safe refusal of premature discard and 23 failed
returns without minting IDs or exhausting retained slots. These use the real private
file lock and actual journal-rename payload; media drivers remain synthetic/silent.
The final warning-polish check and native results are recorded below when complete.

An initial Mac native walkthrough reproduced the failed checkpoint, no-journal
unknown Save, foreign-workspace empty screen, original-owner single pending row and
explicit saved readback with the exact caption. It also exposed a stale recovery
warning after Finish, which prompted the warning follow-up. The initial binding
records that pre-polish binary. No normal-Quit or spoken acceptance is implied.

Two concurrent final proof compilations and one later serial Mac compilation
hit the script's 60-second compile limit while native builds/tests ran. Their logs are retained as compile failures, not
passing tests. Later terminal final results, if accepted, are separate evidence.
The Core data format did not change; Core's prior 80 cases belong to the unchanged
Core source and are not represented as newly rerun tests for this controller edit.

The earlier diagnostic in audio-comment-unknown-save/ expected an unsaved review
row. This implementation preserves the user's explicit Save request. The new
regression requires its exact pending Save, explicit completion and one saved
recording, then verifies cleanup. Historical failure reports stay unchanged.
Ordinary audio entry points remain gated; real dictation/audio acceptance is still
deferred by the user, and private server custody/ordinary integration and the full
application lifecycle remain unfinished.

## Final executable controller checks

The final focused-helper probe passes **107 checks independently in each repo**.
The source hashes in final-controller-checks.json match this checkout. Splitting
the long async probe into a focused workspace-return helper kept all assertions
and completed within the original compile/test timeouts; those limits were not
raised. The extra check covers the current presentation's stale warning, not just
a fresh presentation after settlement. Compiler diagnostics remain in the report.

The four-case initial mobile suites each pass strict verification with no failures,
skips or reported runtime warnings. They cover the largest-text discard regression,
prepared Save cold return, after-draft unknown retry, and the new unwritten Save
workspace journey. Those runs predate only the warning/copy polish. Final warning
acceptance uses its own build/binary binding and selected journey below.

## Accepted final native journey

The final iPhone/iPad build passes one selected workspace-return case on each
Simulator, with zero failures/skips/reported runtime warnings under strict result
verification. It asserts the failed real checkpoint, unknown no-journal Save,
foreign-workspace privacy, exact original-owner Finish action, absence of duplicate
recovery controls, explicit completion, cleared warning and decoded caption after
cold return. Final source/app/test-binary hashes and real team signatures are bound.
The earlier four-case suites are separate pre-polish regression evidence.

Final Mac CUA acceptance uses the exact final signed source/binary recorded in
mac-final-cua.json in the Mac repo. It verifies the same failure/return/Finish flow,
cleared warning and same saved ID/decoded caption after controlled process relaunch.
It does not use Mac XCTest or imply normal Quit interception. Representative final
phone pending/finished and iPad cold-return captures were visually inspected.

The used test apps/Simulators were closed. Obsolete initial raw suites and temporary
attachment exports were pruned after preserving evidence; final selected raw
results remain in their owned /tmp/taskfold-prejournal-polish-* paths. Source and
contract tests are independently owned in each repository. Real microphone,
speech, sound, privacy settings, production tasks and private-server publication
were untouched. The full audio lifecycle and overall Px objective remain open.
