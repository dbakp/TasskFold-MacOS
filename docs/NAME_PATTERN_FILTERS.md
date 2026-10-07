# Name patterns in saved filters

Both independently owned native apps support dynamic project, section and label name conditions. Exact Project/Section/Label conditions keep their existing stable IDs. Name patterns are useful for lists such as all home labels, all client projects ending in Work, or calls across several project sections. This implements the name-pattern part of the P0 query plan; it does not complete the full Todoist language or P0 acceptance.

## Expressions and builder

| Condition | Example | Meaning |
| --- | --- | --- |
| Project name matches | `#*Work` or `project matching:"*Work"` | Tasks in named projects ending in Work |
| Label name matches | `%home*`, compatible `@home*`, or `label matching:"home*"` | Tasks with any currently available label starting with home |
| Section name matches | `/*Calls*` or `section matching:"*Calls*"` | Tasks in any currently available section containing Calls |
| Section name is | `/Meetings` | Every section with this name, across projects |
| No section | `!/*` | Tasks without a section, including Inbox tasks |

`*` matches zero or more characters, across the entire name. Matching ignores case and accents using an invariant locale. Other punctuation, including `?`, is literal. `\*` matches a literal star and `\\` matches a literal backslash in an explicit pattern. The expression serializer escapes quoted values so these survive editing/relaunch. Surrounding whitespace is trimmed. Patterns take 1–120 Unicode scalars and reject internal control characters, dangling escapes and unsupported escapes. Names beyond the bounded 400-scalar evaluation limit do not match.

Use the builder's **Project name matches**, **Section name matches** or **Label name matches** control, or an explicit `matching:` expression when names contain spaces. Quoted project/label shorthands such as `#"Work*"` and `%"home*"` retain literal target resolution; use `project matching:"Work*"` or `label matching:"home*"` to request a pattern explicitly. Existing `project:`, `section:` and `label:` forms remain exact target selectors. Project patterns match real project names; use Inbox explicitly for the Inbox. Subproject `##` and ordered comma sections remain separate unsupported capabilities.

The builder explains that results follow renames and newly matching names. A newly matching project/section/label enters the result set; a renamed target that stops matching leaves it. Zero matching names is a valid dynamic selector; its negation matches eligible tasks outside that selector. Pattern conditions do not invent capture destinations or labels, even when only one current name matches. Exact target conditions still follow renames by identity and fail validation if their target disappears.

## Scope, caching and persistence

Patterns use the current account's available catalog, never task-title guesses. A task referring to an unavailable project, section or label is excluded from the affected name query even under NOT or OR. Section parent-project metadata must agree with the task. Both label UUID storage and the existing exact legacy-name aliases are supported; unresolved aliases do not broaden a negative query.

Task queries include project/section IDs, names and section-parent metadata in cache identity, alongside the existing label catalog and account. Renames, new targets, parent changes and revoked/missing references therefore cause a new evaluation without modifying task data. Pattern matches resolve against the catalog once per query rather than once per task. The editor likewise captures its catalog once per preview. Bounded wildcard matching uses dynamic programming rather than regular-expression backtracking.

Version-1 predicate fields are `project_name`, `section_name`, `label_name`, with canonical pattern strings. No operator, document structure, REST column, migration or backend rollout setting changes. The deployed saved-view constraint accepts this envelope. Each client retains its own parser, evaluator, builder, cache, widget projection and tests; neither builds against its sibling repository.

The existing unsupported-query preservation baseline is the minimum safe reader: iOS `c8d96f8`, Mac `362b3ad`. Both devices need this name-pattern implementation to edit/evaluate these fields. A reader without the fields must preserve the document and disable editing rather than substitute a default query. Clients predating that preservation baseline require upgrading. Quoted literal targets and existing stored target IDs retain their meanings.

Offline account-cache/queue encoding preserves the complete AST. Backup restore retains pattern strings while remapping exact target IDs into the destination account. Patterns then evaluate against the destination account's available names. The private widget projection uses the same native query and publishes matching open task IDs for eight civil days, plus its existing expiry/zone information. It publishes no query AST or pattern strings. Installed/configured widget acceptance remains a signing/distribution gate.

## Verification and remaining gates

Each own Core suite passes 508 tests, with four existing optional integration skips and zero failures. New cases cover bounds, Unicode/case/accent folding, escapes, anchored matching, literal selectors, parsing/serialization, no capture defaults, cache invalidation, missing references under negation/OR, section-parent mismatch, legacy label aliases, account-cache/queue encoding, cross-account backup ID remapping and matching widget membership/privacy. The 3,000-task/eight-day long-pattern fixture passes its two-second budget (0.134 seconds in iOS Debug and 0.282 seconds in Mac Debug under concurrent build load; 0.017/0.016 seconds in the optimized runs). The optimized FilterTests/BackupTests selection also passes all 79 tests in each repo without skips or failures.

Each independently owned `supabase/tests/name_pattern_filters.sql` passes against the deployed database. Actual authenticated owner writes/read/rename/delete succeed; foreign-account and anonymous reads/writes are denied. Fixtures simulate SQL JWT claims, not real native sign-in or HTTP transport. All transactions roll back; both fixture user and view counts are zero. RLS and schema were not changed.

Own unsigned Release app/widget and Debug UI-test-target builds pass; Mac Release is universal x86_64/arm64. Four isolated iPhone/iPad Simulator flows pass across light and dark largest accessibility text: builder validation, exact results, expression editing and relaunch persistence. Twelve inspected, unmodified captures and scoped results are recorded in [name-pattern-evidence.json](name-pattern-evidence.json). Largest text uses scrolling; the phone builder capture is a lower form viewport, while functional assertions establish the selected pattern. This is not a full surface or VoiceOver audit. Mac GUI runtime remains prohibited by the standing user constraint. Real paired native/account/offline/revocation/restore, provisioned widget hosts, physical devices and the full surface/VoiceOver audit remain unproven. Other Todoist grammar, hierarchy, assignee-name patterns, ordered query sections and full P0 acceptance remain open.

[Todoist's official filter reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), checked 7 October 2026, documents `%home*`, `#*Work`, section patterns and `!/*`. Taskfold's literal-selector, folding, escaping and compatibility rules above are explicit native contract choices. [Supabase RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security) describes the permission boundary used by the rolled-back fixture.
