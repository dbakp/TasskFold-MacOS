-- Reviewed rows, not a template document, are the write authority. Source
-- definitions supply provenance and stale-review checks, never target permission.
create table taskfold_private.workflow_run_config(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into taskfold_private.workflow_run_config default values;
create table taskfold_private.workflow_runs(
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 request_id uuid not null,actor_id uuid references auth.users(id) on delete set null,
 fingerprint text not null,result jsonb not null,created_at timestamptz not null default clock_timestamp(),primary key(team_id,request_id)
);
create index workflow_runs_actor on taskfold_private.workflow_runs(actor_id) where actor_id is not null;
alter table taskfold_private.workflow_run_config enable row level security;
alter table taskfold_private.workflow_runs enable row level security;
revoke all on taskfold_private.workflow_run_config,taskfold_private.workflow_runs from public,anon,authenticated,service_role;
create function taskfold_private.workflow_runs_purge() returns trigger language plpgsql security definer set search_path='' as $$begin
 delete from taskfold_private.workflow_runs where team_id=new.id;return new;end$$;
create trigger workflow_runs_purge after update of state on taskfold_private.teams for each row when(new.state='deleted' and old.state is distinct from new.state) execute function taskfold_private.workflow_runs_purge();
revoke all on function taskfold_private.workflow_runs_purge() from public,anon,authenticated,service_role;

create function taskfold_private.workflow_source_task(v jsonb,projects text[],sections jsonb,depth integer default 0) returns void
language plpgsql stable security invoker set search_path='' as $$
declare k text;x jsonb;begin
 if jsonb_typeof(v) is distinct from 'object' or depth>10 or exists(select 1 from jsonb_object_keys(v) e where e<>all(array['id','title','description','priority','project_id','section_id','duration_minutes','labels','subtasks','is_recurring','recurrence_pattern','due_time','time_zone','planned_offset','deadline_offset','repeat_start_offset','repeat_end_offset']))
  or jsonb_typeof(v->'id') is distinct from 'string' or coalesce(v->>'id','')='' or jsonb_typeof(v->'title') is distinct from 'string' or char_length(btrim(v->>'title')) not between 1 and 10000
  or jsonb_typeof(v->'labels') is distinct from 'array' or jsonb_typeof(v->'subtasks') is distinct from 'array' then raise exception using errcode='22023',message='Use a supported template task';end if;
 foreach k in array array['description','project_id','section_id','due_time','time_zone'] loop
  if v ? k and v->k<>'null'::jsonb and jsonb_typeof(v->k)<>'string' then raise exception using errcode='22023',message='Use supported template text';end if;
 end loop;
 if coalesce(v->>'project_id','')<>'' and not (v->>'project_id')=any(projects) then raise exception using errcode='22023',message='Review template project references';end if;
 if coalesce(v->>'section_id','')<>'' and sections->>(v->>'section_id') is distinct from v->>'project_id' then raise exception using errcode='22023',message='Review template section references';end if;
 foreach k in array array['priority','duration_minutes','planned_offset','deadline_offset','repeat_start_offset','repeat_end_offset'] loop
  if v ? k and not(k='duration_minutes' and v->k='null'::jsonb) then
   if jsonb_typeof(v->k)<>'number' then raise exception using errcode='22023',message='Use supported template numbers';end if;
   if (v->>k)::numeric<>trunc((v->>k)::numeric) or (k='priority' and (v->>k)::numeric not between 1 and 4) or (k='duration_minutes' and (v->>k)::numeric not between 1 and 10080)
    or (k like '%offset' and abs((v->>k)::numeric)>365000) then raise exception using errcode='22023',message='Use supported template ranges';end if;
  end if;
 end loop;
 if v ? 'is_recurring' and jsonb_typeof(v->'is_recurring')<>'boolean' then raise exception using errcode='22023',message='Use a supported template repeat rule';end if;
 if v->'is_recurring'='true'::jsonb and not coalesce(taskfold_private.automation_recurrence_valid(v->'recurrence_pattern'),false) then raise exception using errcode='22023',message='Use a supported template repeat rule';end if;
 if coalesce(v->>'due_time','')<>'' and (v->>'due_time')!~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9](\.[0-9]+)?)?$' then raise exception using errcode='22023',message='Use a supported template time';end if;
 if coalesce(v->>'time_zone','')<>'' and not exists(select 1 from pg_catalog.pg_timezone_names where name=v->>'time_zone') then raise exception using errcode='22023',message='Use a supported template time zone';end if;
 for x in select value from jsonb_array_elements(v->'labels') loop
  if jsonb_typeof(x) is distinct from 'object' or jsonb_typeof(x->'name') is distinct from 'string' or coalesce(x->>'name','')='' then raise exception using errcode='22023',message='Use portable template labels';end if;
 end loop;
 for x in select value from jsonb_array_elements(v->'subtasks') loop perform taskfold_private.workflow_source_task(x,projects,sections,depth+1);end loop;
