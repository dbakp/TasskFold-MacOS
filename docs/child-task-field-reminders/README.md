# Independent subtask reminder choices

29 October 2026. Each app repository owns its source, tests and evidence. Normal
child-read/write flags remain absent/off; saved root JSON remains authoritative.
This is another field-editor stage, not completion of the child migration or Px.

## Implemented

- Reuse the complete portable reminder composer and nested ReminderSpecEditor for
  a captured child workspace. Relative, fixed-time, calendar, interval, holiday
  and per-reminder Time Sensitive controls retain the existing implementation.
  The shared-root request initializer and its current-role checks remain intact.
- A child-specific request binds account/workspace/access, root generation/project,
  node and original editor revision. Its caller checks current parent write access.
  A stale Apply cannot target another editor. A private nested checkpoint retains
  its original child identity and unfinished schedule settings.
- Apply updates only the parent's private reminder draft. Save, review and Send
  remain separate. Cancel removes only the composer's own private edit; parent
  fields and saved task settings stay unchanged. Current normal reminder device
  permissions and server-delivery gates are not changed by these controls.
- Unknown/future/private-place/other-channel rows stay exact and locked. A reminder
  field intent emits only explicitly applied settings, preserves unrelated fields
  and can be reconstructed from an actual encrypted private checkpoint.
- Review describes local choices and Off/Enabled/Time Sensitive states without
  exposing raw JSON or private-place coordinates. Missing planned dates have an
  explicit cue; local/device delivery remains separately controlled.
- Mac composer uses a scrolling grouped Form with child controls retaining their
  own identifiers. Label removal also clears an obsolete local validation message.

## Verification and limits

Six new child reminder cases cover absent/null/unknown no-op storage, field-only
commands and restored Off state, exact opaque/extension preservation, atomic invalid
Apply refusal, encrypted applied/unfinished checkpoint readback and privacy-safe
review summaries. Each repo passes 223 selected cases: 70 child commands, 21 child
reads, 55 account transport, 69 backup and eight existing portable-reminder cases.
This filter differs from preceding stages; it is not a full-suite total.

The reserved synthetic native case checks composer Cancel first, then planned-Off
plus a nested ten-minute-before reminder, Apply/Save/review/Send and cold readback.
It removes that added reminder, sends and reopens again, verifying that the planned
reminder stays Off. Exact native results, build/signature checks, source hashes and
screenshots are recorded in verification.json. The separate largest-text/private-
cold regression checks the longer editor's saved feedback; cold readback uses
normal text size. Native tests use the frontmost collection viewport, including
nested composers and the recovery List, rather than the underlying sheet.

Actual alert delivery, device permissions, remote delivery and genuine/provider
schedule behavior are not established by a synthetic field transport. Native
calendar/interval/holiday/Time Sensitive modes, interrupted composer recovery,
shared/member/role/account/window races, Mac runtime/speech and genuine Keychain/
removal lifecycle remain open. Conflict review, general legacy repair, completion/
structure/legacy adapters and authoritative child migration remain open. Existing
user deferrals remain unchanged; the overall goal stays active.

The first native phase passes largest-text/private-cold recovery on each device,
but the reminder case pauses on opening/reopening its composer after Cancel.
The captured hierarchy shows no task write, no queued request and no private
remainder. Explicit request view identity alone is insufficient: v3 passes the
heading guard, but still reproduces the paused composer. The final ownership
change uses a presentation token and retains the editor revision while covered
by its own sheet. The composer also keeps its session while a nested editor is
open; initial nested settings are captured/flushed and nested presentations have
independent UI IDs. Normal task schedule IDs are unchanged. Final execution is
recorded independently; earlier failures are not counted as passes.

The v1/v3 runtime hashes and forward patches refer to the iOS native test host in
both evidence folders. Each repository's final source hashes are recorded on
their own. Reverse v4-to-final, v3-to-v4 and v1-to-v3 in that order against the final
iOS sources to reproduce intermediate runtime sources; native runtime has never been claimed for the Mac from this evidence.

The host-only diagnostic records every source guard as valid except the captured
presentation binding, which alternates absent/present/absent while the composer
remains visible. It contains synthetic booleans only. The temporary flag writer is removed from canonical views. A bounded
DEBUG-only lifecycle hook remains for the exact reserved synthetic host; it
records presentation UUIDs and literal closure reasons, not task content. The final child owner uses an observable reference lease,
closed explicitly on completion, cancellation, source/scene changes and newer
edits. It does not authorize a task write. Final execution is recorded separately.

The reference lease allows initial nested settings protection and Cancel to pass
in v6. The editor also performed its initial selection twice: directly after its
read, then through the key-change observer. Selection now leaves the current edit
intact when the key is already selected. With both changes, v7 passes the full
reminder journey independently on phone and tablet: Cancel with no queued/write/
private remainder; reopen; planned-Off plus add/edit a ten-minute-before reminder;
Apply, Save, review, Send and cold readback; remove the added reminder, repeat and
cold-read the exact Off setting. Both results report no runtime warnings.

Computer use still reports the Mac locked after the latest unlock reply. Mac
build/signature checks do not establish native layout or spoken acceptance.

Final regression phases also pass 2/2 independently on each device, with no
reported runtime warnings. They cover heading guards and largest-text saved
confirmation/private cold recovery. The two final largest-text screenshots and
four representative v7 composer/saved screenshots were visually inspected.

Owned apps are terminated, original Simulator VoiceOver preferences restored
(phone On, tablet Off), and both owned Simulators shut down. Completed result
bundles and exports were pruned after archiving summaries, logs and screenshots.
Reusable current builds, hosts and Core caches remain available.
