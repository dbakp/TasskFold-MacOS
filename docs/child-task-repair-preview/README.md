# Reviewed older-subtask repair previews

30 October 2026. **Read-only server foundation, disabled by default.** This is not an available repair feature and does not complete the migration checkpoint.

## Implemented and checked

- [x] Five explicit operations: make a non-list root into a list, assign a reference to an object, make malformed children into a list, wrap a scalar/array/null value while keeping it as `legacy_original`, and move an entire branch by positional path.
- [x] Preserve unknown fields, exact stored JSON numbers and distinct Unicode keys. Return the complete original and proposed JSONB values independently. The original SQL-null distinction is explicit; no task is manufactured for an empty source.
- [x] Resolve each path against the preceding proposal, validate all ancestors and bounds, and adjust destination positions when removing an earlier sibling. Reject moves into the source branch and unchanged placements.
- [x] Return invalid proposals with their remaining structural issue and no misleading partial task count. Valid proposals still report `mutation_available: false`.
- [x] Bind the repair digest to the full current root, account, existing adoption review, operations and proposed tree. Changing even the root title changes this digest. The initial adoption digest is checked before generating a preview; it is not itself a complete root fingerprint.
- [x] Keep the public entry point under caller RLS, then check live session, current personal/team custody and independent rollout gates. Revoked viewers, stale generations, moved roots and competing root writers cannot reuse a review. Archived tasks remain read-only reviewable.
- [x] Mark any existing projection, record or authority as `indexed_custody`. Structural validity never authorizes reconciling saved copies or reattributing history.
- [x] Each repository independently passes 133 checks in the pinned owned PostgreSQL fixture, with unchanged advisor findings. The fixture removes its own container. No real task, hosted schema, normal feature flag, Simulator or running app is changed.

## Still to implement, in order

- [ ] Archive the complete original root, SQL-null distinction, projections, records and authority atomically before applying anything. Preserve all competing copies and relevant recovery/history custody, with explicit quota bounds.
- [ ] Add apply/check/close and durable exact-request recovery. Under current locks, recompute and compare the full repair digest; reject stale reviews. Add reciprocal nonce fences with every existing writer, and permanent receipt recovery after access loss, deletion or disabled rollout.
- [ ] Resolve indexed-copy and history/attachment/discussion identity custody explicitly. Assigning a new reference must not silently reattribute existing history.
- [ ] Add strict native request/response types and bounded transport. Keep **both** original and proposed trees as opaque raw JSON; neither may pass through the generic floating-point JSON model or a dictionary that collapses Unicode keys.
- [ ] Add premium native before/after review, explicit operation controls and original export, with private draft admission, unreadable-workspace write refusal, account/window/reply fences and real Save/readback acceptance.
- [ ] Support larger-than-limit and unsupported-depth sources with an explicit workflow, without truncation or hidden drops. Normal editable-cache support for opaque payloads is a separate remaining requirement.
- [ ] Finish the wider shared client gate, lifecycle, secure-storage, concurrent work, workload and spoken checks before normal use. Keep all user-deferred rollout, provider and device work paused.

## Contract and limits

`public.taskfold_preview_child_repair(_body jsonb)` accepts only protocol, account, task ID/generation, project/workspace, the current adoption review digest and `changes`. Positional paths use zero-based indices into the root array and then each object's `subtasks`. Sequential operations address the immediately preceding proposal. A move's insertion index refers to the destination **after removal**; its parent path is supplied against the tree before removal and is adjusted internally.

There are 1–64 operations, at most 64 positional levels and source indices 0–999. Source and proposal each stay within 2,000,000 UTF-8 bytes; operations stay within 65,536 bytes and the complete request within 68,000. References are explicit, nonempty strings of at most 128 UTF-8 bytes both raw and NFC. Wrapper titles contain non-whitespace text and fit 500 characters and 1,000 UTF-8 bytes. A valid result must pass the existing 1,000-node, 24-level decoder. Overflow remains a named blocker, not a truncated success. No arbitrary field replacement or deletion operation exists.

`repair_reviews_enabled` and the parent `adoption_enabled` must both be enabled explicitly for previews; the new gate defaults false. There is no mutation route. Pure planner/path helpers are unavailable to client roles. Only the scoped read-only preview helper and public invoker are granted to authenticated callers.

PostgreSQL JSON operations preserve stored JSONB values; this does not claim to recover formatting or duplicate keys lost before the original value was stored. Every ancestor is validated because [PostgreSQL JSON setters](https://www.postgresql.org/docs/17/functions-json.html) can otherwise leave a target unchanged when an intermediate path is absent.

## Evidence and limits of verification

`sql.json` records all 133 named checks and migration hash. `opaque-reply.json` is a real synthetic database reply retaining `9007199254740993`, `1e1000` expanded exactly, and distinct Unicode keys on both sides. Its account/task IDs are disposable fixture identities. Preservation of large numbers is checked inside PostgreSQL and against raw response text, never through JavaScript numeric equality. `verification.json` binds source and evidence hashes.

Development testing caught and corrected an invoker call to a private UUID helper; the wrapper now casts the UUID directly and leaves complete request validation to the scoped entry point. A test's expected error for paused team reads was also corrected: caller RLS rejects visibility before the private helper runs. Final reports cover the corrected migration; preliminary 121-check runs are superseded, not additional feature coverage.

The full local Supabase stack remains unavailable: migration-history verification could not connect. The ordered dependency chain and candidate are executed directly in the isolated fixture, with advisor comparison. No hosted migration or full-stack deployment is claimed. App builds and native runtime were not rerun because this phase changes no app source or entry point; native repair integration remains unchecked and unimplemented.

Run from this repository: `node Scripts/Database/test-child-task-repair-preview.mjs`. The fixture enforces the storage floor before starting and owns its full inputs without a sibling repository dependency.
