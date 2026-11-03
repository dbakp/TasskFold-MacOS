# Publication approval bound to its reviewed audience

Reviewed 3 November 2026. **Local service and typed client transport are verified; native approval/recovery integration remains to build.** Ordinary audio and recording project-transfer gates remain disabled. Nothing is deployed.

## Reproduced problem

The owning local fixture constructs an immutable publication intent before a personal project moves into a team, then submits it afterward. Before this candidate, the production gateway and SQL accept it with HTTP 200. Its target IDs do not encode audience, and current editor permission does not prove that the original approval covered the new audience. The isolated iOS reproduction and each final owning runner observe this behavior; all data and accounts are synthetic.

## Implemented protection

A separate metadata-only review returns the current personal/team audience, project visibility, expiry and a server signature bound to the actor, exact immutable intent and private current-access snapshot. The private snapshot includes the project realm and access revision, relevant memberships/grants or personal invitation records. Routine team operation counters do not invalidate approval. No recipient list, caption, provider path or snapshot hash appears in the public approval.

Before a new reservation, before upload admission and at finalization, the service checks the current audience under the existing account/task fences plus task/project/team locks. A changed audience refuses without publishing. A fresh review after adoption can explicitly approve the destination. Client substitution of visibility or changed caption/identity cannot reuse the old signature. Pending operations also retain their original audience binding; changing access requires closing that exact original operation before starting another approval. An upload already in progress can leave private provider bytes awaiting existing fenced cleanup, but cannot become a published recording after its audience changes.

Approval is separate from the immutable v1 publication intent, sender receipt and object path. Existing published receipts recover exactly even when the new review flag is disabled. Existing pending intents without audience proof cannot silently gain it; metadata Check/Close remains available. The new private audience-binding table has RLS and no direct grants. Its helpers and previous coordinator are inaccessible to client and service roles; the existing authenticated, session-checked service wrapper owns orchestration. The new review flag defaults to false.

Both clients now parse the exact bounded approval, bind it to the complete local intent, reject malformed/expired/wrong-context data and offer explicit metadata Review and approved Publish transport methods. The approved overload adds proof beside the unchanged intent. Legacy transport methods remain for historical recovery; the new server refuses fresh audience-less publication. **The existing native publication flow has not yet adopted these methods.** No UI, durable approval sidecar or cold retry is claimed from transport tests.

## Verification and limits

Each repository passes **112 local SQL/gateway checks**, including the existing 76 project-transfer controls and 36 added audience checks, plus **43 typechecked gateway tests** and **66 focused client tests** (three new client cases). Both independent app/runner builds and strict signatures pass. The SQL checks include the before-candidate control, stale personal proof, no provider request on stale refusal, fresh team approval, exact intent binding, changed access after upload, unchanged pending retry and exact Close. A held project-access row proves the command actually waits; a committed access-revision change invalidates the waiting approval before any provider request. Published and historical receipts remain byte-exact. Four gateway cases verify the metadata budget, approved reserve/finalize routes and malformed proof/reply handling. The client parses each owning SQL fixture and verifies the actual review/publish request bodies without changing the publication intent.

SQL/Auth/byte-provider acceptance uses the existing owned minimal PostgreSQL fixture and production HTTP handler with synthetic sessions/Auth and an in-memory byte adapter. Native Keychain, UI, microphone/playback, real Auth/Storage, full schema and hosted integration remain unaccepted. Seven existing advisor entries remain with no added keys; this is not a clean production audit. All owned containers/services close, no app is launched by build checks and no test Simulator is added. Resource-heavy work is serialized above the 20 GiB floor.

The first extended iOS run reached the production 12-publish-per-minute budget during the final pending retry check. The final fixture clears only its disposable actor's budget between the old transfer controls and the new audience scenario; production limits are unchanged. A client transport test caught a missing allowlist entry for the new Review route; that implementation defect is fixed before the passing runs. A subsequent source review excluded unrelated team usage counters from the signed audience, and final owning SQL runs verify publication remains valid after ordinary counter changes.

## Next implementation

- [ ] Add a premium native audience review before Publish, with plain access wording, explicit confirmation and keyboard/speech support.
- [ ] Persist the exact reviewed approval beside the frozen operation. Cold retry must preserve that proof, never fetch and approve a new audience silently. Expired/changed review needs an explicit new decision; pending changed-audience operations first need exact Check/Close.
- [ ] Invalidate reviews on source/access/workspace/account/lifecycle changes and fence delayed replies. Keep private originals and immutable historical receipts intact.
- [ ] Accept those flows on Mac/iPhone/iPad, then genuine Auth/provider/full-schema and wider account/concurrency/large-library/privacy acceptance. Pending/retained/legacy/mixed-media project transfers and other realms remain separate.

## Recheck

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-audio-publication-audience.mjs /tmp/taskfold-audio-audience-check.json
 deno test --allow-read supabase/functions/audio-comments/handler_test.ts
bash Scripts/test_core.sh --jobs 2 --filter AudioCommentPublishingTests
```

The local SQL fixture owns its resources and uses no hosted credentials. Its optional --export-fixture refreshes only the owning synthetic audience fixture. Run heavy platform checks sequentially and reuse current products.
