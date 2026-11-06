-- Exact, recipient-owned counts without downloading all conversation bodies.
create index task_mentions_recipient_unread on public.task_mentions(recipient_id,created_at,id) where read_at is null;
create function public.taskfold_mentions_summary()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 if (select auth.uid()) is null then raise exception 'Sign in to view your mentions.' using errcode='42501';end if;
 select jsonb_build_object('total',count(*),'unread',count(*) filter(where read_at is null)) into result
  from public.task_mentions where recipient_id=(select auth.uid());
 return result;
end $$;
revoke all on function public.taskfold_mentions_summary() from public,anon;
grant execute on function public.taskfold_mentions_summary() to authenticated;
-- Existing signed-in workspace refresh listens only after Realtime applies row access.
-- This enables in-app refresh, never APNs or server-delivered reminders.
do $$ declare name text;begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach name in array array['task_comments','task_mentions'] loop
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=name) then
    execute format('alter publication supabase_realtime add table public.%I',name);
   end if;
  end loop;
 end if;
end $$;
