# Native project-file preparation and consent — 5 November 2026

Both apps now include private-copy preparation in the existing project-transfer screen. The flow shows progress and a bounded preview of file names, supports Stop/Continue and explicit cancellation, and requires a separate sharing checkbox before the final transfer review. Originals stay private. The final review and success screen identify the transferred file count. No new visual system or ordinary rollout gate is introduced. Installed apps are unchanged.

## Saved recovery and consent

The app saves an immutable, account/origin-bound request in the existing Keychain-backed command vault before its first preparation request. It contains the scope, stable request identity, inspection token and expected file count, without file bytes, provider identities or file names. The vault's existing process lock, conditional removal and account-removal fence apply. Account removal now clears this new private request namespace too.

Cold loading resolves that exact request without starting a preparation or a copy. Continue is explicit. Stop prevents the next copy and ignores a late result; the admitted private network operation may still finish, and the saved request remains. The app hides private progress when its view/context closes. Wrong-account responses, changed source scope/token, unavailable inventory, malformed progress, unrequested policy/receipt facts and incomplete manifests cannot produce consent. A 101-file peer case verifies one initial and one final paging pass, rather than reloading all pages after every copy. This is a bounded call-count check, not high-volume provider performance acceptance.

Consent binds the complete ready manifest to the original request, plan, exact count and bytes. Both clients send the explicit file policy through the existing signed project review, preserve it in the saved transfer command and compare every file receipt fact on cold retry. Inventory or a preparation alone never authorizes sharing. Confirming still uses the existing saved transfer request and server's atomic project/custody transaction.

The transfer screen exposes preparation only for the implemented, enabled server capability. Existing unsupported references remain blocked. Saved preparations remain reachable from Account even when the original team navigation is unavailable. Checking, cancelling or clearing private recovery is separate from the final project move, and a completed transfer cannot be cancelled as an unused preparation.

## Lost first response

The service adds `resolve` and `cancel_request` for the entire frozen preparation body. Resolve cannot create work. Cancelling an identity whose first reply was lost creates a closed, actor-bound record before any late prepare can reopen it. Changed bodies conflict; outside accounts cannot inspect that record. Existing plans use their normal fenced cancellation, retaining quota until provider cleanup is proved. These recovery actions stay available when fresh preparation is disabled. A file policy also checks the existing project-adoption gate before enabling a native confirmation.

This does not claim terminal producer recovery or provider erasure. A private writer already admitted before cancellation still needs the existing settlement/maintenance proof. Missing objects and elapsed time are not deletion or completion evidence.

## Verification

Each owning repository passes **100 genuine local Auth/PostgREST/Storage service checks**, including the new resolve/cancel-before-create/late-prepare boundaries and the existing atomic file transfer, original privacy, 5 MiB inline compatibility and download access checks. [Own full schema evidence](full-schema.json). All owned containers and tmpfs data are removed; each independent migration history is replayed. The existing pg_net placement warning is unchanged. This uses the pinned file-backed provider and loopback transport; it does not establish hosted S3, release TLS or deployed Edge behavior.

Each owning Core suite passes **114 selected tests**: 14 new native file-contract/model/transport cases, 59 existing adoption cases, 5 inventory cases and 36 existing upload/resolve/download regressions. The new fixture is exported only after successful genuine local service verification. In-memory secure-item and transport peers cover saved first-reply loss, cold read-only recovery, exact explicit resume, cancellation, secure-write failure before networking, late/foreign/context refusal, another window clearing recovery, paged scaling, literal gateway routing and explicit consent through Backend. The actual transferred-file receipt also decodes through the existing upload recovery codec. These peers do not establish OS Keychain encryption/locked-storage or native runtime acceptance.

The canonical file-ledger attachment name now follows its immutable intent. Per-reference display names remain intact in tasks/discussions. This keeps transferred copies compatible with the existing file-recovery decoder instead of requiring a separate receipt interpretation.

Each handler suite passes **27 tests**, including default-off publication, recovery/cancellation while disabled, strict committed/empty-cancelled facts and the prior write/readback boundaries. Both current app builds compile and pass strict signature verification in the reused isolated hosts. The iOS builder's recorded long-note variant selects the existing build host only: no note or file UI journey was run. [Build evidence](signed-build.json).

## Still required

Extend the scoped iPhone peer journeys recorded below to Mac/iPad and wider disabled/access-changed availability, largest text, keyboard and speech. Accept provider-integrated native flows separately. Verify native secure storage and multiple-window behavior, rate-limit/high-volume behavior, combined file/recording/integration policies, wider lifecycle/history/account removal, legacy/unavailable references and other ownership/realm directions. Hosted and producer-terminal/maintenance acceptance remain separate. The new code is built; the full everyday feature is not yet accepted or enabled.

