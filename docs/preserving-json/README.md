# Exact JSON content through normal data paths

This phase adds a preserving JSON reader/writer to each independently owned app. Unknown numbers that cannot round-trip through Double and objects whose distinct UTF-8 keys Swift equates retain their validated raw JSON. Disk and request bodies remain ordinary JSON; opaque values never persist placeholder tags or quoted numeric substitutes. Ordinary Codable configuration remains available. The fallback Foundation writer refuses opaque values rather than silently converting them.

Production cache, request, backup, draft and recovery paths use the preserving codec. Auth session-only projections and lexical string parsing intentionally retain Foundation decoding. Widget snapshots outside the app source tree contain typed presentation values and are unchanged. Each app/extension target that shares the app Core sources registers its own codec file.

Checks cover unsafe integer/decimal/exponent families, exact Unicode keys, known-field edits, cache/pending baselines, portable and encrypted backups, cold readback, malformed and duplicate keys, placeholder collisions, concurrent codec calls, quotas, giant-exponent body estimates, legacy caches, sliced Data and UTF byte-order formats. Existing depth/collection/node/body limits also inspect preserved content; preserving a value does not bypass those limits.

## Limits

This is a scoped data-fidelity milestone, not completion of the broader older-subtask migration. A Record with ambiguous top-level dictionary keys is refused; opaque input with a non-default key-decoding strategy is refused. Native evidence uses synthetic personal tasks and a file-backed HTTP peer, not hosted services or genuine Keychain/account acceptance. Exact raw Unicode objects inside fresh child-field projection, main-list routing, indexed/history mapping, shared attachment/discussion custody, broader library/lifecycle/window/background/concurrency and spoken acceptance remain open. The 5,000-record benchmark measures a release-optimized component, not Store or UI responsiveness. Normal child feature gates remain off, and the user's rollout/provider/distribution/device deferrals remain unchanged. No SQL contract or hosted data is changed by this phase.

Verification results and source fingerprints are recorded in verification.json. Test skips are excluded from passed totals.

## Final results

Mac: 3,176 Core cases passed, 33 explicitly skipped, zero failures. Direct computer-use save/send/cold-return passed after authorized Terminal launch. App closed and process absence verified.
