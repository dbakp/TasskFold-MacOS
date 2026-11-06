# Newer queued work through Settings recovery

Reviewed 3 November 2026. Follows [live selection history](../audio-selection-history-native/README.md).

## Product fix

Acknowledging a single task replaced its optimistic row with the server row, then replayed only later single-task mutations with the same record ID. A later selection envelope has its own header ID, so its edit was missed: a newer priority could disappear from the local preview, and a member of a queued deletion could reappear.

Both owning Snapshot implementations now validate a later non-completion selection and reproject only the acknowledged member, in original queue order. Other members already have their optimistic values; rerunning whole-selection admission against those values would reject its original baseline. Generation guards still keep a recreated server task safe. Malformed envelopes cannot gain projection authority. The full original header, member IDs, fields and baselines remain unchanged for one atomic service request; no partial delivery is introduced.

Two pre-fix regressions reproduced the edit-preview and deletion-visibility failures. After the fix, each repo independently passes 208 focused lifecycle, selection, editor and completion tests. Four new cases cover preserved title/priority and peer rows, queued deletion visibility, a new server generation, and malformed duplicate member identities. Both current app/runner builds and strict signatures pass.

## Accepted iPhone route and data

One iPhone Simulator case passes 68 service/native checks and one UI case without skips. The production RootView, Settings → Data & Sync → Backups & restore, recovery presentation, Store, cache and edit-history bridge run against real local PostgreSQL/RLS, production gateway and pinned Storage. Authentication, HTTP routing, initial data/media and startup bootstrap remain controlled synthetic adapters. The DEBUG bootstrap preserves the signed-in fixture instead of the general UI-test local-workspace seed. This is production presentation acceptance in that synthetic workspace, not genuine sign-in/full-schema/hosted startup acceptance.

Start with three tasks in one shared project, two published recordings and one empty member. Delete the selection, expire and physically purge only one recording, then attempt Undo. While that restore is blocked, save a newer root title/notes and a two-task priority change through the production Store editor/planning APIs. Those two complete intents remain behind the original restore.

Cold-launch the actual app shell and reach recovery through Settings. Later preserves all three queued commands. Reopen with fresh consent and recover: only the restore identity/policy changes; both later intents and all newer optimistic values stay exact. Its committed reply is lost. A cold return retries the same restore, applies the single edit, then applies the complete planning group with its reply lost. The acknowledged single edit does not hide the later selection preview. That planning command remains saved unchanged. Another cold return acknowledges the same planning request, clears the queue and matches every final SQL field: newer title/notes and both priorities, with every other field and chosen generation preserved.

Exact ledger actor/task/generation/member/group identities prove one single edit and one complete planning group, with three durable patch receipts and no duplicate effects. Available audio retains its publication identity and exact downloaded bytes; expired audio stays purged and no media is reuploaded. Existing private-vault paths/bytes are compared where present; this case does not capture a new private recording. The Settings sheet remains after the review closes, and the recovery row disappears when no eligible restore remains. All owned configuration/services close and the Simulator is restored.

## Attempts and fixture fidelity

Native v1 reached Settings, preserved the saved requests and later preview, but final retry could not finish: the minimal test database had omitted the existing planning coordinator and its public dispatcher rejected edit operations. The fixture now installs the three owning production planning/assignment/label migrations and asserts the public dispatcher routes edits to that coordinator. No production migration or permission policy changed.

Native v2 passed the full UI flow and both deliberate lost replies. Its post-validator mistakenly queried receipt operation `edit`; the owning schema stores single/member edits as `patch`. Native v3 repeats the unchanged app/UI flow and compares the exact three receipt identities, actors, task generations and group bindings using the actual schema. All 68 checks complete. Earlier attempts establish only their recorded partial scope. Screenshots of Settings at three, one and zero queued changes were inspected at the tested dark appearance and text size.

## Remaining

Clarify retry messaging for uncertain service replies: the current generic team-edit message asks for review even when retry is enough. Finish the direct sync-attention entry, normal authentication/bootstrap, other restore outcomes from Settings, Mac/iPad runtime, account/access/window/background/privacy and spoken/largest-text checks. Broader queued completion/move/recipient histories, sparse/legacy migration, large queues, mixed media/discussion expiry, whole-project transfers and genuine Auth/full-schema/hosted integration remain. The queued case does not inject another recovery-save failure with later edits present; the separate native failure proofs retain their own scope. No deployment, rollout-gate activation or signing/distribution acceptance. The new precise preview substep is separate from the existing recovery cases; 74 curated checkpoints remain unchanged.

After retaining concise attempt evidence, logs, reports and exported images, the two superseded terminal result bundles were removed (51,253,248 allocated bytes). The accepted v3 result and existing hosts/products/devices are retained.

Follow-up: [main-screen recovery and safe retry guidance](../audio-sync-attention-recovery/README.md) now has scoped iPhone acceptance and preserves original requests across manual retries. Earlier remaining lists describe their milestone scope; Mac/iPad, normal bootstrap and wider contexts remain open.
