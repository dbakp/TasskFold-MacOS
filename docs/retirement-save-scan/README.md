# Less reminder-retirement work during ordinary saves

Editing a task used to build an ID grouping for the entire proposed task library, then compare every old task, even when there were no location-reminder rows. The save now scans for the first raw location row before allocating that index. Once found, the existing processing runs for every remaining task. The unchanged-array fast path remains. This avoids extra per-row filtering in dense-reminder libraries.

The raw kind check is only a sufficient exclusion hint: a valid retirement ticket requires a location row. Disabled and unknown-version location rows still reach the original binder. The proposed-ID index still includes all tasks, preserving conservative duplicate-ID cancellation. Existing jobs, action ledgers, reset/cleanup guards and acknowledgements are processed even when no candidate exists. No data format, access authority, setting or rollout gate changes.

Both owning apps implement and compile their own change. Each passes 169 selected Location, snooze and wearable-receipt checks, including three new functional cases for disabled originals/duplicate IDs, unrelated edits retaining an old cancellation until explicit acknowledgement, and malformed/unknown reminder rows. Both signed native SDK builds audit their complete current sources and exact code images. This batch creates no Simulator or manual UI test.

Before/after Debug Core stage medians, milliseconds, for 2,000 tasks:

| Workload | iOS owner before → after | Mac owner before → after |
| --- | ---: | ---: |
| Unchanged tasks | 0.002 → 0.002 | 0.002 → 0.002 |
| No location reminders | 2.786 → 0.765 | 2.812 → 0.805 |
| One location reminder | 2.749 → 2.561 | 2.819 → 2.556 |
| All location reminders | 2.862 → 2.774 | 3.059 → 2.882 |

Seven samples each average five calls to the production staging API; fixture construction is outside timing. Sources and fixture code are hashed. These separate before/after processes measure this component; full save, encoding/file costs, rendering/navigation and physical smoothness remain open. Small dense/unchanged differences do not establish a general speed guarantee.

The first candidate checked a raw hint on every row. Its dense-reminder median regressed to 3.673 ms, so it is rejected and retained separately. An initial test also used an order-sensitive JSON reference encoding; both corrected baselines pass before the production edit. The final candidate preserves the old processing after the first location row, and its final results are the table above. Earlier failures are not counted as passes.

Completed Core module scratch and selected native compiler caches are cleaned with before/after free-space records. Accepted products, exact images/signatures, real data, backups and shared SDKs are preserved. Normal Mac updating still awaits the existing Xcode/App Groups signing prerequisite; phone installation remains deferred. No installed-app or broader workflow checkpoint is promoted by this component improvement.
