# Older account-removal recovery — 3 November 2026

Older commands without a saved status proof can outlive their seven-day server
receipt. If Auth is already gone, sign-in cannot renew their original deletion
authorization. The apps previously kept local copies indefinitely without an
explicit recovery path. They still keep those copies until confirmation, but
now implement reviewed request export and absence-only certificate import.

## Contract

The non-secret request identifies the original server, account, saved command
and SHA-256 of its original private bearer. A separate authenticated operator
can issue a purpose-specific HMAC certificate only after the existing service
RPC confirms Auth and owned Storage metadata are absent. It grants no removal
authority. Verification binds the original bearer and command, rechecks absence
and returns a bound acknowledgement. A recreated account or new file refuses it.
The certificate uses retained global proof keys and can be explicitly revoked
through the existing key policy; there is no new per-account permanent receipt.

Both native apps use their existing private command vault and confirmed cleanup.
Import is capped at 8 KiB, cancellable and coordinated; review checks alone do
not authenticate the signature. The proof must save privately before a network
request. A failed/invalid acknowledgement cannot renew Auth or start a different
deletion. Another account's current session, pending writes, private backup,
backup key and removal command remain independent.

The new native entry defaults Off (`TaskfoldAccountRemovalRecoveryEnabled` is
absent). The operator service remains disabled and undeployed. Existing normal
protocol-2 deletion/proof behavior is preserved. Enablement requires hosted
acceptance of the updated issuer and verifier together. No hosted migration or
deployment occurred in this batch.

## Evidence and limits

Each repository independently passes 78 selected Core removal/coordination/
transport tests and 40 Deno handler/proof tests. Core covers exact matching,
non-secret export, bounded/cancelled reads, private save/CAS and bound transport
acknowledgements. Deno covers actual HMAC issuance/verification, purpose/origin/
bearer/command binding, revoked keys, outages, strict input and read-only routing.
These checks alone do not establish native Store cleanup.

Each independently owned real-provider fixture passes 57 checks using actual
PostgreSQL/pgcrypto and Storage file bytes. It refuses certificates before Auth
absence or residual-file repair, issues and verifies a bound certificate after
repair, and refuses it again after a file or Auth reappears. Existing stale-plan,
partial API failure, outsider byte preservation and 100+1 batch checks remain.
Both fixture databases and Storage containers are removed. Before/after advisor
results are identical, including the documented minimal-fixture
`public.is_project_owner` search-path baseline warning.

Auth presence/absence is modeled with disposable SQL identities. This is not
hosted Auth Admin, S3/versioned storage, or a privileged concurrent-writer claim.
The repair path still requires operator quiescence. Genuine Mac protected-session
runtime depends on deferred profile/signing. Wider device/window/provider and
spoken accessibility acceptance remain separate.

`verification.json` distinguishes accepted checks from remaining activation and native gaps.
The first iPhone run failed on duplicate fixture banner identities and a hidden
Files text-label selector. Those failures were retained and are not acceptance.
The fixture now uses the app's single production banner, and the selector targets
the real file cell. Further attempts exposed retained Files collection views,
partially visible file tiles and premature interaction before modal dismissal;
those failed runs remain recorded. A later run passed immediate cleanup and all
13 preservation checks, then rejected changed cache bytes after cold startup;
the current fixture checks full canonical JSON contents after relaunch, retaining
strict same-process byte checks and exact encrypted-backup checks. A match must
be proved rather than assuming that changed bytes are harmless. Recovery now preserves its selected request
while covered by a full-screen system picker. The JSON review and Verify controls are production code;
only identities, input files and the endpoint responses are synthetic. Server
HMAC/provider acceptance comes from the separate checks above.

## Reproduce

From this owning repository:

```
bash Scripts/test_core.sh --jobs 2 --filter 'AccountRemovalTests|AccountRemovalCoordinationTests|AccountTransportTests'
deno test supabase/functions/delete-account/handler_test.ts supabase/functions/delete-account/proof_test.ts supabase/functions/delete-account/recovery_test.ts supabase/functions/account-removal-repair/handler_test.ts
node Scripts/Database/test-account-removal-repair.mjs
```

The iOS repository additionally owns `Scripts/test_account_recovery_native.py`,
which reuses the reserved prebuilt Simulator host and restores its prior state.
The Mac repository owns its own native source, tests and full app build; it does
not depend on that iOS script. Follow the repository storage floor before heavy
checks. Operator payload and support handling are documented in
`supabase/functions/account-removal-repair/README.md`.


### Accepted iPhone completion and cold return

`iphone-completion.json` records the actually passed completion test from a run
whose separate largest-text refusal test failed. The whole run is not green.
The user-facing file picker/review/Verify flow clears only account A; immediate
checks require exact current/other cache bytes, B's queued work, exact B
ciphertext/key and original B private command, A's removed cache/fence/key, and
one original-authorization request. Cold return keeps all saved JSON fields,
the active/private B session, B's ciphertext/key/command and the removal fence,
with zero further endpoint requests. An independent read-only observer captured
the before/after cache: raw bytes changed, full JSON equality is true, and there
are no changed field paths. This establishes encoding changes rather than data
loss in this synthetic case. It is not a general migration or Mac runtime claim.


### Remaining refusal/picker check

The largest-text native case still stops in system Files before the app receives
its expected selection. Changing to List view also could not activate the
system control through XCTest; that unsupported selector was removed. It is not
counted as passed or silently skipped. Native wrong-file/401/unbound-success
presentation at largest text remains open, while the parser, transport and
server refusal contracts have their separate passing checks. The driver now
supports one selected case and reads XCTest JSON attachments, so resetting the
next synthetic workspace cannot erase the earlier case's evidence. No new
native retry was used to replace the already accepted completion/cold case.
