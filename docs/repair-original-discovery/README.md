# Find saved repair originals without a device journal

Reviewed 7 November 2026. Both clients now have an account-scoped Saved originals browser and export path. Finding an original no longer requires keeping the repair command on this device. The browser shows current readable task names, saved dates and file sizes; it loads bounded pages and keeps at most 500 entries before moving to another page. Loaded entries appear newest first. Export uses the existing native file picker.

Later evidence: the iPhone browser/picker/cold flow is recorded in `docs/repair-original-native-browser/README.md`. Reviewed retention removal, including permissions and lost-reply recovery, is recorded in `docs/repair-original-cleanup/README.md`. The historical acceptance limits below describe the original discovery batch.

The API lists only the signed-in actor’s applied repair receipts. Its UUID keyset cursor is supported by the existing actor/request index. Current names come from the public wrapper under caller RLS, are explicitly shortened at 512 Unicode scalars, and are omitted when current task access is lost. Neither archived task text nor chosen mappings are included in discovery. Original availability is a retention hint, not an authorization promise.

Original export revalidates the live session, receipt/archive pair, exact task generation, project/workspace realm, current root access and every archived history row. The public wrapper additionally enforces current caller task/history RLS. Exact original size/digest and header bindings are checked again in the client without converting original JSON into task rows. This path cannot reconstruct, queue, retry or apply a missing mutation command. Mapped originals can be exported without rebuilding their old identity choices; their archived reconciliation context remains bound to the same request/archive.

Recovery reads have an independent TaskfoldChildRepairArchiveReadsEnabled app switch, so the browser can remain reachable if repair authoring is disabled. The switch is absent/off in normal configurations. Existing repair authoring or local repair history also makes the recovery entry reachable. No normal app gate or hosted service has been enabled. A failed or unavailable server read leaves a retry message, without modifying tasks or originals. Original bytes are fetched only after Export; account, workspace/access, background and dismissal changes fence late results and clear view-owned content.

## Evidence

- Each owner replays its complete own schema and passes 98 genuine local Auth/PostgREST checks. These cover real repair saves, immutable receipt ordering and bounded paging, command-free exact export, paused writes, account isolation, missing/damaged originals, expired sessions, current task/history restrictive policies, title privacy after access loss, API/table privileges, and an actual personal-project invitation, acceptance, repair, command-free export and revocation. The Mac and iOS schemas have their own migration manifests. Every owned service/container is removed. Official advisors report the existing extension_in_public finding; neither new public endpoint is a definer and neither grants anonymous access.
- Each independently owned Swift Core suite passes 87 selected tests, no failures or skips. Six new cases verify actual service discovery/original bytes, strict metadata and integer tokens, duplicate/order/cursor limits, missing/corrupt/foreign/header-mismatched originals and an existing real SQL mapped original without reconstructing its command. Each owner captures its own final service fixture. The six archive cases are retaken against that exact final response; the other 81 unchanged cases retain their earlier passing evidence and are not repeated. The fixture’s optional raw HTTP-text capture is off by default for other tests.
- Full copied-app compilation, input fingerprints and its precise unsigned scope are recorded separately. Compilation is not native browser/picker interaction, signing or distribution acceptance.
- Development corrections and the final presentational follow-up are retained separately. Fixture setup, HTTP-status assumptions and fixture-decoding failures are not counted as accepted work. After successful app compilation, title shortening/empty-name feedback, size-only metadata and contextual accessibility wording received final syntax checks; no same-source full rebuild or native acceptance is claimed for that copy refinement.

Reproduce independently in either owner:

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-child-repair-archive-discovery.mjs /tmp/taskfold-archive-discovery.json
Scripts/test_core.sh --filter 'ChildRepairArchiveTests|ChildTaskRepairTests|ChildCopyMappingClientTests|ChildTaskAdoptionTests'
```

The migration filename was created with the installed Supabase CLI. Changes are exercised as SQL in the disposable runtime; no hosted migration is applied. The normal CLI local stack is not running, so explicit local db pull and migration-list commands cannot connect. Complete owned SQL replay with genuine APIs passes; CLI migration-history/diff acceptance is not claimed. The CLI v3 notice does not apply to the installed v2 CLI; current function/RLS guidance and relevant changelog notices were reviewed.

## Still open

The native browser/picker, cold return, largest text, VoiceOver, account/window/background behavior and large real libraries need their own acceptance. Genuine mapped/shared-team/custodian and departed-editor recovery remain broader cases; this endpoint retains the original actor-bound recovery model. Reviewed archive cleanup, safe restoration/Undo, wider exact editable-cache/history/file/discussion custody and the full older-work migration remain unfinished. An exported repair original is not a complete workspace backup or an automatic restore file. Existing hosted rollout, older-client, distribution, OAuth/email, physical device and genuine audio deferrals remain.

This is new source for the next signed update. Prepared Mac35/phone43 predate this feature; installed Mac31 and last-verified phone34 remain unchanged. Curated checkpoint totals do not increase for this milestone.
