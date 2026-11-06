# Find older tasks across the accessible library

The Subtask storage review screen now searches task titles on the server, including tasks beyond the first loaded page and matches after the displayed title prefix. Clearing the query returns to browsing. Search is debounced, paged and bound to the current query/account/session/workspace/access scope; late results cannot populate another search or a selected review. Long-tail matches receive a bounded excerpt. Existing saved-upgrade and fresh single-task review paths are unchanged.

This is a functional discovery improvement, not completion of the broader older-work/history migration. Normal migration rollout gates remain Off. The independently owned matching SQL migration must be applied before future search activation. No hosted database, installed app, original task, draft, receipt or history was changed by this batch. Frozen Mac29/phone41 packages predate this change and do not contain it. Mac installation still awaits the saved-draft reply; phone installation remains deferred.

## Contract and access

A separate uniquely named invoker RPC uses existing task RLS and the existing live-session/rollout helper before and after its read. No new extension, table, definer content reader or user-metadata authorization is added. NFC/case-insensitive literal title matching treats percent, underscore and backslash as ordinary characters. Only the query and searchable title expression are normalized; saved content is never rewritten. Queries are bounded to 256 Unicode scalars/1024 UTF-8 bytes. UUID keyset pages contain at most 100 metadata rows within the existing 300,000-byte client response cap. Version-2 replies bind the exact normalized query bytes; version-1 browse and identity lookup remain supported. Page order is by UUID; the visible loaded subset sorts by title, without promising a frozen or globally alphabetical result set.

## Verification boundaries

- Each owner's 29 focused Core checks pass, including query limits/Unicode, exact query echo, metadata/excerpt bounds, stale cursors, content leakage refusal, the separate production Backend RPC, unchanged fresh single lookup and each owner’s real SQL-produced version-2 reply.
- Each owner's real local PostgreSQL fixture passes 211 checks. Added search cases cover a target beyond the first 100 browse rows, matching after 650 title characters, canonical accents, literal punctuation, paging 130 matches, private/shared-viewer/revoked access, disabled rollout, expired live session and denied anonymous/service roles. Exact task/record/history fingerprints remain unchanged. Before/after advisors report no new findings. Owned fixture containers are removed.
- The fixture's 155-task library is a correctness case. Its timing includes the local process/connection boundary and is not a large-library performance or physical-device smoothness acceptance.
- Local migrations are CLI-created and applied as raw SQL to disposable owned fixtures. The standard local Supabase stack is not running: CLI `migration list --local` cannot connect. A standard-stack diff/pull/history replay and hosted deployment are not claimed. CLI stays pinned at 2.109.0.
- Native and build results are recorded separately alongside this note. Mac build/signing does not count as Mac interactive or spoken acceptance. Wider history/identity, multiple-window/account lifecycle, ownership/media and rollout work remain visible in the plan.

Supabase's [database function guidance](https://supabase.com/docs/guides/database/functions) informed the separate RPC name, invoker access and explicit grants. Changelog/docs were reviewed for this change; no dependency upgrade was needed.

The existing reserved SQL/native test channel also supports the new read-only route, with bounded/quoted query input and actor/session fixed by the fixture. Six channel validation checks and a 12-check genuine SQL-channel smoke run are recorded per owner. This is not a real hosted REST or native-interaction claim.

## Repeat the owned checks

Use `bash Scripts/test_core.sh --filter ChildTaskAdoptionTests`, `node Scripts/Database/test-reviewed-child-adoption.mjs /tmp/taskfold-search-sql.json`, `node --test Scripts/Database/test-child-mapping-native-channel.mjs` and `node Scripts/Database/run-child-mapping-native.mjs --smoke` from this owner, using a supported Node runtime. The native method is `WorkflowSourceSelectionUITests.testOlderTaskSearchFindsUnloadedRootAndKeepsReviewReadOnly`. Its exact reserved runner guard must pass; the adoption gate is enabled only in that prepared test copy. The production app's Info settings remain unchanged. Native runs restore content-size and owned-device state and retain their source/test fingerprints.

The duplicate app-owned migration chains are verified independently. A future backend rollout must choose one authoritative migration history and deploy the shared contract once; this batch does not run both histories against a hosted service.

Current-source native iPhone and iPad largest-text journeys both pass browse/search/fresh review/Back/query replacement/no-results/clear with no synthetic writes or receipts. The empty-result feedback is placed first and the explanatory paragraph is hidden while searching, following the tablet layout finding. Input after Clear is explicitly refocused; uninterrupted keyboard focus and spoken announcements remain outside this acceptance.
