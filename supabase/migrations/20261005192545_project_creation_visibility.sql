-- STABLE has_project_access reads the statement-start snapshot. A newly inserted
-- project must also be readable through its row owner for INSERT ... RETURNING
-- (the native PostgREST upsert contract). Accepted collaborators keep their access.
alter policy projects_select_access on public.projects using (
 user_id = (select auth.uid()) or public.has_project_access((select auth.uid()), id)
);
