create table public.view_orders (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null check(length(id) between 1 and 300),
 ids jsonb not null default '[]' check(jsonb_typeof(ids)='array' and jsonb_array_length(ids)<=10000 and not jsonb_path_exists(ids,'$[*] ? (@.type() != "string")')),
 updated_at timestamptz not null default now(),
 primary key(user_id,id)
);
alter table public.view_orders enable row level security;
create policy account_owner on public.view_orders for all to authenticated
 using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
revoke all on public.view_orders from anon,authenticated;
grant select,insert,update,delete on public.view_orders to authenticated;
create trigger view_orders_touch before update on public.view_orders for each row execute function taskfold_private.touch_organization();
-- Deliver organization changes through the same authorized Realtime channel as tasks.
do $$ declare t text; begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach t in array array['saved_views','favorites','view_preferences','view_orders'] loop
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
    execute format('alter publication supabase_realtime add table public.%I',t);
   end if;
  end loop;
 end if;
end $$;
