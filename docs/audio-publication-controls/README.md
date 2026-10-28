# Gated native publication controls — 28 October 2026

This checkpoint connects the native publication foundation to a separately gated
saved-recording review. Normal recording/publishing flags are absent/off. No app
was launched, no hosted configuration/data changed and no microphone, speech,
playback, VoiceOver, signing or system approval was requested.

## Implemented

- The saved-recording detail has publishing controls only when both the existing
  private-draft gate and the new `TaskfoldAudioPublishingEnabled` gate are enabled.
  Store admission requires a signed-in cloud workspace, exact current account /
  server / workspace incarnation / task generation / project, current write
  admission and the original recording target. Local, moved, unavailable or
  repairing workspaces cannot publish. No retargeting occurs.
- The Store factory binds the publisher to the exact selected library recording
  and library scope, and captures the current Backend session incarnation. It
  rechecks these through the flow's live callback. Inactive/changed/closed selection
  loses authority immediately, independently of SwiftUI's later redraw.
- Opening a review restores only local publication status. It never sends or
  prepares a new publication. A matching prior confirmation is labelled “Published
  previously”; an unconfirmed send offers “Check publication”. An earlier pending
  revision blocks another identity rather than silently sending an edited version.
- A fresh send requires explicit review/confirmation, stops playback and re-reads
  the exact saved revision immediately before preparing its durable operation.
  Legacy pending records without a server binding are preserved and block the send;
  they are not adopted into a new server/operation. The selected file/bytes must
  still match the fully decoded review.
- The SwiftUI controls show preparation/sending progress, safe retry, retained-local-
  recording feedback and a reload action after local/setup failures. Sign-in
  rejection gets an explicit message. Context/scene departure cancels the UI task
  and invalidates late presentation; local journals/recordings remain intact.
- Source registration is independently owned and idempotent in each app project.
  Ordinary users see no new unfinished publishing entry point.

## Verified

Each repo independently passed **164 audio Core tests**, including three new
local-restoration cases, and **235 actual recording-controller checks**, including
five new publication-source checks: exact fresh selection, local-workspace refusal,
stale-selection refusal, legacy pending refusal and inactive selection authority.
The controller executable uses the actual app controller/Core/codec/vault with
synthetic media drivers and no device permissions or sound.

Both complete application targets build with the new SwiftUI view and Store bridge:
Mac arm64, and iOS Simulator arm64 + x86_64. Builds used a temporary compile-check
bundle identifier and `CODE_SIGNING_ALLOWED=NO`; this is **compilation**, not signed
installation, release distribution, native UI runtime, visual or spoken acceptance.
The built Info dictionaries also prove both ordinary audio flags absent/off.

[Build metadata](builds.json) · [iOS Core](core-ios.txt) · [Mac Core](core-mac.txt) ·
[iOS controller](controller-ios.json) · [Mac controller](controller-mac.json) ·
[iOS app build](app-ios.log.gz) · [Mac app build](app-mac.log.gz) ·
[Source bindings](source-bindings.json).

The previous [native publication foundation](../audio-native-publication/README.md)
records actual native-to-Deno/real-PostgreSQL lost-reply/restart acceptance. That
integration is not a click-through acceptance of these new SwiftUI controls.

Reproduce independently from either repo (use an owned scratch directory):

```sh
swift test --scratch-path /tmp/taskfold-publication-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-publication-core --output /tmp/publication-controller.json
python3 Scripts/configure_audio_comments.py
```

App build commands are preserved in the compressed logs. They compile the repo's
actual project with a synthetic bundle identifier and no signing. Temporary
compile-check app bundles are removed after identity/binary/flag verification;
reusable object/dependency caches remain for subsequent work. No test app/session
was left open. Source and proof remain separate in each repo, without sibling
build dependencies.

## Remaining work before exposure

- Native runtime and visual/accessibility acceptance of Review/Cancel/Publish /
  Check/Reload/close/relaunch across Mac, iPhone and iPad, using an isolated cloud
  fixture. No screen render, native button activation or VoiceOver result is
  claimed by compilation or controller tests.
- A pending-publication list/review for older revisions and recordings whose saved
  source is no longer present; account/server-bound journal management/retention.
  Current controls deliberately block, preserve and report such work.
- Live audio-comment listing, authenticated download/native playback/removal and
  conversation presentation. Historical receipt replay is not current server
  visibility or permission. The current conversation instruction remains behind
  the gate until that presentation is implemented and accepted.
- Real provider/custody/removal/uncertain-upload acceptance and the remaining
  genuine audio checks. Release signing/distribution and the user's other recorded
  deferrals remain unchanged. No server/native audio gate is enabled here.

This completes the compiled gated review/control wiring, not runtime acceptance,
audio comments or the full Px objective.

Follow-up: [private publication-copy recovery](../audio-pending-review/README.md) implements gated orphan review and explicit confirmed-audio retention/removal. Its evidence and remaining limits supersede that specific open item above.
