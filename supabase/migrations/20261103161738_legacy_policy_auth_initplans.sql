-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Cache the request identity once per statement. Keep every existing ownership,
-- membership, role and command rule; row-dependent access helpers stay per-row.
-- ALTER POLICY preserves policy identity, permissiveness and role assignments.
alter policy "Users can create sections in accessible projects" on public.sections
 with check ((select auth.uid()) = user_id and public.has_project_access((select auth.uid()), project_id));

alter policy "Users can view their own labels" on public.labels using ((select auth.uid()) = user_id);
alter policy "Users can create their own labels" on public.labels with check ((select auth.uid()) = user_id);
-- Keep WITH CHECK implicit as before: PostgreSQL applies USING to new rows too.
alter policy "Users can update their own labels" on public.labels using ((select auth.uid()) = user_id);
alter policy "Users can delete their own labels" on public.labels using ((select auth.uid()) = user_id);

alter policy "Users can view their own profile" on public.profiles using ((select auth.uid()) = user_id);
alter policy "Users can insert their own profile" on public.profiles with check ((select auth.uid()) = user_id);
alter policy "Users can update their own profile" on public.profiles
 using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "Users can delete their own profile" on public.profiles using ((select auth.uid()) = user_id);

alter policy "Owners can invite" on public.project_collaborators
 with check (public.is_project_owner((select auth.uid()), project_id));
alter policy "Remove collaborations" on public.project_collaborators
 using (public.is_project_owner((select auth.uid()), project_id) or user_id = (select auth.uid()));
alter policy "View collaborations" on public.project_collaborators
 using (public.is_project_owner((select auth.uid()), project_id)
        or user_id = (select auth.uid())
        or (public.has_project_access((select auth.uid()), project_id) and status = 'accepted'));

alter policy projects_delete_owner on public.projects using ((select auth.uid()) = user_id);
alter policy "Users can create accessible tasks" on public.tasks
 with check ((select auth.uid()) = user_id
             and (project_id is null or public.has_project_access((select auth.uid()), project_id)));

commit;
