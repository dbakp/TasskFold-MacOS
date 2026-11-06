-- Additive project organization and private workflow templates. No task is deleted,
-- completed, rescheduled or reassigned by these schema changes.
alter table public.projects
 add column parent_id uuid references public.projects(id) on delete set null,
 add column is_archived boolean not null default false,
 add column ancestor_archived boolean not null default false,
 add constraint projects_not_own_parent check (parent_id is distinct from id);
create index projects_parent on public.projects(parent_id) where parent_id is not null;

create function taskfold_private.guard_project_organization()
returns trigger language plpgsql security invoker set search_path='' as $$
declare p public.projects; cursor_id uuid; visited uuid[] := array[new.id]; depth integer := 1; subtree_depth integer;
begin
 -- Ordinary edits on a shared child must not require reading its unshared
 -- parent. Ignore attempts to overwrite the derived projection on that path.
 if tg_op='UPDATE' and new.parent_id is not distinct from old.parent_id and new.is_archived is not distinct from old.is_archived then
  if new.ancestor_archived is not distinct from old.ancestor_archived or
     ((select auth.uid()) is distinct from old.user_id and current_user not in ('postgres','service_role')) then
    new.ancestor_archived := old.ancestor_archived; return new;
  end if;
 end if;
 -- Serialize same-owner hierarchy changes, including simultaneous opposite moves.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.user_id::text, 20261020));
 if tg_op='UPDATE' and (new.parent_id is distinct from old.parent_id or new.is_archived is distinct from old.is_archived)
    and (select auth.uid()) is distinct from old.user_id and current_user not in ('postgres','service_role') then
   raise exception 'Only the project owner can move or archive it.' using errcode='42501';
 end if;
 new.ancestor_archived := false;
 cursor_id := new.parent_id;
 while cursor_id is not null loop
   if cursor_id=any(visited) then raise exception 'A project cannot be placed inside itself or one of its subprojects.'; end if;
   visited := array_append(visited,cursor_id); depth := depth+1;
   if depth>20 then raise exception 'Projects can be nested up to 20 levels.'; end if;
   select * into p from public.projects where id=cursor_id;
   if not found or p.user_id<>new.user_id then raise exception 'Choose an available parent project that you own.'; end if;
   if cursor_id=new.parent_id then new.ancestor_archived := p.is_archived or p.ancestor_archived; end if;
   cursor_id := p.parent_id;
 end loop;
 if tg_op='UPDATE' and new.parent_id is distinct from old.parent_id then
   with recursive subtree(id,levels,path) as (
    select new.id,1,array[new.id]
    union all select c.id,s.levels+1,s.path||c.id from public.projects c join subtree s on c.parent_id=s.id
     where not c.id=any(s.path) and s.levels<=20
   ) select max(levels) into subtree_depth from subtree;
   if depth+coalesce(subtree_depth,1)-1>20 then raise exception 'Projects can be nested up to 20 levels.'; end if;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_project_organization() from public,anon,authenticated;
create trigger taskfold_project_organization before insert or update on public.projects
 for each row execute function taskfold_private.guard_project_organization();

create function taskfold_private.refresh_project_archive_descendants()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 -- Derived projection permits a collaborator to hide archived child work even
 -- when the parent itself is not shared with that collaborator.
 if new.is_archived is distinct from old.is_archived or new.ancestor_archived is distinct from old.ancestor_archived then
  update public.projects set ancestor_archived=(new.is_archived or new.ancestor_archived)
   where parent_id=new.id and ancestor_archived is distinct from (new.is_archived or new.ancestor_archived);
 end if;
 return null;
end $$;
revoke all on function taskfold_private.refresh_project_archive_descendants() from public,anon,authenticated;
create trigger taskfold_project_archive_descendants after update on public.projects
 for each row execute function taskfold_private.refresh_project_archive_descendants();

create table public.project_templates (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 name text not null check(length(btrim(name)) between 1 and 160),
 document jsonb not null check(jsonb_typeof(document)='object' and
   case when jsonb_typeof(document->'version')='number' then
     (document->>'version')::numeric>=1 and (document->>'version')::numeric=trunc((document->>'version')::numeric)
   else false end and octet_length(document::text)<=2000000),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index project_templates_owner_name on public.project_templates(user_id,name,id);
alter table public.project_templates enable row level security;
create policy project_templates_owner on public.project_templates for all to authenticated
 using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
revoke all on public.project_templates from anon,authenticated;
grant select,insert,update,delete on public.project_templates to authenticated;
create trigger project_templates_touch before update on public.project_templates
 for each row execute function taskfold_private.touch_organization();
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
  select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='project_templates'
 ) then alter publication supabase_realtime add table public.project_templates; end if;
end $$;
