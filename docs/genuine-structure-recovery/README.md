# Native hierarchy-journal recovery and branch history

Reviewed 3 November 2026. Each independently built owning app passes 26 driver checks across eight separate processes against genuine local Auth, PostgREST and the complete owning database. Production Store-created hierarchy presentation, encrypted action journal, sender, typed move/inverse construction, Backend RPC and Store sync/cache persistence are exercised programmatically.

## Accepted sequence

- Sign in to the real disposable local Auth account and read a trusted synthetic record-authoritative hierarchy. Save a move of a whole branch, including its nested descendant, underneath its sibling while offline. The action is durable, the root mutation queue stays empty and the server tree is unchanged.
- With the app closed, edit the root title and destination sibling's title remotely. Cold reopen the original queued action, send it and drop one real successful hierarchy reply after commit. Keep the original action in attempted state; require the exact expected nested tree and one server structure-revision advance.
- Cold reopen and retry the same action. The real service returns its original replay receipt; confirm it in the encrypted journal and refresh the actual Store/cache. Cold reopen offline again and require unchanged confirmed history and receipt.
- Cold reopen, read current hierarchy and use the actual presentation's queueInverse/send flow to Undo. A new confirmed action restores the original branch order while retaining the remote titles and exact opaque/nested fields. Cold reopen offline and require the same history and cache.
- Cold reopen and reverse that confirmed Undo through the same flow. Redo is a fresh move bound to Undo, not a replay of the first move. Cold reopen offline again. Require the exact moved tree, three original unique nodes, three distinct action IDs and exactly three total structure-revision advances: move, Undo, Redo. Retry must add no extra move/revision.

Driver comparisons use the genuine pre-action server projection as the tree baseline; only the explicitly requested parent/order and remote sibling title may differ. Exact cache/server tree comparison preserves the complete nested branch and opaque values. Root description, generation and record authority stay intact. The original move fingerprint and body remain unchanged throughout all eight processes. Reports bind relevant owning sources, strict signatures and actual binary hashes; each phase reloads the production journal and checks actual Store memory against disk.

## Limits and isolation

This is programmatic native data-engine/controller acceptance, not a visual, keyboard or VoiceOver check of the organizer or system Undo menu. Read/write/completion/structure switches are enabled only in the isolated build and disposable local database. Trusted adoption/promotion does not establish the complete app migration. No ordinary gate, hosted service or rollout policy changes.

The existing reserved DEBUG transport forwards actual local service responses and drops one successful RPC reply; it supplies no Auth/table/RPC fixture. A nonce/account-bound disposable key exercises the real encrypted journal I/O without accepting protected Keychain behavior. Genuine Auth-issued sessions use the existing private disposable test file. TLS/release session handling, competing structure edits, stale/revoked/shared-account/window/background directions, insertion/deletion/archived-Undo histories, full legacy adoption and file/audio migration remain separate. The known pg_net placement warning remains. Existing native field and root recovery evidence is retained separately.

## Reproduce

Build/sign the reserved DEBUG app with current owning sources, then run `node Scripts/Database/test-native-store-sync.mjs mac /tmp/taskfold-native-structure-<unique>.json structure` from this repo. The original root and child-field driver modes remain. Source freshness/signatures, the 20 GiB storage floor, scoped process cleanup and service ownership checks apply. The test app and disposable services are closed, credentials/configuration removed and the iPhone Simulator's initial state restored. Reports contain synthetic data only.

Later scoped field/hierarchy conflict refusal and reviewed replacements are recorded in [the follow-up](../genuine-conflict-review/README.md). The earlier lost-reply/history evidence above retains its original scope.
