# Cancellable workflow preparation

Template instantiation now runs on an owned background task. The Use template
sheet shows a pinned bottom progress indicator and Cancel; its inputs and Create action stay
disabled until preparation ends. Closing the sheet also cancels preparation.
Cancellation is checked while processing projects, sections, tasks, nested
children, labels, list orders and the final command tagging pass. No partial
result is sent to Store. A cancelled request cannot later publish its result,
even if a worker finishes as cancellation arrives.

Before saving, the UI checks the original workspace incarnation, auth-session
incarnation, source document, label catalog and active destination. An earlier
save failure keeps the prepared command for retry; that retry uses the same
check, discarding stale prepared commands instead of applying them in a changed
workspace. Existing Store validation and durable Undo remain in force.

The Core cancellation regression uses a valid 5,000-task project and checks an
interruption after hundreds of steps, unchanged source, a complete retry, and
stable row identities for that run. Separate cases check nested cancellation,
a genuinely cancelled detached task and changed request contexts.

Installed cancellation tests use the production Use template sheet and Store
with a synthetic local peer. A reserved DEBUG-only argument holds preparation
for 10 seconds so automation can cancel or close the sheet. They observe the
saved cache and peer beyond that delay and verify no late save, then verify retry
or cold return. The normal build never takes this fixture branch.

Scope: this moves instantiation off the UI thread. Definition decoding/preview,
Store normalization/projection, local activity, disk I/O and remote delivery
still need full-size responsiveness acceptance. The Core scale workload is not
an installed 5,000-task UI benchmark. Mac runtime remains pending existing UI
Automation approval; no permission change or unchanged-state retry is performed.
No hosted schema, rollout, provider or release setting is changed.
