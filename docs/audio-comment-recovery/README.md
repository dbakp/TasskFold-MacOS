# Recoverable private audio reviews — gated candidate

Validated recordings and exact captions now have a separate account-private
recovery copy. Interrupted reviews can be reopened without replacing an earlier
saved draft. An unconfirmed checkpoint retains its frozen revision before newer
caption updates; only the original owner/task can resume a retained write.

Saved-draft conflicts offer **Save as separate draft**. The running presentation
keeps that copy's identity stable through uncertain retry. Known pre-write quota
and lock failures remain editable; explicit discard does not restart a failed
checkpoint just to delete it. Exact possible committed revisions are checked
before removal, preserving any different version written by another window.

`verification.json` binds the current sources/binaries and completed native
results. Each repo independently passes **55 focused Core tests** (on this Mac)
and **42 actual-controller checks** using its real private vault and synthetic
media drivers. `quota-before-receipt.json` records four reproduced failures with
the pre-fix controller paths; the current controller passes all four.

The current native suites pass **6/6 each on Mac, iPhone and iPad**, with no
reported runtime warnings. The six native cases cover review/save/reopen and silent playback controls,
initial synthetic refusal, refused replacement preservation, dark review/largest
mobile text, interrupted-review recovery after an acknowledged checkpoint, and
explicit discard/cold return. `captures.json` maps selected actual screenshots.
See each final summary and strict verification text for accepted counts/warnings.
Intermediate test/build issues remain in `diagnostics.json`.

This is still an isolated candidate. No ordinary task/conversation entry point,
private server publication, or release gate was enabled. These checks do not prove
normal Quit/background preservation of unsynchronized or partially recorded audio,
real microphone/speaker/TCC/interruption behaviour, spoken accessibility, account
removal, backup/export policy, or durable explicit-Save/recovery linkage after an
uncertain-save relaunch. The user's real-audio deferral remains in force.

See [the complete audio checklist](../AUDIO_COMMENTS.md) and
[all Px items](../PX_CHECKLIST.md). The overall Px goal stays active.
