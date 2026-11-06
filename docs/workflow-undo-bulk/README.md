# Full-size workflow Undo evidence


## 26 October: full-size personal workflow Undo

A valid 5,000-task definition with sections, labels and ordering emits 20,001
records. The former 12,000-record cap silently removed its Undo history. Both
clients now retain one command for the full set, index history/restore work, and
check the normalized PostgreSQL JSON byte budget before saving any creation.
Oversized creation gives a clear message and preserves the exact saved cache.
Large commands require the additive bulk compatibility marker; older services
continue to admit only their supported smaller commands.

The new source-only migration batches typed baseline checks, dependency checks
and deletion while preserving ownership, session, replay and whole-set refusal.
It has not been deployed. Each repo passes 272 selected Core tests, 62 isolated
SQL safety checks and 19 scale checks. Both signed native builds pass. All five
installed scenarios pass on each iPhone/iPad Simulator (10 total), including
oversize rollback and cold return. Mac runtime remains pending: Developer mode
is disabled and the existing UI Automation approval question is unanswered.

A matched 1,000-task database comparison with the same payload and 5,000 outside
tasks improves from about 4.7s to 0.94–0.96s. The full 20,001-record command takes
about 4.8s in the pinned 1-CPU/512MB fixture. Global relation locks still imply
contention; these timings do not establish production latency or responsive
large-workflow creation. Large creation preparation/UI/persistence/delivery,
hosted and paired-client acceptance, wider rank-3/Px work and existing explicit
release/provider/reminder/older-client deferrals remain open.

See workflow-undo-bulk/validation.json and its retained reports. The initial
phone incoming-row assertion failed because the row was below the viewport;
the final check scrolls and verifies it is hittable, retaining exact saved-data
checks. The numeric budget expectation was corrected against actual PostgreSQL
rendering. Scale setup exhausted fixture locks/storage when accumulating cases;
seeding in bounded transactions and separate isolated contexts retained the full
workload. Final reports use identical backgrounds for the timing comparison.

Core logs use the selected suites documented in the dated plan. SQL/scale scripts
are self-contained local fixtures. Native logs cover five named scenarios each
on phone and tablet; signed Mac build acceptance does not imply Mac runtime.
