# Quick-entry suggestions

Taskfold's native capture and task-title editors show searchable directory choices beside the cursor. They use the same saved project, section, label and member identities as the normal task fields. Each repository owns its model and native view; there is no sibling checkout dependency or new backend schema.

| Type | Choices |
| --- | --- |
| `#Cli` | Matching projects and labels, with distinct icons/type labels |
| `#project:Cli` | Projects only; archived projects are excluded |
| `@Cli`, `%Cli`, `#label:Cli` | Existing labels |
| `/Ne` | Sections of the selected project |
| `+Al` | Current members of the selected project; pending, declined and revoked invitations are excluded |

Names can have spaces. Choosing a result supplies a quoted reference and the selected directory identity, so duplicate names do not select an arbitrary row. The project form uses `#project:"Client Work"` to avoid a project/label name collision. Search ignores case and diacritics, ranks prefix matches first, then sorts deterministically. An empty prefix shows the available directory. All matches remain reachable in the scrolling list; choosing a project is required before showing its sections or members. Quoted prose, escaped markers, URLs, email addresses and ordinary file paths are not suggestion triggers. Names containing a quote or newline remain available through the normal field controls; they are outside this reference grammar.

A choice replaces the current reference token, preserving later task-name text and moving the insertion point just after the new reference. Selecting a text range hides suggestions. The X/“Keep reference as text” action, or Escape while the list is active, keeps the words literal. Choosing a result explicitly reenables its field group if it had previously been declined. The normal removable chips can still keep accepted reference text in the title. With a hardware keyboard, Up/Down changes the highlighted result and Return/Tab selects it while the list is active; normal submission remains available when it closes. In capture, the onscreen Done key chooses the highlighted result first, then submits on a later press. A single inserted return is handled for native multiline fields; pasting multiple lines does not submit the draft. Hardware keyboard and Mac runtime acceptance are tracked separately from compilation.

On iPhone, choices remain in the draft until Save or More; More passes resolved task fields to the full editor. The Mac capture panel uses the same normal Add transport, including Day planner capture. In the Mac inspector, choosing references applies those reference fields through its existing autosave queue; other pending date, priority and reminder pieces stay available for normal acceptance/decline. Autosaved title text does not erase the inspector's pending parsing feedback.

The selected ID is draft-only and is revalidated against the current permission-scoped directory when parsing. Removed/renamed projects, removed labels, changed project scope or revoked members cannot silently select another row with the same name. A deleted selected label cannot be recreated from its ID. Persisted tasks carry the existing stable field IDs, not a separate suggestion or account model. Existing workspace-generation, save/merge, assignment-cleanup, offline queue, sync and backup rules still apply.

The public capture vocabulary was checked against [Todoist Quick Add](https://www.todoist.com/help/todoist/features/use-task-quick-add-in-todoist-va4Lhpzz) on 6 October 2026. Taskfold retains its established `@`/`%` label and `#` compatibility behavior. New-project creation, richer natural-language grammar, physical/iPad, Mac runtime and paired native/offline acceptance remain tracked P0 work. This document describes the supported suggestions, not complete Todoist parity.

## Dates, times, repeat rules and reminders

The same cursor menu now previews the supported planning vocabulary. Each offered phrase is run through the actual quick-entry parser with the current task draft before it appears. The displayed date, time, repeat summary or reminder instant/offset comes from that result. A choice supplies editable text; normal chips, Save, More and Mac inspector autosave still apply the fields. The menu does not introduce another persisted date or reminder model.

| Start typing | Example choices |
| --- | --- |
| `tod`, `tom`, weekday prefixes | Today, tomorrow or the next matching weekday |
| `next ` | Each weekday |
| `in 2 ` | Days, weeks, months, hours or minutes |
| `at `, `at 9` | 12/24-hour clocks and half-hours; a time without a date uses today |
| `ev`, `every `, `every! ` | Day/week/month/year, weekdays/weekends or named weekdays; `every!` anchors after completion |
| `every 2 w` | Two weeks, with supported weekday patterns |
| `every month on ` | First Monday, last Friday or the 15th |
| `!`, `!30` | Fixed reminders from now, or offsets before/after the plan |
| `!tom` | Tomorrow at 9 AM |

These are offered templates of Taskfold's supported grammar. The existing [repeat controls](RECURRENCE.md) and [reminder controls](REMINDERS.md) remain available for custom choices. Numeric intervals are checked by the real parser. Duplicate reminders and additions beyond the 20-setting limit are not offered. An offset without a plan explicitly shows that it waits for a planned date; date-only tasks use 8 AM. A fixed reminder retains its instant after task rescheduling. Adding only a time retains an existing planned date; when no valid plan exists, it uses the current calendar’s local day. The preview states the resulting date. Mac capture previews and Save use the same inherited filter/list/Day planning fields. Time-relative phrases are resolved when saving, as in normal quick entry.

Choices preserve the rest of the title and move the cursor after the selected phrase. Menus close after the phrase's trailing space. A cursor inside a recognised repeat phrase with a later start/end/count limit, or a reminder with a later clock, never replaces the longer phrase and removes those settings. Quotes, escapes, URLs, paths, email and directory references do not trigger planning choices. Keep as text disables the relevant field; a complete reminder uses its individual token so other reminders remain accepted. Dismissing an unfinished reminder retains that already-literal fragment and leaves earlier reminders accepted; editing it into a new valid phrase is a new parsing choice. Choosing that token again explicitly reenables it.

The same native rows, scroll area, 44-point targets and keyboard controls serve planning and directory results. Done selects the highlighted result before capture submits. The iPhone editor leaves choices in its draft until Save/Cancel. Mac inspector references retain immediate application; planning words retain chips for acceptance/decline and apply through its normal Return/focus-exit autosave. Existing workspace-generation and current-record guards still protect every save.

Richer natural-language grammar, independently repeating reminders, native Mac/hardware keyboard, paired/offline/account, physical/iPad and installed-widget acceptance remain open. This menu is not a claim of full Todoist Quick Add grammar parity.


### Named dates and period choices — 6 October

The planned-date menu now offers `next week`, `next month`, `next year`, `end of month` and `end of year`, with previews from the actual parser. Full English named dates can be typed directly into a plan, a brace-delimited deadline or a repeat start/end boundary. The exact syntax, omitted-year policy and Taskfold weekday behavior are documented in [Repeat rules and named dates](RECURRENCE.md#named-planned-dates-and-deadlines). Named-month/day autocomplete is not included; complete phrases still produce their normal declineable chips. Independent repeating reminders and the remaining richer grammar/device acceptance stay open.
