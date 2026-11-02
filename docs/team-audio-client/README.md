# Team recording controls and confirmation handoff

Reviewed 2 November 2026. This client work remains behind the separate, explicitly false TaskfoldTeamAudioPublishingEnabled gate in each app. The service-side team publication gate also remains disabled.

## Implemented

- Existing private-recording and publication controls now admit a current editor/manager on a bound team task regardless of its creator. The current account, backend, known task, project/team state and editing capability must agree. Personal recording admission remains independent.
- Task editors now offer their existing recording entry point for admitted team tasks. Saved clips remain owned by the signed-in account in its private device vault; no recording is copied into task fields or exports.
- Existing conversation removal controls now admit a current author or manager. Viewers, archived/paused workspaces, changed accounts/backends and missing team boundaries cannot gain removal through a creator UUID.
- A newly confirmed publication, sender-status recovery or removal hands off only after a durable/exact acknowledgement. The owning Store refreshes and invalidates loaded conversation views; cached confirmations, uncertain/closed sends, failed receipt writes and late replies do not invent another handoff. Sender-only status recovery still cannot publish and keeps its original identity/audio.

## Verification

Each repository independently passes 213 focused AudioComment Core tests, including ten new admission/handoff tests, and 284 actual capture/library/conversation-controller checks with synthetic media drivers, including two removal-handoff checks. There is no microphone, permission prompt or sound output in those controller tests.

The first iOS Core run exposed an old test oracle comparing two fresh binary-property-list serializations as if encoding order were stable. The corrected assertion compares the actual journal file bytes before and after status-only recovery. The journal preservation requirement is retained and strengthened; the original failing attempt is recorded separately from the accepted run.

Current app/runner build, strict-signature and native results are recorded in verification.json. Compiled source matching is checked against each owning repository after test namespace isolation. These checks do not establish genuine Auth/Storage, a full publish/remove UI round trip, runtime Store refresh, all account/window/background cases or accessibility acceptance. Previously accepted local service authority/custody proof remains in team-audio-authority and reviewed-audio-custody; no service or schema source is changed by this client milestone.

## Native capture scope

The iOS repository passes one focused iPhone Simulator case using actual team-task editing, private recording storage and silent synthetic media: Save, unchanged task rows, exact pre-existing file preservation, cold reselect with exact bytes/caption, and editing withdrawal after a viewer boundary. The app is closed and its own Simulator restored. This is capture/permission/cold-recovery proof, not a shared-service publication/removal or Store-refresh acceptance. The Mac build does not inherit this runtime claim.

## Remaining

Full native publishing/removal/status recovery against the actual local service and Store refresh; Mac/iPad runtime and wider access/account/window/background checks; VoiceOver, largest text, contrast and privacy; genuine provider/Auth/full-schema acceptance; reviewed generation restoration and whole-project audio transfers. The older interrupted iPad file-dialog/cache check remains separate and should not be rerun against its unchanged runtime condition. User deferrals remain unchanged. No hosted deployment, release enablement or normal-use gate change.
