# Stop unfinished recording sends during a reviewed project move

Reviewed 3 November 2026. Disabled candidate for personal project branches moving into a team. Whole-project recording transfers remain unfinished and unavailable in ordinary use.

## Behavior

An owner can separately approve moving published recordings and stopping unfinished sends. Both counts appear in review, the saved exact request, recovery and the confirmed result. Pending-only branches do not invent published recordings or require an irrelevant published-recording toggle. Changing access choices clears both consents. Old published-only clients still receive an unsupported capability when unfinished sends exist.

The new `move_published_stop_unfinished_v1` policy binds both counts to the signed inventory and exact request identity. Published custody and project access move atomically with stopping unfinished sends. Stopped sends use the existing retired/cleanup state; their captions and server descriptors are removed, while immutable original identity/hash and authors' saved local files stay unchanged. No unfinished bytes acquire team custody. An upload crossing the move returns closure of the exact original sender request even when its author loses project access. That historical response grants no task/media access. Provider cleanup later purges stopped bytes without changing unrelated sends.

The separate `project_unfinished_transfer_enabled` flag defaults to false and also requires project-transfer and audience-review enforcement. Retained/unavailable inventory still refuses. Nothing was deployed; ordinary client and service gates stay disabled. Each repository owns its implementation, migration, fixture and tests independently.

## Verification

Each owning repository passes 151 actual local SQL/production HTTP-handler checks. These compose the prior published-transfer controls with mixed published/unfinished and pending-only moves, explicit count/policy refusal, stale provider metadata, forced rollback, an in-flight sender losing access, exact receipt replay while paused, closure after cleanup, unchanged unrelated sends, helper privileges and no added advisor findings. The fixture uses synthetic Auth/sessions and an in-memory byte provider, not genuine Auth/Storage or the full production schema. Seven baseline fixture advisor findings remain.

Each owning repository also passes 83 focused client tests, including eight new cases using its own captured SQL responses. These cover explicit policy, pending-only behavior, exact saved counts, malformed capability/receipt refusal, cold lost-reply recovery and backend request fields. The secure-item test adapter is in memory; these tests establish neither native Keychain behavior nor application-layer encryption. App/test-runner build and signature outcomes are recorded in verification.json.

The first iOS attempt correctly refused legacy publication after adding audience enforcement; fixture setup now explicitly reviews and approves its synthetic sends. A second attempt reproduced an actual crossing-upload gap: the stopped original author's reply was unavailable after losing project access. The candidate now resolves only exact own retired/purged intents without current task access. Final iOS and independently run Mac checks include this correction and provider cleanup.

## Remaining

- [ ] Native separate-consent, cancellation, changed-review and exact retry acceptance on iPhone, iPad and Mac, with accessibility/lifecycle checks. Compiling the new controls does not establish runtime acceptance.
- [ ] Retained, legacy and other mixed media policies; other ownership/realm directions. This checkpoint covers published plus unfinished sends only.
- [ ] Genuine Auth/provider/full-schema integration, wider account/access races and deployment review before enabling ordinary use.

Existing user deferrals remain unchanged. The whole-project transfer parent remains To build.

## Recheck

Run heavy work sequentially, using the storage guard and existing products:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-project-recording-transfer.mjs /tmp/taskfold-unfinished-transfer-check.json --unfinished
bash Scripts/test_core.sh --jobs 2 --filter 'TeamProjectAdoptionTests|TeamProjectManagementTests|TeamProjectAccessTests'
```

Add `--export-unfinished-fixture` only when deliberately refreshing this repository's captured contract.
