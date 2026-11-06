# Original subtask export: native delivery and cold readback

Final recorded scope is in `verification.json`; broader acceptance remains unfinished. This phase verifies the original-content copy needed before adding reviewed repair. It does not implement repair or enable independent subtask storage for everyday use.

The reserved debug fixture delivers one frozen raw JSON source directly in a review RPC response. That source includes `9007199254740993`, `1e1000`, composed and decomposed Unicode keys, nested opaque fields and an older string item. The expected source sidecar is independent of the typed client parser and FileDocument. The ordinary legacy cache does not have to represent those opaque values for this export-pipeline fixture. This is not proof of metadata-first discovery or synchronization of every older real-server payload.

The app’s normal FileDocument performs the write through the system picker. The debug hook records only the URL actually returned by that picker after the existing scope check; it never writes the exported destination. The test compares the selected file with the independent raw-source bytes, checks the confirmation, relaunches, and compares the file again. The fixture refuses unfamiliar data in its reserved destination instead of deleting or overwriting it. Synthetic fixture receipts/sidecars are unavailable to ordinary bundle identities and absent from Release behavior.

The same phase reruns the largest review/upgrade/cold-status journey and malformed export cancellation. On iOS the sheet uses an inline title so its name stays readable at accessibility sizes. Reading static confirmation text is checked geometrically; actionable controls still require an actual hit target.

Native methods in `TaskfoldUITests/AudioCommentUITests.swift`:

- `testChildAdoptionNativeLargestReviewUpgradeAndColdStatus`
- `testChildAdoptionNativeMalformedReviewAndOriginalExportCancel`
- `testChildAdoptionNativeOriginalExportSaveAndColdReadback`

The iOS test class is `TaskfoldUITests`; the Mac test class is `TaskfoldMacUITests`. Both use the target `TaskfoldUITests` and the reserved isolated host identities. Save mode is `--child-adoption-export`. Test products must be rebuilt from that repo’s current source and isolated flag configuration. Select those exact three methods for `test-without-building`; reject zero tests or skips. Reuse the existing devices sequentially and omit whole-Simulator diagnostics with `-collect-test-diagnostics never`, retaining per-test logs/attachments.

Limits: this is synthetic local-Documents delivery, not a cloud file-provider transfer, real-account/Keychain test or arbitrary older-payload discovery test. Raw-original exports are content copies, not full-workspace restore packages. Reviewed repairs, server/cache discovery of unrepresentable older payloads, broader account/window/background/VoiceOver checks and full shared custody remain open. No SQL contract is changed or rerun. Core migration sources are unchanged; prior own-repo 562-case regression evidence remains in `../reviewed-child-adoption-native/`. The ordinary feature flag remains absent and nothing is deployed.

Mac XCTest initialization failed before launch. The user then authorized Terminal launch, allowing direct Mac move/cold-Undo and upgrade/cold-status checks; their evidence is owned by the Mac repo. Actual Mac original-export Save/readback remains open. Phone/tablet acceptance is not borrowed.
