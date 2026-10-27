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

Native source-app tests use isolated identities and a synthetic public place. Foundation fixtures cover silent producers, cancellation, late callbacks, expired budgets, actual text/URL decoding, partial-result refusal, opaque previews and byte limits. Actual iPad Maps extension and host reviews pass in normal light and largest-text dark appearance, with screenshots inspected; the current phone regression also passes. See `p2-tablet-share-evidence.json`. These checks do not establish every third-party app/tablet layout, native Mac share-menu operation, wider cloud/device/physical-network transitions or spoken accessibility. Distribution and the user's other deferred work remain deferred.


Real disposable cloud accounts now verify stale extension Save refusal across A → B and durable offline Add across A → B → A. Server tasks remain empty while the original account is offline; only that account receives one task after return, with its queue drained and receipt retained. `p2-share-cloud-evidence.json` separates the real Auth/HTTP/native checks from the controlled app-transport outage. Source errors are pinned below the header so the keyboard cannot hide recovery guidance. Native Mac/VoiceOver and wider device/physical-network acceptance remain open.

The iOS repository owns the native phone cloud-walk controller and private-fixture preparation commands. Its evidence is recorded here for the shared capture contract; it is not a Mac build dependency or native Mac acceptance. This repository independently owns its Mac implementation, Debug outage scope and build inputs. Live Mac share/account/keyboard/VoiceOver acceptance remains open.

## Reproducible Mac Share test preparation — 27 October 2026

The Mac workflow preparer accepts `--share-extension --team TEAMID` with a fresh
`--namespace workflowtests...` and unused temporary `--output` directory. It
includes the native extension, names both components “Taskfold Share Test”, and
assigns both the same team-prefixed isolated App Group. The receipt records the
final renamed group and exact prepared source hashes. Default workflow preparation
still omits extensions and the App Group. This prepares source only; it does not
sign, install, register, enable or launch an app. Synthetic backend configuration
is not substituted automatically: configure it in the copied workspace before
building and retain that adjustment in build evidence.

`python3 Scripts/test_workflow_share_preparation.py` passes three real preparation
checks: matching private host/extension identities and fingerprints, unchanged
default preparation, and missing/invalid-team rejection before creating output.
Production inputs are checked unchanged. The independent extension-configuration
suite passes two checks; the existing multi-process mailbox check preserves 64
complete drafts across four independent writers.

The separately prepared Share host builds and verifies its deep, strict code
signature. With the user's approval, its extension was enabled temporarily and
then restored Off. Genuine native Safari link intake and TextEdit selected-text
intake now pass the recorded local scope. Safari Cancel preserves exact mailbox
and host cache bytes; Save creates one draft while the host stays quit. Host
Cancel preserves it, explicit Add creates one literal task, and Undo/Redo plus
normal cold return preserve the expected task data and durable receipt. Undo
retains creation/deletion history; Redo intentionally refreshes task_generation.
TextEdit review preserves full selected text, invents no URL, and Add respects the
chosen project. Original tasks remain unchanged. See mac-native-share/validation.json
and synthetic snapshots. These checks do not close broader Mac cloud/account,
spoken, permission, external-provider or source-app acceptance.

Template imports also now own a cancellable coordinated reader. Cancel,
dismissal, workspace change or a replacement read cancels the old coordinator;
request checks continue to discard late results. Chunk reads check cancellation
and the existing 2.1 MB bound. An unavailable provider explains how to retry
without suggesting that saved templates changed. Both owned implementations pass
five final reader cases using real held/failing NSFilePresenter coordination;
85 distinct selected Core cases pass across the broader and final runs per repo.
Both apps build, and the current Mac native picker/review/Cancel smoke preserves
exact cache bytes. This is controlled Foundation provider proof, not a real
cloud-provider transfer or native held-provider-cancellation acceptance. See
template-file-recovery/validation.json.
