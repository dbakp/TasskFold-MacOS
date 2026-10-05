# Taskfold P0 implementation and verification

Objective: complete all P0 work from `TODOIST_PORT_PLAN.md`, implement the proposed productive widgets, retain a premium experience, and verify functional and data parity between iOS and macOS. Started 5 October 2026. The full objective remains active until every requirement below is proved in current source and runtime behavior.

## Required outcomes

| Requirement | Required evidence | Current status |
| --- | --- | --- |
| Current Todoist API import with preview, pagination, labels/sections/child relationships, replay safety, supported planning fields and explicit warnings | Response fixtures, transactional integration tests, deployed endpoint smoke test, native preview/import walkthrough | In progress: API v1 importer deployed as v39; 10 API/handler tests and rolled-back database fixtures pass. Native UI and actual provider-account round trips remain |
| Quick entry for project/section, assignee, richer recurrence, duration, deadline and reminder tokens; escaping and declined chips | Shared parser fixtures and creation/edit walkthrough on both clients | Pending |
| Saved filters, favorites, grouping/layout/sort and synchronized view preferences | Query fixtures, offline/relaunch, iOS-to-Mac and Mac-to-iOS tests, access revocation | Pending |
| Independent deadline and planned date | Old-cache codecs, editors/badges/bulk actions, reschedule/undo/recurrence/import cross-client checks | In progress: schema, editors/badges, quick entry and recurrence copying implemented; bulk/query/two-client evidence remains |
| Duration estimates and hourly time blocking | Hour-slot UI, overlap handling, drag/resize undo, time zone/DST and sync tests | In progress: estimates in both editors/import/quick entry; canonical fixed instants and reminder travel/DST checks pass. Hourly planner remains |
| Multiple absolute/relative reminders and remote delivery | Scheduling/cancel fixtures, permissions/failure feedback, physical/background delivery, deduplicated backend delivery | Pending |
| Export, versioned backups and validated restore | Malformed-file rejection, preview, ID mapping/replay, pre-restore backup, cross-client recovery | Pending |
| Configurable My list widget and interactive complete | Independent instances, rename/deletion fallback, account isolation, durable recurring completion, installed hosts | Pending |
| Deadline radar | Real deadlines and link/ranking checks | Pending |
| A small window | Known duration within 10/25/45 minute budget; unknown estimates labeled/excluded | Pending |
| Day capacity | Known task minutes, working hours and calendar busy events; honest unknown estimates | Pending |
| Project pulse | Explicit scope/denominator and reliable complete/reopen history | Pending |
| Inbox reset | Correct Inbox count and direct triage without arbitrary date assignment | Pending |
| Pinned note | Explicit selection, readable content, privacy and synchronized entity/description | Pending |
| Focus session | Persisted timestamp state, pause/resume, restart/relaunch/device switching behavior | Pending |
| All work available after device switching | Tasks/fields/views/favorites/order/notes/sessions/history round trips using isolated account; offline queue and conflict cases | Pending |
| Premium and usable native flows | User walkthroughs on iPhone/iPad and Mac, keyboard/accessibility, empty/error/loading, light/dark/layout checks | Pending |
| Provisioned widget distribution and app packaging | Installed WidgetKit hosts and signing/build/package evidence; explicit external credential limitations | Pending |

## Evidence rules

Do not mark a requirement complete from compilation or a narrow unit test. Record source revision, test scope, runtime results and any missing integration evidence. Use isolated fixtures rather than real task data. Preserve the original objective if a provider, signing or permission prerequisite needs user action. Production credentials are never stored in clients or written to this document.

## 5 October: import and planning foundations

- Applied additive `p0_planning_foundation`, `fixed_planning_instants`, and `restrict_legacy_email_lookup` migrations to the existing Taskfold Supabase project. Mirrored migration history into the web reference repository for reproducible dependencies. No user task data was changed by the integration tests; each fixture transaction rolls back.
- Replaced REST v2 with API v1 envelopes, all-page cursor reads, rate-limit/retry handling, exact comment counts, source-account identity and deterministic per-user source mappings. A single authenticated security-invoker RPC imports projects, sections, labels and task trees transactionally. Retrying skips mapped resources, preserves user edits and does not resurrect deleted mapped tasks. Older imports did not retain source IDs and can produce new copies; preview warns explicitly rather than guessing from titles.
- Native requests explicitly select JSON and allow a longer import timeout; the original web streaming contract remains the default for deployed older clients. New web code uses checked JSON completion and shows warnings before import. Source metadata preserves unsupported fields; attachments remain HTTPS links with an expiration warning. Completed history, archived projects, reminders, collaborators and filter rules are explicitly outside this import boundary.
- Both native editors have independent deadline and estimate controls, row badges and explicit floating/fixed-time selection. Shared quick entry accepts `~25m`, `~2h`, and `{YYYY-MM-DD}`. Escaped/quoted literals and declined planning chips cannot accidentally become planned dates. Recurring occurrences retain estimates and clear one-off deadlines.
- Exact `scheduled_at` timestamps preserve both 02:30 DST folds; the database rebuilds stale instants when older clients reschedule date/time alone. Tests cover Copenhagen/New York travel, date rollover, floating time, deadline independence, legacy caches and queued field persistence. Calendar/widget fixed-time presentation and hourly time blocking still require the later planner work.
- Closed a confirmed legacy privacy gap: unauthenticated email lookup and account-existence lookup are no longer callable. Email display is limited to one's own account, an inviter, or accepted members of projects one owns. Existing unrelated security-advisor findings remain a separate audit item; this does not claim a complete security review.

Verification: 53 Swift tests, one optional live test skipped, zero failures; 10 Deno fixture tests, zero failures; iOS and macOS unsigned app/extension builds; web production build and TypeScript check. The iPhone 17 Pro/iOS 26.5 UI test created a task through quick-entry chips, checked badges, relaunched and confirmed both editor fields. Its inspected screenshot is `p0-previews/ios-deadline-estimate.png`. The Mac UI test built but failed before test execution because macOS was locked and LocalAuthentication was active. The user has been asked to unlock it; no successful Mac walkthrough is claimed.

Remaining for this milestone: actual authenticated Todoist account preview/import/retry, native Mac import and planner UI walkthrough, cross-account/source deletion behavior with real HTTP responses, iPad/dark/accessibility layout evidence, bulk deadline editing and deadline queries, hourly planner, and widget projections. The deployed function rejects unauthenticated requests (HTTP 401). That smoke check proves auth enforcement, not a complete successful provider import. Full P0 and widget goals remain active.
