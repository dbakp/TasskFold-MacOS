-- Keep the existing actor, receipt and all-or-nothing contract. Work is grouped
-- by table: catalog/default work and dependency scans do not repeat per record.
create or replace function taskfold_private.undo_private_workflow(_request uuid,_body jsonb) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid(); fingerprint text; prior taskfold_private.private_workflow_undos;
 name text; target regclass; id_type text; members jsonb; columns text[]; defaults jsonb; value jsonb;
 col record; relation record; fk record; link record; affected boolean; part_refused boolean;
 refused boolean:=false; rows jsonb:='[]'; part_rows jsonb; result jsonb; project_expr text; personal_expr text;
begin
 perform taskfold_private.team_actor();
 if _request is null or jsonb_typeof(_body) is distinct from 'object' or octet_length(_body::text)>16800000
  or _body->>'user_id' is distinct from actor::text or jsonb_typeof(_body->'items') is distinct from 'array'
  or jsonb_array_length(_body->'items')<1 then raise exception using errcode='22023',message='Reopen this workflow Undo';end if;
 fingerprint:=encode(sha256(convert_to(_body::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('private-workflow-undo:'||actor::text,20261026));
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
 select jsonb_object_agg(table_name,ids) into members from (
  select x->>'table' table_name,jsonb_object_agg(x->>'id',x->'base'->>'user_id') ids from jsonb_array_elements(_body->'items') x group by x->>'table'
 ) groups;
 -- Stable-order locks preserve the original fence against incoming FK/logical
 -- references, including RLS-hidden rows and legacy columns without a FK.
 for relation in
  with targets as(select ('public.'||k)::regclass::oid oid from jsonb_object_keys(members) k),
  locks as(select oid from targets union select conrelid from pg_constraint where contype='f' and confrelid in(select oid from targets)
   union select unnest(array['public.tasks'::regclass::oid,'public.projects'::regclass::oid,'public.sections'::regclass::oid]))
  select c.oid,n.nspname,c.relname from locks l join pg_class c on c.oid=l.oid join pg_namespace n on n.oid=c.relnamespace order by c.oid
 loop execute format('lock table %I.%I in share row exclusive mode',relation.nspname,relation.relname);end loop;
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
  personal_expr:=format('(not taskfold_private.is_team_content_project(%s) and not exists(select 1 from taskfold_private.team_project_identities p where p.project_id=%s)%s)',project_expr,project_expr,case when name='tasks' then ' and not taskfold_private.is_team_content_task(t.id)' else '' end);
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
-- Existing EXECUTE ACLs, invoker wrapper and private receipt RLS remain intact.

-- Legacy small-run clients retain protocol 1; larger queues negotiate this additive capability.
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
 result=jsonb_build_object('personal_workflow_undo_bulk_protocol',1,'personal_workflow_undo_protocol',1,'personal_task_types_protocol',1,'task_type_lifecycle_protocol',case when reads and edits and enabled then 1 else 0 end,'task_types_protocol',case when reads and edits and enabled and (select native_task_types_enabled from taskfold_private.team_project_config where singleton) then 1 else 0 end,'workspace_boundary_protocol',1,'account',a,'native_team_reads_enabled',coalesce(reads,false),'setup_paused',not coalesce(enabled,false),'projects',projects,'teams',teams);
 select encode(extensions.hmac(convert_to(result::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 result=result||jsonb_build_object('token',token);
 if octet_length(result::text)>3000000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 return result;
end$$;
