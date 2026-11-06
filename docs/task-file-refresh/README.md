# Refresh saved file recovery before continuing

Reviewed 2 November 2026. Both repositories own their implementation independently. No hosted service, schema, normal-use flag or real tasks changed.

A stale upload window previously retained its safely guarded original but suggested checking or retrying, even when another window had replaced the journal. Recovery can now be refreshed explicitly without closing the sheet. Failed upload-state transitions, recovery reads or clearing block sharing, status/Stop and clearing until a successful read loads the latest journal. The current displayed original remains available for private export. Successful refresh clears stale warnings, observes a replacement or an empty journal, and never publishes, resolves or cancels remotely.

Network uncertainty remains distinct: a dropped reply keeps the same attempted upload and its existing status/retry actions. Refresh does not turn a local read into a server status check. Conditional journal writes and account/origin/session/lease checks remain in force. A late reply cannot overwrite another window's confirmation. Reading recovery after a scope change cannot populate the next account's UI.

Both own focused Core suites pass 72 checks, including six new scenarios: stale-window replacement, competing confirmation before a late reply, failed refresh retaining original bytes, initially unreadable recovery, a cleared journal and lost network confirmation. Tests use actual encrypted file journals; synthetic transport covers network responses. Current native/build results are recorded separately in verification.json.

The native test uses the actual file sheet/model and encrypted journal. A second model on the same isolated vault changes the saved upload; this is not a real multi-process or multi-window test. It then verifies a stale Share is blocked before dispatch, refresh shows the replacement without changing its ciphertext, cold return preserves it and explicit local removal does not change tasks. This does not prove provider publication, actual account switching, human VoiceOver, largest text, background/reinstall behavior or the remaining Mac runtime work. Existing user deferrals remain unchanged.

Reproduce after the storage-floor check with the own Swift package filter `TaskFileUploadTests|TeamTemplateCommandTests|TeamOrganizationCommandTests`. For isolated native acceptance use `testTaskFileNativeStaleRecoveryRefreshAndColdReturn` on the owned phone/tablet products; normal publication stays disabled. Preserve concise evidence before pruning obsolete test results.

The phone and iPad stale-state screenshots were visually checked: the refresh explanation, preserved original name/size and private-copy action are readable. Native tests assert the stale mutation controls are disabled; screenshots alone are not treated as proof of their behavior.


### 2 November 2026 · Account-cache oracle correction

An audit found that the iOS `audioTaskRows` helper compared an unrelated generic `ui-testing.json` fixture cache while the active TeamEditor account uses its UUID cache filename. Earlier assertions made through that helper do not establish active-task preservation. Independent UI, exact-byte and encrypted-vault proofs keep their original scope. The helper now selects the explicit account cache without fallback; corrected phone/iPad reacceptance is tracked in [the current audit](../task-file-workspace-sync/oracle-audit.json).
