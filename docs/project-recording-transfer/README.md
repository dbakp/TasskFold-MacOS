# Reviewed published recordings in personal-project adoption

Reviewed 3 November 2026. This is a disabled candidate for transferring existing published recordings from a personal project branch into a team. **Whole-project recording transfers remain unfinished and unavailable in normal use.**

## Implemented

The signed inspection now advertises a separately gated transfer capability. Both clients require an explicit published-recording consent choice, show the reviewed count and retain that count in the exact saved request and receipt. Changing access decisions clears consent and invalidates an outstanding review response. Saved-request recovery sends the original command after a lost reply rather than constructing a new approval.

The server signs the chosen policy with the existing project review. It locks and rechecks the current recording inventory, task context, provider metadata and configuration, and permits the existing project-realm guard only through exact private transaction/actor/team/project authority. Project access and current recording custody change in one transaction. Immutable publication/sender receipts and object identities remain unchanged. Pending, retained, unavailable and unsupported media contexts refuse. A completed request recovers its original receipt even after fresh transfers are paused.

The new project-transfer flag defaults to false. Ordinary client/audio gates stay off, and no hosted migration or service deployment occurred. Both repositories independently own their code, migration, runner and captured SQL contract.

## Verified scope

Each owning repository passes 76 local database/gateway checks and 75 focused client tests, including six new client cases. Both app/test-runner builds and strict signatures pass. The local fixture uses production SQL and the production HTTP audio handler, synthetic sessions/Auth and an in-memory object-byte adapter; this is not genuine Auth/Storage or full-schema acceptance.

Two personal parent/child recordings are published through the handler. The old personal reader can initially download. During a subsequent download, reviewed adoption changes the audience; the crossing response withholds bytes with 404/unavailable. The new team reader receives the original exact bytes, and the retired reader is refused before another provider read. There are only the two original uploads. A forced failure after custody insertion rolls back project access and custody together; retrying the same command succeeds. Provider-version changes invalidate review, held locks refuse promptly, exact replay cannot duplicate custody and changing policy cannot reuse the request ID. A waiting publication scope reselects the current realm and obeys the team publication gate.

Private helper privileges and baseline advisor keys are checked. The fixture retains seven existing advisor entries with no added keys; it does not claim a clean full production audit. Each owned container and service is removed. Client recovery uses a secure-item memory adapter: native Keychain behavior and application-layer encryption are not established by these tests. No native app interaction is accepted by the build checks.

## Required before ordinary use

- [x] Bind publication approval to its reviewed audience. The [audience foundation](../audio-publication-audience/README.md) reproduced the old-private-intent boundary and verifies current-context checks before upload/finalization. Both apps implement explicit review and durable approval; [native recovery](../publication-approval-recovery/README.md) accepts bounded iPhone main Check and pending Resume. Wider native/realm acceptance remains below, and normal gates remain off.
- [x] Verify combined connection-pause and recording consent: neither approval can be stripped; connection pause, custody and receipt apply together and replay exactly.
- [ ] Accept native consent, cancellation, changed review and saved-request recovery on Mac, iPhone and iPad, including accessibility and lifecycle changes.
- [ ] Accept genuine Auth/provider/full-schema integration and wider account/access races. Add separately reviewed policies for pending/retained/legacy/mixed media and other realm directions.

The whole-project transfer parent stays To build. This checkpoint records actual local service/client progress without treating a disabled partial implementation as product completion.

## Attempt qualifications

The first iOS fixture tried to modify protected invitation fields; its setup was corrected to the existing invitation/acceptance workflow. Later fixture attempts incorrectly expected 503 for a reader losing access; the actual handler returns 404/unavailable. A successful baseline download was added before that crossing test. The iOS v4 and independent Mac v1 first passed 63 checks. Extended final iOS v5 and Mac v2 runs also verify combined connection and recording policy, passing 76 checks each. One initial client test incorrectly expected application encryption from a memory secure-item adapter; its claim was corrected to exact recovery and exclusion of media/caption content. Final owning client suites pass all 75 cases.

## Recheck

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-project-recording-transfer.mjs /tmp/taskfold-project-recording-transfer-check.json
bash Scripts/test_core.sh --jobs 2 --filter 'TeamProjectAdoptionTests|TeamProjectManagementTests|TeamProjectAccessTests'
```

Run resource-heavy checks sequentially and reuse existing build products. The database command needs Docker and uses synthetic data only. Use its --export-fixture option only when deliberately refreshing that repository's captured contract.

## Audience follow-up

The [publication audience foundation](../audio-publication-audience/README.md) now reproduces the old-private-intent gap and verifies signed audience checks in the local service and typed client transport. Native explicit approval and durable retry are now implemented in both apps, with bounded iPhone Check/Resume acceptance in the [recovery follow-up](../publication-approval-recovery/README.md). The [pending-boundary follow-up](../pending-approval-boundaries/README.md) also accepts bounded iPhone fresh review, missing/local-expiry Check and Close. Wider platforms and the remaining whole-project media policies stay open; the whole-project feature remains disabled.

## Unfinished-send follow-up

The [reviewed stop policy](../project-unfinished-recordings/README.md) now covers published plus unfinished sends, including pending-only branches, a crossing upload that loses access, atomic rollback and later cleanup. Each repo passes 151 local SQL/gateway checks and 83 client cases. Native consent/recovery, retained/legacy/other mixed contexts and realm directions remain open. The earlier pending refusal describes the published-only policy, which remains unchanged.

## 5 November · Genuine local service integration

The published-only personal project branch now passes 49 genuine Auth/REST/Storage and validated local TLS checks in each repo, using the production audio handler and full owning schema. Exact bytes, crossing-access refusal, immutable receipts/provider metadata, paused exact replay, audience-bound approval, direct Storage refusal and real session revocation pass. This supersedes the synthetic-backend qualification for this scoped service path; it does not accept native app, hosted S3 or the remaining mixed/legacy/realm directions. One unchanged pg_net placement warning remains. [Full scope and reproduction](../genuine-project-recordings/README.md).
