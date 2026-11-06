# Native protected recording and recovery integration · 5 November 2026

The own signed iPhone app passes 24 checks, and the own signed sandboxed Mac app passes 23. Each uses genuine disposable local Auth, REST and Storage services plus the production audio handler over a validated loopback TLS connection. The same application session, AAC decoder, recording vault, publication flow and Backend remain in use. Source hashes, binary hashes, exact assertions and service removal are retained in the two verification reports.

## What is accepted

- Five separate cold app processes perform create, wrong-CA refusal, committed upload with a lost reply, confirmation/download, and offline reopening. A sixth process removes only the synthetic recording/recovery folder.
- The existing `SecureSession.read` and `saveAsync` APIs persist and reopen the actual local Auth session through native Keychain, without a session-file fallback. A fresh nonce scopes only the test service names. Ordinary service names, encoding, accessibility settings and APIs stay unchanged.
- The actual per-account `BackupVault.deviceKey`, AES-GCM save and load paths recover one synthetic task. Key fingerprint and ciphertext stay identical through all five cold processes; the original private recording remains byte exact and mode 0600. The iPhone driver also compares its own raw-file hash with the app report.
- The original reviewed publication operation survives failed TLS and a lost success reply. Confirmation and download do not send a second upload; unrelated task data stays exact.
- Each repo independently passes three focused Core regressions for serialized background session writes, encrypted backup round trip, and tampered/wrong-key/foreign-account refusal.

The encrypted recovery copy and the private recording/publication journal are distinct stores. This does not assert that recording journal files are encrypted by BackupVault.

## Scope boundaries

The Simulator returns no file-protection attribute. The initial attempt deliberately failed that assertion; its retained report documents the boundary. The accepted run reports `hardwareFileProtectionAccepted: false` and the actual unavailable attribute. This is native Keychain/API integration, not proof of physical lock/reboot enforcement or distribution trust. iPad, interactive audio controls, wider account/access/lifecycle cases, native adoption/custody transfer, legacy/other realm directions and hosted S3 remain separate. Advanced normal-use gates stay off.

The Mac-only debug input bridge reads an exact nonce-matched private temporary directory and emits a metadata-only report through stdout. The isolated host's old read-only `/` exception was narrowed to `/private/tmp/`; no normal app entitlement changed. The driver never reads or writes the Mac app's protected container externally. This closes the prior runtime acceptance gap through a different controlled path; it does not claim removal of older inaccessible fixture files.

## Cleanup and daily apps

Both owned apps, handlers, all five local service containers and their networks are closed/removed. TLS/control folders and current synthetic media/recovery files are removed. Test-only Keychain session and backup items are deliberately retained under the exact nonsecret namespaces in each report, including the failed initial iPhone run; no normal Keychain item is deleted. Local tokens cease to be useful when their disposable services disappear.

The normal Mac app and installed iPhone build are unchanged. Prepared optimized Mac22/phone34 archives are frozen earlier inputs, already verified independently; these later debug-test edits are not represented as a new package-source match. The iPhone update is authorized but the device is currently unavailable. The Mac update still awaits its saved-draft window.

## Reproduce

Build each current reserved signed host, then run its own runner separately:

```
node Scripts/Database/test-native-audio-publication.mjs ios /tmp/taskfold-new-protected-ios.json --keychain
node Scripts/Database/test-native-audio-publication.mjs mac /tmp/taskfold-new-protected-mac.json --keychain
```

Use a fresh report filename. The default mode remains the earlier file-session fixture; it does not establish native Keychain acceptance. Source binding includes Backups and both production audio handlers. Tests use synthetic accounts only and do not change hosted schemas or user data.
