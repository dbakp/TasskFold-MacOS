# Exact copied-record comparison

Unchanged immutable Record copies now use their existing private source marker before walking every authored field. A fields write resets that marker; freshly decoded/reconstructed rows retain the exact comparison fallback. Equal TaskCache refreshes adopt the newest source for subsequent copy comparisons while retaining existing cached results, query counts and authored opaque bytes. Real content changes still invalidate. JSON/Codable and domain equality contracts are unchanged.

Both owners independently implement the change. Regression checks cover distinct array buffers, every fields-write form, nested edits, row order/length, reconstructed rows, Unicode, signed zero, NaN payloads and opaque raw-format equivalence. The full Mac suite ran before one supplemental test was added; the supplemental case passed separately with production unchanged. iOS full Core includes that case, and Watch tests pass. See core-verification.json for exact selected/skipped scope.

The same-host Debug diagnostic compares five passes over 2,000 records with the prior exact reference. Copied unchanged and tail-edit cases improve from roughly 143–157 ms to 3.8–4.7 ms. Reconstructed-equal rows retain comparable fallback cost. Answers match in every measured mode. This is comparison preparation evidence, not physical-device FPS or whole-app smoothness acceptance.

The optimized iPhone Simulator Store check is running; its result is not accepted yet. No physical iPhone installation or rollout-gate change.
