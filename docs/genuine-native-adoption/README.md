# Genuine native reviewed legacy adoption

Reviewed 3 November 2026. The actual independently built owning app passes 16 checks across four separate processes using genuine local Auth/REST and all owning database migrations. This is the normal Store review/discovery, adoption model, admission, encrypted migration journal, Backend public migration endpoint and final Store sync/cache/record-read path. The driver does not call the private adoption or promotion procedures to seed authority.

## Accepted sequence

- Create one synthetic valid legacy JSON hierarchy with three unique authored node IDs, a nested completed child with its saved completion timestamp, and opaque nested metadata. Verify that no separate-record authority exists.
- Sign in through the actual app Backend and read a genuine eligible migration review. Preserve a synthetic unsent root-editor draft through the actual encrypted BackupVault. Migration queueing must refuse it, leave the journal empty, retain the exact decrypted draft and leave its ciphertext byte-for-byte unchanged. Close only that synthetic preserved edit, then queue the same reviewed migration through the normal admission path. Live review/admission remains online; no offline-authority shortcut is claimed.
- Close the app with its original migration durably queued and authority still absent. Change the root title remotely, keeping the reviewed tree/identity unchanged. Cold reopen, send the original request through the actual model and drop one actual successful RPC reply after commit. The server must have authority while the device retains attempted state with no invented result.
- Cold retry the unchanged original command/review digest. Recover the real applied/replayed proof, refresh actual Store data and read all three separate records through the normal client decoder. Cold reopen offline again with that same proof and cache. Require exactly one applied migration receipt and exact original tree, completed flag/timestamp, opaque fields, generation and root description; the remote title survives.

The client decoder binds record keys to authored IDs and requires its materialized tree to equal the actual cached source. Driver comparisons additionally require the complete pre-migration tree in both server and final cache, unique records, the saved nested completion timestamp, unchanged existing task_activity rows and no ordinary root mutation queue. The fixture does not synthesize new history or claim nonempty older activity coverage from an empty activity table.

## Scope and limits

This accepts one valid legacy hierarchy and the preserved-edit/lost-reply/cold recovery path. It does not accept every older format, duplicate/foreign identity mapping, mixed histories, files/audio, shared-workspace migration, changed digests, concurrent edits, revoked access, multiple windows, larger libraries or hosted rollout. Existing identity/history and recording proofs retain their separately documented scope. Ordinary migration gates remain disabled; no hosted service or release setting changes.

Native acceptance here is programmatic controller/data-engine work, not a visual/keyboard/VoiceOver walkthrough of the migration screen. The reserved DEBUG factory uses the existing test transport to forward real local responses and drop one actual successful reply. Its nonce/account key exercises actual encrypted journal/BackupVault I/O, while genuine issued sessions use the existing private disposable test file. Protected Keychain access, TLS/release session handling and pg_net placement remain separate.

## Reproduce

Build/sign the current reserved isolated host, then run `node Scripts/Database/test-native-store-sync.mjs mac /tmp/taskfold-native-adoption-<unique>.json adoption` from this repo. The owning-source/signature checks, 20 GiB floor and scoped process/service cleanup apply. Current hosts/products and the existing iPhone Simulator are reused; no new device/build tree is created. The test app/services are closed, disposable credentials/configuration removed and the initial iPhone Simulator state restored. Only the explicitly created synthetic preserved draft is closed to continue the test.
