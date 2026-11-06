# Native original-send review — 28 October 2026

The production publication-copy review now scrolls its result into view before
requesting VoiceOver focus on the materialized row. The unconfirmed result is
shorter and precise: “Still unconfirmed. Checking did not upload audio. Your
recording is preserved.” Previously, the long result exceeded the largest-text
viewport, and requesting focus on an unloaded Form row was ineffective.

The rendering layer receives the existing Store authorization factories rather
than reading Store itself. Production permission checks, journal contracts and
transport are unchanged. Check and Close remain available for the sender's saved
operation when its original task is unavailable; Resume retains current task
publishing admission and its separate confirmation.

## Accepted native scope

Five distinct journeys pass on each of iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator, across the recorded phases:

- [x] Metadata-only unconfirmed check with unavailable original task; Resume hidden.
- [x] Close Cancel makes no closure request; confirmed closure retains private
  media. A cold launch retains closed proof and offers no Check/Resume. Private
  removal Cancel retains playback; separately confirmed removal keeps closed
  proof, releases only local publication media and makes no transport request.
- [x] Closing an already-published send preserves confirmation and private audio.
- [x] Resume Cancel makes no upload; separate confirmation makes exactly one.
- [x] Failed Check preserves the pending original and its media.
- [x] Real system VoiceOver output identifies the unconfirmed result and says
  checking did not upload audio, after the asynchronous result becomes available.
- [x] Four final dark Accessibility XXXL images were inspected. Status text and the
  tested action rows fit the actual Form viewport; long content remains scrollable.

These are five test methods: the long recovery journey combines several checks.
They are not a claim of five new product features or all Px completion.
[Acceptance map](acceptance.json) records each accepted method and its phase.
The phone's speech run passes alone; its full functional phase has three passes
and the offscreen-query failure, corrected by the final focused pass. The iPad
full phase has four passes and that same superseded query failure; its final
focused pass completes the long journey. No skipped tests or runtime warnings are
reported in those summaries. This does not certify every system/tool log as clean.

[Phone status](phone-unconfirmed-largest.png) · [Phone closure](phone-closed-largest.png) ·
[iPad status](ipad-unconfirmed-largest.png) · [iPad closure](ipad-closed-largest.png) ·
[Phone speech](phone-voiceover.json) · [iPad speech](ipad-voiceover.json).

## Fixture and build boundaries

The DEBUG-only reserved team-editor host presents the actual production review
and controller with real private publication/draft vaults and fully decoded
synthetic AAC. Only transport and silent playback are substituted. The exact
isolated bundle and `--audio-owner-review-testing` are required. Reset affects
only its own `owner-review` folder. No microphone, speaker, real task, token or
provider is involved. Normal audio gates remain absent/off; no backend/schema or
hosted deployment changes occur in this checkpoint.

The speech test starts Check with VoiceOver off, holds the synthetic response,
then releases it through a fixture-local file only after the real VoiceOver
service returns initial speech. It tests asynchronous result focus, not activation
of Check through a VoiceOver gesture. XCTest teardown blocks restore the state
observed at each test and terminate the app even after assertion aborts. The iPad
also returns to its independently observed Off setting. The phone's state before
the first failed attempt was not recorded; no whole-turn restoration claim is made.
Mac system VoiceOver was not changed.

Both independently owned isolated app/test builds pass and verify strict
signatures. App executable **and loaded debug dylib**, tests and source hashes are
recorded in [build.json](build.json), [source-bindings.json](source-bindings.json)
and [installed-builds.json](installed-builds.json). Simulator ad-hoc and Mac
isolated development signing do not accept distribution. The final test-only
change moves the existing exact-runner guard before VoiceOver state access;
both builds were rechecked. Accepted production view code and loaded debug dylib are unchanged. The iOS
launcher stub changed during the test rebuild; its earlier and final hashes are
recorded separately, rather than treating stub equality as proof of app code.

Initial attempts remain visible in `attempts/`: lazy Form queries and duplicate
alert matches were corrected, then native evidence drove shorter result copy and
scroll-before-focus. A bounded temporary focus trace produced a diagnostic pass;
that trace was removed before the accepted bare phone speech and final journeys.
The failed Intel Simulator link used an arm64-only cached AppAuth dependency;
final Simulator builds target arm64. The initial Mac test-class naming mismatch
was corrected. Full final build logs are archived; no passing Mac runtime is inferred.

## Still open

- Native Mac review/layout/spoken acceptance; computer use reported the Mac locked.
- Full Store/shared-account/window/departure lifecycle and the main publisher UI.
- VoiceOver activation of every action and the other spoken result variants.
- Legacy/unbound/corrupt journal review, history/marker policy, team audio custody,
  genuine hosted provider and genuine recording/dictation acceptance.

Audio/Px remains unfinished and gated. Previous real database/native API evidence:
[sender-only recovery](../audio-owner-status/README.md). Existing user release and
provider deferrals remain unchanged.

## Reproduction

Use this repo's `Scripts/prepare_team_editor_native_test.py --output <new-path>
--headings` to create a fresh reserved host; do not enable ordinary audio flags.
Build its Taskfold scheme for testing. On this Apple Silicon Mac, pass
`ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=YES` for Simulator builds.
Select the five `testAudioOwnerReview…` methods in
`TaskfoldUITests/AudioCommentUITests.swift`, disable parallel test cloning, and use
the explicit existing Simulator destination. The build logs record exact commands
and destinations. The same repo-local helper prepares Mac; native Mac execution
still requires an unlocked desktop. Tests use XCTest teardown blocks for cleanup.

[Cleanup](cleanup.json) verifies no remaining Taskfold executables and both owned
Simulators returned to Shutdown. Obsolete test products, raw videos/results and
redundant temporary files were removed; reusable source/build caches remain.
