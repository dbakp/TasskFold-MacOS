# Subtask ordering and saved-request review

29 October 2026. Both app repositories independently own these changes. Ordinary
child read/write flags remain absent/off; no hosted migration or real task/account
mutation occurred.

- The subtask picker now follows verified parent-first traversal and saved sibling
  order, rather than internal-key sorting. Its first selection is the first saved
  node. Nested choices are indented and expose their level to accessibility.
- A removal confirmation captures its exact entry, original recovery model and
  workspace scope. Workspace departure clears it, and an action cannot dispatch
  into a replacement account's model. The model still checks its scope/lease.
- A refused discard rereads the durable journal. If another window attempted or
  coalesced a request, the next review shows its current phase/body. If rereading
  fails, stale entries are hidden and the existing Read again action is available.
- Unknown service errors after sending use the existing unconfirmed-result message
  rather than exposing raw network diagnostics. Typed service refusals and
  cancellation keep their distinct behavior; the original attempt stays durable.

## Verification

Two new discard cases reproduce two failures on the old controller. A strengthened
lost-reply message assertion independently reproduces one failure before error
normalization. A new shuffled-envelope fixture proves saved sibling order, parent-
first traversal and nesting depth while retaining exact reconstructed source.
Final Core/build/native results, phase/source hashes and cleanup are recorded in
verification.json.

Native checks use the existing exact-allowlisted isolated owner host with synthetic
HTTP peer/key/accounts. They do not establish actual shared/team/multiple-window
Store lifecycle or hosted delivery. The two-window refusal conditions are tested
at the real journal/controller boundary; actual simultaneous app windows and
account changes while a system confirmation is live remain open.

The wider child migration remains unfinished: additional field controls/conflict
review, structure/completion/legacy adapters, genuine Keychain/removal lifecycle,
clean Mac runtime, speech and hosted/paired acceptance. Existing user deferrals
remain unchanged.

Both final app/test builds pass and strict app/runner signatures verify. The first
iPhone native case passes uncertain-discard Cancel/confirm and cold return before
message normalization; its UI/removal code is final. The final-source iPhone case
passes lost-reply/cold retry with one write across two requests. Both report no
runtime warnings. Direct Mac computer use verifies the readable warning, Cancel
and synthetic request removal, then final plain-language uncertainty and exact
retry (one write, two requests). No new Mac XCTest or warning-free-runtime claim
is made. The nested menu itself has not received native visual/speech acceptance.
