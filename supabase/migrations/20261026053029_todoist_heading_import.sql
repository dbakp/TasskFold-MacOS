-- Source only. Requires the heading contract; rollout remains disabled.
create table if not exists public.import_sources (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 provider text not null check (provider = 'todoist'),
 source_account text not null check (length(source_account) between 1 and 200),
 entity text not null check (entity in ('projects','sections','labels','tasks')),
 source_id text not null check (length(source_id) between 1 and 200),
 record_id uuid not null,
 imported_at timestamptz not null default now(),
 primary key (user_id, provider, source_account, entity, source_id)
);
alter table public.import_sources enable row level security;
do $$ begin
 if not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='import_sources' and policyname='import_sources_owner') then
  create policy import_sources_owner on public.import_sources for all to authenticated
   using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
 end if;
end $$;
revoke all on public.import_sources from anon, authenticated;
grant select, insert, delete on public.import_sources to authenticated;

CREATE OR REPLACE FUNCTION public.taskfold_import_todoist(_account text, _bundle jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 u uuid := auth.uid(); kind text; item jsonb; row_data jsonb; source text; dest uuid;
 imported int; skipped int; result jsonb := '{}';
 p public.projects; s public.sections; l public.labels; t public.tasks;
 children int := 0; comments_count int := 0; typed boolean := false; node jsonb; nesting integer;
begin
 if u is null then raise exception 'Sign in to import'; end if;
 if _account is null or length(_account) not between 1 and 200 or jsonb_typeof(_bundle) is distinct from 'object' then raise exception 'Invalid import'; end if;
 -- Bound the outer collection before recursively checking its task types.
 if jsonb_typeof(_bundle->'tasks') is distinct from 'array' or jsonb_array_length(_bundle->'tasks') > 20000 then raise exception 'Invalid or oversized import collection'; end if;
 -- Interpret only root tasks and recognized subtasks containment.
 if _bundle ? 'version' or _bundle ? 'capabilities' then
  if _bundle->'version' is distinct from '2'::jsonb or _bundle->'capabilities' is distinct from '["task_headings"]'::jsonb then raise exception 'Unsupported import capability'; end if;
  typed := true;
 end if;
 for item in select value from jsonb_array_elements(case when jsonb_typeof(_bundle->'tasks')='array' then _bundle->'tasks' else '[]'::jsonb end) loop
  for node, nesting in
   with recursive nodes(value,depth) as (
    select item->'record',0
    union all
    select child.value,nodes.depth+1 from nodes cross join lateral jsonb_array_elements(case when jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) child(value)
   ) select value,depth from nodes where jsonb_typeof(value)='object'
  loop
   if typed and nesting > 32 then raise exception 'Imported heading hierarchy exceeds this reader version'; end if;
   if node ? 'is_heading' and node->'is_heading' <> 'null'::jsonb and jsonb_typeof(node->'is_heading') <> 'boolean' then raise exception 'Unsupported imported task type'; end if;
   if node->'is_heading'='true'::jsonb and not typed then raise exception 'Heading import requires the task_headings capability'; end if;
  end loop;
 end loop;
 perform pg_advisory_xact_lock(hashtextextended(u::text || ':todoist:' || _account, 0));
 foreach kind in array array['projects','sections','labels','tasks'] loop
  if jsonb_typeof(_bundle->kind) is distinct from 'array' or jsonb_array_length(_bundle->kind) > 20000 then raise exception 'Invalid or oversized import collection'; end if;
  imported := 0; skipped := 0;
  for item in select value from jsonb_array_elements(_bundle->kind) loop
   source := item->>'source_id'; row_data := item->'record';
   if source is null or length(source) not between 1 and 200 or jsonb_typeof(row_data) is distinct from 'object' then raise exception 'Invalid source record'; end if;
   if exists(select 1 from public.import_sources where user_id=u and provider='todoist' and source_account=_account and import_sources.entity=kind and source_id=source) then
    skipped := skipped + 1; continue;
   end if;
   dest := (row_data->>'id')::uuid;
   if dest is null then raise exception 'Import record requires an ID'; end if;
   row_data := row_data || jsonb_build_object('user_id',u);
   case kind
   when 'projects' then
    p := jsonb_populate_record(null::public.projects, row_data);
    insert into public.projects(id,user_id,name,description,color,order_index,source_metadata)
     values(p.id,u,p.name,p.description,coalesce(p.color,'#3b82f6'),coalesce(p.order_index,0),coalesce(p.source_metadata,'{}'));
   when 'sections' then
    s := jsonb_populate_record(null::public.sections, row_data);
    if not exists(select 1 from public.projects where id=s.project_id and user_id=u) then raise exception 'Imported section requires an owned project'; end if;
    insert into public.sections(id,user_id,project_id,name,order_index) values(s.id,u,s.project_id,s.name,coalesce(s.order_index,0));
   when 'labels' then
    l := jsonb_populate_record(null::public.labels, row_data);
    insert into public.labels(id,user_id,name,color) values(l.id,u,l.name,coalesce(l.color,'#3b82f6'));
   when 'tasks' then
    t := jsonb_populate_record(null::public.tasks, row_data);
    if t.project_id is not null and not exists(select 1 from public.projects where id=t.project_id and user_id=u) then raise exception 'Imported task requires an owned project'; end if;
    if t.section_id is not null and not exists(select 1 from public.sections where id=t.section_id and project_id=t.project_id and user_id=u) then raise exception 'Imported section does not belong to task project'; end if;
    insert into public.tasks(id,user_id,title,description,completed,priority,due_date,due_time,project_id,section_id,labels,subtasks,reminders,attachments,comments,created_at,completed_at,recurrence_pattern,is_recurring,deadline_date,duration_minutes,time_zone,source_metadata,scheduled_at,is_heading)
     values(t.id,u,t.title,t.description,coalesce(t.completed,false),coalesce(t.priority,4),t.due_date,t.due_time,t.project_id,t.section_id,coalesce(t.labels,'{}'),coalesce(t.subtasks,'[]'),coalesce(t.reminders,'{}'),coalesce(t.attachments,'[]'),coalesce(t.comments,'[]'),coalesce(t.created_at,now()),t.completed_at,t.recurrence_pattern,coalesce(t.is_recurring,false),t.deadline_date,t.duration_minutes,t.time_zone,coalesce(t.source_metadata,'{}'),t.scheduled_at,t.is_heading);
    children := children + coalesce((item->>'subtask_count')::int,0);
    comments_count := comments_count + coalesce((item->>'comment_count')::int,0);
   end case;
   insert into public.import_sources(user_id,provider,source_account,entity,source_id,record_id) values(u,'todoist',_account,kind,source,dest);
   imported := imported + 1;
  end loop;
  result := result || jsonb_build_object(kind || 'Imported',imported,kind || 'Skipped',skipped);
 end loop;
 return result || jsonb_build_object('success',true,'subtasksImported',children,'commentsImported',comments_count) || case when typed then jsonb_build_object('formatVersion',2,'capabilities',jsonb_build_array('task_headings')) else '{}'::jsonb end;
end $function$;


revoke all on function public.taskfold_import_todoist(text,jsonb) from public, anon;
grant execute on function public.taskfold_import_todoist(text,jsonb) to authenticated;
