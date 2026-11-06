# Publication approval recovery

The later [pending-boundary follow-up](../pending-approval-boundaries/README.md) accepts the separate iPhone fresh review, missing/local-expiry Check and Close controls. This document records the earlier warm-retry/pending-Resume checkpoint.

Reviewed 3 November 2026. This checkpoint fixes local approval-write recovery in both independently owned applications. Ordinary sharing and project-transfer gates remain disabled; whole-project transfers remain unfinished.

## Accepted client behavior

A failed acknowledgement after the approval file has been atomically renamed can leave the current window with its pre-write snapshot. Repeating Publish now accepts only the exact proof that window already reviewed, preserving the frozen request. A write failure before rename also remains safely retryable. Neither failure sends media before approval is durable, and neither retry fetches another review.

Another window's different approval remains a conflict on every retry. A refused snapshot is never promoted into the current window's expected baseline. A focused repeated-retry case reproduced an unintended replacement on the second attempt before this correction. Existing terminal confirmation or closure for the same exact original request can be observed without sending, rewriting the terminal file or replacing its approval.

Each owning repository passes 78 publication tests, including five new cases: before/after-rename retry, repeated competing-approval refusal, and confirmation/closure by another window. The initial three failing recovery cases and the separately reproduced repeated-retry failure were observed before their respective corrections. Tests compare actual saved terminal bytes; re-encoding a binary property list is not an identity check. These are synthetic Core tests, not concurrent full-app windows or audible accessibility acceptance.

## Accepted iPhone pending-screen Resume

The owning iOS Simulator case passes 39 native/service checks, with one UI test and no skips. It opens the separate pending-publication row after a cold launch. It first cancels Resume and compares the journal's actual saved bytes, then explicitly resumes the original send. The actual earlier publication committed while its response was deliberately lost. The second request repeats exactly the same approval and original intent; real local Storage receives only one upload. The same v4 proof, request, retained audio, private saved recording and task content survive. No replacement audience review or task edit occurs during Resume.

This case uses dark appearance at standard L text size. The earlier main-screen cold Check was accepted separately at Accessibility XXXL. Native pending-screen fresh Review/expiry/Close, iPad/Mac runtime and audible VoiceOver are not established by this case. Both app/runner builds and strict signatures pass; Mac's native report is explicitly archived as owning iOS evidence. All owned local services/configuration are removed, the Simulator's previous state restored and the test app quit. A duplicate Apple Simulator accessibility-loader diagnostic appears in the runtime log; this is not a warning-free platform claim. No host, device or migration was added.

## Remaining acceptance

Pending-screen fresh Review/Cancel/Publish, expired/missing approval, Check and exact Close still need bounded native acceptance against the current service. Mac/iPad runtime, wider live access changes, actual multiple windows, VoiceOver and genuine Auth/full-schema/hosted integration remain separate. No new migration or gateway behavior is introduced here. User-deferred release, remote-delivery and provider setup work remains deferred.

## Attempt qualifications

The first native pending-row run reproduced premature dismissal before Resume: a lifecycle-only attempt also failed. Both app implementations now present the review from the stable library parent rather than a scrolling section, retain its covered presentation lifetime, and still invalidate on explicit Close or changed account/access. Each owning controller harness passes 289 checks, including a new explicit-closure check; the pending native case verifies returning to the library and then closing it normally. The failed run cleaned all services/configuration and restored the Simulator. Its concise report is retained; the obsolete result bundle was pruned after preserving the failure log.

The stable presenter then exposed a separate native Form-row issue: Resume also invoked metadata Review because the two automatic buttons shared a cell. Both actions now use independent borderless behavior. The native oracle requires exactly the two original deliberate reviews and an unchanged approval across Resume/Cancel. Another candidate was deliberately stopped for a return-list cleanup correction; a later run stopped at the isolated fixture’s 20-entry draft quota before any network call. Ten strictly identified obsolete synthetic drafts were pruned, preserving publication journals and all real apps/accounts. The next run reached the second Resume confirmation but XCTest found nested representations of the same alert button; the selector now takes its first exact match, as the existing main-screen test already does. Cleanup and attempt reports are archived.

## Recheck

Run `python3 Scripts/check_test_storage.py --path /tmp`, then `bash Scripts/test_core.sh --jobs 2 --filter AudioCommentPublishingTests` in the owning repository. The iOS-only native mode is `node Scripts/Database/test-audio-team-native-provider.mjs ios-audience-pending /tmp/taskfold-pending-audience-recheck.json`, using current signed owning products and the existing isolated phone. Serialize heavy work and retain the 20 GiB storage floor.
