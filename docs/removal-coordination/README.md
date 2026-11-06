# Coordinated account-removal recovery

This follow-up prevents separate current app processes from overwriting the shared private removal journal. The lock covers the whole read/validate/change/write transaction for all accounts in one service. Exact duplicate confirmation and cleanup acknowledgements are idempotent; stale acknowledgements cannot replace a newer same-account command.

The Store can acknowledge cleanup completed by another process only after a successful journal read, no pending entry for that account, a matching server origin and the existing server-confirmed removal fence. A missing journal entry alone does not authorize data erasure. A matching old session is cleared; a newer cloud account and a local workspace are preserved. A failed clear of the same account keeps recovery pending.

The six new Core cases cover two independent vaults, overlapping account changes, an external process holding the actual file lock, duplicate acknowledgements, newer-command protection and separate service namespaces. Native acceptance uses the real Store, private Keychain session/removal records, encrypted backup keys/files and account caches, with synthetic accounts and a simulated endpoint. It does not establish genuine Mac Auth/Storage deletion or residual-file repair.

The existing isolated hosts/products are reused. DEBUG acceptance needs both an exact reserved bundle ID and an explicit proof flag, uses a dedicated removal/session service, and never calls the real server. Normal/release behavior has no fixture path. The iOS UI fixture's expected synthetic account paths follow the new isolated identities.

Expired pre-proof legacy attempts, residual server-file repair, genuine Mac deletion and broader failure variants remain open. All user-paused rollout/provider/distribution work remains paused.

The Mac runtime attempt stopped immediately after the reserved-journal check at the first protected-session write. Its exact failure is retained in `mac-keychain-block.json`; this is a failed acceptance attempt, not a passing Keychain check.

The first iPhone pass accepted finished-elsewhere reconciliation (30 assertions), expired-authorization retry (17) and late account-switch handling (19). Review then found that remembered A also needed reconciliation when unrelated B remained queued. The final Store reconciles after every pass; the added native assertion checks A signs out while B's exact command/cache/encrypted backup remain and B retains a recovery warning. Final acceptance is recorded separately from these v1 results.

The process lock coordinates participating current clients. It does not make an older binary that ignores that lock safe; the separately paused older-client rollout gate remains.

Final acceptance: both full apps build and pass strict signature verification. The final iPhone Simulator scenarios pass 32 / 17 / 19 recorded assertions, including queued B preservation during A reconciliation. Both repositories retain their 30 passing focused Core checks. Mac runtime remains unaccepted; its earlier protected-write failure is retained rather than replaced with a passing synthetic-memory check.
