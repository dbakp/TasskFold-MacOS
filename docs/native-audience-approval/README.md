# Explicit native audience review and durable publication approval

The later [recovery follow-up](../publication-approval-recovery/README.md) accepts bounded warm retries and the separate iPhone pending-screen Resume. The evidence below records this earlier main-screen checkpoint.

Reviewed 3 November 2026. Both applications now implement the review and saved approval flow. **The bounded iPhone Saved recordings journey is accepted; separate pending-request controls and wider platform/recovery acceptance remain.** Ordinary audio and project-transfer gates stay off. Nothing is deployed.

## Behavior

Opening a recording stays local. An explicit **Review who can listen** action obtains the server audience for one frozen publication intent. The screen distinguishes personal, private-team and team-visible access and explains that downloaded copies cannot be recalled. Cancel discards the unsaved approval. Publish needs a separate confirmation, then saves the exact proof before the first media request. A returned confirmation retains the same proof and immutable original intent.

The account/server-bound private journal adds a strict v4 format while preserving v1/v2/v3 reads. Expired proof remains readable for recovery, but cannot authorize upload. Exact status Check and Close continue to preserve the private recording. Reopening does not fetch a new audience automatically. Resume reads the same persisted approval and rejects a missing, expired or competing replacement decision. Atomic file locks, rename/fsync and expected-proof checks prevent one window from overwriting another window’s approval or an existing receipt.

Both native screens show the server-reviewed audience, expiry and explicit sending controls. The main Saved recordings view also offers Close original send. The separate pending-publication screen can review its exact original bytes without creating or changing a saved draft. Local access-boundary changes, source/account/workspace changes and departure invalidate review; late callbacks cannot restore it. Private file lookup deliberately retains its original account/server namespace, independently of the publishing-only access stamp. Review status and audience summaries have distinct accessibility focus targets; audible VoiceOver acceptance is still outstanding.

## Accepted evidence

Each owning repository passes **73 publication client tests**, including seven new cases, and **288 synthetic controller checks**, including four new cases. The client checks cover explicit metadata review, no authority saved on review/Cancel, proof persistence before transport, exact retry after a new controller, readable expiry plus metadata-only confirmation, competing-window refusal, delayed review departure, malformed proofs and file-level unknown rename outcome. Controller checks cover stamped access changes and exact pending-source identity/bytes without creating a draft or approval. These controller executables exclude Store integration; current Store lookup is separately exercised by the iPhone journey and compiled on Mac. Existing unrelated compiler warnings remain; no warning-free Core claim is made.

Both isolated app/runner builds and strict signatures pass. The owning iOS repository also runs one new native case at dark Accessibility XXXL on the existing iPhone 18 Pro Simulator against production SQL/gateway and pinned real local Storage. Its **36 service/native assertions**, one UI test, no skips and no reported runtime warnings establish:

- Opening does not authorize sharing. A private-team review includes administrators, even if an old test expected team-wide wording.
- Cancel saves no approval and sends no audio; the second explicit review reuses the frozen request.
- Final confirmation stores v4 approval before one upload. The real committed publication reply is deliberately lost.
- After terminating/relaunching the app, metadata Check confirms the same original request without a third review or second upload. Intent, approval, audio, saved source and task data remain unchanged.
- The published record has one private audience binding. Only after native verification does the runner retire the synthetic comment and verify actual fenced provider cleanup.

Auth/sign-in, native HTTPS/PostgREST routing and recording drivers are synthetic. This is real local Storage/SQL acceptance, not genuine Auth, microphone/playback, hosted/full-schema, pending-screen, Mac or iPad runtime acceptance. The phone report is archived in both repositories explicitly as **owning iOS evidence**; Mac does not claim its source was run on the phone. All owned configurations/services/containers are removed, the Simulator’s previous state is restored and no test app remains running. No device or build host was added. Heavy jobs ran sequentially above the 20 GiB floor.

[Phone review at largest text](phone-review-largest-text.png) · [Cold confirmation](phone-cold-confirmation.png)

## Attempt qualifications

The first iOS build exposed a missing Store environment in the parent pending section; it was restored. A source audit then separated private-directory lookup from the new sharing access stamp. The final iOS and Mac builds include both corrections. A temporary test-generator syntax failure did not modify product sources; the native case was added before its accepted build.

Native attempt 1 stopped after a successful private Save: the test waited for an offscreen lazy library button at the largest text size. Its captured hierarchy showed the app correctly back on the main form. The test now reveals controls through actual scrolling. Attempt 2 received a correct private-team review but expected team-visible wording; only that expectation changed. Neither attempt uploaded audio and both cleaned all owned resources. Final attempt 3 passes the complete bounded journey. File-level unknown-rename durability was covered here; the later [recovery follow-up](../publication-approval-recovery/README.md) accepts the bounded in-process cases.

## Remaining work

- [ ] Accept the separate Original publications review screen, saved Resume, expired/missing approval and exact Close with the current service.
- [x] Check bounded in-process approval-write ambiguity and repeated competing-proof refusal: see [the recovery follow-up](../publication-approval-recovery/README.md). Actual multiple app windows, changed remote access and wider departure/recovery remain; never silently renew approval during retry.
- [ ] Accept iPad and Mac native controls, actual VoiceOver speech/keyboard, wider contrast/lifecycle and genuine Auth/full-schema/hosted integration. Do not repeat the unchanged Mac authentication failure.
- [ ] Finish remaining whole-project transfer media policies and native transfer acceptance. This checkpoint does not complete the whole-project feature or the full Px goal.

## Recheck

```sh
python3 Scripts/check_test_storage.py --path /tmp
bash Scripts/test_core.sh --jobs 2 --filter AudioCommentPublishingTests
```

The iOS-only native runner command is `node Scripts/Database/test-audio-team-native-provider.mjs ios-audience /tmp/taskfold-native-audience-phone-check.json`. It requires current owning signed app/runner products, Docker and the existing owned phone Simulator. Reuse resources and run heavy jobs sequentially. Other native runner modes were adapted to the audience protocol but are not newly accepted by this checkpoint.
