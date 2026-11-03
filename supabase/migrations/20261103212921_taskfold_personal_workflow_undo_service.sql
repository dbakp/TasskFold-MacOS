-- Personal workflow Undo has its own capability discovery; no team rollout.
create table if not exists taskfold_private.private_workflow_undos (
 account_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null, fingerprint text not null, result jsonb not null,
 created_at timestamptz not null default clock_timestamp(), primary key(account_id,request_id)
);
alter table taskfold_private.private_workflow_undos enable row level security;
revoke all on taskfold_private.private_workflow_undos from public,anon,authenticated,service_role;

-- Privileged solely to verify the current Auth session/removal fence. Locks
-- serialize account removal/revocation with this bounded write transaction.
create or replace function taskfold_private.require_workflow_actor() returns uuid
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid(); sid text:=auth.jwt()->>'session_id';
begin
 if actor is null or sid is null or sid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  raise exception using errcode='28000',message='Sign in again';
 end if;
 perform 1 from auth.users u join auth.sessions s on s.user_id=u.id
 where u.id=actor and s.id=sid::uuid and (s.not_after is null or s.not_after>clock_timestamp())
  and (u.banned_until is null or u.banned_until<=clock_timestamp()) and u.email_confirmed_at is not null and coalesce(u.email,'')<>''
 for share of u,s;
 if not found or exists(select 1 from taskfold_private.account_removal_receipts where account_id=actor and created_at>clock_timestamp()-interval '7 days') then
  raise exception using errcode='28000',message='Account access is unavailable';
 end if;
 return actor;
end$$;
revoke all on function taskfold_private.require_workflow_actor() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.require_workflow_actor() to authenticated;

-- Keep the existing actor, receipt and all-or-nothing contract. Work is grouped
-- by table: catalog/default work and dependency scans do not repeat per record.
create or replace function taskfold_private.undo_private_workflow(_request uuid,_body jsonb) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid(); fingerprint text; prior taskfold_private.private_workflow_undos;
 name text; target regclass; id_type text; members jsonb; columns text[]; defaults jsonb; value jsonb;
 col record; relation record; fk record; link record; affected boolean; part_refused boolean;
 refused boolean:=false; rows jsonb:='[]'; part_rows jsonb; result jsonb; project_expr text; personal_expr text;
