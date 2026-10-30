# Reviewed older-subtask adoption: Store and native candidate

This phase connects the reviewed adoption client to Store and the native Account workflow. The ordinary feature flag remains absent and nothing is deployed. This is a candidate integration milestone, not completed storage migration or permission to enable it for everyday use.

## Implementation

- Account/origin-owned encrypted request history, current-context review and scope-safe titles; saved status/Stop/history remain discoverable if the send gate is turned off.
- Admission checks root edits, pending field/completion/structure/transfer actions, hierarchy drafts, open editor sessions and preserved encrypted task-editor drafts. Draft inspection does not modify or retire a draft. Unreadable or affected drafts refuse the upgrade.
- Native explicit review, ordered preview, Upgrade, retained confirmation, original-request retry, Check and stop, and deliberate local-history removal.
- Read-only diagnosis and original-byte JSON export. The on-screen raw preview is bounded; omitted oversized sources are not exported as partial or null data. Repair is not implemented here.
- Real account-removal cleanup is wired to the new journal. Genuine account-removal/Keychain acceptance remains separate.

## Recorded checks and their limits

The own-project selected Core suite has 562 passing cases, including 22 adoption cases (four added admission cases). Each repo’s actual prior SQL-wire fixture matches its compiled test bundle. SQL was not rerun because this phase changes no service contract. Both isolated app/test products build and pass strict development-signature checks.

The four native journeys are identified in `TaskfoldUITests/AudioCommentUITests.swift`:

1. `testChildAdoptionNativeLargestReviewUpgradeAndColdStatus`
2. `testChildAdoptionNativeLostReplyColdRetryUsesOriginalRequest`
3. `testChildAdoptionNativePrivateDraftProtectionAndUnappliedStop`
4. `testChildAdoptionNativeMalformedReviewAndOriginalExportCancel`

Use the reserved isolated host identity, its synthetic fixture key and only the isolated host’s adoption flag. Launch modes are `--child-adoption-native`, `--child-adoption-lose-reply`, `--child-adoption-unapplied` and `--child-adoption-malformed`. The test helper supplies the remaining reserved launch arguments; ordinary app identities refuse this fixture. Run the individual `TaskfoldUITests/TaskfoldMacUITests/<method>` selectors with `test-without-building` after rebuilding that own-source isolated host. Four selected methods must actually run, with no skipped cases. Reuse the existing devices and run platforms sequentially. `-collect-test-diagnostics never` omits whole-Simulator sysdiagnoses; per-test attachments and failure logs are still retained.

The file-backed synthetic peer establishes native controls, persistence and recovery behavior. It does not establish server authorization/atomicity or genuine Keychain availability. The prior real PostgreSQL/RLS evidence is in `../reviewed-child-adoption/`. Full synthetic-peer source-root field hashes are compared before/after, and the actual encrypted draft-file hash is compared after refusal and cold relaunch. The fixture key is deliberately separate from real app secrets.

Opening and cancelling the real export picker does not prove a saved export’s byte-for-byte readback or an external file-provider transfer. Native malformed-content repair, all older formats, larger workflows, shared attachment/discussion custody, real accounts/secure storage, multiple-window/background behavior and VoiceOver remain open. Cross-journal races and broader concurrent admission still need implementation/acceptance before enablement.

The Mac owns its Store, views, fixtures and four compiled native tests. Its native journey was not run because the screen is locked; phone/tablet results are not borrowed as Mac acceptance.
