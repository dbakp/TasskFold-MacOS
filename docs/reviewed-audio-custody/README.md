# Reviewed recording project moves and Undo

Reviewed 2 November 2026. Undeployed candidate; ordinary-use shared-audio gates remain disabled.

## Implemented scope

- New team publications bind a private current project audience to the existing immutable publication ledger and Storage identity. Existing unbound recordings are not automatically adopted.
- A reviewed same-team task move with an unchanged task generation counts published recordings, binds their full inventory to the review, and requires the matching acknowledgement. The native review explains destination access and the limits of revoking downloaded copies.
- Commit and Undo move recording and companion-file custody atomically with the task. Readers follow current project access; original sender receipts, upload paths and sender-status history retain their original identity. Lost replies replay safely. A move during a download withholds its bytes.
- Tasks without recordings retain their exact previous move hashes. A real move performed before applying the candidate can still be undone afterward.
- Pending, legacy unbound, changed/busy/missing Storage, generation replacement and whole-project realm changes refuse. Provider metadata loss preserves private custody so an authorized current manager can retire the publication even while publishing is disabled.

## Verification and limits

The owning repository runs actual local PostgreSQL functions, roles/RLS and the production audio gateway. Auth and object-byte HTTP are controlled synthetic adapters; this is not genuine hosted Auth/Storage or full-schema migration acceptance. Reports and source hashes are in verification.json; compressed logs and captured SQL wire fixtures are retained. Owned fixture containers and adapters are removed after each run.

The focused Core suite validates review parsing, bounded durable acknowledgements, older-client compatibility and actual owning-SQL review/command/receipt parsing. The existing file-custody regression runs with the candidate applied. Its historical taskFileUploadSHA256 report field names the injected concatenated audio migration input, not an upload-only test.

Current isolated app/runner builds and strict signatures are checked separately. A successful build does not accept the new review's runtime interactions, VoiceOver, largest text or layout. No app is launched for these build checks.

## Remaining work

- Native team publication/removal controls, Store handoff and recovery, and the recording-bearing move review's runtime/accessibility acceptance.
- Reviewed task-deletion generation restoration and whole-project adoption/realm transfers; these are deliberately outside the same-generation move exception.
- Genuine provider delivery, cleanup/quota, Auth/full-schema and wider account/window/background/access/privacy acceptance, plus broader legacy migration.
- The previously interrupted iPad dialog/cache reacceptance stays open; do not repeat the broad suite against its unchanged runtime condition.

No hosted migration, service deployment, scheduler or release enablement occurs here. The user's remote-reminder, old-client rollout-safety and distribution deferrals remain unchanged.

Follow-up: the [certified generation-restoration service](../audio-generation-restore/README.md) now has separate local proof. Native review, wider lifecycle and whole-project transfers remain open. Earlier remaining lists describe their original stage.
