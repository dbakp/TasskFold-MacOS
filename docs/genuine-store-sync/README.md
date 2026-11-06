# Genuine local Store offline queue and cold recovery

Reviewed 3 November 2026. The actual independently built app process runs the production Backend sign-in, Store.authenticated, normal Store.sync/workspace read/merge/persist, Store.save and persisted Snapshot queue. Real pinned local Supabase Auth, PostgREST, PostgreSQL and Storage are initialized from every owning migration. The reserved DEBUG fixture seeds no synthetic HTTP sessions or table replies.

## Verified flow

Each app independently passes 15 driver checks across five terminated/relaunched app processes:

1. **Initial:** Sign in to the real disposable Auth account; finish actual new-account Store sync and persist its genuine task/profile in the account UUID cache.
2. **Queue:** Reopen offline, save a description through Store.save, and verify exactly one mutation and matching Store/disk state. The actual server must remain unchanged.
3. **Loss:** While the app is closed, change the remote task title and edit a sibling through the real child RPC. Reopen the exact original queue, perform its actual write, and drop the real successful HTTP reply after commit. Preserve the unchanged original queue on disk and the app's honest connection-interruption notice.
4. **Replay:** Reopen the same persisted request, retry, and clear it only after confirmation. Read/merge/persist the local description plus the remote title and sibling edit.
5. **Verify:** Reopen offline again; require the final cache and empty queue without reconstructing them from a new server read. Preserve the task generation and opaque nested JSON.

The driver directly verifies that the synthetic root promotion returns record authority, then verifies the original generation still owns that authority after the complete Store flow. Its remote sibling edit exercises the real separate-record RPC; the app's queued change is a root description, not a durable independent child-field journal. Every phase checks actual Store memory against its actual account cache. Pending payload fingerprints and driver deep comparisons bind cold retry to the original request. Reports bind app source and binary hashes; all current-source, build and signature checks are retained.

## Isolation and limits

The DEBUG factory requires both exact reserved bundle identity and explicit flags. It bypasses unrelated legacy synthetic bootstraps and permits the ordinary Store.sync path. The production HTTPS guard remains unchanged: a test-only URLProtocol forwards this one reserved HTTPS origin to the owned loopback gateway, preserving actual request/reply bodies and status codes. The transport can refuse network requests or drop one successful patch reply; it supplies no table/Auth result. This is not genuine TLS or release-network acceptance.

Real Auth-issued sessions are stored in a nonce/account-bound private test file so the cold process can reopen them without using the Mac user's Keychain. Only disposable configuration/session files are removed at cleanup; the test app is closed, owned services are removed and the iPhone Simulator's initial state is restored. This does not establish protected Keychain/session storage. Native data-engine acceptance is programmatic, not a visual, keyboard or spoken walk of the normal sign-in/editor UI.

No production schema, provider or normal-use switch changed. Existing full-schema API tests remain separately recorded in `../full-schema-sync/`; their 15 advisor warnings remain open. Independent child-field/structure journals, complete app adoption/migration, new/shared account and multiple-window/background/access-loss directions, actual file/audio handlers and wider native/accessibility/privacy cases remain. No hosted rollout, remote reminders, old-client retirement or distribution was enabled.

## Reproduce

Build/sign the exact isolated DEBUG app/test host with current owning sources, then choose `ios` or `mac` as the platform and run, for example, `node Scripts/Database/test-native-store-sync.mjs ios /tmp/taskfold-native-store-<unique>.json` from its own repo. The driver checks source freshness, strict signatures, the 20 GiB storage floor, owning bundle/device paths and exact Mac executable ownership. It installs before starting the services. Pinned runtime images and Supabase CLI requirements are documented in `../full-schema-sync/`. Failed setup attempts retain their qualification in `attempts.json`; no failed run is reclassified as a pass.
