# Durable local audio Save — gated candidate

The exact local Save intent is persisted before its draft write. Finish reloads
that intent and retains its draft/operation IDs across process relaunch, including
an interrupted separate-copy Save. Recovery copies associated with it are not
offered as independent unsaved reviews. Exact primary bytes and ordered cleanup
make the recorded retries idempotent; a late Finish cannot resurrect deleted audio.

Each independently owned repo passes **66 focused Core tests** and **54 controller
checks** with real private files and synthetic media. Four native cases pass each
on Mac, iPhone and iPad, with no reported runtime warnings. The new prepared-Save
case runs at dark/largest text on mobile, ordinary dark text on Mac; it interrupts
acknowledgement, actually terminates/relaunches the app, finishes the Save and
cold-reopens exactly one saved recording. This is not a mid-syscall power-loss,
real microphone/playback/TCC or spoken-accessibility claim.

`verification.json` binds current source/binary hashes and scopes. Native summaries,
strict verifier output, commands and selected actual captures are adjacent.
`owner-before-checks.json` records the one failing summary-isolation check before
the actor-owner binding fix; current checks all pass. Only synthetic data was used.

Ordinary app entry points and server publication remain gated. Atomic concurrent
review claiming, prepared-Save cancellation/quota and orphan/corrupt-file recovery,
retained attempts after unreadable state lookups, full Quit/background/raw-media,
removal/backup/export and private server lifecycle remain open. The user's genuine
audio deferral is unchanged. See [audio implementation/acceptance](../AUDIO_COMMENTS.md)
and [all Px items](../PX_CHECKLIST.md). The overall goal stays active.
