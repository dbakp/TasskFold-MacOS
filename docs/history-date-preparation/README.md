# Local history date preparation

Sampling a current isolated Mac 5,000-root local save found repeated ISO8601
formatter setup in root state normalization, root validation/timestamp creation,
and assignment annotation. The sample is diagnostic evidence; it is not a
precise CPU percentage or an unprofiled latency comparison.

Local recording now owns lazy fractional/whole-second formatters, raw UTF-8
instant/day memos and one last formatted date for a synchronous pass. A fresh
workflow shares that context across its root/child/provenance records. Ordinary
recording calls own separate contexts; a large assigned checklist can reuse its
one timestamp. Unassigned/legacy/recurrence provenance no longer constructs an
unused timestamp. No context survives the call or crosses accounts/threads.

Normalization still tries fractional ISO8601 first and the whole-second fallback,
uses the same fractional UTC output and day validation, and keeps invalid inputs
invalid. The default external state/stamp helpers and read-side parser retain
their previous behavior. All row/type/identity/sequence/epoch/ledger/overflow
checks still run; there is no new persisted format, retention cap or migration.

Before the implementation changed, a 375-case deterministic corpus froze output
for root/child create, completion, reopen, reschedule and deletion. It includes
whole/fractional/offset dates, long fractions, pre-epoch/future/leap/DST inputs,
invalid days/instants, empty values, Unicode spellings, headings and refusal
results. The sorted output SHA-256 remains
`901745ac563fae6de8dab06750891d3a603061398928f060dde2db55861db977`.
The earlier creation-history digest is also retained unchanged. Mixed-spelling
creation batches match ordinary metadata; full-size child history and existing
history/provenance/overflow/Undo checks remain covered.

Native acceptance repeats the preceding stage's same five cases on each signed
Mac/iPhone/iPad Debug host: cloud-mode 1,000-root creation; local 1,000/5,000-root
creation with prior immutable root/child history and one native Undo; injected
save-failure recovery; and real intent completion/retry/Undo/cold return. This is
15 platform/case pairs. Mac's reserved host uses the actual intent through a test
panel and does not embed a desktop widget extension. Native workflows are flat
and show counts instead of rendering 5,000 production task rows. Child-rich
history scale has separate Core coverage, not native creation acceptance.

The broader goal remains active. Durable encoding/I/O, the remaining save pause,
background widget readiness, assignment-heavy scaling, production-screen input
responsiveness and hosted/paired bulk delivery remain open. Normal rollout flags
and the user's release/provider/reminder/older-client/geofence deferrals remain
unchanged. No real task/account, Todoist source or hosted service was used.

## Accepted results

Each repo passes 164 actual selected Core tests against final production source,
including both frozen byte comparisons and the new mixed-date case. All five
requested cases pass on each final signed native host, with zero failures, skips
or runtime warnings (15 final platform/case pairs). Earlier native rounds before
the ordinary-assignment timestamp correction are superseded by these final runs.

| 5,000-root local fixture | Previous save return | Current save return | Previous widget ready | Current widget ready |
| --- | ---: | ---: | ---: | ---: |
| iPhone Simulator | 12.45s | 1.90s | 19.53s | 8.83s |
| iPad Simulator | 12.23s | 1.88s | 19.18s | 8.83s |
| Mac | 7.59s | 2.03s | 15.54s | 10.09s |

These are Debug observations from the same case definitions under varying system
load, not release guarantees or production-screen interaction measurements. The
sampled run is excluded from the timing comparison. Widget readiness is measured
from the start of the save; its earlier finish mostly reflects the shorter save.
Background widget construction still takes roughly another 7–8 seconds after the
save and remains open. The roughly two-second main-thread save pause is also too
long for a premium interaction.

Core's full 5,000-root/child recording sample is now about 1.8s in each repo,
versus about 14.0s/21.7s in the preceding accepted rounds; load varied, so these
are diagnostic scale observations, not benchmark thresholds. No row, history or
widget-list quota was introduced to obtain the improvement.

See accepted-metrics.json, previous-stage-metrics.json, validation.json, the three
native summaries/case logs, current-input-bindings.json and accepted-core.log.
pre-change-date-corpus.log preserves the pre-refactor output digest; the sample
excerpt and sampling-control.json retain the scoped diagnosis. One reusable
native host/build per platform remains; obsolete owned test outputs are pruned.
