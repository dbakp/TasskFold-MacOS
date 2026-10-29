# Child field request lifecycle and native recovery surfaces

29 October 2026. This follows the typed command/queue foundation with Store
construction, account lifecycle source integration, a presentation controller and
gated native title/notes/priority editing plus saved-request recovery screens.
Normal `TaskfoldChildRecordReadsEnabled` and `TaskfoldChildRecordWritesEnabled`
remain absent/false. No hosted SQL, ordinary app exposure, real tasks or Keychain
items changed. Full child migration, rank 6 and Px remain unfinished.

## Implemented

- [x] Build encrypted journals beneath the confirmed account's backup vault using
  its existing device Keychain key, process lock and account-removal tombstone.
  Confirmed account cleanup explicitly removes its journal without decrypting it;
  whole-vault cleanup also removes every origin. Source integration is compiled;
  genuine app/Keychain/account-removal runtime acceptance remains open.
- [x] Separate recovery availability from write rollout flags. An existing request
  remains discoverable after write exposure is disabled. Only the currently signed-
  in original account/origin can open a presentation. Inactive recovery views close
  their lease and hide text; account/session/access changes immediately hide the
  old view's content before asynchronous reload runs.
- [x] Current sending admission requires both rollout flags, online current access,
  matching task generation/project, a writable non-archived project and no pending
  legacy parent-task mutation. Team work uses the existing captured team-editor
  admission; personal writes require the owner and existing personal admission.
  Queueing can remain offline after an admitted read. Server checks stay authoritative.
- [x] The observable recovery controller serializes presentation actions, saves
  before sending, retains original attempts after failures, reloads durable phase
  before showing controls and stores confirmation before requesting current sync.
  It never copies a receipt into a task snapshot. Stale successes/errors clear the
  presentation and cannot refresh a different account/workspace context.
- [x] Saved-request screens show queued, uncertain and confirmed states with the
  original fields. Sending is explicit; removing an uncertain request requires an
  explicit warning that it cannot cancel/undo server work. Disk checks still refuse
  stale-body removal or a queued review that became uncertain in another window.
- [x] The new gated editor starts from a verified saved child read and changes only
  explicit title, notes or priority fields. Save checkpoints intent on the device;
  review/send is a separate action. Existing parent/checklist saves stay separate.
  Other planning/assignment/labels/reminder fields are not yet controls in this form.
- [x] Reuse private unsent-editor preservation for typing, node changes, inactivity
  and departure; retain per-node drafts in the open presentation. An async successful
  checkpoint may finish only the exact private draft revision captured before it
  started; newer typing remains preserved. Original child target metadata is kept
  with that private recovery, never replayed as authority.

## Verified in this stage

Each repository independently passes **195 selected Core cases**: 32 child-command/
journal/sender/controller/draft-finish cases, 20 child-read cases, 19 tree cases,
55 account-transport cases and 69 backup cases. Nine cases were added here: seven
presentation-controller scenarios plus two conditional-draft-finish checks. They
cover original-request retention, no network before saving, stale coalesced review,
failed receipt save/retry, explicit uncertain discard, same-account new-session
success/error refusal, access changes during refresh and newer unsent typing.

Full isolated Mac and iOS Simulator app/test builds compile Store and the new
screens; strict deep signatures are checked. The Core package excludes Store and
Views: its tests do **not** prove actual Store permission/cleanup execution, native
navigation, real Keychain prompts, field focus, row layout, speech or provider
behavior. No such runtime/visual acceptance is claimed. SQL is unchanged; the
previous stage's local 95-case database scope is not expanded/reclaimed here.

## Remaining before exposure

- [ ] Synthetic native end-to-end editor, queue/send/retry/discard, actual Store
  permission/account/window changes and private draft preservation/recovery tests.
- [ ] Genuine private Keychain and confirmed removal/retry acceptance for this new
  storage scope; reboot/crash and cross-process lifecycle acceptance.
- [ ] Complete title/notes/priority layout and spoken acceptance on Mac/phone/tablet,
  largest text, long values, keyboard focus, cancellation and error recovery.
- [ ] Integrate remaining supported field controls, clear field-specific conflict
  review and exact re-review of later same-target edits; no silent automatic rebase.
- [ ] Completion/structure/heading/legacy adapters, authoritative-record migration,
  server receipt history/quota policy, hosted compatibility and paired delivery.

Read/write gates remain off while these acceptance gaps remain. All user-deferred
rollout/distribution/provider/genuine-audio/location work stays deferred.
