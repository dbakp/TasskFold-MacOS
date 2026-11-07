# Clearer shared-storage waiting state

After the existing short startup delay, the banner initially shows connection progress. If shared storage is still waiting ten seconds later, it explains that Taskfold remains usable and offers a labeled Dismiss action. On Mac, guidance conditionally mentions a macOS access request; it does not claim a prompt exists. Phone guidance describes the background connection without referring to Mac settings.

Dismiss hides only this view status. It neither retries nor cancels the worker, grants permissions, edits work, nor changes the publication/privacy contracts. A later failure remains visible with the existing Try again action. Successful connection clears the presentation state. The phone dismiss target is at least 44 points in each direction.

This is a bounded usability follow-up to the observed normal Mac35 shared-storage wait. It does not resolve the operating-system access wait or imply its cause. Normal Mac35 remains installed, running and previously verified synced; current computer control reports the Mac locked after the user's unlock reply. The original readonly postlaunch cache check remains running and blocked in open(), with its same handle preserved. No repeat unlock question or app restart was issued. Final cache/queue readback and shared-storage readiness remain unverified. Phone installation remains deferred.

Native and compilation results are recorded in verification.json after the current-source checks. No task/schema, service, rollout gate, signing profile or system setting is changed. Broader native Mac/iPad, speech, lifecycle and physical performance scope remains separate.

## Verified scope

The signed current-source iPhone 18 Pro/iOS 27 ordinary-text dark journey passes the actual 10-second guidance, 44-point Dismiss action, unchanged full saved-snapshot values, continuing held producer, interface taps, private task Save, immediate sign-out redaction, release of a stale producer, return and cold saved-state checks. All 11 recorded observations pass, with no runtime warnings in the result summary. The long-wait screenshot was inspected: the guidance and Dismiss control are readable and not clipped. This synthetic hold does not prove a real system permission prompt. Native Mac/iPad, largest text, speech and failure/retry controls remain separate from this phone journey.

The source-isolation preflight first refused before boot/launch because its checker assumed a former host's Store namespace rewrite. Inspection confirmed this existing reserved host instead rewrites only the two shared-disk constants plus the established Backend/Backups namespaces. The corrected checker accepts only those exact reviewed substitutions and byte-matches every other Swift source, the test source and final binaries. The app's storage behavior was not changed to accommodate the test. The first unintended extra-architecture build was deliberately interrupted for its cache footprint; its scratch cleanup is recorded separately. The final arm64 compile and native journey pass.

Native case: `WorkflowSourceSelectionUITests.testInitialSharedStorageWriteKeepsWindowUsableAndCannotUndoSignOut`, using the existing reserved `workflowteststeameditbridge` host and fixed phone pool. All app code remains independently owned; the Mac compilation result is recorded separately from the iOS owner's native evidence.
