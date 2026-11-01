# Native history-mapping review and recovery models

Both independently owned clients now implement a native history-review form, saved partial choices, complete mapped previews/commands and exact mapped-original decoding. **This is implementation and core/build verification, not accepted native save/recovery.** Normal-use repair/adoption flags remain disabled, and no hosted schema was changed.

The reviewer explicitly chooses existing history or a new identity for each selected task/heading. A searchable native list shows recorded titles, locations, status, completion date/time and available assignee names; histories already used elsewhere are excluded. Existing history requires a separate choice of selected versus recorded completion/type/assignee/recurring relationship. Every unused stored identity must be explicitly retired before preview. Nothing is matched automatically. Unresolved recurrence/recipient conflicts still stop at the server.

Partial choices save after each action using the existing account/root-bound journal and compare-and-swap draft token. They store identity/consent metadata, not source trees or notes. Partial reviews cannot queue a task mutation. A complete review can return to the form without losing individual decisions; matching the same identity again retains its details. A changed snapshot/copy/incarnation requires a fresh review. Account/access changes hide the comparison and editor through the existing scope gates.

Complete choices use the existing preview, confirmation, saved request, retry/check/stop and original export paths. Mapped summaries must match every chosen identity, incarnation, lifecycle, new/reset count and required reset/retirement boundary. The displayed retirement count counts explicit stored-history retirements, not older already-deleted references in the audit. Source trees stay on the exact lexical byte path. Mapped original archives require the exact submitted choice and a valid reconciliation context bound to the same request/archive, in addition to size/digest/root/generation/project checks.

Mapped metadata gets the backend's larger bounded request allowance. Ordinary repair limits and the ordinary streamed preview limit are unchanged. The global saved-state budget remains bounded. Native controls use the existing wrapping action-label style; user titles are displayed verbatim, with localized static labels. Long titles remain shortened for review; exports keep the full source.

## Evidence

- `client-verification.json`: 85 focused tests pass in this repository, including nine new actual-wire/model tests and a new journal/model test. They cover real PostgreSQL preview/receipt/original bytes, partial cold state, no default matches, explicit lifecycle/retirement, stale/foreign/duplicate/injected choices, bound summary/context rejection, larger mapped metadata, preserved ordinary limits, editing a completed review back to partial state, refusal to queue partial choices and cold lost-reply status recovery without replacing the saved request.
- `database-contract-verification.json`: the 77 mapped-transaction assertions are rerun independently in this repository while capturing the extra read-only native-client contract. The captured JSON comes from PostgreSQL under the authenticated fixture role; the original's canonical bytes and server receipt are preserved. No sibling repository is a runtime/build input. The earlier database verification's test-source digest is refreshed from this passing run; its SQL chain is unchanged.
- `build-verification.json`: current isolated app/runner builds and signature checks, with source/isolation/product hashes. This proves compilation/signing, not native interaction or distribution readiness.

Reproduce the owned wire capture and core checks:

```sh
python3 Scripts/check_test_storage.py --path /tmp
TASKFOLD_MAPPING_CONTRACT_FIXTURE=TaskfoldTests/Fixtures/child-copy-mapping-contract-v1.json \
  node Scripts/Database/test-child-copy-mapping-apply.mjs
Scripts/test_core.sh --filter 'ChildCopyMappingClientTests|ChildTaskRepairTests|ChildTaskCopyReviewTests|ChildTaskAdoptionTests'
```

The new native fixture records include the real identity/incarnation/location shape needed to open the form. Its older mock preview/write handler now explicitly refuses mapped operations (`PT503`) rather than incorrectly certifying a mapping it does not simulate. A separate DEBUG-only local SQL channel now connects the reserved host to the actual mapping transactions; see `../child-copy-mapping-native-channel/README.md`. Full native interaction and an independent saved-data verifier remain open.

A Mac runtime attempt stopped at the locked screen before any form interaction. Its owned test process was closed. No native matching/search, keyboard/speech/largest-text, cold partial form, mapped save/recovery or exact native mapped-original readback is accepted by this milestone. The current app binaries have not been installed into the user's normal app.

## Remaining

- Use the local SQL test endpoint, finish the independent saved-data verifier and exercise both full app workflows, including search/cancel, explicit choices, edit/Undo/reset, partial/complete cold return, one save, lost reply/status recovery and exact original export/readback.
- Verify account/access/window/privacy, keyboard, VoiceOver and large-text/library behavior. Mac runtime needs an unlocked desktop.
- Resolve broader recipient/recurrence histories, exact editable caches, shared file/discussion/archive custody and genuine shared-account/hosted migration acceptance. Other Mac workflows and all existing user deferrals remain open.
