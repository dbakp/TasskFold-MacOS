# Heading-aware shared workflows

Status: implemented in both independently owned apps and service migrations;
normal heading/collaboration rollout remains disabled. No hosted changes or real
user data were used. The existing personal template/copy/export format remains
portable and preserves known v2 definitions.

## Product behavior

A team owner/admin can publish or replace a reviewed v2 template without losing
root or nested headings. Publishing stores a reusable definition; it does not
create tasks. Readable team definitions can still be copied privately unchanged.
The full shared-run review identifies headings as “Heading · stays open” and
shows their nested productive work. Personal and readable shared definitions can
create a complete project hierarchy, section or task in an eligible shared
workspace. New work has fresh identities and no imported completion/discussion,
files or assignments.

A completed shared checklist item must have its reopening saved before it can
become a heading. The organizer now explains the required separate save while
keeping the draft, instead of failing with a generic review error at final Save.

## Transport and admission

- Known v2 definitions require exactly `capabilities: ["task_headings"]`; unknown
  capabilities, malformed flags and future executable definitions are refused.
- Heading publication/replacement and runs carry `workflow_types_protocol: 1`.
  Their acknowledgments must echo that version before an encrypted saved command
  is cleared. Missing/future acknowledgments cannot silently accept a downgrade.
- Library storage keeps its preexisting opaque/future-document behavior for old
  storage requests. Opted-in typed publication additionally validates the entire
  current format. Library list/detail shapes and ordinary v1 command/receipt
  shapes remain unchanged.
- New heading runs require the app opt-in and fresh signed task-type/lifecycle
  support, rechecked before sending. The server rechecks current actor/session,
  source document/revision/access, destination editing authority, archive state,
  quotas, order baselines and rollout configuration under existing locks.
- Every typed run preserves exact root/nested type metadata and tree structure
  against the reviewed definition. Ordinary v1 review-added checklist detail
  remains compatible, while unnegotiated type metadata is refused.
- Native typed lifecycle admission creates each root/tree inside the existing
  atomic workflow transaction. Whole-project failure leaves no partial branch.
- Saved encrypted requests keep one original identity/envelope across lost replies
  and relaunch. Replay acknowledges recorded work without duplicating it; new
  authoring can be paused while accepted requests remain confirmable.
- New private validators have no client grants. Existing public endpoints,
  actor checks, role rules and feature defaults are preserved.

Migration: `20261026165807_shared_workflow_task_headings.sql`. It follows the
existing heading contract, edit and typed-lifecycle migrations. This is source
preparation, not a hosted migration or release-signing change.

## Verification

Each independently owned repo passes 96 selected Core cases, 60 heading-specific
real PostgreSQL/advisor checks and 89 existing SQL workflow regressions with the
new migration installed. Signed iPhone/iPad publication/copy/cold preservation
passed; their final heading-run lost-reply/cold retry scenarios also passed. The
signed Mac heading-run review/lost-reply/cold retry case passed. Five retained
output images were inspected, and normal v1 receipt/read shapes stay compatible.
Initial native failures were test selectors, the Mac Switch value representation
and the test runner’s home directory; their logs are retained with final passes.
The final count fix has both Core and native coverage.

Final results and source fingerprints are in `shared-workflow-headings/`.
The owned PostgreSQL runner removes its container after each run; no hosted
service is contacted. Native template/workflow UI tests use the file-backed,
network-isolated URLProtocol peer, separately from real PostgreSQL acceptance.
They do not imply full HTTP/PostgREST delivery or cross-device acceptance.

The previous heading-edit milestone's frozen signed Mac root-editor test also
passed after UI-automation authorization; see `TEAM_TASK_TYPE_NATIVE.md` and
`shared-heading-native/mac-summary.json`.

Remaining broader rank-3/Px work includes full native transport and concurrency
races, wider accessibility/largest-text, installed widgets/cross-device coverage
and other template/import adapters. All user-deferred provider, notification,
upgrade and distribution work remains deferred.


Cleanup: all test processes ended, both owned Simulator app/runner installs were
removed and their containers verified absent, and 25 owned prepared build/result
folders (about 3.31 GB of temporary files) were deleted after retaining the small
verification record. No Taskfold app processes remain. Repository build caches
and unrelated work were preserved; see `shared-workflow-headings/cleanup.json`.
