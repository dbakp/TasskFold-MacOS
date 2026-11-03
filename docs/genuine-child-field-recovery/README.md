# Native durable subtask field recovery through real local APIs

Reviewed 3 November 2026. The actual owning app passes 14 driver checks across four separate processes. Genuine local Auth, the entire owning database history, PostgREST and Storage run in the existing isolated full-schema runtime. This uses the production Store child-record read, recovery-model factory, encrypted journal, sender, Backend RPC and final Store.sync/read/merge/persist path.

## Accepted flow

1. Sign in to a real disposable local Auth account, read the reviewed/promoted synthetic root, prepare a child description change from the genuine child read, then turn transport offline and save through the actual recovery model. Exactly one queued journal entry has the original command and baseline. It never enters the ordinary root mutation queue, and the server remains unchanged.
2. With the app closed, change the root title and a different child remotely. Cold reopen the exact journal, send through the actual Store-created model and drop one real successful child-edit reply after commit. The real server contains the description; the device retains the exact command/baseline in attempted state and an honest unconfirmed-result message.
3. Cold reopen and explicitly retry that original request. The real service returns an idempotent replay receipt for its original request ID; the journal durably confirms it. The model refreshes actual Store data, retaining the remote root title and sibling change.
4. Cold reopen offline again. The confirmed original command, baseline and exact receipt persist, and the actual Store cache contains all edits without a new server read. Opaque child data, root description, task generation and separate-record authority remain intact. Confirmed history is intentionally retained, not erased as if it were the ordinary task queue.

The app's report reads the journal again through a fresh production journal instance after each phase. Fingerprints bind command plus original baseline across processes; the driver independently compares the original command and receipt. The current-source/build hashes and strict signatures bind the observed apps to their owning source. The driver also verifies its launched iPhone process has stopped after termination before reporting cleanup.

## Scope and limits

The reserved DEBUG fixture and explicit flags supply a nonce/account-bound disposable encryption key and private test-session file. The real encrypted file-I/O implementation runs, but this does not accept protected Keychain access or release key/session handling. The existing test-only URLProtocol routes actual replies through the loopback gateway and drops one actual reply; it fabricates no Auth/table/RPC data and does not establish TLS behavior. Native data-engine acceptance is programmatic, not a keyboard, visual or spoken editor walkthrough.

Read/write switches are enabled only in the isolated build. Trusted promotion and local server gates apply only to the synthetic root; ordinary app gates and hosted services are unchanged. Conflicting edits to the same child, independent structure journals, full adoption/legacy migration, shared-account/window/background/access-loss directions, file/audio integration and the remaining pg_net placement review stay open. This is an additional accepted child-field recovery flow, not proof that the whole subtask-storage migration is complete. Existing root-queue recovery has its separately retained evidence.

## Reproduce

Build/sign the reserved DEBUG host with current owning sources, then run `node Scripts/Database/test-native-store-sync.mjs mac /tmp/taskfold-native-child-field-<unique>.json child` from this repo. The default mode remains the original root-queue test. The driver checks source freshness and signatures, enforces the 20 GiB storage floor, reuses the existing product/device, closes its app/services and restores the iPhone Simulator's original state. Reports contain only synthetic data; disposable credentials/configuration are removed.