end$$;
revoke all on function taskfold_private.workflow_source_task(jsonb,text[],jsonb,integer) from public,anon,authenticated,service_role;
create function taskfold_private.workflow_source(doc jsonb) returns void
language plpgsql stable security invoker set search_path='' as $$
declare ids text[]:='{}';section_ids text[]:='{}';task_ids text[]:='{}';parents jsonb:='{}';section_map jsonb:='{}';v jsonb;k text;id text;cursor_id text;seen text[];begin
 if jsonb_typeof(doc) is distinct from 'object' or doc->'version' is distinct from '1'::jsonb or coalesce(doc->>'kind','') not in('project','section','task') or exists(select 1 from jsonb_object_keys(doc) e where e<>all(array['version','kind','projects','sections','tasks'])) then raise exception using errcode='22023',message='Use a supported template definition';end if;
 foreach k in array array['projects','sections','tasks'] loop
  if jsonb_typeof(doc->k) is distinct from 'array' or jsonb_array_length(doc->k)>(case when k='projects' then 1000 else 5000 end) then raise exception using errcode='22023',message='Use bounded template contents';end if;
 end loop;
 for v in select value from jsonb_array_elements(doc->'projects') loop
  if jsonb_typeof(v) is distinct from 'object' or exists(select 1 from jsonb_object_keys(v) e where e<>all(array['id','name','description','color','parent_id','order_index'])) then raise exception using errcode='22023',message='Use a supported template project';end if;
  foreach k in array array['id','name','description','color','parent_id'] loop
   if v ? k and v->k<>'null'::jsonb and jsonb_typeof(v->k)<>'string' then raise exception using errcode='22023',message='Use supported project text';end if;
  end loop;
  id=v->>'id';if coalesce(id,'')='' or id=any(ids) or coalesce(btrim(v->>'name'),'')='' then raise exception using errcode='22023',message='Use unique named template projects';end if;
  ids=array_append(ids,id);parents=parents||jsonb_build_object(id,v->'parent_id');
 end loop;
 foreach id in array ids loop
  cursor_id=id;seen='{}';
  while coalesce(cursor_id,'')<>'' loop
   if cursor_id=any(seen) or cardinality(seen)>=20 or not cursor_id=any(ids) then raise exception using errcode='22023',message='Use a bounded template hierarchy';end if;
   seen=array_append(seen,cursor_id);cursor_id=parents->>cursor_id;
  end loop;
 end loop;
 for v in select value from jsonb_array_elements(doc->'sections') loop
  if jsonb_typeof(v) is distinct from 'object' or exists(select 1 from jsonb_object_keys(v) e where e<>all(array['id','name','project_id','order_index'])) then raise exception using errcode='22023',message='Use a supported template section';end if;
  id=v->>'id';
  if jsonb_typeof(v->'id') is distinct from 'string' or coalesce(id,'')='' or id=any(section_ids) or jsonb_typeof(v->'name') is distinct from 'string' or coalesce(btrim(v->>'name'),'')='' or jsonb_typeof(v->'project_id') is distinct from 'string' or not coalesce(v->>'project_id','')=any(ids) then raise exception using errcode='22023',message='Use named template sections in their projects';end if;
  section_ids=array_append(section_ids,id);section_map=section_map||jsonb_build_object(id,v->>'project_id');
 end loop;
 for v in select value from jsonb_array_elements(doc->'projects') union all select value from jsonb_array_elements(doc->'sections') loop
  if v ? 'order_index' then
   if jsonb_typeof(v->'order_index')<>'number' then raise exception using errcode='22023',message='Use whole template ordering';end if;
   if (v->>'order_index')::numeric not between 0 and 2147483647 or (v->>'order_index')::numeric<>trunc((v->>'order_index')::numeric) then raise exception using errcode='22023',message='Use bounded template ordering';end if;
  end if;
 end loop;
 if (doc->>'kind'='project' and (select count(*) from jsonb_array_elements(doc->'projects') e where coalesce(e->>'parent_id','')='')<>1)
  or (doc->>'kind'='section' and (cardinality(ids)<>1 or cardinality(section_ids)<>1))
  or (doc->>'kind'='task' and (jsonb_array_length(doc->'tasks')<>1 or cardinality(ids)>1 or cardinality(section_ids)<>0)) then raise exception using errcode='22023',message='Use a complete template structure';end if;
 for v in select value from jsonb_array_elements(doc->'tasks') loop
  perform taskfold_private.workflow_source_task(v,ids,section_map);
  id=v->>'id';if id=any(task_ids) then raise exception using errcode='22023',message='Use unique template tasks';end if;task_ids=array_append(task_ids,id);
 end loop;
