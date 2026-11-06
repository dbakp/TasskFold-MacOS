# Background widget publication

Large, fresh personal workflow saves may now queue widget rendering after their
private cache and commands are durable. Calendar-capacity refreshes use the same
queue. Each app owns its implementation. All other callers retain immediate
publication, including sign-out/access changes and widget completion receipts.

A value-only input captures the full projection on the app actor. A utility
worker constructs and encodes it. The queue runs one renderer at a time and
retains only its newest pending request. Cancellation never permits an old
success or error to publish or clear a newer projection. The final file
replacement stays on the app actor, behind workspace generation, session,
access revision, readable/sign-in state and account checks. A failed project
save requeues its restored state if its access revision changed. Cold startup
still loads and synchronously republishes the durable workspace.

No task/list limit, new rollout flag, server change or external dependency is
introduced. Widget completion acknowledgement and short feedback keep their
existing synchronous save path. The source model's child-history value is
Sendable; no unchecked concurrency conformance was added.

Core evidence exercises delayed uncooperative rendering, bounded concurrency,
coalescing, invalidated success/failure, latest failure/recovery, projection
parity, feedback expiry/account binding and empty-account redaction. Native
evidence holds a real app projection while invoking immediate sign-out
redaction, independently changes its access revision without cancelling its
queue ticket, then verifies recovery and unchanged saved data. Scale evidence
records save-return and full-widget-ready times separately. These are isolated
Debug measurements; production-screen rendering, durable-cache I/O, activity
history and hosted delivery remain separate work.

Final counts, metrics and invocation outcomes are recorded in validation.json.
Historical failed attempts remain identified there; the successful coverage map
is not a claim that every first attempt passed. Binary/source bindings identify
the exact tested inputs. No real workspace or Todoist content is used.

The reserved native host must be prepared with
`Scripts/prepare_team_editor_native_test.py --headings --output <new-folder>`.
The explicit flag is recorded in its receipt; normal source configuration stays
off. Native workflow startup checks the actual authoring state, so a missing
opt-in fails promptly instead of running a suite against a disabled button.
Mac widget text assertions read the Cocoa accessibility value when its label is
empty. These corrections affect synthetic acceptance, not normal rollout policy.

The fresh-directory proof creates its nonce-scoped result folder before testing,
waits a bounded time for a held renderer to start, and records failures as data.
iOS test entry now opens the local workspace before seeding its task. A missing
root says Unavailable; its Complete button stays disabled until its real token
is captured. This prevents an empty fixture from passing its initial state check.
Native assertions wait for the actual completed/open state after invoking an
asynchronous intent. These fixture changes have no release UI path.

The broad Mac matrix retains seven internal XCTest QoS warnings, the same count
and warning text as the previous scale stage. Its functional acceptance uses the
verifier's explicit runtime-warning allowance; it is not clean-runtime evidence.
The targeted fresh-directory Mac proof has no runtime warnings.

Debug timing now separates durable save return from complete widget readiness:

| Device | 1,000-task save return | Widget ready | 5,000-task save return | Widget ready |
| --- | ---: | ---: | ---: | ---: |
| iPhone Simulator | 1.52s | 2.34s | 6.82s | 19.27s |
| iPad Simulator | 1.39s | 2.23s | 6.96s | 20.08s |
| Mac | 0.89s | 1.76s | 4.45s | 18.63s |

The earlier 5,000-task synchronous save, including its widget publication, took
13.30/13.54/11.38s. Moving rendering off that path does not make total widget
availability faster, or prove responsive production input. The remaining 4–7s
save pause is still too long. Durable-cache I/O, normalization/local-history
scaling, full production rendering and hosted/paired bulk delivery remain open,
along with wider ranked Px work. All normal rollout flags and user deferrals
remain unchanged. No real workspace, hosted schema or service was changed.
