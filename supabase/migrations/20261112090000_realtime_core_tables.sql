-- Publish the core workspace tables to Realtime (12 November 2026).
--
-- Both apps subscribe to postgres_changes for tasks, projects, sections, labels,
-- project_collaborators and profiles, and later migrations assumed tasks were already
-- published ("the same authorized Realtime channel as tasks"). The hosted publication
-- never contained them, so cross-device task edits arrived only through polling.
-- Incremental sync re-reads just the tables named by Realtime events, so these tables
-- must be published for edits to show up promptly. Realtime still applies each
-- table's RLS policies before delivering a change to a subscriber.
do $$ declare t text; begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach t in array array['tasks','projects','sections','labels','project_collaborators','profiles'] loop
   if to_regclass(format('public.%I',t)) is not null
      and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
    execute format('alter publication supabase_realtime add table public.%I',t);
   end if;
  end loop;
 end if;
end $$;
