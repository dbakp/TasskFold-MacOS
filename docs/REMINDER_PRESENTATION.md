# Time Sensitive reminder presentation

This is an opt-in local presentation capability within rank 5. Normal alerts remain the default. It does not implement Critical Alerts, alarms that override Silent mode, emergency delivery, a guaranteed delivery time or server-delivered reminders.

## Native choices

An individual custom reminder has a Time Sensitive switch, default Off. It applies to From plan, Fixed time, Repeats and Interval, without changing the authored schedule, task plan, count or time zone. The draft retains the existing Cancel/Done and containing task Save/autosave/Undo contract. Workspace, task incarnation and original reminder rows are revalidated before applying. The automatic At planned time switch stays normal; add a custom reminder to choose presentation explicitly. Existing duplicate-time protection prevents a normal and Time Sensitive copy of the same reminder.

The separate Allow Time Sensitive reminders switch is Off initially for each workspace/account on each device. It is device-local and excluded from synced tasks, templates and portable backups. A collaborator may change a reminder on a task they can edit, but that does not grant this allowance on anyone's device. The allowance covers marked reminders in that workspace, regardless of who marked them. It does not request a new system permission or enable ordinary reminder delivery. Existing notification authorization is still required.

Before scheduling, the app reads current system notification settings. Elevated presentation requires both the device allowance and an enabled system Time Sensitive setting. Otherwise the same reminder uses normal active presentation. The screen explains disabled/unavailable system support and links to the existing system-settings action. Returning to the app refreshes scheduling/settings through the existing lifecycle. A system setting changed while the app remains suspended is still enforced by the OS; Taskfold does not promise immediate background queue reconciliation.

Focus finish alerts remain normal. Snoozing retains the exact original reminder identity/occurrence and the current device/system allowance. Normal delivery-off, account changes, task completion, access revocation, edits and deletion retain their existing cancellation/receipt rules. Device allowance changes replace pending content at the same instant, including existing snoozes, without changing task data. Already presented alerts are not retracted merely because the local allowance changes.

## Persisted and notification contracts

Version 4 wraps one validated local schedule. It has `presentation: "time-sensitive"`, `schedule_version: 1`, `2` or `3`, and the existing fields for that schedule kind. Channels must be exactly `["local"]`; the automatic planned ID is prohibited. Unknown fields survive supported edits. Malformed wrappers are unsupported and preserved, with no substitute planned alert. A legacy-version extension named presentation cannot elevate an alert. Turning the choice off restores the normal schedule version and removes the wrapper's known presentation fields.

The `r7` signature binds presentation to the validated underlying schedule signature, including task generation, completion revision and original occurrence. No legacy-signature fallback is issued. Changing presentation invalidates an old Complete/Tomorrow/Snooze response in either direction. Device/system presentation allowance is not a task edit and does not invalidate otherwise valid actions. Request content comparison includes the actual interruption level so an existing pending request is updated after an allowance change. Native content uses only active or timeSensitive, with the standard notification sound.

The selected previous readers independently compiled for this milestone treat the entire version-4 row as unsupported, preserve it through task edits, serialization and recurrence copies, and schedule no replacement alert. This verifies those revisions only; general older-client rollout enforcement remains deferred. Current readers preserve repeating schedules/choices on task successors without retargeting the completed original task's callback. Absolute reminders are omitted from successors as before. Queue serialization and portable backup retain authored settings, never device consent.

Version 4 is explicitly local-only. The owned server reminder validator recognizes only versions 1/2 and excludes it; no worker, schema, remote registration or delivery policy is changed here. This milestone has no new hosted-service delivery acceptance claim. Full remote reminders and their device/reinstall recovery remain deferred.

## Capability and acceptance boundaries

The main app's independent entitlements declare the Time Sensitive Notifications capability. Extensions do not request it. The current isolated Mac signing configuration has no provisioning profile for this capability, so a signed Mac build is blocked; compilation without signing and offscreen native component rendering are separate checks. The existing ad-hoc Mac distribution entitlements do not declare it, and use normal fallback when the system reports it unavailable. Genuine signed installation, enabled-capability behavior, Focus interruption and device-setting recovery require later distribution/platform acceptance, not another ordinary debug build.

Exact source hashes, core and native test outcomes, initial failures and remaining acceptance are recorded in `p2-reminder-presentation-evidence.json`. Holiday source/policy, location reminders, floating-device clocks, remote delivery and the remaining Px backlog remain open.

Apple references checked 21 October 2026: [interruption level](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive), [Time Sensitive capability setup](https://developer.apple.com/videos/play/wwdc2021/10091/), [notification design](https://developer.apple.com/design/human-interface-guidelines/managing-notifications).
