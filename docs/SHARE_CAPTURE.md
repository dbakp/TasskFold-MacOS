# Reviewed share capture and source-app intake

Both apps independently own a native extension, bounded device-local mailbox and host review. Share text or one HTTP(S) web link, edit the draft, and choose Save draft. Taskfold then offers a separate review with Inbox/active-project destination and explicit Add. Words such as tomorrow, p1 and #literal remain literal shared content; this flow does not execute quick-entry commands.

## Source handling

Apple Maps supplies an opaque `com.apple.mapkit.map-item` preview alongside separate `public.url` and `public.plain-text` providers. The preview remains unread. The intake accepts this exact ancillary-only provider only when the same share also supplies a validated web link. The review explains that map previews are not copied. It does not decode place objects, invent a link, fetch a page or request location access.

An unknown attachment, a mixed opaque/unknown representation, a map object without a web link, invalid URL or excess content refuses the whole selection. No partial draft is saved. Existing limits remain four extension items, eight providers, one unique web link, 100 KB of combined text including separators, and 8,192 bytes per source URL. Mailbox version 1 and its existing account/workspace checks are unchanged.

## Waiting and cancellation

All provider reads share one absolute 20-second intake deadline. A slow later attachment cannot restart that budget. Source failure, missing content or timeout leaves Save unavailable with a useful message; reopening sharing retries. Editable fields stay disabled until intake finishes, preventing a late response from replacing user edits. Review itself has no time limit after content arrives. Cancel or dismissal cancels the reader and prevents a late result from populating a dismissed review.

A locked, once-only continuation gate arbitrates completion, timeout and cancellation. Foundation owns the source provider's underlying work; `loadItem` exposes no cancellable Progress. Taskfold stops waiting and safely ignores late callbacks, without promising to terminate another app's work. Existing mailbox access is not included in that provider-wait guarantee.

## Durable save

The extension has no credentials or backend connection. Save rechecks its original account/workspace generation and writes an atomic, locked draft. In the host, task creation and its private receipt commit before acknowledging the mailbox draft. Failed saves retain review and retry; relaunch cannot duplicate an acknowledged task. Account changes never retarget an old draft. See `p2-share-capture-evidence.json` for earlier Safari, host-review and mailbox acceptance, and `p2-share-provider-evidence.json` for the subsequent provider/Maps checks and exact remaining limits.

Native source-app tests use isolated identities and a synthetic public place. Foundation fixtures cover silent producers, cancellation, late callbacks, expired budgets, actual text/URL decoding, partial-result refusal, opaque previews and byte limits. These checks do not establish every third-party app, native Mac share-menu operation, cloud/offline transitions, tablet extension layout or spoken accessibility. Distribution and the user's other deferred work remain deferred.
