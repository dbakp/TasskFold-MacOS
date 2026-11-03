# Native whole-selection recording recovery

Reviewed 2 November 2026. Follows [the service/Core boundary](../audio-selection-recovery/README.md).

## Implementation

Both apps’ gated sync-attention/Backups recovery component now supports whole-selection recovery. The stable presentation owner distinguishes a single task from a selection and retains the sheet until its request-guarded close finishes. The single-task view is preserved.

Store admission binds the exact queue head, account, workspace generation, backend origin and session incarnation. Metadata reads run four at a time and are rechecked after every chunk. The complete selection review includes members without recordings. A closed receipt and fresh explicit omission consent create one replacement queue head; the actual persist call occurs before sync is scheduled. A local write failure restores the complete previous in-memory snapshot. Recorded confirmation replays the unchanged original intent and saves its acknowledgement instead of inventing rows from metadata.

The grouped native screen lists the saved task titles and recording states, explains which available audio stays, requires unchecked omission consent, and offers Later without changing the queue. Consent is cleared on refresh, scene change, expiry and failure. A visibility incarnation rejects an in-flight action after the scene leaves and returns; context/session/head checks remain separate. Submission disables repeat actions and interactive dismissal. Capture the original context when confirming a recorded result so its successful acknowledgement can close after the queue head changes.

## Owning iPhone proof

The reserved iPhone Simulator root hosts the production deletion/recovery views and real Store/cache/persistence. The test seeds two publications through the actual local production gateway and pinned Storage API, then deletes three selected tasks: one recording expires and is physically purged, one remains retained and one task has no audio. Authentication, HTTPS/PostgREST routing, media and the root screen remain controlled synthetic fixtures. This is not genuine Auth/full-schema/hosted, hardware capture/playback, ordinary Backups navigation or Mac/iPad runtime acceptance.

The case verifies initial disabled recovery, explicit consent, Later preserving the complete pending request, cold return with fresh unchecked consent, and a deliberately failed actual persist after terminal server closure. The saved original request survives that failure. After consent is supplied again, the app saves fresh header/member identities with unchanged task fields, chosen generations and deletion certificates. The service applies the replacement, its reply is deliberately lost, and a cold launch retries the same complete request values. Exactly one group and three task restorations are recorded; one closure persists. Every cold cache row equals actual SQL. Available audio retains its identity and exact downloadable bytes; expired audio remains purged with no replacement upload. Existing private-vault files, where present, are compared by path and bytes; this case does not capture a new private draft.

The accepted phone v3 report has 59 owning service/native assertions and one UI test passed without skips. All owned configuration/services are removed and the Simulator is restored. The controls and save-failure messages were visually inspected at the tested text size; largest text, spoken VoiceOver and wider layouts remain separate.

## Attempt qualifications

Phone v1 stopped before deletion while waiting for a consent control below the lazily rendered form viewport. All three actual recording summaries had returned; the harness now scrolls before requiring that control. Phone v2 passed the complete UI case, including failure rollback and cold retry, but its post-validator treated an explicitly expected absent acknowledgement as the helper's default true. The checker now distinguishes omitted expectation arguments from an explicit undefined expectation, retaining exact absence checking. Neither attempt establishes the final whole-run result. Phone v3 repeats the unchanged app case and completes every post-validation check.

The first iOS build compiled the initial screen. The final iOS build includes visibility/submission guards, copy cleanup, private-byte checks and the scroll correction. At that milestone, Core models/transport and the service migration were unchanged from the preceding independently verified 200 Core/186 service suites; they were not rerun merely for reassurance. The later history change has its own evidence linked below. The new Store/view paths are exercised in the owning app build and native flow.

## Remaining

The group recorded-result confirmation method and screen still need their own native case. Warm Undo/Redo history now has [exact rebinding and Core regression checks](../audio-history-rebinding/README.md); actual native history-cycle and save-failure acceptance remain open. The proof above predates that follow-up. Authored later-action dependencies also need wider cases. Finish Mac/iPad runtime, ordinary sync-attention/Backups presentation, access/account/window/background/privacy, largest text/speech/keyboard, larger selections, mixed file/audio and discussion expiry, whole-project transfers and genuine Auth/full-schema/hosted integration before exposure. Prior single-task evidence keeps its own scope. No normal-use flag or deployment changes.

Final integration checks: both independently owned app/runner builds pass strict signatures. The current iOS product also passes the existing single-task recorded-Undo/publication/playback/removal case and all 43 owning checks, after the shared presenter/router changes. That regression is not acceptance of the separate group recorded-confirmation screen. Two terminal obsolete result bundles were removed after retaining their reports, logs and exported attachments; the accepted selection/regression results and existing build hosts/products/devices remain.

Follow-up: [iPhone live history and recorded selection confirmation](../audio-selection-history-native/README.md) now have their own scoped native proof. The checks and remaining lists above describe this earlier milestone; later queued edits, normal entry, other platforms and genuine integration remain open.

Follow-up: [later queued work through iPhone Settings recovery](../audio-queued-settings-recovery/README.md) now has scoped native acceptance and fixes single-acknowledgement selection previews. Earlier remaining lists retain their milestone scope; direct sync-attention, normal bootstrap and wider platforms/contexts remain open.
