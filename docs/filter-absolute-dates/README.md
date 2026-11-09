# Absolute dates in local filter descriptions

Complete descriptions now accept exact ISO Gregorian dates for planned dates and deadlines: “Open tasks planned after 2032-04-05” and “Tasks with a deadline on 2032-04-05”. Existing strict before/after, completion, priority, project, alternative and exclusion handling stays in place. Date-like quoted names/search remain literal. No model is invoked for recognized descriptions; incomplete or malformed wording still refuses this local path.

Validation requires the entire unquoted token to be ten ASCII characters YYYY-MM-DD, and an actual Gregorian day in UTC. Invalid leap days, month/day rollover, year zero, non-padded or localized digits, slash dates, timestamps and trailing text are rejected. This validation never resolves a relative date to today's absolute value. Existing relative and saved-filter semantics are unchanged.

Six new functional Core cases cover actual planned/deadline counterexamples, strict bounds/missing dates, composition, leap/format refusal, literal targets/search and local-origin drafts. This is parser/Core acceptance; no new native, iPad, speech, installed-update or raw-model quality acceptance is claimed. Both independently owned apps include their own source/tests. Model-engine, local-first routing and source/privacy/explicit-save guards are byte-for-byte unchanged.

A separate typed demonstration model experiment failed its unchanged twelve-case quality check and was rejected before this feature. Its original candidate, observations and exact restoration are recorded under ../filter-example-context. Absolute date support is independent deterministic functionality; it does not close that model-quality gap.

Both owners execute50 focused Core cases:48 pass and2 explicit real-model cases skip. No full SDK rebuild is claimed for this pure parser change. Generated module scratch is removed and both selected Core caches remain below768MiB; no Simulator is booted.
