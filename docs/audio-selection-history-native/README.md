# Selection recovery: live history and recorded confirmation

Reviewed 3 November 2026. Follows [history rebinding](../audio-history-rebinding/README.md) and [selection cold retry](../audio-selection-native/README.md).

## Accepted iPhone scope

Two isolated iPhone Simulator cases exercise the production deletion/recovery views, Store, edit-history bridge, actual cache persistence and real local PostgreSQL/RLS, production gateway and pinned Storage API. Three tasks belong to one shared project: two have seeded published recordings and one has none. Authentication, HTTPS/PostgREST routing, root screen and media remain synthetic adapters. This does not establish genuine Auth, full-schema parity, hosted delivery, ordinary Backups navigation, capture hardware or Mac/iPad runtime.

**Live history — 69 checks.** Keep the app running after the first deletion and attempted Undo. Expire and physically purge only one recording. Later preserves the complete pending command and history. After service closure, an actual persist failure keeps the original disk queue and fingerprint of every Undo/Redo action and logical history ID. Retry requires fresh explicit omission consent, saves the replacement and changes its matching history. Actual Store Redo deletes all three tasks, using no recording acknowledgement for the purged/empty members while retaining the available recording. Actual Undo restores all three with fresh generations and each new deletion certificate. A cold return preserves the exact final task fields and empty queue. Available audio keeps its identity and exact downloadable bytes; purged audio stays absent, with no replacement upload. This case deliberately delivers the replacement reply normally so history remains live; the earlier separate cold-retry case covers a lost replacement reply.

**Already-restored selection — 46 checks.** The original retained Undo applies, but its committed reply is lost. The screen offers unchanged confirmation with no omission consent. Later preserves the complete request and history. Confirming replays the same request, then an actual acknowledgement-persist failure keeps the original queue, task rows and complete history fingerprint. Retry sends the same request again, clears the queue and returns to the host. A cold return matches SQL. Exactly one group and three task restorations exist, with no terminal closure or duplicate restoration. Both published recordings remain available with exact bytes and no new upload.

Both cases compare existing private-vault paths and bytes where present; neither captures a new private recording, so no non-empty private-capture positive control is inferred. Both pass one UI case without skips, remove their owned configuration/services and restore the Simulator. No real workspace data is touched.

## Presentation and attempt qualification

The recorded-acknowledgement error now explains that the confirmation could not be saved and the selection is kept. Retry remains available. Screenshot review of recorded v1 found the long message below the initial viewport; its functional 46 checks passed, but full message reachability was not established. Recorded v2 adds a native scroll-and-viewport assertion before capturing that message and repeats all 46 checks. The warm case's app code and executed test path are unchanged by that recorded-only assertion. The final screenshots are inspected at the tested dark appearance and text size; largest text and spoken accessibility remain separate.

The isolated debug root adds a guarded Redo control and a deterministic fingerprint of complete history actions and logical IDs. The one-shot failure hook now also covers actual recorded-acknowledgement persistence. These controls/hooks are DEBUG-only and require the exact isolated fixture arguments; normal-use gates are unchanged. The app/runner builds and strict signatures pass independently for both owners.

## Remaining

Finish later queued dependencies, ordinary sync-attention/Backups presentation, Mac/iPad runtime, account/access/window/background/privacy, spoken accessibility and largest text. Larger selections, mixed file/audio and discussion expiry, whole-project transfers and genuine Auth/full-schema/hosted integration remain. The existing 204 focused Core checks cover unchanged owning model/test sources; they are not rerun for debug probes and a message change. The service migrations are unchanged. No deployment, release-signing acceptance or normal-use activation; curated bars remain 74 checkpoints and 34 substeps.

After retaining the functional v1 report, logs and exported images, its superseded terminal result bundle was removed (2,105,344 allocated bytes). The accepted warm/v2 results and existing build hosts/products/devices are retained.

Follow-up: [later queued work through iPhone Settings recovery](../audio-queued-settings-recovery/README.md) now has scoped native acceptance and fixes single-acknowledgement selection previews. Earlier remaining lists retain their milestone scope; direct sync-attention, normal bootstrap and wider platforms/contexts remain open.
