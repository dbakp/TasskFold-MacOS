# Signed recording inventory for project transfers

Reviewed 3 November 2026. **The custody transfer itself is still unfinished.** This stage supplies its signed inventory, client validation and review explanation; it does not enable moving recording-bearing projects.

## Changed behavior

Previously the ordinary project transfer preview omitted recording inventory and could appear ready to transfer, although a later recording guard refused the commit. The existing signed inspection now includes a private digest of actual publication ledger rows, their current task context, custody and provider metadata. The client receives only counts of published, unfinished, removed/retained and unavailable recordings. Captions, publication identities, provider paths and the inventory digest stay on the server.

Both clients validate this exact versioned summary and reject unsupported, incomplete, extra, negative, fractional, excessive or inconsistent values. Inspection/review equality binds the same summary. Even an enabled service flag cannot make a recording-bearing review author a transfer command before custody support exists. The native review adds count rows and a recording-specific explanation rather than the generic disabled-service message. These views build; their new rows have no native runtime, speech or largest-text acceptance yet.

The read-only census accepts one-dimensional unique selections of 1–1,000 projects, checks at most 10,001 active/retained publication rows, and refuses over 10,000 rows or 8 MiB of serialized inventory metadata. Its digest is accumulated incrementally. Recording metadata also counts toward the existing 32 MiB overall review limit. Current publication state, generation/project context, object identity/version/metadata and ownership affect the signed result; bucket readiness is reflected in unavailable counts. Pending, retired and unavailable recordings are represented rather than silently dropped; a large inventory refuses instead of truncating.

Fresh server commits explicitly refuse any recording-bearing selection before changing projects, tasks, access, ledger or provider metadata. Connection pause cannot bypass that refusal. Projects without recordings still transfer through the existing coordinator. Previously completed transfer requests still recover their original receipt even while fresh adoption is paused. This stage does not create new recording-transfer consent, authority or custody writes. Existing private drafts and ordinary-use gates are unchanged. No hosted schema/service deployment occurs.

## Verification

Each independent repository passes **34 local database checks** and **69 focused project-transfer Core tests**, including four new client cases. A reproduction against the actual previous iOS Core source executes two new regression cases and produces 14 expected failing assertions; the current source is restored before the passing run. The Mac reproduction is not separately claimed.

The database fixture uses the owning production SQL functions, authenticated role and session checks in an owned minimal schema. Recording and Storage metadata rows are seeded synthetic data. It does not establish new publication/gateway delivery, actual provider bytes, genuine Auth, a full migration stack or concurrent writer behavior. Both source projects include independently generated CLI migration files and own their test runner, captured wire fixture and evidence. No sibling repository is a build dependency.

Checks cover the whole parent/subproject census, deterministic signatures, changed provider version, unsafe bucket and changed byte-size metadata, hidden caption/path/digest, direct commit refusal with exact unchanged source rows, account isolation, unavailable private helper privileges, invalid selections and oversized payload refusal. Normal no-recording commits and old completed receipt replay remain accepted. The actual owning SQL inspection/review wire is parsed by each client. Advisor reports retain seven pre-existing entries before and after, with no additional keys. Each fixture container is removed.

Both existing isolated app/test hosts are refreshed from owning source, build successfully and pass strict signatures. No native app is launched for these build checks. Core compilation retains unrelated pre-existing test warnings; this is not a warning-free-runtime claim.

## Attempt qualifications

The first iOS SQL run stopped in the test assertion helper: a default argument converted explicit undefined into true. The second accepted the first 20 checks, then its Boolean privilege result needed JSON encoding for the fixture scalar reader. Both cleaned up their containers; neither exposed a production-candidate failure. A third run passed 31 checks before adding selection shape/size and oversized-inventory cases. The final iOS run and independent Mac run each pass all 34 checks against current source.

## Remaining implementation

Implement explicit recording-transfer policy in the reviewed command and signature; exact transaction-local transfer authority; sorted inventory/provider fences; atomic current-custody updates while preserving immutable publication/upload/sender receipts; and contentless replay/confirmation. Pending uploads, retired/legacy inventory, failed/competing writes, access revocation, in-flight downloads, mixed media and private history need their corresponding reviewed custody decisions. Build the premium consent/recovery controls and accept them on Mac/iPhone/iPad, then genuine Auth/provider/full-schema integration. The wider Px work remains active. This inventory is a foundation for the requested transfer, not a substitute for it.

## Recheck in either owning repository

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-project-recording-inventory.mjs /tmp/taskfold-project-recording-inventory-check.json
bash Scripts/test_core.sh --jobs 2 --filter 'TeamProjectAdoptionTests|TeamProjectManagementTests|TeamProjectAccessTests'
```

Use `--export-fixture` on the database command only when refreshing that repository's captured SQL wire fixture. The normal recheck leaves it unchanged. Docker is required for the owned database fixture; no hosted credentials are used.