begin
 -- TASKFOLD_PERSONAL_WORKFLOW_UNDO_V1
 perform taskfold_private.require_workflow_actor();
 if _request is null or jsonb_typeof(_body) is distinct from 'object' or octet_length(_body::text)>16800000
  or _body->>'user_id' is distinct from actor::text or jsonb_typeof(_body->'items') is distinct from 'array'
  or jsonb_array_length(_body->'items')<1 then raise exception using errcode='22023',message='Reopen this workflow Undo';end if;
 fingerprint:=encode(sha256(convert_to(_body::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('private-workflow-undo:'||actor::text,20261026));
 perform taskfold_private.require_workflow_actor();
 select * into prior from taskfold_private.private_workflow_undos where account_id=actor and request_id=_request;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='22023',message='This workflow Undo request changed';end if;
  if (prior.result->>'applied')::boolean then return prior.result;end if;
  refused:=true;
 end if;
 if exists(select 1 from jsonb_array_elements(_body->'items') x where jsonb_typeof(x) is distinct from 'object'
  or coalesce(x->>'table','')<>all(array['projects','sections','labels','tasks','view_orders']) or coalesce(x->>'id','')=''
  or jsonb_typeof(x->'base') is distinct from 'object' or x->'base'->>'id' is distinct from x->>'id'
  or x->'base'->>'user_id' is distinct from actor::text)
  or exists(select 1 from jsonb_array_elements(_body->'items') x group by x->>'table',x->>'id' having count(*)>1) then
  raise exception using errcode='22023',message='Review this workflow Undo identity';end if;
 -- Membership keys must match PostgreSQL's canonical UUID text. Otherwise
 -- alternate spellings could miss a hidden logical label/dependency reference.
 if exists(select 1 from jsonb_array_elements(_body->'items') x
  where x->>'table'<>'view_orders' and x->>'id' is distinct from ((x->>'id')::uuid)::text) then
  raise exception using errcode='22023',message='Review this workflow record identity';
 end if;
 select jsonb_object_agg(table_name,ids) into members from (
  select x->>'table' table_name,jsonb_object_agg(x->>'id',x->'base'->>'user_id') ids from jsonb_array_elements(_body->'items') x group by x->>'table'
 ) groups;
 -- Stable-order locks preserve the original fence against incoming FK/logical
 -- references, including RLS-hidden rows and legacy columns without a FK.
 for relation in
  with targets as(select ('public.'||k)::regclass::oid oid from jsonb_object_keys(members) k),
  locks as(select oid from targets union select conrelid from pg_constraint where contype='f' and confrelid in(select oid from targets)
   union select unnest(array['public.tasks'::regclass::oid,'public.projects'::regclass::oid,'public.sections'::regclass::oid,'public.project_collaborators'::regclass::oid]))
  select c.oid,n.nspname,c.relname from locks l join pg_class c on c.oid=l.oid join pg_namespace n on n.oid=c.relnamespace order by c.oid
 loop execute format('lock table %I.%I in share row exclusive mode',relation.nspname,relation.relname);end loop;
 perform taskfold_private.require_workflow_actor();
 for name in select jsonb_object_keys(members) loop
  target:=('public.'||name)::regclass;id_type:=case when name='view_orders' then 'text' else 'uuid' end;
  select array_agg(attname::text) into columns from pg_attribute where attrelid=target and attnum>0 and not attisdropped;
  if exists(select 1 from jsonb_array_elements(_body->'items') x where x->>'table'=name and (x->'base')-columns<>'{}'::jsonb) then
   raise exception using errcode='22023',message='Review this workflow record format';end if;
  defaults:='{}';
  for col in select a.attname,pg_get_expr(d.adbin,d.adrelid) expr from pg_attribute a join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
   where a.attrelid=target and a.attnum>0 and not a.attisdropped and a.attname<>all(array['created_at','updated_at'])
  loop
   execute 'select jsonb_build_object($1,to_jsonb(('||col.expr||')))' into value using col.attname;defaults:=defaults||value;
  end loop;
  project_expr:=case when name='projects' then 't.id' when name in('tasks','sections') then 't.project_id' else 'null::uuid' end;
  -- Ownership alone cannot recover access to a revoked shared project.
  -- Match the deployed personal SELECT/DELETE access predicate, while keeping
  -- full-schema team custody exclusions when those services are installed.
  personal_expr:=case when name='tasks' then '(t.project_id is null or public.has_project_access($4,t.project_id))'
                      when name='sections' then 'public.has_project_access($4,t.project_id)' else 'true' end;
  if to_regprocedure('taskfold_private.is_team_content_project(uuid)') is not null then
   personal_expr:=personal_expr||format(' and not taskfold_private.is_team_content_project(%s)',project_expr);
  end if;
  if to_regclass('taskfold_private.team_project_identities') is not null then
   personal_expr:=personal_expr||format(' and not exists(select 1 from taskfold_private.team_project_identities p where p.project_id=%s)',project_expr);
  end if;
  if name='tasks' and to_regprocedure('taskfold_private.is_team_content_task(uuid)') is not null then
   personal_expr:=personal_expr||' and not taskfold_private.is_team_content_task(t.id)';
  end if;
  personal_expr:='('||personal_expr||')';
  execute format($q$
   with input as materialized(select x->>'id' id,x->'base' base from jsonb_array_elements($1->'items') x where x->>'table'=$2),
   compared as (
    select t.id is not null present,%s personal,to_jsonb(t) current_row,
     to_jsonb(jsonb_populate_record(null::%s,$3||i.base)) expected_row,
     array(select k from unnest(array['created_at','updated_at']) k where not (i.base ? k)) omitted
    from input i left join %s t on t.id=i.id::%s and t.user_id=$4
   )
   select coalesce(bool_or(not present or not coalesce(personal,false) or (current_row-omitted) is distinct from (expected_row-omitted)),true),
    coalesce(jsonb_agg(jsonb_build_object('table',$2,'row',current_row)) filter(where present and personal),'[]') from compared
  $q$,personal_expr,target,target,id_type) into part_refused,part_rows using _body,name,defaults,actor;
  refused:=refused or part_refused;rows:=rows||part_rows;
  -- One join per FK relation for all targets, with typed keys that can use an
  -- index. A compact membership object replaces repeated full-payload scans.
  for fk in select c.*,n.nspname,r.relname,a.attname,format_type(a.atttypid,a.atttypmod) column_type from pg_constraint c
   join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace
   join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1] where c.contype='f' and c.confrelid=target
  loop
   if fk.nspname='public' and fk.relname in('task_assignment_provenance','task_reminder_jobs') then continue;end if;
   if cardinality(fk.conkey)<>1 then refused:=true;continue;end if;
   execute format($q$select exists(select 1 from %I.%I dep join jsonb_object_keys($1->$2) ids(id) on dep.%I=ids.id::%s
    where not coalesce($3='public' and ($1->$4->>(to_jsonb(dep)->>'id'))=(to_jsonb(dep)->>'user_id'),false))$q$,fk.nspname,fk.relname,fk.attname,fk.column_type)
    into affected using members,name,fk.nspname,fk.relname;
   refused:=refused or affected;
  end loop;
 end loop;
 for link in select * from (values('projects','parent_id','projects'),('sections','project_id','projects'),('tasks','project_id','projects'),('tasks','section_id','sections'),('tasks','recurrence_parent_id','tasks')) v(source,col,target) loop
  if not (members ? link.target) then continue;end if;
  execute format($q$select exists(select 1 from public.%I dep join jsonb_object_keys($1->$2) ids(id) on dep.%I=ids.id::uuid
   where ($1->$3->>(dep.id::text)) is distinct from dep.user_id::text)$q$,link.source,link.col)
   into affected using members,link.target,link.source;
  refused:=refused or affected;
 end loop;
 if members ? 'labels' and exists(select 1 from public.tasks t
  where (members->'tasks'->>(t.id::text)) is distinct from t.user_id::text
  and exists(select 1 from jsonb_path_query(to_jsonb(t),'$.**.labels[*]') label where members->'labels' ? (label#>>'{}'))) then refused:=true;end if;
 if not refused then
  foreach name in array array['view_orders','tasks','labels','sections','projects'] loop
   if not (members ? name) then continue;end if;
   execute format('delete from public.%I t using jsonb_object_keys($1->$2) ids(id) where t.id=ids.id::%s and t.user_id=$3',name,case when name='view_orders' then 'text' else 'uuid' end) using members,name,actor;
  end loop;
  rows:='[]';
 end if;
 result:=jsonb_build_object('id',lower(_request::text),'applied',not refused,'rows',rows);
 insert into taskfold_private.private_workflow_undos(account_id,request_id,fingerprint,result)
 values(actor,_request,fingerprint,result||jsonb_build_object('rows','[]'::jsonb)) on conflict(account_id,request_id) do nothing;
 return result;
end$$;

revoke all on function taskfold_private.undo_private_workflow(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.undo_private_workflow(uuid,jsonb) to authenticated;
create or replace function public.taskfold_undo_private_workflow(_request uuid,_body jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from pg_catalog.pg_proc where oid=to_regprocedure('taskfold_private.undo_private_workflow(uuid,jsonb)')
  and strpos(prosrc,'TASKFOLD_PERSONAL_WORKFLOW_UNDO_V1')>0) then
  raise exception using errcode='PT503',message='Workflow Undo needs a service update. Your work is unchanged';
 end if;
 return taskfold_private.undo_private_workflow(_request,_body);
end$$;
revoke all on function public.taskfold_undo_private_workflow(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_undo_private_workflow(uuid,jsonb) to authenticated;

create or replace function public.taskfold_workflow_undo_capabilities() returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare actor uuid; supported boolean;
begin
 actor:=taskfold_private.require_workflow_actor();
 select exists(select 1 from pg_catalog.pg_proc where oid=to_regprocedure('taskfold_private.undo_private_workflow(uuid,jsonb)')
  and strpos(prosrc,'TASKFOLD_PERSONAL_WORKFLOW_UNDO_V1')>0) into supported;
 return jsonb_build_object('protocol',1,'account',actor,'undo_protocol',case when supported then 1 else 0 end,'bulk_protocol',case when supported then 1 else 0 end);
end$$;
revoke all on function public.taskfold_workflow_undo_capabilities() from public,anon,authenticated,service_role;
grant execute on function public.taskfold_workflow_undo_capabilities() to authenticated;
notify pgrst,'reload schema';
