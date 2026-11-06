# Genuine mixed-recording project transfer

Reviewed 5 November 2026. Each owning repository now passes **58 checks** for a project branch containing published, uploading and removed recordings through genuine local Supabase Auth, PostgREST, PostgreSQL and Storage. Publication and maintenance use their production HTTP handler factories with default fetch, over the task-owned validated TLS bridge. No hosted schema, production handler body, client flag or normal app input changed.

## Accepted scope

Three real Auth signups produce live JWT sessions. Team/invitation membership and feature-gate setup are trusted synthetic SQL, not invitation-UI acceptance. All recordings are reviewed/published/removed through actual authenticated handler requests; unfinished state is created by holding a genuinely successful Storage POST before its publication finalizes, without inserting a fabricated reservation.

The selected parent/child branch contains one published clip, one in-flight upload and one removed clip. An unselected project has another original clip. Independent stop/private-history gates refuse the new policy while paused; older choices cannot silently move the mixed inventory. Signed review binds all three counts and rejects changed effects. An injected private-history failure rolls back projects, canonical tasks, ledger, custody, fences and provider rows exactly, leaving no transfer authority. The exact original command then commits.

Only the published clip gains team custody and its original bytes/receipt survive. The crossing upload receives an exact closed proof. Both the stopped and removed originals acquire their own private fence, and the new audience is refused before provider reads. Canonical tasks, the published/removed source ledgers, unrelated publication and real Storage identities/metadata remain exact. Lost-reply confirmation still works with fresh transfers paused; replay does not upload again.

The actual production maintenance handler claims two retired operations, performs two real Storage API deletes, confirms absence and reports both purged. The exact private fences and original sender's closure remain; selected published and unselected live recordings survive unchanged. This is Storage API deletion/absence proof, not a cryptographic filesystem-erasure claim. No scheduler or outbound job is enabled.

## Evidence and limits

The iOS repository replays all 207 own migrations; Mac replays 206. Their independent reports bind driver/runtime/bridge/server/production handler/wire source hashes before/after, exact migration hashes and pinned image digests. Both report 4 uploads, 6 downloads and 2 deletes. Current official advisor baselines retain the existing pg_net `extension_in_public` finding with no new findings. This is not a clean hosted security audit.

The first iOS attempt expected a fence only for the previously removed clip. The existing SQL contract correctly fences all retired originals, including the stopped upload. That test expectation was corrected to assert the exact two operation identities both before and after deletion; the initial attempt remains unaccepted and retained separately. No production policy was weakened to make the test pass.

The fixtures add only an opt-in after-Storage-POST hook and a key-protected production maintenance route. The random maintenance key stays in the local server/fixture environment; it is never returned to native clients or committed. Existing ordinary audio routing remains the default, and TLS validation is never bypassed. Services use bounded tmpfs and previously pinned cached images; every run closes its handler, private TLS directory, five owned containers and internal network.

Native project-adoption controls/journals, protected Keychain storage, other realm directions, legacy/foreign-custody histories and hosted S3 remain open. The earlier published-only 49-check and iPhone 17-check native publication proofs retain their recorded scope; they were not repeated unchanged. Normal recording/migration entry points remain disabled. Prepared optimized Mac22/iPhone34 updates and installed daily sessions are unchanged by this test-only work.

## Reproduce

From this owning repo with the existing pinned images, Node, Deno and installed Supabase CLI v2:

```sh
node Scripts/Database/test-full-schema-mixed-recordings.mjs /tmp/taskfold-mixed-unique.json
```

The current [CLI v3 breaking change](https://supabase.com/changelog/supabase-cli-v3) was reviewed; installed v2.109.0 was retained and no hosted command was used. Current [self-hosted Storage documentation](https://supabase.com/docs/guides/self-hosting/self-hosted-s3) distinguishes the file backend used here from S3. The [TLS cipher change](https://supabase.com/changelog/cbc-tls-ciphers-deprecated) explicitly excludes self-hosted stacks; it does not establish hosted client acceptance for this local test.
