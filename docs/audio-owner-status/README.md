# Sender-only audio recovery — 28 October 2026

Check original send is now metadata-only. Resuming an upload requires a separate
confirmed action and current task publishing permission. Close original send
requires confirmation and retains the private recording. These controls are in
source behind existing disabled gates; native layout, spoken and full Store
lifecycle acceptance of the new controls remains open.

## Behavior and boundaries

- A live authenticated sender can check their exact saved immutable intent even
  after the original task is deleted or access is revoked. This grants no current
  task, comment or media read permission. Other actors cannot inspect that history.
- An unknown operation remains unconfirmed. Explicit closure writes a durable
  actor-qualified marker that blocks delayed reservation/finalization. An existing
  pending operation retires without releasing an unresolved upload lease.
- Closing an already-published operation returns its historical confirmation; it
  never removes the published comment. Status confirmation preserves private audio
  even when normal publishing would compact it. Local media removal is separate.
- Account/server/session/workspace/selection binding is checked across awaits.
  Status-only flows cannot publish or retry, including through legacy transports.
- Missing, foreign, corrupt, conflicting or unavailable responses cannot become
  closure. Lost acknowledgements retain the journal until an exact later result.

## Database and gateway review

The CLI-generated migration is
`supabase/migrations/20261028212632_audio_owner_publication_status.sql`.
The private actor/operation marker table has RLS and no direct customer/service
role grants. The authenticated gateway uses a service-only RPC and its existing
metadata rate budget; neither status nor cancellation makes a Storage request.
The old coordinator helper is no longer executable by service_role. SECURITY
DEFINER functions use an empty search path and recheck live actor/session state.
Account/task/operation locking preserves the existing coordinator order; real
concurrent close-first and reserve-first transactions are covered.

Absent-operation markers store a 32-byte intent hash, IDs and timestamp, with a
1,000-per-actor cap and Auth-user cascade. At the cap, new unknown closure refuses
and the client stays uncertain; existing history/known-operation cancellation
continues. No automatic marker pruning or history-retention policy is accepted.

Each canonical migration was applied to a fresh owned PostgreSQL fixture after a
draft review; advisors report no added findings. `supabase migration list --local`
could not connect because the default local Supabase stack is not running. The
fixture proof does not establish local migration history or hosted deployment.
There are no hosted schema, Storage-policy or ordinary feature-flag changes.

## Verification in each independent repository

| Check | Passed | Scope |
|---|---:|---|
| Core audio | 203 | Eight added status/closure, exact intent, stale scope, HTTP and media-preservation cases. |
| Actual controllers | 282 | Existing synthetic controller/codec/vault regression; no new UI acceptance. |
| Deno gateway | 31 | Six added strict metadata/check/close/history/authentication cases. |
| PostgreSQL + gateway | 51 | Actor isolation, both real transaction races, task deletion/access loss, lease fence, grants/RLS, marker cap and cascade. |
| Native owner recovery | 37 | Separate native processes → production gateway → real PostgreSQL; lost close/publish ACK, no Storage during metadata checks, cold proof, late-send fencing and denied media reads. |
| Terminal recovery regression | 54 | Existing closed-operation and uncertain-object recovery with the new migration. |
| Publication regression | 24 | Existing publish/read/remove/lost-reply behavior with the new migration. |
| Full app build | Succeeded | Unsigned generic iOS Simulator and macOS arm64; no application launch. |

The native API fixtures execute Core/Backend and full local AAC decoding in Mac
processes, using controlled Auth/Storage and real PostgreSQL 17.6. They do not test
an installed app, real account/provider, microphone, speech or device lifecycle.
Synthetic data only. Reports show owned PostgreSQL containers removed. Source and
binary hashes, architecture, gate values and final raw logs are archived here.

During iteration, existing Core tests caught changed/unsanitized error copy; the
product implementation was corrected without weakening those assertions. Draft
fixture failures exposed an invalid test cast, a correctly rejected custody-guard
mutation and a missing exact RPC allowlist entry. The fixtures were corrected;
no custody guard or production authorization was relaxed.

## Still open

- Native Check/Resume/Close layout, confirmation/cancellation, VoiceOver and full
  Store/account/window departure acceptance. Source builds are insufficient.
- Legacy/unbound/corrupt journal review and longer-term history/marker policy.
- Team audio publishing/removal/custody and genuine hosted provider acceptance.
- Genuine microphone/dictation and previously deferred release/provider work.

Audio/Px remains unfinished and gated. Earlier evidence:
[closed-publication recovery](../audio-publication-closed/README.md).

## Reproduction

Run from this repository with the documented PostgreSQL fixture prerequisites and
its independently built Core scratch directory (see the existing publication
fixture documentation). Use a new report path for each run:

```sh
node Scripts/Database/test-audio-owner-status.mjs /tmp/owner-db.json supabase/migrations/20261028212632_audio_owner_publication_status.sql
node Scripts/Database/test-audio-owner-native.mjs /tmp/taskfold-audio-recovery-core-PLATFORM /tmp/owner-native.json supabase/migrations/20261028212632_audio_owner_publication_status.sql
```

Replace `PLATFORM` with `ios` or `mac` for that repo's scratch build. These
commands create and remove only their labeled disposable PostgreSQL fixture.

Follow-up: [native original-send review](../audio-owner-review-native/README.md)
accepts representative mobile component controls and unconfirmed-result speech.
The earlier checkpoint above remains API/database scope; full Store/Mac/provider
acceptance is still open.
