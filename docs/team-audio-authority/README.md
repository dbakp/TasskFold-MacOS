# Team audio publication and removal authority

Reviewed 2 November 2026. This source candidate adds team-task publication and removal authority to the existing audio service. It is not deployed and no normal-use feature gate is enabled. Each repository owns its migration and test runner independently.

Editors and managers can publish to a current, generation-bound team task only when the separate `team_publication_enabled` switch, existing team/read/edit switches, membership, project role and active/unarchived state admit it. The new switch defaults to false. Viewers, revoked members and former creators without current access cannot publish. Implicit team-visible editor access is overridden by an explicit viewer grant.

An author with current edit access can retire their own recording; a current project manager can retire another author's recording. A former creator or peer editor cannot use an ownership shortcut. Removal still requires active team/project edit access, but remains available when audio publication is disabled. It clears public caption/descriptor metadata and schedules the existing fenced cleanup path; it does not delete Storage bytes, release quota early or change a task. The original sender's exact-intent history can reconcile a manager's removal after access loss without restoring live media access.

Admission takes the team lock before the project-binding lock, matching access management. Writable admission locks the current membership strongly enough to fence insertion of a new viewer grant over implicit editor access. Actual concurrent transactions verify grant revocation, new-grant downgrade and team-management serialization. The existing scope function is replaced in place, preserving its identity for prepared coordinators; its personal-task/collaborator branch retains the prior behavior.

## Verification

Each repo independently passes 66 actual local PostgreSQL/production-gateway checks, plus all 51 existing owner-publication recovery checks with the candidate applied. The regression input is the owning repo's actual native-task-edit migration, original owner-status migration and this candidate, in that order. Reports bind the candidate and runner hashes to current sources. Advisor comparisons show no added findings, and owned HTTP/PostgreSQL fixtures are closed/removed.

The gateway publishes one immutable controlled upload, retries without duplicating it, downloads exact synthetic AAC bytes and refuses bytes when access is withdrawn during the provider read. The Auth and byte Storage HTTP adapters are synthetic; database roles, session/grant truth, command handlers and row mutations are real. This is not genuine Supabase Auth/Storage, hosted, full-migration or native-app acceptance. No app code changed, so this batch does not rebuild/reaccept the apps or repeat unchanged Core tests.

Reproduce from this repository using Node 22 or newer: run `python3 Scripts/check_test_storage.py --path /tmp`, then `node Scripts/Database/test-team-audio-authority.mjs /tmp/taskfold-team-audio-check.json`. The fixture also enforces the default 20 GiB floor and removes only its uniquely labeled container. Reuse existing runtimes and run heavy checks sequentially.

## Remaining implementation and acceptance

- Reviewed media custody for task moves, Undo/Redo and generation restoration. Existing audio-custody triggers still refuse live-media moves/replacement; this candidate does not bypass them or silently retarget a recording.
- Native team publishing/removal controls, Store integration and account/window/background recovery with the real service.
- Real provider delivery, removal/cleanup/quota release, genuine sign-in/full-schema and wider legacy/accessibility/media acceptance.
- Normal-use exposure and deployment only after those requirements are accepted. All existing user deferrals remain unchanged; the separate iPad dialog/cache recheck is still unaccepted.
