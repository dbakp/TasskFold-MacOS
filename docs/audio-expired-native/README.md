# Native expired-recording recovery and cold retry

Reviewed 2 November 2026. Follows [the explicit expired-recovery implementation](../audio-expired-recovery/README.md).

## Changes

Retained-recording restoration reviews now stop at the actual retention deadline, even if their five-minute metadata lifetime has not ended. The native review uses the earlier deadline. It refreshes when connectivity, sync activity or the queue head changes, and clears old consent. Confirming an already-recorded Undo closes only within the captured workspace/session after its queue head is acknowledged.

The native test observed a recovery navigation bar still present in the accessibility tree after task-only recovery changed the pending command. Retaining the launching row alone did not resolve that assertion. Both apps now attach presentation outside the conditional row, close through the request-guarded presentation owner, and release the submission lock before closing. The final test additionally requires the sheet to be absent or untappable and the underlying task status to be tappable, with after-submit pixels captured; an existence-only check is not used to infer visual dismissal. Shared task content stays hidden whenever the original workspace/intent is no longer current.

## Isolated runtime case

The iOS case uses the production retention and recovery views, real Store history/queue/persistence, real local PostgreSQL authorization, the production gateway and pinned Storage API. Only the reserved debug root, authentication/HTTPS/PostgREST adapters and media capture/playback drivers are synthetic. It never contacts a real account or changes real tasks.

After an actual acknowledged task deletion, the owned test provider expires only the synthetic audio retention record and runs the real fenced cleanup worker. The original retained-recording Undo is refused. The case then checks unchecked task-only consent, enabled/disabled actions, Later preserving the complete original request and private bytes, cold return with fresh consent, explicit terminal closure and a fresh task-only request. It deliberately loses the committed task-only reply; the final cold launch must retry the same request values and confirm exactly one restoration. Private originals and task content must remain exact apart from the previously chosen new generation; expired audio must not be downloaded, republished or resurrected.

HTTP member order is not a frozen command contract. The report retains raw request hashes for diagnosis, compares the parsed complete request values for cold retry, and additionally requires the real SQL idempotency receipt and exactly one restore ledger row. It does not weaken the service's keyed fingerprint check.

## Attempt qualifications

- Phone v1 passed Later and cold preservation but stopped at the second switch interaction with value 0; it submitted no closure or replacement. The harness now follows the same viewport sequence as the earlier successful switch interaction, asserts enabled state and captures before/after images. It still requires actual value 1.
- Phone v2 passed consent and reached real closure and task-only commit with the deliberately lost reply, but stopped at the existence-only dismissal assertion. Phone v3 retained the presenting row and stopped at that same assertion. Neither reached cold retry or establishes a full flow.
- The final owning verification/report records whether stable presentation ownership, actual return to the task screen and full cold retry pass. Earlier normal recording Undo proof does not establish this new path.

## Remaining scope

This case belongs to iOS and does not establish Mac runtime, iPad recovery, spoken VoiceOver, largest text, actual hardware capture/playback, wider window/account/background/access/privacy or local save-failure behavior. The already-recorded outcome button still needs its own native flow, as do whole-selection closure/recovery, mixed file/audio and discussion-expiry behavior, personal/legacy migration and whole-project transfers. Genuine Auth/full-schema/hosted acceptance remains open. All normal-use switches stay Off, and nothing is deployed.

The older iPad file-picker/cache scope and the initial reminder-scheduling wait remain separately open. No unchanged broad iPad test was repeated. Heavy jobs reuse existing hosts/devices/products and run sequentially behind the default 20 GiB floor; owned fixtures close the app and restore the Simulator after each terminal attempt.

Phone v4 passes the complete native case and all 46 owning service/native assertions. Its after-submit screenshot shows the underlying debug task host, and the test requires that host to be hittable. Exactly one closure and one restored task are recorded; the lost reply and cold replay use the same fresh task-only request values. The original private recording and publication journal stay unchanged. All owned configuration/services are removed and the Simulator is restored. Both repositories independently pass 186 Core tests, including the new actual-retention-boundary case. This is a debug-root/production-review flow, not acceptance of normal Backups navigation or every main-app entry context.

Follow-up: [recorded Undo confirmation and selection-review admission](../audio-recorded-native/README.md) adds scoped iPhone warm recorded-result acceptance; the remaining platform and lifecycle qualifications above still apply.
