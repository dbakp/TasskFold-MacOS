# Native history matching, saved recovery and exact original export

The iPhone Simulator now completes the real local-database workflow through native controls. Both apps also have a stable history chooser presentation, an always-visible iPhone search field, adaptive primary/secondary candidate text and a saved confirmation that stays selected while its original is exported. The chooser is owned by the repair screen instead of a reusable List section. Refresh, account/scope changes and privacy cleanup dismiss it before discarding its context.

## Accepted phone scope

One iOS-repository test passed on the existing iPhone 18 Pro Simulator, iOS 27.0, ordinary text size and dark appearance. It uses three synthetic existing task histories in a personal Inbox root and selects the saved snapshot with explicit **Keep recorded details** for each history:

- Open the actual SQL-backed comparison, search for no match and cancel without adding a choice.
- Search and choose one recorded identity/lifecycle, close the app and recover that incomplete review without defaulting the other histories.
- Match the other histories, preview the actual SQL proposal, return to edit without losing choices, preview again and recover the complete review after another cold launch.
- Confirm one actual save, deliberately lose its successful response, cold-launch, check the original saved request and recover the same database receipt. Cold-launch again and retain the confirmation.
- Fetch the archived original through the actual authenticated fixture RPC, save it using the native Files picker to the isolated app's observed local Documents, retain the saved confirmation and read the file again after another cold launch.

The independent verifier decrypts only this synthetic journal using its published test key and compares it with direct database snapshots and the request/response trace. It proves one committed mapping and saved request, unchanged bound incarnations and prior history, a single neutral reconciliation event, no manufactured work credit, all three original copies and an exact **9,809-byte** native file. SHA-256: `ff4f78fab2512b466b959d7cb94d6ec31be1e5e9a736d3caf4cbc2d26423b8e9`.

This is a local PostgreSQL fixture under its authenticated actor/session, not hosted or genuine-account HTTP acceptance. No normal-use flags, hosted schema or real tasks changed. The owned database was removed and the phone shut down afterward.

## Evidence

- `phone-test-summary.json`: one native test passed, no failures or skips.
- `phone-saved-data-verification.json` and `phone-fixture/`: actual synthetic database/journal/trace/file readback. Both repositories own their verifier and a copy of the recorded iOS-only evidence; this does not claim Mac runtime acceptance.
- `verifier-refusal-checks.json`: an extra exported byte, a damaged encrypted journal and a foreign saved root are rejected, with any earlier successful report invalidated first.
- `verification.json`: current source/isolation correspondence, app/runner builds and strict signatures, five channel/refusal tests and 11 actual SQL/channel checks independently per repository. The extra SQL case exercises the target-discovery RPC used before native review.

Reproduce the saved-data proof without a database or sibling checkout:

```sh
node Scripts/verify_child_mapping_native.mjs \
  docs/child-copy-mapping-native/phone-fixture \
  docs/child-copy-mapping-native/phone-fixture/export/Taskfold-original-2026-11-01.json \
  /tmp/taskfold-native-mapping-readback.json
```

For a new native run, build the reserved host and run `testChildMappingSQLNativeSearchColdReviewSaveAndOriginal`. After installation the test creates an empty reserved channel and a `child-mapping-native-ready.request` marker in its Application Support. Start `Scripts/Database/run-child-mapping-native.mjs --directory <that-channel> --lose-first-save --follow-simulator-container`. Xcode can rename the container at first launch; the helper follows only its unique owned nonce within that same Simulator, refusing missing or ambiguous ownership. Keep it running across cold launches and retain the resulting snapshots before cleanup. The native test refuses an existing destination file or nonempty channel; preserve earlier synthetic evidence before another run.

## Still open

Mac controls remain unaccepted because the desktop is locked; the app/runner compile and sign. iPad, new and retired identities, changed lifecycles/recurrence/recipients, stale and lost-access choices, account/window/privacy, keyboard, VoiceOver, largest text and large libraries still require wider acceptance. Native navigation into an extra subfolder in this Simulator's system Files picker was unreliable; only the observed local Documents destination is accepted here. Other locations and providers remain unverified.

Broader exact editable-cache, complex history and shared file/discussion custody work is still unfinished. Normal use stays disabled and all agreed rollout/configuration deferrals remain. This milestone does not increase curated completion bars.
