# Child-record client data layer

29 October 2026. Both apps now own the same bounded reader and their own Backend/
Store integration. Normal `TaskfoldChildRecordReadsEnabled` is absent/false.
No view automatically calls it or replaces a saved task, and no hosted schema or
ordinary app exposure changed. Full child migration and Px remain unfinished.

## Implemented

- [x] Decode the protocol/account/project/task/generation/revision envelope and
  individually addressed records. Refuse missing/unexpected members, unsafe
  counters, duplicate identity/incarnation, invalid NFC keys, malformed parents,
  non-contiguous/duplicate sibling positions, bad raw paths, cycles and orphans.
- [x] Reconstruct from parent/order rather than response array order. Preserve
  absent/null/empty child containers and original decomposed ID bytes, retain
  supported opaque fields, and compare the exact result with the captured saved
  tree. A different server tree requires refresh/review; it never overwrites a
  local draft or silently appends missing nodes.
- [x] Preflight JSON member uniqueness before Swift dictionaries can collapse
  duplicate or canonically equivalent names, including inside opaque metadata.
  Bound input to 2 MB, records to 1,000, child depth to 24 and general JSON nesting
  to 128. Refuse non-finite/out-of-safe-range numbers instead of accepting an
  unaddressable representation. This uses the app's existing Double-backed JSON
  model; it is not a new arbitrary-precision numeric representation.
- [x] Backend posts only root ID/generation with the expected account, rejects
  redirects, uses no-store/no-cookie requests and enforces declared/streamed body
  limits. Scope checks precede/finish network work and detached decoding. Cancellation
  propagates to the decoder. Gate/review/size/auth errors have bounded user-facing
  messages instead of showing raw server diagnostics.
- [x] Store captures account, origin, workspace, session incarnation, access
  revision, snapshot revision and exact root. Both success and failure are refused
  after any captured context changes, including sign-out/departure/unavailable
  content. This method returns a verified read; it does not mutate/cache the task.

## Verification

Each repo independently passes **93 selected Core/transport cases**: 19 new
child-read tests, 19 existing tree tests and 55 account-transport regressions.
The 19 child tests include exact reconstruction of a real PostgreSQL-produced
response, 1,000 shuffled records, shape/Unicode/metadata refusal, a null legacy
root/generation, pure context comparisons and actual Backend requests through a
synthetic URLProtocol. Held successful and failed replies cannot escape an account
switch; a real Backend same-account sign-in also invalidates a held read.

Each repo reruns **43 database checks** and exports its own synthetic accepted
response/root to `TaskfoldTests/Fixtures/child-task-record-read.json`. `database.json`
binds this actual database output to the Swift fixture. This is not a live
PostgREST/HTTP-to-Postgres test: Backend transport uses controlled URLProtocol
responses. Database fixtures retain their prior minimal-schema boundaries and
no-added-advisor result; containers are removed.

`core.log.gz`, `app-build.log.gz` and `verification.json` record final source hashes,
test counts, binaries and full app/test compilation with strict deep signatures.
Store is excluded from Core packages, so its acceptance here is source and full
app compilation, not runtime lifecycle proof. Mac and Simulator builds do not
accept release/distribution. No new runtime warning/visual/spoken claim is made.
Other files/build tooling still emit warnings; none references the four changed
Swift files in the final logs. An initial new test fixture Sendable warning was
fixed by removing an SDK-unavailable conformance and protecting its handler with
an NSLock; the final 93-case runs were repeated afterward.

The next [server field-command stage](../child-task-field-edits/README.md) now
passes its local SQL scope and preserves this strict read protocol. It does not
enable native writes or close the remaining client lifecycle work below.

## Still open

- [ ] Actual Store lifecycle and editor/inspector adoption, session/access changes
  during Store work, runtime performance, loading/error/retry presentation and
  native accessibility checks. Pure lease tests do not prove these UI journeys.
- [ ] Independent idempotent child commands, completion/version rules, structural
  baselines, certified Undo and legacy-write concurrency. No mutation authority
  can be inferred from a read response.
- [ ] Offline state, complete current-schema/security/provider lifecycle,
  project/account changes, widgets/exports and reviewed unsupported legacy data.
  Oversized/ambiguous/unsupported numeric metadata needs review; it is not dropped.
- [ ] User-deferred hosted rollout/old-client transition and distribution.

## Reproduction

In this repo:

```sh
SUPABASE_TELEMETRY_DISABLED=1 node Scripts/Database/test-child-task-record-reads.mjs /tmp/child-client-database.json
swift test --scratch-path /tmp/taskfold-audio-recovery-core-mac --jobs 2 --filter 'ChildTaskRecordReadTests|SubtaskTreeTests|AccountTransportTests'
```

The committed fixture is the accepted `wireFixture` from that repo's database
report. Tests require no real token, account, task, microphone, provider or hosted
service. Full isolated app commands are archived in the build logs. Prepared hosts
retain reserved bundle/storage namespaces and are verified against the repo source
with only their documented namespace transformations. No app/Simulator was launched.
