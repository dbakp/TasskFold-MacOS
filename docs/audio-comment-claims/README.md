# Concurrent local audio recovery and cancellation

The private local Save transaction now arbitrates recovered-review ownership across
independent editors. Exact content reuses the winner; a different edited review
requires a deliberate separate copy. A locked catalog avoids duplicate-looking
Saved, recovery and pending rows without hiding different edits.

Pending cancellation first persists a discarding phase under the same operation.
Relaunch can finish that discard without decoding or playing audio, and a stale
Save cannot revive it. An already committed recording refuses pending cancellation;
finishing its Save preserves it. Cancelling an unfinished replacement retains the
earlier exact saved version. Full logical entry quota is covered. The new private v2 formats retain strict v1
reads; this does not establish compatibility with older writers or reopen the
user-deferred rollout safeguards.

Each repo independently passes **79 focused Core tests** and **62 actual controller
checks**. `processes.json` records two executable PIDs establishing source snapshots
before a barrier release, actual POSIX file-lock arbitration and one resulting
recording with no pending/recovery copy. This proves the observed file transaction,
not a mid-syscall power-loss or full application lifecycle guarantee. The process
proof links this repo's Core on macOS; Simulator acceptance is separate.

`source-bindings.json`, `controller.json` and `core.log` bind the checked implementation.
Native acceptance and inspected captures are recorded alongside these files.
Generated media and a silent player were used. Real audio remains user-deferred.

Open before ordinary exposure: orphan/corrupt-file recovery, retained attempts after
unreadable state lookups, active raw-media and Quit/background ownership, account
removal and backup/export rules, ordinary task integration, private server access/
custody/publication, real permissions/audio/interruption and spoken acceptance.
The overall Px goal remains active. Prior checkpoint limitations remain except for
the recovered-review claiming and prepared-Save cancellation completed here.


Final acceptance: four selected native cases pass each on ARM64 Mac, iPhone
Simulator and iPad Simulator, with zero failures/skips/reported runtime warnings.
They cover ordinary reviewed Save/cold return, preserved already-committed audio
after refused pending cancellation, durable discard after acknowledgement loss
and relaunch, and exact single-draft Finish Save recovery. The last two use dark
largest mobile text. Final captures were inspected; the phone action is fully
visible after normal scrolling. Native initial failures and the Form-action/test
query corrections are recorded in audio-comment-claims/. Hardware, spoken and
full application/server lifecycle acceptance are not implied.
