-- Durable, account-owned organization. Preferences/favorites use stable scope keys and
-- a composite account key, so two devices address the same row without sharing accounts.
create table public.saved_views (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 name text not null check(length(trim(name)) between 1 and 120),
 query_ast jsonb not null check(jsonb_typeof(query_ast)='object' and query_ast->>'version'='1' and jsonb_typeof(query_ast->'root')='object'),
 layout text not null default 'list' check(layout in ('list','board')),
 grouping text not null default 'none' check(grouping in ('none','project','priority','date','deadline')),
 sort_by text not null default 'manual' check(sort_by in ('manual','priority','date','deadline','duration','title')),
 include_completed boolean not null default false,
 order_index integer not null default 0 check(order_index>=0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index saved_views_account_order on public.saved_views(user_id,order_index,id);
create table public.favorites (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null check(length(id) between 1 and 200),
 order_index integer not null default 0 check(order_index>=0),
 created_at timestamptz not null default now(),
 primary key(user_id,id)
);
create table public.view_preferences (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null check(length(id) between 1 and 200),
 layout text not null default 'list' check(layout in ('list','board','calendar')),
 grouping text not null default 'none' check(grouping in ('none','project','priority','date','deadline')),
 sort_by text not null default 'manual' check(sort_by in ('manual','priority','date','deadline','duration','title')),
 include_completed boolean not null default false,
 priority_filter integer not null default 0 check(priority_filter between 0 and 4),
 overdue_collapsed boolean not null default false,
 updated_at timestamptz not null default now(),
 primary key(user_id,id)
);
create or replace function taskfold_private.touch_organization()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.user_id is distinct from old.user_id then raise exception 'Organization ownership cannot be changed'; end if;
 new.updated_at := now(); return new;
end $$;
revoke all on function taskfold_private.touch_organization() from public,anon,authenticated;
do $$ declare table_name text; begin
 foreach table_name in array array['saved_views','favorites','view_preferences'] loop
  execute format('alter table public.%I enable row level security',table_name);
  execute format('create policy account_owner on public.%I for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()))',table_name);
  execute format('revoke all on public.%I from anon,authenticated',table_name);
  execute format('grant select,insert,update,delete on public.%I to authenticated',table_name);
 end loop;
end $$;
create trigger saved_views_touch before update on public.saved_views for each row execute function taskfold_private.touch_organization();
create trigger view_preferences_touch before update on public.view_preferences for each row execute function taskfold_private.touch_organization();
