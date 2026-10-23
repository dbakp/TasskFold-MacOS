-- Acceptance-branch bridge only. The preview starts from recorded 2025 web
-- migrations, while inspected live native base fields were installed separately.
-- No production data or server secrets are copied. Source feature migrations
-- load unchanged after this base. Never run this fixture bridge on main.
-- Native base grants inspected on main; preview web history omits them.
grant select,insert,update,delete on public.projects,public.project_collaborators to authenticated,service_role;
create schema taskfold_private;
revoke all on schema taskfold_private from public,anon;
grant usage on schema taskfold_private to authenticated,service_role;
alter table public.tasks add column assigned_to uuid,add column deadline_date date,
 add column duration_minutes integer,add column time_zone text,
 add column reminder_specs jsonb not null default '[]',
 add column source_metadata jsonb not null default '{}',add column scheduled_at timestamptz;
create table public.view_preferences(user_id uuid not null default auth.uid() references auth.users on delete cascade,id text not null,
 layout text not null default 'list',grouping text not null default 'none',sort_by text not null default 'manual',
 include_completed boolean not null default false,priority_filter integer not null default 0,overdue_collapsed boolean not null default false,
 updated_at timestamptz not null default now(),working_hours jsonb,primary key(user_id,id));
create table public.view_orders(user_id uuid not null default auth.uid() references auth.users on delete cascade,id text not null,ids jsonb not null default '[]',updated_at timestamptz not null default now(),primary key(user_id,id));
create table public.favorites(user_id uuid not null default auth.uid() references auth.users on delete cascade,id text not null,order_index integer not null default 0,created_at timestamptz not null default now(),primary key(user_id,id));
create table public.saved_views(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users on delete cascade,name text not null,query_ast jsonb not null,layout text not null default 'list',grouping text not null default 'none',sort_by text not null default 'manual',include_completed boolean not null default false,order_index integer not null default 0,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.import_sources(user_id uuid not null default auth.uid() references auth.users on delete cascade,provider text not null,source_account text not null,entity text not null,source_id text not null,record_id uuid not null,imported_at timestamptz not null default now(),primary key(user_id,provider,source_account,entity,source_id));
do $$declare name text;begin
 foreach name in array array['view_preferences','view_orders','favorites','saved_views','import_sources'] loop
  execute format('alter table public.%I enable row level security',name);
  execute format('revoke all on public.%I from public,anon,authenticated',name);
  execute format('grant select,insert,update,delete on public.%I to authenticated,service_role',name);
  execute format('create policy native_owner on public.%I to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()))',name);
 end loop;end$$;

-- Inspected live pure merge helper, also retained by the local dependency fixture.
create function taskfold_private.merge_edit(b jsonb,d jsonb,c jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare r jsonb;k text;v jsonb;bv jsonb;dv jsonb;cv jsonb;
begin
 if d is not distinct from b then return c;end if;
 if c is not distinct from b or c is not distinct from d then return d;end if;
 if jsonb_typeof(b)='object' and jsonb_typeof(d)='object' and jsonb_typeof(c)='object' then
  r:=c;
  for k in select jsonb_object_keys(b||d) loop
   if d->k is distinct from b->k then
    v:=taskfold_private.merge_edit(b->k,d->k,c->k);
    if v is null then r:=r-k;else r:=jsonb_set(r,array[k],v);end if;
   end if;
  end loop;return r;
 end if;
 if jsonb_typeof(b)='array' and jsonb_typeof(d)='array' and jsonb_typeof(c)='array'
 and not exists(select 1 from jsonb_array_elements(b||d||c) x where jsonb_typeof(x)<>'object' or coalesce(x->>'id','')='')
 and not exists(select 1 from (values(b),(d),(c)) q(a) where jsonb_array_length(a)<>(select count(distinct x->>'id') from jsonb_array_elements(a) x)) then
  r:='[]';
  for cv in select * from jsonb_array_elements(c) loop
   select x into bv from jsonb_array_elements(b) x where x->>'id'=cv->>'id';
   select x into dv from jsonb_array_elements(d) x where x->>'id'=cv->>'id';
   if bv is null then
    if dv is not null and dv<>cv then raise exception 'TASKFOLD_CONFLICT: An item changed on another device. Review the conflicting change.';end if;
    r:=r||jsonb_build_array(cv);
   else
    v:=taskfold_private.merge_edit(bv,dv,cv);if v is not null then r:=r||jsonb_build_array(v);end if;
   end if;
  end loop;
  for dv in select * from jsonb_array_elements(d) loop
   select x into bv from jsonb_array_elements(b) x where x->>'id'=dv->>'id';
   if not exists(select 1 from jsonb_array_elements(c) x where x->>'id'=dv->>'id') then
    if bv is null then r:=r||jsonb_build_array(dv);
    elsif bv<>dv then raise exception 'TASKFOLD_CONFLICT: This item was deleted on another device. Your edit is saved locally.';end if;
   end if;
  end loop;return r;
 end if;
 raise exception 'TASKFOLD_CONFLICT: The same field changed on another device. Your edit is saved locally.';
end $$;

-- Inspected live organization trigger, a dependency of project templates.
create function taskfold_private.touch_organization() returns trigger language plpgsql set search_path='' as $$begin
 if new.user_id is distinct from old.user_id then raise exception 'Organization ownership cannot be changed';end if;
 new.updated_at:=now();return new;
end$$;
revoke all on function taskfold_private.touch_organization() from public,anon;
