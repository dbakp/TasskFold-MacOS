# Shared-file viewer access

Reviewed 2 November 2026. Both repositories own their app source and tests independently. New file publication stays disabled by default; no service or migration was deployed.

## Changes

Viewers can open Shared files from the stopped-editing task details, and accessible files also have an entry point in the shared conversation. These routes capture the original workspace, project and task generation; an older screen cannot silently retarget to a replacement task or another account. The existing task-edit guards remain in place.

Read admission requires the current verified shared-workspace boundary, the live project row, matching account/backend, known task custody and a supported reader role. Creator identity and historical custody alone confer no access. Reading does not require write capability, so paused/archived projects can still present files when current read access permits them. Every download retains separate server authorization, descriptor/hash/size checks and client scope checks before and after delivery.

The read-only file sheet never opens the private upload journal or constructs its upload model. Viewers see file-copy actions without Choose/Share/Stop/Clear-recovery controls. Existing-file rows are independent of upload-recovery loading; a private recovery problem cannot hide accessible shared files. Access loss removes shared file rows and dismisses a pending export. Import callbacks recheck publishing authority after the asynchronous file read. Account recovery remains available independently for the sender's own saved upload.

On iOS, a viewer who never mounted an editing form can close an unchanged existing task. That captured source is not treated as an unsaved draft. Actual changed drafts retain the existing preservation requirements.

## Evidence and remaining scope

The five added Core cases cover viewer/non-owner reads, paused/archived write denial, foreign account/backend, missing/revoked boundary, missing/duplicate/moved project rows, replacement generations and embedded IDs. Both repositories pass 66 focused Core checks, including prior encrypted journal, sender cancellation and transport regressions. Native build and interaction results are recorded separately in verification.json; compilation alone is not interaction acceptance.

The iPhone and iPad each pass the actual native case with zero failures/skips: viewer role is asserted before and after cold launch, known download bytes match while saved rows/pending mutations remain unchanged, task details open the read-only file sheet, publishing/recovery controls are absent, withdrawing project access removes the file, and Close returns without creating a draft. The retained mobile screenshots show readable standard-text dark layouts; the Withdraw control is DEBUG-only. Actual file-exporter interaction and VoiceOver/largest-text acceptance are separate.

Both current app/runner products build and pass strict signatures, with source/binary hashes retained. Mac's Xcode runner timed out enabling automation before app launch. The direct computer-use fallback then reported the Mac locked; that app was closed without claiming UI acceptance. The Mac's runtime viewer check remains open. The reused iOS host was missing its shared test scheme: the first build compiled the app only. Restoring its own repo's scheme rebuilt the actual current UI runner. The first runtime attempt exposed an editor-role fixture caused by a platform-specific seed expression; the corrected fixture and explicit before/after-cold role assertions now pass. Initial runs are not counted as acceptance.

The reserved DEBUG fixture uses a synthetic viewer, task and file. Its HTTP peer intercepts only the synthetic download endpoint and supplies known bytes; other requests remain offline. Native assertions check verified bytes without changing saved task rows/queued mutations, cold reopen, the real task-detail entry point, read-only file controls and live access withdrawal. It does not prove real Storage delivery, normal credentials or actual file-picker/export destinations. It is available only in the pre-existing exact isolated host identifiers and requires both test flags.

Actual provider integration, native file selection/export/retry/cancellation and wider account/window/background/accessibility/largest-text acceptance, attachment removal/recovery and broader file/audio/legacy migration remain open. The conversation entry point has source/build coverage unless explicitly listed as accepted native scope. Existing release/provider/device deferrals and curated checkpoint totals are unchanged.

## Reproduce

Run `python3 Scripts/check_test_storage.py --path /tmp` before heavy checks (20 GiB floor). Use the owning repo's external Swift test cache and filter `TaskFileUploadTests|TeamTemplateCommandTests|TeamOrganizationCommandTests`. Run `testSharedFileViewerReadOnlyAndRevokedAccess` only in the reserved isolated app/runner, using synthetic data. Reuse products and devices; serialize heavy platform jobs. Do not launch the normal app or use real tasks for this fixture.
