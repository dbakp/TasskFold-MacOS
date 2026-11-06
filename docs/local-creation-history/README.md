# Fresh local workflow history

Fresh personal workflows now record local task history in one synchronous pass
through their private working snapshot, before publishing or saving it. Root
event IDs/sequences and validated child event IDs/sequences are indexed once.
Non-task workflow commands no longer repeatedly validate the child ledger.

The pass admits only unique, already projected task POST rows owned by the current
account; it validates the full scope before writing metadata. Indices are private
to that call, released afterward, and never shared across workers/accounts. A
recording timestamp is captured for each appended task and reused for its root,
child and assignment annotations. There is no new persisted contract or migration.

Root ID idempotency and legacy sequence parsing remain intact, including unknown
old rows. Invalid child events or duplicate child sequences still refuse new
child history without blocking valid root history. Duplicate child IDs retain
the previous filtering/sequence-gap behavior. Overflow refuses the same entire
child action. Existing empty, missing and unknown epochs keep their old rules.
Assignment provenance uses its ordinary recorder, including orphan repair,
recurrence attribution and existing row identities. Case-aliased incoming task
IDs use ordinary sequential projection to preserve invalidation ordering.

Ordinary edits/deletes/retries retain individual recording calls. Non-fresh runs,
identity collisions and shared operations keep their existing Store path. Cloud
creation still queues every command. The normal Store validation, durable-save
failure rollback, account fences, one-step workflow Undo and immediate widget
privacy/receipt paths remain in place. No history is truncated or capped.

## Verification scope

The frozen pre-change control encodes root/child events, epochs and provenance
with sorted keys: 100 new roots/200 children plus prior immutable history and
replayed command IDs. Its SHA-256 remains
`b7d5c92f934e1e2af8103699b1d895b9d92f7c94fdcb0f8885e065d92c40ab4e`.
New checks compare batch and ordinary metadata, malformed-ledger refusal, duplicate
sequences/IDs, sequence limits, epoch variants, invalid-scope atomic refusal,
assignment/orphan/recurrence semantics and complete 5,000-root/child encoding.
Only newly generated provenance row/event nonces are excluded in its assignment
parity comparison; pre-existing row identities are asserted separately.

Native acceptance uses the reserved signed Debug host and synthetic data only:
1,000- and 5,000-root local workflows with 100 prior root events and 200 prior
child events, complete project/section/label/order projection and widget lists, a 1,000-root Undo,
and an injected failed disk save. A cloud-mode 1,000-root save and actual widget
intent completion/retry/Undo/cold return guard the surrounding paths. The failed
save deliberately injects an out-of-space error; it does not report real disk
exhaustion. Teardown restores the fixture snapshot and quits the test app.

These fixtures display task counts instead of rendering 5,000 production rows.
They do not prove production-screen interaction, release latency, native child-rich
workflow creation, hosted/paired delivery or distribution. Core full-size child
history has separate coverage. Assignment-heavy scaling and per-event timestamp
construction still need work. Save return and background widget readiness remain
separate measurements; neither is a responsiveness guarantee.

The broader ranked backlog remains active. Normal heading rollout flags,
release/provider/reminder/older-client/geofence deferrals and hosted services are
unchanged. No real workspace, Todoist account or external database was used.

## Accepted results

Each repo passes 162 distinct selected Core cases. The final test-only partial
child-duplicate gap assertion was expanded afterward and that case was rerun
successfully in each repo. Each signed Mac/iPhone/iPad host passes all five
requested cases, zero failures/skips/runtime warnings (15 platform/case pairs).
The reserved Mac host does not embed a desktop-widget extension; the intent case
runs the real intent through its test panel, not through an installed desktop
widget. iOS signatures include the app, extensions and test runner.

| Signed Debug fixture | 1,000-root save return | Widget ready | 5,000-root save return | Widget ready |
| --- | ---: | ---: | ---: | ---: |
| iPhone Simulator | 2.56s | 3.22s | 12.45s | 19.53s |
| iPad Simulator | 2.62s | 3.25s | 12.23s | 19.18s |
| Mac | 1.52s | 2.21s | 7.59s | 15.54s |

These local-history fixtures differ from the preceding cloud-mode measurements;
there is no pre-change native local baseline, so they are not an end-to-end speedup
comparison. The retained pre-change Core 100-root sample took 1.1075s; the
separate accepted 100-root batch samples took about 0.40s (iOS repo) and 0.64s
(Mac repo), with normal timing variation/other work on the machine. The full-size
5,000-root/child Core case and native local save remain slow. Repeated ledger
scans are removed; per-event work, durable encoding/I/O and background readiness
remain priorities before claiming a premium large-workflow interaction.

See validation.json, accepted-metrics.json, the three native summaries and actual
case logs, current-input-bindings.json, accepted-core.log, expanded-gap-case.log
and pre-change-control.log. Obsolete owned outputs are pruned after retaining
these bindings and summaries; one reusable native host/build per platform remains.