end$$;
revoke all on function taskfold_private.workflow_source(jsonb) from public,anon,authenticated,service_role;

create function taskfold_private.workflow_run(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid();t uuid;q uuid;st uuid;source_id uuid;p uuid;parent uuid;folder uuid;id uuid;generation uuid;nonce uuid;v jsonb;src jsonb;dest jsonb;doc jsonb;current_doc jsonb;source_revision bigint;expected_revision bigint;
 team taskfold_private.teams;binding taskfold_private.team_content_projects;prior taskfold_private.workflow_runs;
 fingerprint text;role text;mode text;kind text;name text;visibility text;issued text;group_id text;section uuid;old_ids jsonb;new_ids jsonb;updated integer;charge integer;before_usage integer;
 project_ids uuid[]:='{}';section_ids uuid[]:='{}';task_ids uuid[]:='{}';order_keys text[]:='{}';ordered_ids uuid[]:='{}';result jsonb;task_results jsonb:='[]';child_request jsonb;reply jsonb;source_kind text;today date:=(clock_timestamp() at time zone 'UTC')::date;
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>4200000
  or not b ?& array['team_id','request_id','team_revision','source','destination','projects','sections','tasks','orders']
  or exists(select 1 from jsonb_object_keys(b) k where k<>all(array['team_id','request_id','team_revision','source','destination','projects','sections','tasks','orders'])) then raise exception using errcode='22023',message='Review a complete bounded workflow';end if;
 t=taskfold_private.team_uuid(b,'team_id');q=taskfold_private.team_uuid(b,'request_id');src=b->'source';dest=b->'destination';
 perform taskfold_private.team_fields(src-'document',array['kind','id','team_id','revision']);
 source_id=taskfold_private.team_uuid(src,'id');source_kind=src->>'kind';doc=src->'document';
 if source_kind not in('personal','shared') or source_kind is null or jsonb_typeof(doc) is distinct from 'object' or doc->'version' is distinct from '1'::jsonb
  or coalesce(doc->>'kind','') not in('project','section','task') or not doc ?& array['projects','sections','tasks'] or octet_length(doc::text)>2000000 then raise exception using errcode='22023',message='Use a supported reviewed workflow';end if;
 perform taskfold_private.workflow_source(doc);
 kind=doc->>'kind';
 if source_kind='shared' then st=taskfold_private.team_uuid(src,'team_id');
 elsif src->'team_id'<>'null'::jsonb or src->'revision'<>'null'::jsonb then raise exception using errcode='22023',message='Review a private template source';end if;
 perform taskfold_private.team_fields(dest,array['mode','project_id','revision','visibility','folder_id','parent_id','parent_revision']);
 mode=dest->>'mode';
 if mode='project' then
  p=taskfold_private.team_uuid(dest,'project_id');
  if kind='project' or dest->'visibility'<>'null'::jsonb or dest->'folder_id'<>'null'::jsonb or dest->'parent_id'<>'null'::jsonb or dest->'parent_revision'<>'null'::jsonb then raise exception using errcode='22023',message='Review the destination project';end if;
 elsif mode='new' then
  if kind<>'project' or dest->'project_id'<>'null'::jsonb or dest->'revision'<>'null'::jsonb or coalesce(dest->>'visibility','') not in('team','private') then raise exception using errcode='22023',message='Review the new project audience';end if;
  visibility=dest->>'visibility';
  if dest->'parent_id'<>'null'::jsonb then parent=taskfold_private.team_uuid(dest,'parent_id');end if;
  if dest->'folder_id'<>'null'::jsonb then folder=taskfold_private.team_uuid(dest,'folder_id');end if;
  if parent is null and dest->'parent_revision'<>'null'::jsonb then raise exception using errcode='22023',message='Review the parent project';end if;
 else raise exception using errcode='22023',message='Choose a workflow destination';end if;
 foreach name in array array['projects','sections','tasks','orders'] loop
  if jsonb_typeof(b->name) is distinct from 'array' or jsonb_array_length(b->name)>5000 then raise exception using errcode='22023',message='Choose a bounded workflow';end if;
 end loop;
 if jsonb_array_length(b->'projects')>1000 or (mode='project' and b->'projects'<>'[]'::jsonb) or (mode='new' and jsonb_array_length(b->'projects')=0)
  or jsonb_array_length(b->'tasks')<>jsonb_array_length(doc->'tasks') or jsonb_array_length(b->'sections')<>jsonb_array_length(doc->'sections')
  or (mode='new' and jsonb_array_length(b->'projects')<>jsonb_array_length(doc->'projects')) then raise exception using errcode='22023',message='Review the entire workflow';end if;
 charge=jsonb_array_length(b->'projects')+jsonb_array_length(b->'sections')+jsonb_array_length(b->'tasks');
 if charge not between 1 and 2000 then raise exception using errcode='PT429',message='Choose a smaller workflow';end if;
 -- Template runs exclude assignments/history. Reject them before holding team
 -- locks, so nested lifecycle calls never acquire another user's Auth lock late.
 for v in select value from jsonb_array_elements(b->'tasks') loop
  for child_request in select v union all select value from jsonb_each(taskfold_private.automation_tree_index(coalesce(v->'subtasks','[]'))) loop
   if coalesce(child_request->'assigned_to','null')<>'null'::jsonb or coalesce(child_request->'completed','false')<>'false'::jsonb
    or coalesce(child_request->'completed_at','null')<>'null'::jsonb or coalesce(child_request->'comments','[]')<>'[]'::jsonb or coalesce(child_request->'attachments','[]')<>'[]'::jsonb then
    raise exception using errcode='22023',message='Use a fresh workflow without assignments or history';end if;
  end loop;
 end loop;
 -- Auth locks precede all team locks; cross-team source/destination locks sort.
 perform 1 from taskfold_private.teams where teams.id in(t,st) order by teams.id for update;
 perform taskfold_private.team_actor();
 select * into team from taskfold_private.teams where teams.id=t;
 role=taskfold_private.team_role(t,a);
 if team.id is null or team.state='deleted' or role is null then raise exception using errcode='PT404',message='Destination is unavailable';end if;
 if team.state<>'active' then raise exception using errcode='PT409',message='Reopen the destination team';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared workflows are not enabled';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared workflows are not enabled';end if;
 perform 1 from taskfold_private.workflow_run_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared workflows are not enabled';end if;
 if source_kind='shared' then
  if coalesce(taskfold_private.team_role(st,a),'') not in('owner','admin','member') or not exists(select 1 from taskfold_private.teams where teams.id=st and state<>'deleted') then raise exception using errcode='PT404',message='Source is unavailable';end if;
  perform 1 from taskfold_private.team_template_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Shared templates are not enabled';end if;
 end if;
 if mode='project' and (coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=t))
  or mode='new' and role='guest' then raise exception using errcode='42501',message='Editing access is required';end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if fingerprint is null then raise exception using errcode='PT503',message='Shared workflows are unavailable';end if;
 select * into prior from taskfold_private.workflow_runs where team_id=t and request_id=q;
 if found then
  if prior.actor_id is distinct from a or prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This workflow request identity is already used';end if;
  -- Recheck current access even on replay; never recreate removed content.
  for v in select value from jsonb_array_elements(prior.result->'projects') loop
   if coalesce(taskfold_private.team_project_role(a,(v#>>'{}')::uuid),'') not in('manager','editor') then raise exception using errcode='42501',message='Workflow access changed';end if;
  end loop;
  return prior.result||jsonb_build_object('replayed',true);
 end if;
 if jsonb_typeof(b->'team_revision') is distinct from 'number' or b->'team_revision'<>to_jsonb(team.revision) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the current team';end if;
 if source_kind='personal' then
  select document into current_doc from public.project_templates where project_templates.id=source_id and user_id=a for share;
 else
  select document,revision into current_doc,source_revision from taskfold_private.team_templates where team_id=st and team_templates.id=source_id for share;
  if src->'revision' is distinct from to_jsonb(source_revision) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the current source template';end if;
 end if;
 if current_doc is null or current_doc is distinct from doc then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the current source template';end if;
 if team.usage_day=today and team.day_operations+charge>2000 then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 before_usage=case when team.usage_day=today then team.day_operations else 0 end;
 if mode='project' then
  select * into binding from taskfold_private.team_content_projects where project_id=p and team_id=t for update;
  if dest->'revision' is distinct from to_jsonb(binding.revision) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the destination project';end if;
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for update;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Destination is archived';end if;
 elsif parent is not null then
  select * into binding from taskfold_private.team_content_projects where project_id=parent and team_id=t for update;
  if binding.project_id is null or dest->'parent_revision' is distinct from to_jsonb(binding.revision) or coalesce(taskfold_private.team_project_role(a,parent),'')<>'manager' then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the parent project';end if;
  perform 1 from public.projects where projects.id=parent and not is_archived and not ancestor_archived for update;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Parent is archived';end if;
 end if;
 if folder is not null and not exists(select 1 from taskfold_private.team_folders where team_id=t and team_folders.id=folder) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the folder';end if;
 if (select count(*) from taskfold_private.team_content_projects where team_id=t)+jsonb_array_length(b->'projects')>1000 then raise exception using errcode='54000',message='Team project limit reached';end if;
 -- Serialize every fresh task ID before any task write, matching native inserts.
 for id in select taskfold_private.team_uuid(value,'id') from jsonb_array_elements(b->'tasks') order by 1 loop
  perform pg_advisory_xact_lock(hashtextextended(id::text,78137));
  if exists(select 1 from public.tasks where tasks.id=cmd.id) or exists(select 1 from taskfold_private.task_generations where task_id=cmd.id)
   or exists(select 1 from taskfold_private.team_content_tasks where task_id=cmd.id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Use fresh workflow task identities';end if;
 end loop;
 issued=to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
 -- Existing private controllers perform full normal admission. The temporary
 -- operation scope permits only this function's checked section/hierarchy writes.
 insert into taskfold_private.team_content_operations values(txid_current(),t);
 for v in select value from jsonb_array_elements(b->'projects') loop
  perform taskfold_private.team_fields(v-'description',array['id','user_id','name'],array['color','parent_id','order_index','is_archived','team_id','visibility']);
  id=taskfold_private.team_uuid(v,'id');
  if v->'user_id'<>to_jsonb(a) or (v ? 'team_id' and v->'team_id'<>to_jsonb(t)) or (v ? 'visibility' and v->>'visibility'<>visibility)
   or coalesce(v->'is_archived','false')<>'false'::jsonb or id=any(project_ids) then raise exception using errcode='22023',message='Use fresh projects and the reviewed audience';end if;
  if v->'parent_id' is not null and v->'parent_id'<>'null'::jsonb and not taskfold_private.team_uuid(v,'parent_id')=any(project_ids) then raise exception using errcode='22023',message='Review a parent-first workflow';end if;
  if exists(select 1 from public.projects where projects.id=cmd.id) or exists(select 1 from taskfold_private.team_project_identities where project_id=cmd.id) or exists(select 1 from taskfold_private.project_content_epochs where table_name='projects' and row_id=cmd.id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Use fresh project identities';end if;
  foreach name in array array['description','color'] loop
   if v ? name and v->name<>'null'::jsonb and jsonb_typeof(v->name)<>'string' then raise exception using errcode='22023',message='Use supported project text';end if;
  end loop;
  if v ? 'order_index' and (jsonb_typeof(v->'order_index')<>'number' or (v->>'order_index')::numeric not between 0 and 2147483647 or (v->>'order_index')::numeric<>trunc((v->>'order_index')::numeric)) then raise exception using errcode='22023',message='Use whole project ordering';end if;
  nonce=md5(q::text||':project:'||id::text)::uuid;
  reply=taskfold_private.team_project_command('create',jsonb_build_object('team_id',t,'project_id',id,'request_id',nonce,'issued_at',issued,'team_revision',team.revision,'name',v->>'name','visibility',visibility,'folder_id',folder));
  update public.projects set description=v->>'description',color=v->>'color',order_index=coalesce((v->>'order_index')::integer,0),parent_id=coalesce((v->>'parent_id')::uuid,parent) where projects.id=cmd.id;
  project_ids=array_append(project_ids,id);
 end loop;
 if mode='new' and (select count(*) from jsonb_array_elements(b->'projects') z where z->'parent_id' is null or z->'parent_id'='null'::jsonb)<>1 then raise exception using errcode='22023',message='Review one complete workflow branch';end if;
 for v in select value from jsonb_array_elements(b->'sections') loop
  perform taskfold_private.team_fields(v,array['id','user_id','name','project_id'],array['order_index']);
  id=taskfold_private.team_uuid(v,'id');name=taskfold_private.team_name(v);
  if v->'user_id'<>to_jsonb(a) or id=any(section_ids) or (mode='project' and v->'project_id'<>to_jsonb(p)) or (mode='new' and not taskfold_private.team_uuid(v,'project_id')=any(project_ids)) then raise exception using errcode='22023',message='Review each workflow section';end if;
  if (exists(select 1 from public.sections where sections.id=cmd.id) or exists(select 1 from taskfold_private.project_content_epochs where table_name='sections' and row_id=cmd.id)) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Use fresh section identities';end if;
  if v ? 'order_index' and (jsonb_typeof(v->'order_index')<>'number' or (v->>'order_index')::numeric not between 0 and 2147483647 or (v->>'order_index')::numeric<>trunc((v->>'order_index')::numeric)) then raise exception using errcode='22023',message='Use whole section ordering';end if;
  insert into public.sections(id,user_id,project_id,name,order_index) values(id,a,taskfold_private.team_uuid(v,'project_id'),name,
   case when mode='project' then (select coalesce(max(order_index),-1)+1 from public.sections where project_id=p) else coalesce((v->>'order_index')::integer,0) end);
  section_ids=array_append(section_ids,id);
 end loop;
 for v in select value from jsonb_array_elements(b->'tasks') loop
  id=taskfold_private.team_uuid(v,'id');generation=taskfold_private.team_uuid(v,'task_generation');
  if id=any(task_ids) or v->'completed' is distinct from 'false'::jsonb or (mode='project' and v->'project_id'<>to_jsonb(p)) or (mode='new' and not taskfold_private.team_uuid(v,'project_id')=any(project_ids)) then raise exception using errcode='22023',message='Review fresh incomplete workflow tasks';end if;
  if v->'section_id' is not null and v->'section_id'<>'null'::jsonb and not taskfold_private.team_uuid(v,'section_id')=any(section_ids) then raise exception using errcode='22023',message='Use only the reviewed new sections';end if;
  nonce=md5(q::text||':task:'||id::text)::uuid;
  child_request=jsonb_build_object('team_id',t,'project_id',v->'project_id','task_id',id,'request_id',nonce,'task_generation',generation,'record',v);
  reply=taskfold_private.team_task_lifecycle('create',child_request);
  task_ids=array_append(task_ids,id);task_results=task_results||jsonb_build_array(jsonb_build_object('id',id,'generation',generation,'project_id',v->'project_id'));
 end loop;
 for v in select value from jsonb_array_elements(b->'orders') loop
  perform taskfold_private.team_fields(v-array['base_ids','task_ids'],array['project_id','section_id']);
  id=taskfold_private.team_uuid(v,'project_id');section=null;
  if v->'section_id'<>'null'::jsonb then section=taskfold_private.team_uuid(v,'section_id');end if;
  group_id='group:'||id::text||':'||coalesce(section::text,'none');
  if group_id=any(order_keys) or jsonb_typeof(v->'task_ids') is distinct from 'array' or jsonb_typeof(v->'base_ids') is distinct from 'array' or jsonb_array_length(v->'base_ids')>10000 or jsonb_array_length(v->'task_ids')=0 then raise exception using errcode='22023',message='Review complete workflow ordering';end if;
  if exists(select 1 from jsonb_array_elements(v->'base_ids') e where jsonb_typeof(e)<>'string' or (e#>>'{}')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
   or (select count(distinct e) from jsonb_array_elements(v->'base_ids') e)<>jsonb_array_length(v->'base_ids')
   or exists(select 1 from jsonb_array_elements_text(v->'base_ids') e where e::uuid=any(task_ids)) then raise exception using errcode='22023',message='Review the existing list order and fresh task identities';end if;
  order_keys=array_append(order_keys,group_id);
  for child_request in select value from jsonb_array_elements(v->'task_ids') loop
   if jsonb_typeof(child_request)<>'string' then raise exception using errcode='22023',message='Use task order identities';end if;
   nonce=taskfold_private.team_uuid(jsonb_build_object('id',child_request),'id');
   if nonce=any(ordered_ids) or not nonce=any(task_ids) or not exists(select 1 from public.tasks where tasks.id=nonce and project_id=cmd.id and section_id is not distinct from section) then raise exception using errcode='22023',message='Review every new task once in its group';end if;
   ordered_ids=array_append(ordered_ids,nonce);
  end loop;
  perform pg_advisory_xact_lock(hashtextextended(a::text||':'||group_id,20261025));
  select ids into old_ids from public.view_orders where user_id=a and view_orders.id=group_id for update;
  if coalesce(old_ids,'[]') is distinct from v->'base_ids' then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Your list order changed; review it again';end if;
  new_ids=(v->'base_ids')||(v->'task_ids');
  insert into public.view_orders(user_id,id,ids) values(a,group_id,new_ids) on conflict on constraint view_orders_pkey do update set ids=excluded.ids where view_orders.ids is not distinct from v->'base_ids';
  get diagnostics updated=row_count;
  if updated<>1 then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Your list order changed; review it again';end if;
 end loop;
 if cardinality(ordered_ids)<>cardinality(task_ids) then raise exception using errcode='22023',message='Include the complete workflow order';end if;
 delete from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t;
 update taskfold_private.teams set usage_day=today,day_operations=before_usage+charge where teams.id=t;
 result=jsonb_build_object('run_protocol',1,'account',a,'team_id',t,'request_id',q,'projects',to_jsonb(project_ids),'sections',to_jsonb(section_ids),'tasks',task_results,'replayed',false);
 insert into taskfold_private.workflow_runs(team_id,request_id,actor_id,fingerprint,result) values(t,q,a,fingerprint,result);
 return result;
end$$;
revoke all on function taskfold_private.workflow_run(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.workflow_run(jsonb) to authenticated;
create function public.taskfold_team_workflow_run(_body jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select taskfold_private.workflow_run(_body)$$;
revoke all on function public.taskfold_team_workflow_run(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_team_workflow_run(jsonb) to authenticated;
