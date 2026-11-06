# Native pending-approval boundaries

Reviewed 3 November 2026. The owning iPhone Simulator now accepts fresh pending-request Review/Cancel/Publish, missing approval, historical local expiry, metadata Check and explicit Close against the current local service. Whole-project recording transfers remain unfinished and ordinary sharing/transfer gates remain disabled.

## Accepted behavior

- An original request without approval offers no Resume. Check reports unconfirmed without reserving or uploading audio.
- Explicit Review displays the private-team audience. Cancel saves no approval and preserves the private draft. A second Review and separate Publish confirmation save approval before the real publication; its committed reply is deliberately lost.
- After quitting the app, the fixture changes only the saved approval's expiry to a past date. The app can read this historical local proof, offers no Resume, and uses metadata Check to recover the existing server receipt. The expired approval, original intent/audio, saved private draft and task data remain unchanged.
- A second unapproved original request can be checked without an upload. Cancelling Close leaves its exact saved file unchanged. Confirming Close freezes that original operation, retains its private audio and stores the returned closure proof. After relaunch, it stays closed and offers neither Resume, Review nor Check.

The native runner passes **42 service/native checks**, with **one UI test, zero skips and no reported runtime warnings**. Actual production SQL/RLS, gateway and pinned local Storage are exercised. Four metadata requests have the explicit Close sequence false/false/false/true; only the two deliberate audience reviews occur, and only one publication/upload exists. The second operation creates exactly one sender closure marker and differs from the published original. The runner then retires/purges only the synthetic published object and confirms its bytes are absent from the provider. All owned configurations/services are removed, the Simulator's prior state restored and the test app quit. No new device or host is created.

Both current isolated app/runner builds and strict signatures pass. Each repository owns its fixture independently; Mac archives the phone report explicitly as owning iOS evidence. The DEBUG seed control is available only in the reserved native provider, exact synthetic account/server and a dedicated argument. It saves/decodes a synthetic private clip and freezes its request through the actual vault/journal; it does not approve, upload or mutate tasks. It avoids repeating the already accepted recording-capture journey. The native HTTP adapter records only the original operation identifier and explicit Close bit alongside its existing request digest.

## Limits and remaining work

This case uses dark appearance and standard L text. Auth/sign-in, native HTTP routing and recording generation remain synthetic. The expiry step deliberately edits a **local** historical record; it is not a server-validated expired signature or an elapsed server-TTL test. Core/server expiry checks are separate existing evidence. No new Core or gateway suite was run for unchanged product code, and no new server migration or production behavior is introduced here. A platform accessibility-loader diagnostic appears in the log; this is not a warning-free platform claim.

- [ ] Implement the remaining pending/retained/legacy/mixed recording policies and realm directions for whole-project transfers.
- [ ] Accept wider native transfer consent/cancellation/changed reviews and saved-request recovery on iPhone, iPad and Mac. The Mac native runner still needs its own actual test target audited; a build is not runtime acceptance.
- [ ] Complete wider account/access/window/lifecycle, VoiceOver/keyboard/largest-text and genuine Auth/provider/full-schema/hosted integration scope.

All user deferrals remain. The existing audience and recovery follow-ups remain authoritative for their own 112 service checks, 78 client tests, 289 controller checks and previous main-screen Check/pending Resume acceptance; those counts are not new tests in this checkpoint.

## Recheck

After the default storage guard, use `node Scripts/Database/test-audio-team-native-provider.mjs ios-audience-boundaries /tmp/taskfold-pending-boundaries-recheck.json` from the owning iOS repo with current signed isolated products. Reuse the existing phone/hosts, serialize heavy work and retain the 20 GiB free-space floor. Keep the isolated vault below its separate 20-entry limit by pruning only strictly identified obsolete synthetic drafts when needed; never erase real app data.
