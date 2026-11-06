# Shared-draft badges without foreground mailbox decoding

Both app owners now resolve and read shared-draft badge counts away from the interface thread. One read runs at a time; repeated refreshes replace one pending request with the newest request. Cancelled/obsolete results cannot overwrite a newer count, and the worker cannot report an impossible count outside the existing 64-draft mailbox capacity. Each foreground refresh remains fresh rather than caching a count across extension saves.

The disk reader copies bounded bytes while holding the existing file lock, then releases the lock before decoding and validating the mailbox. It retains the existing 8,000,000-byte cap, version/content/identity/capacity validation and exact imported-receipt filtering. These reads do not rewrite the mailbox. Background completions must still match account/workspace generation, session incarnation, workspace read/access revision, origin and the current durable-receipt map. Account changes, unreadable workspaces and inactive publication invalidate badge work and clear its visible count. An explicit synchronous draft review invalidates older badge work before publishing its exact count.

The queue lives in the app-side sharing-plan module; the incoming Share extension continues to compile only the credential-free common mailbox contract. The first app build caught this target boundary and it was corrected before acceptance. No file-format, task mutation, publication or import/acknowledgement semantics change. DEBUG controls are restricted to the exact reserved test bundles plus explicit fixture arguments and use their own app-support mailbox, not a normal app group.

## Evidence

- Each owner passes 22 focused sharing Core checks: 14 existing capture/data/import checks plus eight new reader cases. These cover one active/newest pending read, cancellation/invalidation, exact foreground-review precedence, stale failure suppression, failure/retry, fresh subsequent reads, invalid counts and malformed/unsupported/duplicate/over-capacity data. A real 64-draft mailbox larger than 5 MB decodes off the interface thread, excludes only the exact handled receipt, hides another account and retains every mailbox byte.
- Current signed phone and tablet flows exercise the actual Store and its production count property. A held read leaves an interface button usable. A changed receipt map refuses the old reply, the handled draft is excluded, and restoring the original snapshot returns the count to two. Both the complete active saved-cache bytes and mailbox bytes remain unchanged. Device/content-size state is restored.
- The final independent Mac source builds and passes strict signature verification. This is not native Mac interaction, speech, physical-device smoothness or all-account/window acceptance.

## Remaining scope

This fixes the badge-count read path. Explicit shared-draft review/cleanup, capture publication/import/save and widget disk operations retain their existing synchronous semantics. In particular, it does not eliminate the previously observed startup wait for macOS shared-app-data permission. Full shared-draft review loading and startup publication need their own bounded work and privacy/transaction checks. General navigation, drag/rendering, large libraries and broader platform/accessibility/account cases remain open.

Mac29 remains installed, running and synced. Neither its frozen package nor deferred phone41 includes this source change. No new ordinary rollout gate, hosted deployment, physical-phone installation or normal-app data mutation occurred. A later verified Mac feature pack can be installed under the user's standing authorization without asking about drafts.

Repeat Core checks with `bash Scripts/test_core.sh --filter 'SharedCapture(CountReader)?Tests'`. Native case: `WorkflowSourceSelectionUITests.testSharedDraftBadgeReadStaysResponsiveAndRejectsChangedReceipts` in the reserved signed host. There are no database migrations or provider prerequisites for this local change.

Subsequent delivery: this source is packaged and installed in Mac30. Its system permission/startup status is recorded separately in [Mac30 installation](../mac30-installation/README.md); phone installation remains deferred.
