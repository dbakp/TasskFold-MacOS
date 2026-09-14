# Collaboration foundation

## Delivered

- Assign a task, subtask, or sub-subtask to yourself or an accepted project member from its inspector. Assigned rows expose a quick reassignment menu.
- Assigned to Me collects matching work across projects, including children of collapsed or unassigned parents. Each matching child is shown once, with its root task as context. Completion, inspection, undo, text filtering, and the completed toggle work here.
- New tasks captured in Assigned to Me are assigned to the current user.
- Moving to another project clears previous assignments. Leaving or revoking membership clears that person's assignments, including nested work, and removes access even to shared tasks they originally authored.
- Native project creation and invitation acceptance now work with the server's access rules. Invitations normalize email case and link accounts created after an invitation.

## Saving concurrent work

The Mac's persistent mutation queue records the pre-edit value of each changed task field. `taskfold_patch_task` locks the accessible task and performs a three-way merge. It preserves unrelated fields and independently identified comments, attachments, and nested subtasks. Repeated delivery of an unchanged edit is safe. Concurrent edits to the same value, or edits to an item deleted elsewhere, pause the queue instead of silently overwriting data.

The sidebar offers **Review** for a conflict. The review compares the local and shared values. **Keep My Edit** merges the local intent into the shared record without removing independent remote items. **Use Shared Edit** discards that queued edit. Later offline edits are replayed in either case. Resolution is persisted before sync resumes; another simultaneous edit may require review again. Undo/redo rebase collection changes so undoing your comment does not remove a teammate's later comment.

The inspector retains the baseline of unfinished edits when live updates arrive. New saves use the values the user actually edited from, rather than treating a recently refreshed value as their baseline.

## Backend and access

The three migrations in `supabase/migrations` were deployed to the configured TaskFold project. Filenames match the applied migration versions. Schema additions retain existing task JSON and REST data shapes; no real records were migrated or deleted.

- Project members remain owner/collaborator. Viewer roles and permission-management UI are a later milestone.
- Assignment validation runs on the server, including direct REST writes.
- The member-directory RPC exposes only the IDs, names, and avatars of accessible project members, not profile preferences or email addresses.
- The task-edit RPC uses caller permissions and RLS; it cannot bypass project access.
- New privileged helper functions use an empty search path, reside in a private schema, and are not executable by public clients. The member directory intentionally grants authenticated execution with an explicit membership check.

## Verification

`supabase/tests/collaboration.sql` must run inside `BEGIN` / `ROLLBACK`. It creates synthetic auth users with `example.invalid` addresses, switches authenticated identities, and exercises creation, pending/accepted access, concurrent comment and nested edits, retries, conflict rejection, invalid assignees, ownership changes, outsiders, revocation, project moves, and invitations linked on signup. It sends no email. The fixture transaction passed against the configured database and was rolled back.

Core tests cover queue compatibility, baseline persistence, RPC transport/conflict errors, nested merge resolution, and preserving remote comments during undo. Mac UI tests cover assignments at all supported depths, completion/undo, persistence, and conflict review with an independent teammate comment. Delivery results are recorded in PREMIUM_MAC_PLAN.md.

## Limits and follow-up plan

1. **Roll out the merge protocol to web and iOS.** This release enables the RPC on macOS. Older apps and the existing iOS UI still use ordinary REST writes; edits sent by those clients do not have concurrency protection. Old cached mutations without a baseline retain their previous transport. Arrays with legacy items lacking stable IDs fail safely on conflicting changes and require review.
2. **End-to-end accounts and delivery.** Database role tests verify authorization. They do not replace two separately signed-in client sessions or verify invitation-email delivery. No emails were sent during this work.
3. **Mentions and activity inbox.** Add @mentions, assignment notifications, unread state, per-project notification preferences, and activity history after all clients share safe writes.
4. **Permissions and sharing controls.** Add viewer/editor roles, resend/revoke invitation controls, ownership transfer, and clear personal/shared project organization. Check duplicate active invitations and email-change linking.
5. **Recovery and diagnostics.** Provide a review/export path for edits whose task or project access was removed; retain the queued edit meanwhile. Move large attachments from embedded JSON to governed object storage. Add deterministic tests with two actual concurrent network sessions and offline reconnection.

Supabase advisors were reviewed. The new member-directory authenticated-definer notice is intentional and covered by access tests. Existing findings remain outside this milestone: public RPC grants (including old email lookup helpers), GraphQL schema visibility, pg_net's schema, leaked-password protection, and older policy/index performance suggestions. See [privileged function grants](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable), [GraphQL visibility](https://supabase.com/docs/guides/database/database-linter?lint=0026_pg_graphql_anon_table_exposed), and [password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection). Address these in a dedicated backend hardening pass; do not interpret the authorization tests as a complete security audit.

## Identity and invitation update — 14 September 2026

The Mac client now renders resolved account names/photos and member avatars, including the owner and current user. Custom profile fields take precedence; removing a custom photo reveals the Google fallback. Collaborator management enriches accepted rows from the member directory while retaining pending statuses and removal/leave actions.

Member metadata persists separately for each account/project. Changes to the known membership roster trigger refresh; otherwise a 15-minute freshness window avoids fetching every project after every sync. A failed project request retains that project's cached data without discarding successful requests for others. Offline/retry messaging is available in the assignee popover. Current project/member state filters assignment choices and the server continues to authorize all writes. Photo cache entries are account-scoped, revalidated after a day, and retained as a fallback when offline.

Invitation deep links retain their destination through sign-in and open Settings → Invitations. Acceptance/decline refresh the store and affected directory. No invitation email implementation was replaced.

Backend verification passed again inside a rolled-back transaction: `collaboration.sql` plus `member_identity.sql`. The additional fixture checks Google name/photo fallback, custom field precedence, and fallback after custom photo removal. No real emails or task changes were made. These tests verify the deployed contract and permissions; they do not prove email delivery, image rendering, or two separately signed-in interactive clients.

The authoritative directory definition is now the already-deployed iOS migration `20260914091713_project_member_profiles.sql`: a public invoker RPC delegates to its private access-checked profile helper. Do not replay the older Mac directory migration over that definition. For a new backend, apply the current iOS schema/profile migration along with the collaboration prerequisites.

Manual fixture follow-up: a real HTTPS avatar decoded and rendered, retained its name/photo after relaunch, and exposed a stable accessible assignment button and named-member picker. Invitation routing reached the signed-out destination and persisted across relaunch. This is image/routing evidence; live Google login, custom upload/removal UI, email delivery, and two interactive accounts remain untested in this milestone.

Final macOS XCTest follow-up passed for remote image loading/cache relaunch, invitation-route persistence, nested assignment/persistence, conflict review preserving independent comments, clipboard image attachments, and hierarchy completion/undo. These ran against the pinned iOS `9960d97` shared Core. The distribution app is installed and its window launch is verified; the 1.1.0 DMG includes these features.
