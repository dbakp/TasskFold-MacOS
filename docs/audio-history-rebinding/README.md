# Recording recovery and warm edit history

Reviewed 3 November 2026. Follows [native selection recovery](../audio-selection-native/README.md).

## Change

A successful expired-recording recovery changes the saved request identity and recording policy. The previous in-memory edit history still held the retained-recording acknowledgement. Redo could therefore try to delete a task using a recording count that no longer existed.

Both independently owned implementations now plan a precise history replacement before persistence. Match the complete original restore action in either history direction and its unique inverse template; replace both with the reviewed recovery and its matching inverse. Preserve the logical history ID, unrelated actions, ordering, task fields, chosen generation and deletion certificates. The inverse clears only omitted-recording acknowledgements and keeps available recordings. Ambiguous or missing inverse matches refuse the recovery without altering history.

Store assigns the planned Undo/Redo stacks only after the replacement snapshot has been saved. On failure it restores the previous snapshot and leaves both history stacks untouched. Existing menu registrations continue to refer to the same logical history ID. Single-task recovery uses the same boundary.

## Verification and limits

Each repository runs its own focused lifecycle, type-lifecycle, selection, editor and completion suite: 204 tests, zero failures. Four new cases cover forward/reversed selection histories, actual fresh inverse-command construction, retained/omitted/empty members, unrelated action preservation, ambiguous or missing counterparts, unreviewed changes and the single-task inverse acknowledgement.

Both current native app/runner products are built and signature-checked separately. This establishes compilation of the Store integration, not native runtime acceptance. The earlier iPhone selection flow and single-task regression belong to their earlier recorded product; they have not been rerun against this change. Prior service evidence is historical and unchanged; no SQL, provider or deployment change is claimed.

Still required: the actual warm native recovery → Redo deletion → Undo restoration cycle, actual persistence-failure history verification, group recorded-result confirmation, later dependent edits, wider account/lifecycle/accessibility and Mac/iPad acceptance. Normal-use gates stay Off. Curated progress bars remain unchanged.

## Build attempts

The first isolated iOS build stopped because two existing native screen files were absent from its test copy. A repair script then stopped on an absent optional isolation receipt; the second build started without that repair and failed on the same missing inputs. No app code was changed to accommodate the test copy. The two files were restored from each owning repository using the existing identifier substitutions, and the refresh helper now includes them. Final build results are recorded separately in verification.json; these failed attempts do not count as acceptance.

Follow-up: [iPhone live history and recorded selection confirmation](../audio-selection-history-native/README.md) now have their own scoped native proof. The checks and remaining lists above describe this earlier milestone; later queued edits, normal entry, other platforms and genuine integration remain open.

Follow-up: [later queued work through iPhone Settings recovery](../audio-queued-settings-recovery/README.md) now has scoped native acceptance and fixes single-acknowledgement selection previews. Earlier remaining lists retain their milestone scope; direct sync-attention, normal bootstrap and wider platforms/contexts remain open.
