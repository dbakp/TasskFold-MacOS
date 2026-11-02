# Native shared-file selection and copy dialogs

Reviewed 2 November 2026. Each app repository owns its source. New publication remains disabled by default; no hosted service/migration or real provider account was used.

## Changes

The explicit SwiftUI `onCancellation` callbacks now handle picker cancellation (the older completion-only form does not reliably receive it). File copies report Save, Cancel or failure at the top of the form so compact iPad sheets do not bury the feedback and return accessibility focus to the originating copy action. An identified presentation freezes the filename/source; a late callback cannot update a different copy presentation. Shared copies recheck current read access, while a sender's own saved local copy remains independent of project access. Workspace change or sheet close clears presentation bytes and feedback. Copy results do not resolve, rewrite or clear the encrypted upload journal.

The workspace-change message now directs read-only viewers back to their task rather than to upload recovery. Existing choose-file callbacks still recheck current publishing authority before and after their bounded security-scoped read. File selection freezes bytes locally before any explicit Share action.

## Native evidence

See verification.json for the owning platform's actual accepted scope, build and source hashes. Tests use the existing reserved app identity, a synthetic task/account and five-byte files. The real document dialogs must expose the LocalStorage provider, the exact test destination and its marker before Save is allowed. No cloud destination is accepted by this workflow.

The shared-copy case checks Cancel without a file/receipt or changed tasks, saves through the actual system picker, independently reads the saved bytes and returned URL, then checks the file after cold relaunch. The private-selection case cancels the real importer, selects a real local file, checks encrypted recovery, changes the selected source externally, and verifies the frozen original survives private copy export and cold recovery. It explicitly removes only that known unsent test upload afterward; saved tasks and the selected source remain independent. The viewer/cold/access-withdrawal case is retained as a regression.

DEBUG-only dialog defaults and receipts are restricted to the pre-existing exact isolated app IDs and explicit test arguments. The selection fixture enables selection in that host only, seeds an editor instead of a viewer and never invokes publication. Test resets remove only known five-byte output copies; an unexpected existing output is preserved and stops setup. Normal release configuration has no test capability override.

Core upload/journal code is unchanged from the preceding 66-check run; that result is not counted as a new test run. This batch's evidence concerns current app compilation and actual native dialogs. The phone and iPad copy screenshots were visually checked: the confirmation fits above the read-only notice and file action. Real provider publication/download/cleanup, wider account/window/background/retry, speech/largest-text, Mac runtime and file/audio/legacy work remain separate unless expressly accepted in the platform report. Existing rollout/provider/device deferrals and curated checkpoint totals remain unchanged.

## Reproduce

Run `python3 Scripts/check_test_storage.py --path /tmp` first (20 GiB floor). Reuse the isolated current-source app/runner products and owned iPhone/iPad simulators, serializing heavy jobs. Execute `testSharedFileNativeCopyCancelSaveAndColdReadback`, `testTaskFileNativeSelectionCancelAndPrivateCopy` and the existing `testSharedFileViewerReadOnlyAndRevokedAccess`. Guard the test scheme, actual compiled test source and signatures before launching; a build-only result is not a native pass. Retain concise reports/screenshots and close the isolated apps afterward.

Only local, synthetic files are accepted here. The importer test never presses Share; the service response used for shared-copy content is injected. Save uses the actual system LocalStorage provider, and the test reads back the returned file URL and bytes independently. Spoken focus and largest text are not accepted by these standard-text, dark-appearance runs.
