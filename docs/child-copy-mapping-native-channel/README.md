# Local database channel for native mapping acceptance

The reserved DEBUG host can now send mapping review, comparison, preview, save, check, close and original RPCs to an owned PostgreSQL fixture. The fixture loads this repository's actual candidate migration chain. SQL executes as the authenticated synthetic actor/session, not the database owner. No hosted schema, account, credentials, normal flags or network permissions are changed.

The app transports original request bytes through a bounded file channel. The helper returns the database's canonical JSON text as base64 without parsing and re-encoding the response. It publishes the committed root/history before making the response visible. This keeps the native save/recovery/export path connected to the actual transaction rather than implementing a second mapping algorithm in the old mock.

Only the reserved app bundle IDs plus existing synthetic test arguments and `--child-mapping-sql-native` enable it. Its own `Child mapping SQL native peer` app-support folder separates it from earlier test work. Starting without a prepared fixture fails closed; reset arguments cannot overwrite SQL state. The channel restricts supported RPCs, root/generation/account, payload size, file identity and per-run nonce. It rejects symbolic-link request files. Database errors return only their code; no passwords, tokens or SQL diagnostics cross into the app. Normal HTTP/TLS behavior is unchanged.

The helper refuses a nonempty or symbolic-link directory, creates no listener or published port, stops after 15 minutes or a local `stop` marker/SIGTERM, removes its readiness file and force-removes only its uniquely labelled owned database. The retained synthetic state can be inspected after shutdown. Existing native mocks still refuse mapped writes unless this separate channel is explicitly enabled.

## Reproduce

Run each repository independently, with no sibling files as inputs:

```sh
node --test Scripts/Database/test-child-mapping-native-channel.mjs
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/run-child-mapping-native.mjs --smoke
```

For a native run, prepare an **empty**, reserved `Child mapping SQL native peer` folder inside the isolated app's Application Support directory, then run:

```sh
node Scripts/Database/run-child-mapping-native.mjs --directory '/absolute/app-support/Child mapping SQL native peer' --lose-first-save
```

Wait for the helper's `ready` result. Launch the previously authorized isolated host with `--uitesting --team-editor-testing --child-fields-native --child-adoption-saved-copies --child-mapping-sql-native`. Do not pass `--child-fields-native-reset`. Keep the helper running across cold app launches. Its optional lost-save reply is delivered only after a successful database commit; subsequent checks/replays use the real receipt. This setup is local synthetic acceptance, not genuine-account/cloud HTTP acceptance.

## Verification and limits

`verification.json` records this repository's source hashes, automatic channel/refusal checks, actual local transaction checks and build scope. The SQL smoke exercises mapped save, a lost response, recovery/replay with write gates closed, unchanged exact original bytes, safe request refusal, one receipt and a neutral history event. Separate file-channel tests cover unsupported/malformed/stale requests, canonical number/Unicode wire preservation, pre-response publication and symbolic-link safety.

**Native controls are not accepted by this milestone.** The Mac was still locked when inspected, so no app was launched. Search/cancel, keyboard/speech/large text, partial and complete cold review, editing choices, native one-save recovery and native original-export/readback still need full app interaction and an independent saved-data verifier. No progress checkpoint is promoted to Verified for this test connection. Wider recipient/recurrence, editable-cache and shared-custody gaps remain unchanged.