On-device-only assistance and deferred further iPhone installation remain the user's current choices. Normal phone34/Mac14 and frozen packages remain unchanged. Only reusable test/compiler outputs are cleaned; no real tasks, Keychain entries, backups, Docker volumes or unrelated devices are deleted.

## Reproduce

Run in the owning repo, with heavy platforms serialized:

```sh
python3 Scripts/check_test_storage.py --path /tmp
deno test supabase/functions/project-files/handler_test.ts
deno run --allow-run --allow-env --allow-read --allow-write --allow-net=127.0.0.1 Scripts/Database/test-full-schema-project-file-transfer.ts /tmp/taskfold-native-files-own.json --export-native-fixture
swift test --scratch-path ~/Library/Caches/TaskfoldBuild/core-ios --filter 'ProjectFilePreparationTests|TeamProjectAdoptionTests|TeamProjectFileInventoryTests'
```

The Mac repo uses its own core-mac scratch path. Each repository owns its app/project/package bindings, service, migration, captured fixture and tests. No sibling checkout is required.

## Follow-up: responsive Stop and paused service

Stop now immediately releases the preparation controls, preserving the exact saved request. Continue can reconcile that same request without waiting for the previous HTTP response; a late response cannot overwrite progress or clear the newer run’s busy state. Closing clears the private screen immediately while retaining recovery. A paused attempt cannot provide sharing consent. An already admitted private copy may still finish on the server; Stop does not assert server cancellation or deletion.

When a fresh project inspection says file transfer is unavailable, the screen hides Continue and sharing consent, explains the pause, and keeps read-only Check and explicit Cancel available. Review and final confirmation use the same inspection-bound consent check. Existing server validation remains authoritative.

See [follow-up verification](controls-verification.json) for the current focused checks and build results. The full native interaction, accessibility and provider acceptance listed above remains pending; no normal gate or installed app changed.

## 6 November — native consent, cancellation and cold recovery

The final review and success file-count rows now expose a single explicit accessibility label/value. The real iPhone accessibility query previously returned an empty value despite a visible count; the corrected rows return the exact count. Saved-transfer recovery also identifies the reviewed copies and explains that Retry confirms those same copies while originals remain private. This verifies the accessibility properties, not a human VoiceOver listening check.

The owning iOS repository now records three accepted native journeys in the existing signed iPhone Simulator host. The tests use the production transfer screens, Backend transport, Keychain-backed command vaults, cache and workspace refresh against a network-blocked synthetic peer:

- Preparation leaves sharing unchecked and Review disabled. Explicit consent permits final review; Back clears consent. An applied confirmation with a deliberately lost reply survives process termination; cold Retry submits the exact original command, produces one transfer, exposes the saved/result counts and refreshes the destination file reference with no queued writes.
- A lost first preparation reply survives closing/relaunch. Cold checking issues no new preparation or copy. Explicit Cancel leaves all source tables unchanged and no saved recovery after another relaunch.
- Stop releases Close while a copy response is held. Closing/relaunch preserves the same preparation request. Only explicit Continue prepares the ready result; cancellation then clears recovery without a transfer.

The captured genuine service file contract is adapted onto the existing synthetic native workspace IDs. The peer performs no provider copy, SQL transaction or real account access. The existing 100 genuine local service checks remain separate evidence; these UI runs do not replace them. All three standard-size runs pass with no runtime warnings and restore the Simulator's prior text size and shutdown state. The first oversized-text attempt exposed an offscreen lazy-control assumption in the harness; the tests now scroll to the control and explicitly record/restore text size.

[Current owning build evidence](native-ui-verification.json). The Mac screen/fixture builds and signs successfully; the iPhone UI results are context from its owning repository, not Mac runtime acceptance. The existing Mac host's identity, session namespace and private app-group binding are verified before preparing its synthetic file scenario. No sibling repository is required for the Mac build or fixture.

The complete iPhone consent/review/confirmation-loss/cold-retry journey also passes at the largest accessibility text size, with the final/result counts readable in the scrolling list. The Simulator restores its previous text size and shutdown state. This does not establish human speech, every other largest-text control, Mac/iPad runtime or an integrated provider journey. Repeat fixture preparation preserves the timestamps of unchanged project, Info and resource inputs in both owning hosts; this is verified directly to avoid unnecessary build invalidation.
