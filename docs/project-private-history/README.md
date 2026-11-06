# Removed recordings stay private during project adoption

Reviewed 3 November 2026. Whole-project transfers remain disabled in ordinary use and unfinished. This checkpoint adds the separately disabled `move_recordings_keep_removed_private_v1` policy in this repository's own service, client, UI and tests.

## Behavior

A personal project can move published recordings to a team, stop unfinished sends and keep removed recordings private, with separate explicit choices. Review, saved requests and exact receipts bind all three counts. A removed-only project has counts 0 published / 0 unfinished / 1 removed; it does not invent a move or stop action. Changing access or going Back clears approval. The primary button uses the concise “Transfer to team” label, wraps vertically at large text sizes and retains the exact project count in its accessibility label. Existing published-only and stop-only request shapes remain compatible.

Removed recordings are neither republished nor assigned team custody. Their original retired ledgers, private copies and cleanup schedule stay intact. Missing original tasks, old generations or already-removed provider bytes do not prevent keeping that history private. A private fence stores only the opaque operation ID and creation time; it does not duplicate account or team identities. Cleanup can purge the original bytes while the fence continues to prevent that old operation reopening. A fresh copy requires a new operation and fresh audience approval to publish.

The new capability requires the existing transfer/audience/bucket gates and its separate default-off history gate. If unfinished sends exist, their independent gate must also be enabled. Foreign/team custody and unavailable recordings remain unsupported. No hosted service or normal-use gate changed.

## Service and client evidence

Each repository passes 233 checks through actual local PostgreSQL and the production HTTP handler, using synthetic Auth and an in-memory byte provider. The final two-column private-fence schema was rechecked in both repos. Tests cover mixed counts, removed-only adoption, explicit consent/count binding, stale inventory, forced rollback, exact replay with gates paused, old stop-only connection pausing, private access, cleanup, refused resurrection and a separately approved new publication. No new advisor keys occur against the seven-warning synthetic baseline; owned services are removed. This is not genuine Auth/Storage or full hosted-schema verification.

Each repository passes 91 focused client tests, including eight new cases using its own captured service contract: exact three-count parsing, removed-only review, old wire compatibility, explicit policy, saved metadata consistency, receipts, strict capabilities and cold exact retry through a memory secure-item adapter. This is not a native Keychain audit. An initial new test assertion used the wrong expected type; it was corrected before final successful runs.

## Native and build evidence

See verification.json for the final build and native outcome. The owning iPhone case covers removed-only consent, review, Back/reset and cancellation with unchanged task tables and no transfer command. Its initial interaction run passed, but screenshot inspection found a clipped long primary label at Accessibility XXXL. The label was shortened and given explicit multiline layout; the changed build passed the same case again and its fresh screenshot was inspected. Both independently owned app/test-runner builds and strict signatures pass. No previous unchanged phone case or Core/service suite was repeated for the label-only fix. The interrupted older Mac build is not counted as acceptance. It uses a synthetic network-blocked native peer; actual local service checks are separate. It does not accept native integrated commit, history cold retry, Mac/iPad runtime or audible VoiceOver.

## Still required

- [ ] Legacy, foreign-custody, other mixed recording histories and other realm directions.
- [ ] Integrated native service/Storage acceptance, Mac/iPad transfer controls and wider lifecycle/account/window/display/accessibility cases.
- [ ] Genuine accounts, hosted schema/provider compatibility and real delivery/reinstall cases in their respective checkpoints.

The full Px goal remains active. Previously accepted unchanged phone consent/retry cases were not repeated for this extension. All user deferrals remain in force.
