-- A personal workflow Undo checks its whole created set in one transaction.
-- The private definer is needed to see RLS-hidden dependent work, not to confer
-- task/project access. The public entry point remains security invoker.
create table taskfold_private.private_workflow_undos (
 account_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null, fingerprint text not null, result jsonb not null,
 created_at timestamptz not null default clock_timestamp(), primary key(account_id,request_id)
);
alter table taskfold_private.private_workflow_undos enable row level security;
revoke all on taskfold_private.private_workflow_undos from public,anon,authenticated,service_role;

create function taskfold_private.undo_private_workflow(_request uuid,_body jsonb) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid(); fingerprint text; prior taskfold_private.private_workflow_undos;
 item jsonb; target regclass; current_row jsonb; expected_row jsonb; project uuid; defaults jsonb; col record;
 relation record; fk record; affected boolean; refused boolean:=false; rows jsonb:='[]'; result jsonb;
begin
 perform taskfold_private.team_actor();
 if _request is null or jsonb_typeof(_body) is distinct from 'object' or octet_length(_body::text)>16800000
  or _body->>'user_id' is distinct from actor::text or jsonb_typeof(_body->'items') is distinct from 'array'
  or jsonb_array_length(_body->'items') not between 1 and 12000 then
  raise exception using errcode='22023',message='Reopen this workflow Undo';end if;
 fingerprint:=encode(sha256(convert_to(_body::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('private-workflow-undo:'||actor::text,20261026));
 select * into prior from taskfold_private.private_workflow_undos where account_id=actor and request_id=_request;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='22023',message='This workflow Undo request changed';end if;
  if (prior.result->>'applied')::boolean then return prior.result;end if;
  refused:=true; -- Re-read surviving personal rows for a recorded refusal; never replay old access.
 end if;
 for item in select value from jsonb_array_elements(_body->'items') loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'table','')<>all(array['projects','sections','labels','tasks','view_orders'])
   or coalesce(item->>'id','')='' or jsonb_typeof(item->'base') is distinct from 'object'
   or item->'base'->>'id' is distinct from item->>'id' or item->'base'->>'user_id' is distinct from actor::text then
   raise exception using errcode='22023',message='Review this workflow Undo identity';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(_body->'items') x group by x->>'table',x->>'id' having count(*)>1) then
  raise exception using errcode='22023',message='Review duplicate workflow Undo records';end if;
 -- Lock targets and every FK-dependent relation in a stable order. This rare,
 -- bounded history action must not race incoming references (including SET NULL
 -- and cascade FKs). It also fences non-FK nested label changes in tasks.
 for relation in
  with targets as(select distinct ('public.'||(x->>'table'))::regclass::oid as oid from jsonb_array_elements(_body->'items') x),
  locks as(select oid from targets union select conrelid from pg_constraint where contype='f' and confrelid in(select oid from targets)
    union select unnest(array['public.tasks'::regclass::oid,'public.projects'::regclass::oid,'public.sections'::regclass::oid]))
  select c.oid,n.nspname,c.relname from locks l join pg_class c on c.oid=l.oid join pg_namespace n on n.oid=c.relnamespace order by c.oid
 loop execute format('lock table %I.%I in share row exclusive mode',relation.nspname,relation.relname);end loop;
 for item in select value from jsonb_array_elements(_body->'items') loop
  target:=('public.'||(item->>'table'))::regclass;
  execute format('select to_jsonb(t) from %s t where id=$1::%s and user_id=$2',target,case when item->>'table'='view_orders' then 'text' else 'uuid' end) into current_row using item->>'id',actor;
  if current_row is null then refused:=true;continue;end if;
  if current_row->>'user_id' is distinct from actor::text then raise exception using errcode='42501',message='This workflow record is unavailable';end if;
  project:=case when item->>'table'='projects' then (item->>'id')::uuid when item->>'table' in('tasks','sections') then (current_row->>'project_id')::uuid else null end;
  if taskfold_private.is_team_content_project(project) or exists(select 1 from taskfold_private.team_project_identities where project_id=project)
   or (item->>'table'='tasks' and taskfold_private.is_team_content_task((item->>'id')::uuid)) then
   refused:=true;continue;
  end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('table',item->>'table','row',current_row));
  -- Canonicalize against the actual column types/defaults. New mutable columns
  -- fail closed when their current value differs; timestamps assigned at insert
  -- may be absent from a creation intent.
  defaults:='{}';
  for col in select a.attname,pg_get_expr(d.adbin,d.adrelid) as expr from pg_attribute a
   left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
   where a.attrelid=target and a.attnum>0 and not a.attisdropped
  loop
   if not (item->'base' ? col.attname) and col.expr is not null and col.attname<>all(array['created_at','updated_at']) then
    execute 'select jsonb_build_object($1,to_jsonb(('||col.expr||')))' into expected_row using col.attname;
    defaults:=defaults||expected_row;
   end if;
  end loop;
  if exists(select 1 from jsonb_object_keys(item->'base') k where not exists(select 1 from pg_attribute a where a.attrelid=target and a.attname=k and a.attnum>0 and not a.attisdropped)) then
   raise exception using errcode='22023',message='Review this workflow record format';end if;
  execute format('select to_jsonb(jsonb_populate_record(null::%s,$1))',target) into expected_row using defaults||(item->'base');
  for col in select key from jsonb_each(current_row) loop
   if col.key=any(array['created_at','updated_at']) and not (item->'base' ? col.key) then continue;end if;
   if current_row->col.key is distinct from expected_row->col.key then refused:=true;end if;
  end loop;
  -- Any reference outside this command means later work would be detached or
  -- cascaded away. Only server-derived assignment/reminder bookkeeping is exempt.
  for fk in select c.*,n.nspname,r.relname,a.attname,format_type(a.atttypid,a.atttypmod) as column_type from pg_constraint c
   join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace
   join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
   where c.contype='f' and c.confrelid=target
  loop
   if fk.nspname='public' and fk.relname in('task_assignment_provenance','task_reminder_jobs') then continue;end if;
   if cardinality(fk.conkey)<>1 then refused:=true;continue;end if;
   execute format('select exists(select 1 from %I.%I dep where dep.%I=$1::%s and not exists(select 1 from jsonb_array_elements($2) x where $3=''public'' and x->>''table''=$4 and x->>''id''=to_jsonb(dep)->>''id'' and x->''base''->>''user_id''=to_jsonb(dep)->>''user_id''))',fk.nspname,fk.relname,fk.attname,fk.column_type)
    into affected using item->>'id',_body->'items',fk.nspname,fk.relname;
   if affected then refused:=true;end if;
  end loop;
  -- Organization contracts also have logical links on installations whose
  -- original columns predate FK constraints. Guard these links explicitly.
  if item->>'table'='projects' and (
   exists(select 1 from public.projects p where p.parent_id=(item->>'id')::uuid and not exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'='projects' and x->>'id'=p.id::text))
   or exists(select 1 from public.sections p where p.project_id=(item->>'id')::uuid and not exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'='sections' and x->>'id'=p.id::text))
   or exists(select 1 from public.tasks p where p.project_id=(item->>'id')::uuid and not exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'='tasks' and x->>'id'=p.id::text))) then refused:=true;end if;
  if item->>'table'='sections' and exists(select 1 from public.tasks p where p.section_id=(item->>'id')::uuid and not exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'='tasks' and x->>'id'=p.id::text)) then refused:=true;end if;
  if item->>'table'='labels' and exists(select 1 from public.tasks t
    where jsonb_path_exists(to_jsonb(t),'$.**.labels[*] ? (@ == $label)',jsonb_build_object('label',item->>'id'))
    and not exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'='tasks' and x->>'id'=t.id::text and x->'base'->>'user_id'=t.user_id::text)) then refused:=true;end if;
 end loop;
 if not refused then
  -- The client sends reverse creation order, so children/tasks precede parents.
  for item in select value from jsonb_array_elements(_body->'items') loop
   execute format('delete from public.%I where id=$1::%s and user_id=$2',item->>'table',case when item->>'table'='view_orders' then 'text' else 'uuid' end) using item->>'id',actor;
  end loop;
  rows:='[]';
 end if;
 result:=jsonb_build_object('id',lower(_request::text),'applied',not refused,'rows',rows);
 insert into taskfold_private.private_workflow_undos(account_id,request_id,fingerprint,result) values(actor,_request,fingerprint,result||jsonb_build_object('rows','[]'::jsonb)) on conflict(account_id,request_id) do nothing;
 return result;
end$$;
revoke all on function taskfold_private.undo_private_workflow(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.undo_private_workflow(uuid,jsonb) to authenticated;
create function public.taskfold_undo_private_workflow(_request uuid,_body jsonb) returns jsonb
language sql security invoker set search_path='' as $$select taskfold_private.undo_private_workflow(_request,_body)$$;
revoke all on function public.taskfold_undo_private_workflow(uuid,jsonb) from public,anon,service_role;
grant execute on function public.taskfold_undo_private_workflow(uuid,jsonb) to authenticated;

-- Advertise writer compatibility in the existing signed access boundary.
create or replace function taskfold_private.workspace_boundary() returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();ids uuid[]:='{}';tr taskfold_private.teams;reads boolean;edits boolean;enabled boolean;projects jsonb;teams jsonb;result jsonb;token text;
begin
 perform taskfold_private.team_actor();
 select native_reads_enabled,native_task_edits_enabled into reads,edits from taskfold_private.team_project_config where singleton for share;
 select c.enabled into enabled from taskfold_private.team_config c where singleton for share;
 -- Match role-command serialization; recheck identity after every potential wait.
 for tr in select t.* from taskfold_private.teams t join taskfold_private.team_members m on m.team_id=t.id where m.user_id=a and t.state<>'deleted' order by t.id for share of t loop ids=array_append(ids,tr.id);end loop;
 perform 1 from taskfold_private.team_access_epochs e where e.team_id=any(ids) order by e.team_id for share;
 perform taskfold_private.team_actor();
 -- The epoch includes access ABA changes, not ordinary task edits. Continuous
 -- collaboration need not prevent refreshing under unchanged permissions.
 select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'state',t.state,'revision',t.revision,'access_revision',e.revision) order by t.id),'[]') into teams
  from taskfold_private.teams t join taskfold_private.team_access_epochs e on e.team_id=t.id
  join taskfold_private.team_members m on m.team_id=t.id and m.user_id=a where t.id=any(ids) and t.state<>'deleted' and reads;
 select coalesce(jsonb_agg(v order by id),'[]') into projects from (
  select p.id,jsonb_build_object('id',p.id,'team_id',null,'role',case when p.user_id=a then 'owner' else 'collaborator' end,
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',true) v
  from public.projects p where not exists(select 1 from taskfold_private.team_project_identities i where i.project_id=p.id)
   and (p.user_id=a or exists(select 1 from public.project_collaborators c where c.project_id=p.id and c.user_id=a and c.status='accepted'))
  union all
  select p.id,jsonb_build_object('id',p.id,'team_id',c.team_id,'role',taskfold_private.team_project_role(a,p.id),
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',coalesce(edits and enabled and t.state='active' and not(p.is_archived or p.ancestor_archived) and taskfold_private.team_project_role(a,p.id) in('manager','editor'),false))
  from public.projects p join taskfold_private.team_content_projects c on c.project_id=p.id join taskfold_private.teams t on t.id=c.team_id
  where reads and c.team_id=any(ids) and t.state<>'deleted' and taskfold_private.team_project_role(a,p.id) is not null
 ) q;
 if jsonb_array_length(projects)>10000 or jsonb_array_length(teams)>1000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 result=jsonb_build_object('personal_workflow_undo_protocol',1,'personal_task_types_protocol',1,'task_type_lifecycle_protocol',case when reads and edits and enabled then 1 else 0 end,'task_types_protocol',case when reads and edits and enabled and (select native_task_types_enabled from taskfold_private.team_project_config where singleton) then 1 else 0 end,'workspace_boundary_protocol',1,'account',a,'native_team_reads_enabled',coalesce(reads,false),'setup_paused',not coalesce(enabled,false),'projects',projects,'teams',teams);
 select encode(extensions.hmac(convert_to(result::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 result=result||jsonb_build_object('token',token);
 if octet_length(result::text)>3000000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 return result;
end$$;
